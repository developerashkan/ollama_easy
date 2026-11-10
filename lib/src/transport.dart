// HTTP layer: retries, timeouts, aborts, interceptors and NDJSON decoding.
// Internal; not exported.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cancel_token.dart';
import 'exceptions.dart';
import 'interceptors.dart';
import 'json_utils.dart';
import 'retry.dart';

/// Settings shared by every request of one client.
class TransportConfig {
  TransportConfig({
    required this.client,
    required this.headers,
    required this.timeout,
    required this.streamIdleTimeout,
    required this.retryPolicy,
    required this.interceptors,
  });

  final http.Client client;
  final Map<String, String> headers;
  final Duration? timeout;
  final Duration? streamIdleTimeout;
  final OllamaRetryPolicy retryPolicy;
  final List<OllamaInterceptor> interceptors;
}

/// A raw HTTP result for endpoints that do not return JSON.
class RawResult {
  const RawResult(this.statusCode, this.headers, this.bytes);
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bytes;
}

class Transport {
  Transport(this.config);

  final TransportConfig config;

  /// Cancelled by [close]; every request listens to it.
  final OllamaCancelToken _closeToken = OllamaCancelToken();

  bool get isClosed => _closeToken.isCancelled;

  void close() => _closeToken.cancel('client closed');

  /// Sends a request and decodes a JSON object response.
  Future<JsonMap> json(
    String method,
    Uri uri,
    String endpoint, {
    JsonMap? body,
    OllamaCancelToken? cancelToken,
    Duration? timeout,
    OllamaRetryPolicy? retryPolicy,
  }) async {
    final result = await raw(
      method,
      uri,
      endpoint,
      body: body,
      cancelToken: cancelToken,
      timeout: timeout,
      retryPolicy: retryPolicy,
    );
    return decodeObject(result.bytes, uri, result.statusCode);
  }

  /// Sends a request and returns the raw status and body.
  ///
  /// When [acceptStatus] returns `true` for a non-2xx status, the response is
  /// returned instead of thrown (used for `HEAD /api/blobs`).
  Future<RawResult> raw(
    String method,
    Uri uri,
    String endpoint, {
    JsonMap? body,
    List<int>? bodyBytes,
    String? contentType,
    OllamaCancelToken? cancelToken,
    Duration? timeout,
    OllamaRetryPolicy? retryPolicy,
    bool Function(int statusCode)? acceptStatus,
  }) async {
    final scope = _Scope(uri, cancelToken, _closeToken);
    final effectiveTimeout = timeout ?? config.timeout;
    try {
      final opened = await _open(
        _Spec(
          method: method,
          uri: uri,
          endpoint: endpoint,
          body: body,
          bodyBytes: bodyBytes,
          contentType: contentType,
          streaming: false,
          retryPolicy: retryPolicy ?? config.retryPolicy,
          acceptStatus: acceptStatus,
          // The whole attempt (headers + body) must finish in time.
          timeout: effectiveTimeout,
        ),
        scope,
      );
      final bytes = await _readAll(opened.response.stream, scope);
      return RawResult(
          opened.response.statusCode, opened.response.headers, bytes);
    } on OllamaException catch (error) {
      if (scope.lastRequest != null && !scope.errorReported) {
        await _notifyError(error, scope.lastRequest!);
      }
      rethrow;
    } finally {
      scope.finish();
    }
  }

