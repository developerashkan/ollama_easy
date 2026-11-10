import 'dart:async';
import 'dart:convert';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  group('NDJSON streaming', () {
    test('objects split across arbitrary byte chunks are reassembled',
        () async {
      for (final size in [1, 2, 3, 7, 16, 1000]) {
        final server = FakeServer((_) => ndjsonResponse([
              chatChunk('Hel'),
              chatChunk('lo, '),
              chatChunk('world'),
              chatChunk('', done: true, extra: doneStats),
            ], chunkSize: size));
        final text = await server
            .ollama()
            .chatTextStream([const OllamaMessage.user('hi')]).join();
        expect(text, 'Hello, world', reason: 'chunk size $size');
      }
    });

    test('multi-byte UTF-8 characters split between chunks decode correctly',
        () async {
      // Persian, emoji (4 bytes) and CJK, cut at every single byte.
      const pieces = ['سلام ', '😀🚀', ' 你好'];
      final server = FakeServer((_) => ndjsonResponse([
            for (final piece in pieces) generateChunk(piece),
            generateChunk('', done: true),
          ], chunkSize: 1));
      final text = await server.ollama().askStream('x').join();
      expect(text, pieces.join());
    });

    test('CRLF separators, blank lines and a missing final newline', () async {
      final server = FakeServer((_) => ndjsonResponse([
            generateChunk('a'),
            '',
            '   ',
            generateChunk('b'),
            generateChunk('c', done: true),
          ], separator: '\r\n', trailingNewline: false, chunkSize: 5));
      expect(await server.ollama().askStream('x').join(), 'abc');
    });

    test('the final done chunk carries typed metrics', () async {
      final server = FakeServer((_) => ndjsonResponse([
            chatChunk('Hi'),
            chatChunk('', done: true, extra: doneStats),
          ]));
      final chunks = await server
          .ollama()
          .chatStream([const OllamaMessage.user('x')]).toList();
      final last = chunks.last;
      expect(last.done, isTrue);
      expect(last.reason, OllamaDoneReason.stop);
      expect(last.evalCount, 50);
      expect(last.totalDuration, const Duration(seconds: 2));
      expect(last.tokensPerSecond, closeTo(50, 0.001));
      expect(last.promptTokensPerSecond, closeTo(20, 0.001));
      expect(last.totalTokens, 60);
    });

    test('collect() merges content, thinking, tool calls and metrics',
        () async {
      final server = FakeServer((_) => ndjsonResponse([
            chatChunk('', thinking: 'Let me '),
            chatChunk('', thinking: 'think.'),
            chatChunk('The answer'),
            chatChunk(' is 42.'),
            {
              'model': 'm',
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'function': {
                      'name': 'save',
                      'arguments': {'value': 42}
                    }
                  }
                ],
              },
              'done': false,
            },
            chatChunk('', done: true, extra: doneStats),
          ]));
      final response = await server
          .ollama()
          .chatStream([const OllamaMessage.user('x')], think: true).collect();
      expect(response.text, 'The answer is 42.');
      expect(response.thinking, 'Let me think.');
      expect(response.toolCalls.single.name, 'save');
      expect(response.toolCalls.single.arguments, {'value': 42});
      expect(response.evalCount, 50);
      expect(response.done, isTrue);
      expect(server.last.json['think'], isTrue);
    });

    test('thinkingDeltas and textDeltas split the stream', () async {
      final server = FakeServer((_) => ndjsonResponse([
            chatChunk('', thinking: 'hmm'),
            chatChunk('ok'),
            chatChunk('', done: true),
          ]));
      final ollama = server.ollama();
      expect(
          await ollama
              .chatStream([const OllamaMessage.user('x')])
              .thinkingDeltas
              .toList(),
          ['hmm']);
      expect(
          await ollama
              .chatStream([const OllamaMessage.user('x')])
              .textDeltas
              .toList(),
          ['ok']);
    });

    test('generate collect() merges response text and keeps final stats',
        () async {
      final server = FakeServer((_) => ndjsonResponse([
            generateChunk('one '),
            generateChunk('two'),
            {...generateChunk('', done: true), ...doneStats},
          ]));
      final response = await server.ollama().generateStream('x').collect();
      expect(response.response, 'one two');
      expect(response.evalCount, 50);
    });

    test(
        'an error line mid-stream throws OllamaStreamException after the '
        'earlier chunks', () async {
      final server = FakeServer((_) => ndjsonResponse([
            chatChunk('partial'),
            {'error': 'model runner has unexpectedly stopped'},
          ]));
      final received = <String>[];
      Object? error;
      final done = Completer<void>();
      server.ollama().chatTextStream([const OllamaMessage.user('x')]).listen(
          received.add,
          onError: (Object e) => error = e,
          onDone: done.complete);
      await done.future;
      expect(received, ['partial']);
      expect(error, isA<OllamaStreamException>());
      expect((error! as OllamaException).message,
          'model runner has unexpectedly stopped');
    });

    test('an error line in a pull stream fails the pull', () async {
      final server = FakeServer((_) => ndjsonResponse([
            {'status': 'pulling manifest'},
            {'error': 'pull model manifest: file does not exist'},
          ]));
      await expectLater(
        server.ollama().pull('nope'),
        throwsA(isA<OllamaStreamException>().having(
            (e) => e.message, 'message', contains('file does not exist'))),
      );
    });

    test('a malformed JSON line throws OllamaResponseFormatException',
        () async {
      final server = FakeServer((_) => ndjsonResponse([
            generateChunk('a'),
            '{"response": "b", "done": fal',
          ]));
      await expectLater(server.ollama().askStream('x').toList(),
          throwsA(isA<OllamaResponseFormatException>()));
    });

    test('a stream that ends without done:true is reported as cut off',
        () async {
      final server = FakeServer(
          (_) => ndjsonResponse([generateChunk('a'), generateChunk('b')]));
      await expectLater(
        server.ollama().generateStream('x').toList(),
        throwsA(isA<OllamaStreamException>()
            .having((e) => e.message, 'message', contains('done'))),
      );
    });

    test('invalid UTF-8 in a stream becomes OllamaResponseFormatException',
        () async {
      final server = FakeServer((_) => rawResponse([
            ...utf8.encode('{"response":"'),
            0xff,
            0xfe,
            ...utf8.encode('"}\n')
          ]));
      await expectLater(server.ollama().askStream('x').toList(),
          throwsA(isA<OllamaResponseFormatException>()));
    });

    test('streams are lazy: nothing is sent until listened to', () async {
      final server =
          FakeServer((_) => ndjsonResponse([generateChunk('a', done: true)]));
      final stream = server.ollama().askStream('x');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requests, isEmpty);
      await stream.toList();
      expect(server.requests, hasLength(1));
      expect(server.last.json['stream'], isTrue);
    });

    test('pause and resume are honoured (back-pressure)', () async {
      final server = FakeServer((_) => ndjsonResponse([
            for (var i = 0; i < 20; i++) generateChunk('$i '),
            generateChunk('', done: true),
          ], chunkSize: 4));
      final received = <String>[];
      final done = Completer<void>();
      late StreamSubscription<String> subscription;
      subscription = server.ollama().askStream('x').listen((text) {
        received.add(text);
        if (received.length == 5) {
          subscription
              .pause(Future<void>.delayed(const Duration(milliseconds: 30)));
        }
      }, onDone: done.complete);
      await done.future;
      expect(received, hasLength(20));
    });
  });
}
