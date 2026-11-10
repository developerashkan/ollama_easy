import 'dart:async';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

Map<String, Object?> toolCallResponse(List<Map<String, Object?>> calls) => {
      'model': 'm',
      'message': {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          for (final call in calls) {'function': call},
        ],
      },
      'done': true,
    };

Map<String, Object?> answer(String text) => {
      ...chatChunk(text, done: true),
      ...doneStats,
    };

final weather = OllamaTool.function(
  name: 'get_weather',
  description: 'Weather for a city',
  parameters: OllamaSchema.object({'city': OllamaSchema.string()}),
  handler: (args) => {'city': args['city'], 'celsius': 21},
);

/// Answers with the queued responses in order.
FakeServer scripted(List<Map<String, Object?>> responses) {
  var index = 0;
  return FakeServer((_) => jsonResponse(responses[index++]));
}

void main() {
  group('runTools', () {
    test('runs the loop: call → result (with tool_name) → final answer',
        () async {
      final server = scripted([
        toolCallResponse([
          {
            'name': 'get_weather',
            'arguments': {'city': 'Paris'}
          },
        ]),
        answer('It is 21°C in Paris.'),
      ]);
      final run = await server.ollama().runTools(
        [const OllamaMessage.user('Weather in Paris?')],
        tools: [weather],
      );
      expect(run.text, 'It is 21°C in Paris.');
      expect(run.iterations, 2);
      expect(run.invocations.single.result, {'city': 'Paris', 'celsius': 21});
      expect(run.messages.map((m) => m.role), [
        OllamaRole.user,
        OllamaRole.assistant,
        OllamaRole.tool,
        OllamaRole.assistant,
      ]);

      final first = server.requests.first.json;
      expect((first['tools'] as List).single, {
        'type': 'function',
        'function': {
          'name': 'get_weather',
          'description': 'Weather for a city',
          'parameters': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'}
            },
            'required': ['city'],
            'additionalProperties': false,
          },
        },
      });
      final second = server.requests.last.json['messages'] as List;
      expect(second.last, {
        'role': 'tool',
        'content': '{"city":"Paris","celsius":21}',
        'tool_name': 'get_weather',
      });
    });

    test('parallel calls run concurrently and keep their order', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final slow = OllamaTool.function(
        name: 'slow',
        parameters: OllamaSchema.object({'n': OllamaSchema.integer()}),
        handler: (args) async {
          started.add('${args['n']}');
          if (started.length == 2) gate.complete();
          await gate.future;
          return 'n=${args['n']}';
        },
      );
      final server = scripted([
        toolCallResponse([
          {
            'name': 'slow',
            'arguments': {'n': 1}
          },
          {
            'name': 'slow',
            'arguments': {'n': 2}
          },
        ]),
        answer('done'),
      ]);
      final run = await server.ollama().runTools(
        [const OllamaMessage.user('go')],
        tools: [slow],
      );
      expect(started, ['1', '2']);
      expect(run.invocations.map((i) => i.message.content), ['n=1', 'n=2']);
    });

    test('unknown tools, handler errors and denials are reported to the model',
        () async {
      final failing = OllamaTool.function(
        name: 'explode',
        parameters: OllamaSchema.object({}),
        handler: (_) => throw StateError('disk full'),
      );
      final server = scripted([
        toolCallResponse([
          {'name': 'nope', 'arguments': {}},
          {'name': 'explode', 'arguments': {}},
          {
            'name': 'get_weather',
            'arguments': {'city': 'Rome'}
          },
        ]),
        answer('Sorry.'),
      ]);
      final run = await server.ollama().runTools(
        [const OllamaMessage.user('x')],
        tools: [failing, weather],
        approve: (call) => call.name != 'get_weather',
      );
      final contents = run.invocations.map((i) => i.message.content).toList();
      expect(contents[0], contains('unknown tool "nope"'));
      expect(contents[0], contains('explode, get_weather'));
      expect(contents[1], 'Error: Bad state: disk full');
      expect(contents[2], contains('denied'));
      expect(run.invocations.every((i) => !i.succeeded), isTrue);
    });

    test('rethrowToolErrors surfaces handler errors', () async {
      final server = scripted([
        toolCallResponse([
          {'name': 'boom', 'arguments': {}},
        ]),
      ]);
      await expectLater(
        server.ollama().runTools([
          const OllamaMessage.user('x')
        ], tools: [
          OllamaTool.function(
              name: 'boom',
              parameters: const {'type': 'object'},
              handler: (_) => throw const FormatException('bad')),
        ], rethrowToolErrors: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('maxIterations stops a model that never stops calling tools',
        () async {
      final server = FakeServer((_) => jsonResponse(toolCallResponse([
            {
              'name': 'get_weather',
              'arguments': {'city': 'X'}
            },
          ])));
      await expectLater(
        server.ollama().runTools([const OllamaMessage.user('x')],
            tools: [weather], maxIterations: 3),
        throwsA(isA<OllamaToolLoopException>()
            .having((e) => e.messages.length, 'messages', 1 + 3 * 2)),
      );
      expect(server.requests, hasLength(3));
    });

    test('runToolsStream emits deltas, tool events and done', () async {
      var call = 0;
      final server = FakeServer((_) {
        call++;
        if (call == 1) {
          return ndjsonResponse([
            chatChunk('', thinking: 'Need weather. '),
            {
              ...toolCallResponse([
                {
                  'name': 'get_weather',
                  'arguments': {'city': 'Oslo'}
                },
              ]),
              'done': false
            },
            chatChunk('', done: true),
          ]);
        }
        return ndjsonResponse([
          chatChunk('Cold '),
          chatChunk('in Oslo.'),
          chatChunk('', done: true, extra: doneStats),
        ]);
      });
      final events = await server.ollama().runToolsStream(
          [const OllamaMessage.user('Oslo?')],
          tools: [weather]).toList();
      expect(events.map((e) => e.runtimeType.toString()), [
        'OllamaToolRunThinkingDelta',
        'OllamaToolRunCallStarted',
        'OllamaToolRunCallFinished',
        'OllamaToolRunTextDelta',
        'OllamaToolRunTextDelta',
        'OllamaToolRunDone',
      ]);
      final done = events.last as OllamaToolRunDone;
      expect(done.run.text, 'Cold in Oslo.');
      expect(done.run.response.evalCount, 50);
      expect(server.requests.first.json['stream'], isTrue);
    });

    test('tool call arguments given as a JSON string are decoded', () {
      final call = OllamaToolCall.fromJson({
        'id': 'c1',
        'function': {'index': 0, 'name': 'f', 'arguments': '{"a": 1}'},
      });
      expect(call.arguments, {'a': 1});
      expect(call.id, 'c1');
      expect(call.index, 0);
      expect(call.toJson(), {
        'id': 'c1',
        'function': {
          'index': 0,
          'name': 'f',
          'arguments': {'a': 1}
        },
      });
      expect(
          OllamaToolCall.fromJson({
            'function': {'name': 'f', 'arguments': 'not json'}
          }).arguments,
          {'input': 'not json'});
    });

    test('OllamaTool.fromJson and withHandler', () async {
      final tool = OllamaTool.fromJson({
        'type': 'function',
        'function': {
          'name': 'add',
          'parameters': {'type': 'object'}
        },
      }).withHandler((args) => 3);
      expect(tool.name, 'add');
      expect(await tool.handler!({}), 3);
      expect(tool.toJson()['function'], {
        'name': 'add',
        'parameters': {'type': 'object'}
      });
    });
  });
}
