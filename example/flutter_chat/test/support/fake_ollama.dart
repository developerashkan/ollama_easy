import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_easy/ollama_easy.dart';

/// An in-memory Ollama: two models, and a chat endpoint that streams
/// [reply] word by word (with [thinking] first when `think` is on).
class FakeOllama {
  FakeOllama({
    this.reply = 'Streams deliver values over time, like a conveyor belt.',
    this.thinking = 'The user wants a simple analogy. A conveyor belt works.',
    this.wordDelay = const Duration(milliseconds: 40),
    this.online = true,
    this.endless = false,
  });

  String reply;
  String thinking;
  Duration wordDelay;
  bool online;
  bool endless;
  final List<Map<String, Object?>> chatRequests = [];

  Ollama client() => Ollama(
        httpClient: MockClient.streaming(_handle),
        retryPolicy: OllamaRetryPolicy.none,
      );

  Future<http.StreamedResponse> _handle(
      http.BaseRequest request, http.ByteStream body) async {
    final bytes = await body.toBytes();
    if (!online) throw http.ClientException('Connection refused', request.url);
    switch (request.url.path) {
      case '/api/tags':
        return _json({
          'models': [
            {'name': 'qwen3:4b', 'model': 'qwen3:4b'},
            {'name': 'llama3.2:latest', 'model': 'llama3.2:latest'},
            {'name': 'embeddinggemma:latest', 'model': 'embeddinggemma:latest'},
          ],
        });
      case '/api/chat':
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        chatRequests.add(json);
        return http.StreamedResponse(
            _chat(json['think'] == true, request), 200);
    }
    return _json({'error': 'not found'}, 404);
  }

  Stream<List<int>> _chat(bool think, http.BaseRequest request) async* {
    final abort = request is http.Abortable ? request.abortTrigger : null;
    var aborted = false;
    unawaited(abort?.then((_) => aborted = true));
    List<int> line(Map<String, Object?> message, {bool done = false}) =>
        utf8.encode('${jsonEncode({
              'model': 'qwen3:4b',
              'message': {'role': 'assistant', 'content': '', ...message},
              'done': done,
              if (done) ...{
                'done_reason': 'stop',
                'eval_count': 42,
                'eval_duration': 1200000000,
              },
            })}\n');
    if (think) {
      for (final word in thinking.split(' ')) {
        await Future<void>.delayed(wordDelay);
        yield line({'thinking': '$word '});
      }
    }
    var i = 0;
    final words = reply.split(' ');
    while (endless || i < words.length) {
      if (aborted) throw http.RequestAbortedException(request.url);
      await Future<void>.delayed(wordDelay);
      final word = words[i % words.length];
      yield line({'content': i == 0 ? word : ' $word'});
      i++;
    }
    yield line({}, done: true);
  }

  static http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(body))), status);
}