  /// Sends a request and decodes an NDJSON response stream.
  ///
  /// The stream is single-subscription and lazy: the request starts when you
  /// listen. Cancelling the subscription aborts the request. A
  /// `{"error": ...}` line becomes an [OllamaStreamException]. When
  /// [requireDone] is set, a stream that ends without a `"done": true` object
  /// fails with [OllamaStreamException].
  Stream<JsonMap> ndjson(
    String method,
    Uri uri,
    String endpoint, {
    required JsonMap body,
    OllamaCancelToken? cancelToken,
    bool requireDone = false,
  }) {
    late final _Scope scope;
    StreamSubscription<JsonMap>? subscription;
    late final StreamController<JsonMap> controller;
    var finished = false;

    Future<void> fail(Object error, [StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      if (error is OllamaException &&
          scope.lastRequest != null &&
          !scope.errorReported) {
        await _notifyError(error, scope.lastRequest!);
      }
      scope.finish();
      controller.addError(error, stackTrace);
      await controller.close();
    }

    controller = StreamController<JsonMap>(
      onListen: () async {
        scope = _Scope(uri, cancelToken, _closeToken);
        final _Opened opened;
        try {
          opened = await _open(
            _Spec(
              method: method,
              uri: uri,
              endpoint: endpoint,
              body: body,
              streaming: true,
              retryPolicy: config.retryPolicy,
              // Only the wait for the first response is bounded here; the
              // body is bounded by the idle timeout.
              timeout: config.timeout,
            ),
            scope,
          );
        } catch (error, stackTrace) {
          await fail(error, stackTrace);
          return;
        }
        if (controller.isClosed || finished) return;
        var sawDone = false;
        final lines =
            _guard(opened.response.stream, scope, config.streamIdleTimeout)
                .transform(utf8.decoder)
                .transform(const LineSplitter());
        subscription = lines
            .map((line) => _decodeLine(line, uri))
            .where(
              (json) {
                if (json == null) return false;
                if (json['done'] == true) sawDone = true;
                return true;
              },
            )
            .cast<JsonMap>()
            .listen(
              controller.add,
              onError: (Object error, StackTrace stackTrace) {
                subscription?.cancel();
                fail(_mapStreamError(error, uri, scope), stackTrace);
              },
              onDone: () {
                if (requireDone && !sawDone) {
                  fail(OllamaStreamException(
                    'The stream ended before the final "done" chunk. '
                    'The connection may have been cut by a proxy.',
                    uri: uri,
                  ));
                  return;
                }
                finished = true;
                scope.finish();
                controller.close();
              },
              cancelOnError: true,
            );
        if (controller.isPaused) subscription!.pause();
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        // Only an early cancel needs work; see the note in _guard about not
        // returning a finished subscription's cancel future.
        if (finished) return null;
        finished = true;
        scope.abort(_AbortReason.unsubscribed);
        scope.finish();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  // ---------------------------------------------------------------------------

  Future<_Opened> _open(_Spec spec, _Scope scope) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final request = OllamaHttpRequest(
        method: spec.method,
        uri: spec.uri,
        endpoint: spec.endpoint,
        headers: {
          ...config.headers,
          if (spec.contentType != null)
            'Content-Type': spec.contentType!
          else if (spec.body != null)
            'Content-Type': 'application/json',
        },
        body: spec.body == null ? null : Map.of(spec.body!),
        bodyBytes: spec.bodyBytes,
        streaming: spec.streaming,
        attempt: attempt,
      );
      scope.lastRequest = request;
      try {
        return await _attempt(request, spec, scope);
      } on OllamaException catch (error) {
        if (scope.isAborted || !spec.retryPolicy.canRetry(error, attempt)) {
          scope.errorReported = true;
          await _notifyError(error, request);
          rethrow;
        }
        scope.disarm();
        await _sleep(spec.retryPolicy.delayFor(attempt, error), scope);
      }
    }
  }

  Future<_Opened> _attempt(
    OllamaHttpRequest request,
    _Spec spec,
    _Scope scope,
  ) async {
    if (scope.isAborted) throw scope.exception();
    for (final interceptor in config.interceptors) {
      await interceptor.onRequest(request);
    }
    if (scope.isAborted) throw scope.exception();
    scope.uri = request.uri;

    final httpRequest = http.AbortableRequest(
      request.method,
      request.uri,
      abortTrigger: scope.trigger,
    )..headers.addAll(request.headers);
    final bytes = request.bodyBytes ??
        (request.body == null ? null : utf8.encode(jsonEncode(request.body)));
    if (bytes != null) httpRequest.bodyBytes = bytes;

    scope.arm(
        spec.timeout, spec.streaming ? 'the first response' : 'the response');
    final stopwatch = Stopwatch()..start();
    final send = config.client.send(httpRequest);
    final Object first;
    try {
      first =
          await Future.any<Object>([send, scope.trigger.then((_) => _aborted)]);
    } catch (error) {
      if (scope.isAborted) throw scope.exception();
      throw _mapError(error, request.uri);
    }
    if (identical(first, _aborted)) {
      // MockClient and custom clients may ignore the abort trigger. Make sure
      // a late response does not leak a connection.
      unawaited(send.then((response) {
        response.stream.listen(null, onError: (_) {}).cancel();
      }, onError: (_) {}));
      throw scope.exception();
    }
    final response = first as http.StreamedResponse;

    final info = OllamaHttpResponse(
      request: request,
      statusCode: response.statusCode,
      headers: response.headers,
      elapsed: stopwatch.elapsed,
    );
    for (final interceptor in config.interceptors) {
      await interceptor.onResponse(info);
    }

    final status = response.statusCode;
    final ok = status >= 200 && status < 300;
    if (!ok && !(spec.acceptStatus?.call(status) ?? false)) {
      final body = await _readAll(response.stream, scope)
          .then((bytes) => utf8.decode(bytes, allowMalformed: true));
      throw OllamaException.fromResponse(
        statusCode: status,
        body: body,
        uri: request.uri,
        headers: response.headers,
      );
    }
    // Non-streaming calls keep the timer running for the body; streams switch
    // to the idle timeout once the body is listened to.
    if (spec.streaming) scope.disarm();
    return _Opened(response);
  }

  Future<void> _sleep(Duration delay, _Scope scope) async {
    if (delay > Duration.zero) {
      await Future.any<void>([Future<void>.delayed(delay), scope.trigger]);
    }
    if (scope.isAborted) throw scope.exception();
  }

  Future<List<int>> _readAll(Stream<List<int>> stream, _Scope scope) {
    // listen() rather than `await for`: dart2js always awaits the iterator's
    // cancel() at the end of the loop, which is a root-zone future that
    // stalls in other zones (FakeAsync, app error zones).
    final builder = BytesBuilder(copy: false);
    final completer = Completer<List<int>>();
    _guard(stream, scope, null).listen(
      builder.add,
      onError: (Object error, StackTrace stackTrace) {
        if (completer.isCompleted) return;
        completer.completeError(
            _mapStreamError(error, scope.uri, scope), stackTrace);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  /// Wraps a body stream so that aborts and idle timeouts surface as errors
  /// even with clients that ignore the abort trigger.
  Stream<List<int>> _guard(
    Stream<List<int>> source,
    _Scope scope,
    Duration? idleTimeout,
  ) {
    late StreamSubscription<List<int>> subscription;
    void Function()? removeAbortListener;
    var sourceDone = false;
    final controller = StreamController<List<int>>(sync: true);

    void closeWith(Object error) {
      if (controller.isClosed) return;
      controller.addError(error);
      controller.close();
      if (!sourceDone) unawaited(subscription.cancel());
    }

    controller
      ..onListen = () {
        scope.arm(idleTimeout, 'the next streamed chunk', keepExisting: true);
        removeAbortListener = scope.onAbort(() => closeWith(scope.exception()));
        subscription = source.listen(
          (chunk) {
            scope.arm(idleTimeout, 'the next streamed chunk',
                keepExisting: true);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (controller.isClosed) return;
            controller.addError(
                scope.isAborted ? scope.exception() : error, stackTrace);
          },
          onDone: () {
            sourceDone = true;
            removeAbortListener?.call();
            if (!controller.isClosed) controller.close();
          },
          cancelOnError: true,
        );
      }
      ..onPause = () {
        if (idleTimeout != null) scope.disarm();
        subscription.pause();
      }
      ..onResume = () {
        scope.arm(idleTimeout, 'the next streamed chunk', keepExisting: true);
        subscription.resume();
      }
      ..onCancel = () {
        removeAbortListener?.call();
        // Never return the cancel future of a finished subscription: it can
        // be a root-zone future, which stalls code running in other zones
        // (FakeAsync in widget tests, error zones in apps).
        if (sourceDone) return null;
        return subscription.cancel();
      };
    return controller.stream;
  }

  JsonMap? _decodeLine(String line, Uri uri) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      throw OllamaResponseFormatException(
        'Malformed JSON line in stream: ${error.message}',
        uri: uri,
        body: trimmed,
        cause: error,
      );
    }
    final map = asJsonMap(decoded);
    if (map == null) {
      throw OllamaResponseFormatException(
        'Expected a JSON object in stream but got ${decoded.runtimeType}.',
        uri: uri,
        body: trimmed,
      );
    }
    final error = map['error'];
    if (error != null) {
      throw OllamaStreamException(
        error is Map ? '${error['message'] ?? error}' : '$error',
        uri: uri,
        body: trimmed,
      );
    }
    return map;
  }

  Object _mapStreamError(Object error, Uri uri, _Scope scope) {
    if (scope.isAborted) return scope.exception();
    if (error is OllamaException) return error;
    if (error is FormatException) {
      return OllamaResponseFormatException(
        'Invalid UTF-8 in response: ${error.message}',
        uri: uri,
        cause: error,
      );
    }
    return _mapError(error, uri);
  }

  OllamaException _mapError(Object error, Uri uri) {
    if (error is OllamaException) return error;
    if (error is http.RequestAbortedException) {
      return OllamaCancelledException('Request aborted.', uri: uri);
    }
    if (error is TimeoutException) {
      return OllamaTimeoutException('Timed out.',
          uri: uri, timeout: error.duration);
    }
    final message =
        error is http.ClientException ? error.message : error.toString();
    return OllamaConnectionException(
      'Could not reach Ollama at ${uri.origin}: $message',
      uri: uri,
      cause: error,
    );
  }

  Future<void> _notifyError(
      OllamaException error, OllamaHttpRequest request) async {
    for (final interceptor in config.interceptors) {
      try {
        await interceptor.onError(error, request);
      } catch (_) {
        // A failing logger must not hide the real error.
      }
    }
  }

  /// Decodes a JSON object body. An empty body decodes to `{}`.
  static JsonMap decodeObject(List<int> bytes, Uri uri, int statusCode) {
    // Always UTF-8, whatever the Content-Type says: proxies often drop the
    // charset and `http` would then fall back to latin1.
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.trim().isEmpty) return <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw OllamaResponseFormatException(
        'The response was not valid JSON: ${error.message}',
        statusCode: statusCode,
        uri: uri,
        body: text,
        cause: error,
      );
    }
    final map = asJsonMap(decoded);
    if (map == null) {
      throw OllamaResponseFormatException(
        'Expected a JSON object but received ${decoded.runtimeType}.',
        statusCode: statusCode,
        uri: uri,
        body: text,
      );
    }
    return map;
  }
}

final Object _aborted = Object();

class _Spec {
  _Spec({
    required this.method,
    required this.uri,
    required this.endpoint,
    required this.streaming,
    required this.retryPolicy,
    this.body,
    this.bodyBytes,
    this.contentType,
    this.timeout,
    this.acceptStatus,
  });

