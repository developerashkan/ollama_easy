import 'dart:async';
import 'dart:convert';

import 'exceptions.dart';

/// A request about to be sent. Interceptors may change [uri], [headers] and
/// [body].
class OllamaHttpRequest {
  OllamaHttpRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.endpoint,
    this.body,
    this.bodyBytes,
    this.streaming = false,
    this.attempt = 1,
  });

  /// HTTP method, e.g. `POST`.
  final String method;

  /// Full request URL.
  Uri uri;

  /// Request headers. Mutable.
  final Map<String, String> headers;

  /// The API endpoint, e.g. `chat`, `tags` or `blobs/sha256:...`.
  final String endpoint;

  /// The JSON body, if any. Mutable.
  Map<String, Object?>? body;

  /// A raw body (blob uploads). Takes precedence over [body].
  List<int>? bodyBytes;

  /// Whether the response is read as a stream.
  final bool streaming;

  /// 1 for the first attempt, 2 for the first retry, and so on.
  final int attempt;
}

/// Response metadata, available once the status and headers arrive.
class OllamaHttpResponse {
  const OllamaHttpResponse({
    required this.request,
    required this.statusCode,
    required this.headers,
    required this.elapsed,
  });

  final OllamaHttpRequest request;
  final int statusCode;
  final Map<String, String> headers;

  /// Time from sending the request until the headers arrived.
  final Duration elapsed;
}

/// Hooks into every request the client makes.
///
/// Override only what you need. Hooks may be async. Use them for dynamic auth
/// headers, tracing, metrics or logging.
///
/// ```dart
/// class TokenInterceptor extends OllamaInterceptor {
///   @override
///   Future<void> onRequest(OllamaHttpRequest request) async {
///     request.headers['Authorization'] = 'Bearer ${await getToken()}';
///   }
/// }
/// ```
abstract class OllamaInterceptor {
  const OllamaInterceptor();

  /// Called before each attempt, including retries.
  FutureOr<void> onRequest(OllamaHttpRequest request) {}

  /// Called when response headers arrive (any status code).
  FutureOr<void> onResponse(OllamaHttpResponse response) {}

  /// Called once with the final error of a failed call.
  FutureOr<void> onError(OllamaException error, OllamaHttpRequest request) {}
}

/// An interceptor built from callbacks.
class OllamaCallbackInterceptor extends OllamaInterceptor {
  const OllamaCallbackInterceptor({
    FutureOr<void> Function(OllamaHttpRequest request)? onRequest,
    FutureOr<void> Function(OllamaHttpResponse response)? onResponse,
    FutureOr<void> Function(OllamaException error, OllamaHttpRequest request)?
        onError,
  })  : _onRequest = onRequest,
        _onResponse = onResponse,
        _onError = onError;

  final FutureOr<void> Function(OllamaHttpRequest request)? _onRequest;
  final FutureOr<void> Function(OllamaHttpResponse response)? _onResponse;
  final FutureOr<void> Function(
      OllamaException error, OllamaHttpRequest request)? _onError;

  @override
  FutureOr<void> onRequest(OllamaHttpRequest request) =>
      _onRequest?.call(request);

  @override
  FutureOr<void> onResponse(OllamaHttpResponse response) =>
      _onResponse?.call(response);

  @override
  FutureOr<void> onError(OllamaException error, OllamaHttpRequest request) =>
      _onError?.call(error, request);
}

/// Logs requests, responses and errors. `Authorization` and other secret
/// headers are redacted.
///
/// ```dart
/// Ollama(interceptors: [OllamaLogInterceptor(logBody: true)]);
/// ```
class OllamaLogInterceptor extends OllamaInterceptor {
  OllamaLogInterceptor({
    void Function(String line)? logger,
    this.logHeaders = false,
    this.logBody = false,
    this.maxBodyLength = 1000,
  }) : logger = logger ?? print;

  final void Function(String line) logger;
  final bool logHeaders;
  final bool logBody;

  /// Request bodies longer than this are truncated (base64 images get long).
  final int maxBodyLength;

  static const _secretHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'x-api-key',
    'api-key',
  };

  @override
  void onRequest(OllamaHttpRequest request) {
    final retry = request.attempt > 1 ? ' (retry ${request.attempt - 1})' : '';
    logger('[ollama] --> ${request.method} ${request.uri}$retry');
    if (logHeaders) {
      for (final entry in request.headers.entries) {
        final value = _secretHeaders.contains(entry.key.toLowerCase())
            ? '<redacted>'
            : entry.value;
        logger('[ollama]     ${entry.key}: $value');
      }
    }
    if (logBody && request.body != null) {
      var text = jsonEncode(request.body);
      if (text.length > maxBodyLength) {
        text = '${text.substring(0, maxBodyLength)}… (${text.length} chars)';
      }
      logger('[ollama]     $text');
    }
  }

  @override
  void onResponse(OllamaHttpResponse response) {
    logger('[ollama] <-- ${response.statusCode} ${response.request.uri} '
        '(${response.elapsed.inMilliseconds} ms)');
  }

  @override
  void onError(OllamaException error, OllamaHttpRequest request) {
    logger('[ollama] <-- ERROR ${request.method} ${request.uri}: $error');
  }
}
