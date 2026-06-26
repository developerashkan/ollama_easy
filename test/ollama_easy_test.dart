import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

void main() {
  test('ask posts a non-streaming generate request', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://localhost:11434/api/generate');

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['model'], 'gemma4');
      expect(body['prompt'], 'Hello');
      expect(body['stream'], isFalse);

      return http.Response(
        jsonEncode({
          'model': 'gemma4',
          'created_at': '2026-06-25T00:00:00Z',
          'response': 'Hi there',
          'done': true,
        }),
        200,
      );
    });

    final ollama = Ollama(httpClient: client);

    expect(await ollama.ask('Hello'), 'Hi there');
  });

  test('askStream parses newline-delimited JSON chunks', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'http://localhost:11434/api/generate');
      return http.Response(
        [
          jsonEncode({'model': 'gemma4', 'response': 'Hel', 'done': false}),
          jsonEncode({'model': 'gemma4', 'response': 'lo', 'done': true}),
        ].join('\n'),
        200,
      );
    });

    final ollama = Ollama(httpClient: client);

    expect(await ollama.askStream('Hello').join(), 'Hello');
  });

  test('chatText returns the assistant message content', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['messages'], isA<List>());

      return http.Response(
        jsonEncode({
          'model': 'gemma4',
          'message': {'role': 'assistant', 'content': 'Use ValueNotifier.'},
          'done': true,
        }),
        200,
      );
    });

    final ollama = Ollama(httpClient: client);

    final text = await ollama.chatText([
      const OllamaMessage.user('Flutter tip?'),
    ]);

    expect(text, 'Use ValueNotifier.');
  });

  test('models parses available model details', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'http://localhost:11434/api/tags');

      return http.Response(
        jsonEncode({
          'models': [
            {
              'name': 'gemma4',
              'model': 'gemma4',
              'size': 123,
              'details': {'family': 'gemma', 'parameter_size': '8B'},
            },
          ],
        }),
        200,
      );
    });

    final ollama = Ollama(httpClient: client);
    final models = await ollama.models();

    expect(models.single.name, 'gemma4');
    expect(models.single.details?.family, 'gemma');
  });
}