  final String method;
  final Uri uri;
  final String endpoint;
  final JsonMap? body;
  final List<int>? bodyBytes;
  final String? contentType;
  final bool streaming;
  final OllamaRetryPolicy retryPolicy;
  final Duration? timeout;
  final bool Function(int statusCode)? acceptStatus;
}

class _Opened {
  _Opened(this.response);
  final http.StreamedResponse response;
}

enum _AbortReason { cancelled, closed, timeout, unsubscribed }

/// Tracks why and when one logical call (all of its attempts) is aborted.
class _Scope {
  _Scope(this.uri, OllamaCancelToken? token, OllamaCancelToken closeToken) {
    _removers.add(closeToken.addListener(() => abort(_AbortReason.closed)));
    if (token != null) {
      _removers.add(
          token.addListener(() => abort(_AbortReason.cancelled, token.reason)));
    }
  }

  Uri uri;
  OllamaHttpRequest? lastRequest;
  bool errorReported = false;

  final Completer<void> _trigger = Completer<void>();
  final List<void Function()> _removers = [];
  final List<void Function()> _abortListeners = [];
  _AbortReason? _reason;
  Object? _detail;
  Timer? _timer;
  Duration? _timeoutValue;
  String _timeoutPhase = '';
  bool _finished = false;

  Future<void> get trigger => _trigger.future;
  bool get isAborted => _reason != null;

