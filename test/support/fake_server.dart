import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_easy/ollama_easy.dart';

/// A request captured by [FakeServer].
class Recorded {
  Recorded(this.request, this.bodyBytes);

  final http.BaseRequest request;
  final List<int> bodyBytes;

  String get method => request.method;
  Uri get url => request.url;
  String get path => request.url.path;
  Map<String, String> get headers => request.headers;

  Map<String, Object?> get json =>
      (jsonDecode(utf8.decode(bodyBytes)) as Map).cast<String, Object?>();

  /// Completes when the client aborts this request.
  Future<void>? get abortTrigger => request is http.Abortable
      ? (request as http.Abortable).abortTrigger
      : null;
}

typedef FakeHandler = FutureOr<http.StreamedResponse> Function(
    Recorded request);

/// An in-memory Ollama server built on `MockClient.streaming`.
class FakeServer {
  FakeServer(this.handler);

  /// Answers every request with the same JSON object.
  FakeServer.json(Map<String, Object?> body, {int status = 200})
      : handler = ((_) => jsonResponse(body, status: status));

  FakeHandler handler;
  final List<Recorded> requests = [];

  late final http.Client client = MockClient.streaming((request, body) async {
    final recorded = Recorded(request, await body.toBytes());
    requests.add(recorded);
    return handler(recorded);
  });

  Ollama ollama({
    Uri? baseUrl,
    String? apiKey,
    Map<String, String>? headers,
    Duration? timeout = const Duration(seconds: 5),
    Duration? streamIdleTimeout = const Duration(seconds: 5),
    OllamaRetryPolicy retryPolicy = OllamaRetryPolicy.none,
    List<OllamaInterceptor> interceptors = const [],
    Map<String, Object?>? defaultOptions,
    Object? defaultKeepAlive,
  }) {
    return Ollama(
      baseUrl: baseUrl,
      apiKey: apiKey,
      headers: headers,
      httpClient: client,
      timeout: timeout,
      streamIdleTimeout: streamIdleTimeout,
      retryPolicy: retryPolicy,
      interceptors: interceptors,
      defaultOptions: defaultOptions,
      defaultKeepAlive: defaultKeepAlive,
    );
  }

  Recorded get last => requests.last;
}

http.StreamedResponse jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {
    'content-type': 'application/json; charset=utf-8',
  },
}) {
  final bytes = utf8.encode(body is String ? body : jsonEncode(body));
  return http.StreamedResponse(Stream.value(bytes), status, headers: headers);
}

/// NDJSON response. [chunkSize] splits the *bytes* into pieces of that size
/// (so JSON objects and UTF-8 characters are cut in the middle).
http.StreamedResponse ndjsonResponse(
  List<Object> lines, {
  int? chunkSize,
  String separator = '\n',
  bool trailingNewline = true,
  Duration? delay,
  int status = 200,
}) {
  final text = lines
          .map((line) => line is String ? line : jsonEncode(line))
          .join(separator) +
      (trailingNewline ? separator : '');
  final bytes = utf8.encode(text);
  return http.StreamedResponse(
    byteStream(bytes, chunkSize: chunkSize, delay: delay),
    status,
    headers: const {'content-type': 'application/x-ndjson'},
  );
}

http.StreamedResponse rawResponse(List<int> bytes, {int status = 200}) =>
    http.StreamedResponse(Stream.value(bytes), status);

Stream<List<int>> byteStream(List<int> bytes,
    {int? chunkSize, Duration? delay}) async* {
  final size = chunkSize ?? bytes.length;
  for (var start = 0; start < bytes.length; start += size) {
    if (delay != null) await Future<void>.delayed(delay);
    final end = start + size > bytes.length ? bytes.length : start + size;
    yield bytes.sublist(start, end);
  }
}

/// A response whose body is fed manually; records when it is cancelled.
class ControlledBody {
  ControlledBody() {
    controller = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;

  http.StreamedResponse response({int status = 200}) =>
      http.StreamedResponse(controller.stream, status);

  void addJson(Object json) =>
      controller.add(utf8.encode('${jsonEncode(json)}\n'));

  Future<void> close() => controller.close();
}

Map<String, Object?> chatChunk(String content,
        {bool done = false, String? thinking, Map<String, Object?>? extra}) =>
    {
      'model': 'm',
      'created_at': '2026-11-10T00:00:00Z',
      'message': {
        'role': 'assistant',
        'content': content,
        if (thinking != null) 'thinking': thinking,
      },
      'done': done,
      ...?extra,
    };

Map<String, Object?> generateChunk(String response, {bool done = false}) => {
      'model': 'm',
      'response': response,
      'done': done,
    };

const doneStats = {
  'done_reason': 'stop',
  'total_duration': 2000000000,
  'load_duration': 100000000,
  'prompt_eval_count': 10,
  'prompt_eval_duration': 500000000,
  'eval_count': 50,
  'eval_duration': 1000000000,
};
