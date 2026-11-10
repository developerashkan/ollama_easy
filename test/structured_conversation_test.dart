import 'dart:async';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

class City {
  City(this.name, this.population);

  factory City.fromJson(Map<String, Object?> json) =>
      City(json['name']! as String, json['population']! as int);

  final String name;
  final int population;
}

final citySchema = OllamaSchema.object({
  'name': OllamaSchema.string(),
  'population': OllamaSchema.integer(minimum: 0),
});

Map<String, Object?> reply(String text) => chatChunk(text, done: true);

void main() {
  group('structured outputs', () {
    test('decodeJsonObject tolerates fences and surrounding text', () {
      expect(decodeJsonObject('{"a":1}'), {'a': 1});
      expect(decodeJsonObject('```json\n{"a": 1}\n```'), {'a': 1});
      expect(
          decodeJsonObject('Sure! Here it is: {"a": {"b": 2}} Hope it helps'), {
        'a': {'b': 2}
      });
      expect(decodeJsonValue('[1, 2]'), [1, 2]);
      expect(() => decodeJsonObject(''),
          throwsA(isA<OllamaResponseFormatException>()));
      expect(() => decodeJsonObject('[1]'),
          throwsA(isA<OllamaResponseFormatException>()));
      expect(() => decodeJsonObject('no json'),
          throwsA(isA<OllamaResponseFormatException>()));
    });

    test('askStructured sends the schema as format and decodes', () async {
      final server = FakeServer(
          (_) => jsonResponse(reply('{"name":"Paris","population":2100000}')));
      final city = await server.ollama().askStructured('Paris?',
          schema: citySchema, fromJson: City.fromJson, system: 'Be factual.');
      expect(city.name, 'Paris');
      expect(server.last.json['format'], citySchema);
      expect((server.last.json['messages'] as List).first,
          {'role': 'system', 'content': 'Be factual.'});
    });

    test('chatStructured repairs once, showing the model its mistake',
        () async {
      var calls = 0;
      final server = FakeServer((_) => jsonResponse(reply(++calls == 1
          ? '{"name":"Paris"}'
          : '{"name":"Paris","population":1}')));
      final city = await server.ollama().chatStructured(
        [const OllamaMessage.user('Paris?')],
        schema: citySchema,
        fromJson: City.fromJson,
      );
      expect(city.population, 1);
      final retry = server.last.json['messages'] as List;
      expect(retry, hasLength(3));
      expect((retry.last as Map)['content'], contains('could not be used'));
    });

    test('chatStructured gives up with OllamaResponseFormatException',
        () async {
      final server = FakeServer((_) => jsonResponse(reply('not json')));
      await expectLater(
        server.ollama().chatStructured([const OllamaMessage.user('x')],
            schema: citySchema, fromJson: City.fromJson, repairAttempts: 2),
        throwsA(isA<OllamaResponseFormatException>()),
      );
      expect(server.requests, hasLength(3));
    });

    test('askJson defaults to format json and decodes leniently', () async {
      final server = FakeServer((_) => jsonResponse(
          generateChunk('```json\n{"title":"Streams"}\n```', done: true)));
      expect(await server.ollama().askJson('x'), {'title': 'Streams'});
      expect(server.last.json['format'], 'json');
    });

    test('schema builders', () {
      expect(OllamaSchema.nullable(OllamaSchema.string()), {
        'type': ['string', 'null']
      });
      expect(
          OllamaSchema.object({'a': OllamaSchema.boolean()},
              required: [])['required'],
          []);
      expect(OllamaSchema.array(OllamaSchema.number(), minItems: 1), {
        'type': 'array',
        'items': {'type': 'number'},
        'minItems': 1,
      });
      expect(OllamaSchema.enumeration(['a', 'b'])['enum'], ['a', 'b']);
      expect(
          OllamaSchema.anyOf([OllamaSchema.string()])['anyOf'], hasLength(1));
    });
  });

  group('conversation', () {
    test('keeps history and sends the system prompt first', () async {
      var n = 0;
      final server = FakeServer((_) => jsonResponse(reply('reply ${++n}')));
      final chat = server.ollama().conversation(system: 'Be brief.');
      expect(await chat.send('one'), 'reply 1');
      expect(await chat.send('two'), 'reply 2');
      final sent = server.last.json['messages'] as List;
      expect(sent.map((m) => (m as Map)['content']),
          ['Be brief.', 'one', 'reply 1', 'two']);
      expect(chat.history, hasLength(4));
      expect(chat.lastResponse?.text, 'reply 2');
    });

    test('trimming drops whole oldest turns and keeps tool pairs together', () {
      final chat = OllamaConversation(
        client: Ollama(),
        maxMessages: 4,
        history: const [
          OllamaMessage.user('q1'),
          OllamaMessage.assistant('', toolCalls: [
            OllamaToolCall(name: 'f', arguments: {}),
          ]),
          OllamaMessage.tool('r', toolName: 'f'),
          OllamaMessage.assistant('a1'),
          OllamaMessage.user('q2'),
          OllamaMessage.assistant('a2'),
        ],
      );
      expect(chat.history.map((m) => m.content), ['q2', 'a2']);
      expect(chat.history.first.role, OllamaRole.user);

      final byChars = OllamaConversation(
        client: Ollama(),
        maxChars: 10,
        history: const [
          OllamaMessage.user('aaaaaaaaaaaa'), // alone exceeds the budget
        ],
      );
      expect(byChars.history, hasLength(1), reason: 'the latest turn is kept');
    });

    test('sendStream yields deltas and stores the full reply', () async {
      final server = FakeServer((_) => ndjsonResponse([
            chatChunk('Hello'),
            chatChunk(' there'),
            chatChunk('', done: true, extra: doneStats),
          ]));
      final chat = server.ollama().conversation();
      expect(await chat.sendStream('hi').toList(), ['Hello', ' there']);
      expect(chat.history.last.content, 'Hello there');
      expect(chat.lastResponse?.evalCount, 50);
    });

    test(
        'a cancelled stream keeps the partial reply; a failed send rolls '
        'back the question', () async {
      final body = ControlledBody();
      final server = FakeServer((_) => body.response());
      final chat = server.ollama().conversation();
      final token = OllamaCancelToken();
      final future = chat.sendStream('story', cancelToken: token).toList();
      body.addJson(chatChunk('Once upon'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      await expectLater(future, throwsA(isA<OllamaCancelledException>()));
      expect(chat.history.map((m) => m.content), ['story', 'Once upon']);

      server.handler = (_) => jsonResponse({'error': 'boom'}, status: 500);
      await expectLater(
          chat.send('again'), throwsA(isA<OllamaServerException>()));
      expect(chat.history.map((m) => m.content), ['story', 'Once upon']);
    });

    test('tools with handlers run automatically inside a conversation',
        () async {
      var call = 0;
      final server = FakeServer((_) => jsonResponse(++call == 1
          ? {
              'model': 'm',
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'function': {'name': 'time', 'arguments': {}}
                  }
                ],
              },
              'done': true,
            }
          : reply('It is noon.')));
      final chat = server.ollama().conversation(tools: [
        OllamaTool.function(
            name: 'time',
            parameters: OllamaSchema.object({}),
            handler: (_) => '12:00'),
      ]);
      expect(await chat.send('Time?'), 'It is noon.');
      expect(chat.history.map((m) => m.role), [
        OllamaRole.user,
        OllamaRole.assistant,
        OllamaRole.tool,
        OllamaRole.assistant,
      ]);
    });

    test('undo, clear and JSON round trip', () async {
      final chat = OllamaConversation(
        client: Ollama(),
        system: 'sys',
        model: 'm',
        history: const [
          OllamaMessage.user('a'),
          OllamaMessage.assistant('b'),
          OllamaMessage.user('c'),
          OllamaMessage.assistant('d'),
        ],
      );
      final restored =
          OllamaConversation.fromJson(chat.toJson(), client: Ollama());
      expect(restored.system, 'sys');
      expect(restored.model, 'm');
      expect(restored.history.map((m) => m.content), ['a', 'b', 'c', 'd']);
      expect(chat.undo().map((m) => m.content), ['c', 'd']);
      expect(chat.history, hasLength(2));
      chat.clear();
      expect(chat.history, isEmpty);
      expect(chat.messages.single.role, OllamaRole.system);
    });
  });
}