  void abort(_AbortReason reason, [Object? detail]) {
    if (_reason != null || _finished) return;
    _reason = reason;
    _detail = detail;
    _timer?.cancel();
    _trigger.complete();
    for (final listener in List.of(_abortListeners)) {
      listener();
    }
    _abortListeners.clear();
  }

  void Function() onAbort(void Function() listener) {
    if (isAborted) {
      scheduleMicrotask(listener);
      return () {};
    }
    _abortListeners.add(listener);
    return () => _abortListeners.remove(listener);
  }

  /// Starts (or restarts) the timeout timer. With [keepExisting] and a null
  /// [duration], a running timer is left alone.
  void arm(Duration? duration, String phase, {bool keepExisting = false}) {
    if (duration == null) {
      if (!keepExisting) disarm();
      return;
    }
    _timer?.cancel();
    if (isAborted || _finished) return;
    _timer = Timer(duration, () {
      _timeoutValue = duration;
      _timeoutPhase = phase;
      abort(_AbortReason.timeout);
    });
  }

  void disarm() {
    _timer?.cancel();
    _timer = null;
  }

  OllamaException exception() {
    switch (_reason) {
      case _AbortReason.timeout:
        return OllamaTimeoutException(
          'Timed out after ${_timeoutValue?.inMilliseconds} ms waiting for '
          '$_timeoutPhase.',
          uri: uri,
          timeout: _timeoutValue,
        );
      case _AbortReason.closed:
        return OllamaCancelledException('The Ollama client was closed.',
            uri: uri, reason: 'client closed');
      case _AbortReason.unsubscribed:
        return OllamaCancelledException('The stream listener cancelled.',
            uri: uri);
      case _AbortReason.cancelled:
      case null:
        return OllamaCancelledException('Request cancelled.',
            uri: uri, reason: _detail);
    }
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    disarm();
    for (final remove in _removers) {
      remove();
    }
    _removers.clear();
  }
}
