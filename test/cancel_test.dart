import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  group('cancellation', () {
    test('cancelling while waiting for headers aborts the request', () async {
      final never = Completer<http.StreamedResponse>();
      final server = FakeServer((_) => never.future);
      final token = OllamaCancelToken();
      final future = server.ollama().chat(
        [const OllamaMessage.user('x')],
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      var aborted = false;
      unawaited(server.last.abortTrigger!.then((_) => aborted = true));
      token.cancel('user pressed stop');
      await expectLater(
        future,
        throwsA(isA<OllamaCancelledException>()
            .having((e) => e.reason, 'reason', 'user pressed stop')),
      );
      expect(aborted, isTrue);
    });

    test(
        'cancelling mid-stream emits OllamaCancelledException, closes the '
        'stream and stops reading the body', () async {
      final body = ControlledBody();
      final server = FakeServer((_) => body.response());
      final token = OllamaCancelToken();
      final received = <String>[];
      Object? error;
      final done = Completer<void>();
      server.ollama().chatTextStream([const OllamaMessage.user('x')],
          cancelToken:
              token).listen(received.add,
          onError: (Object e) => error = e, onDone: done.complete);
      body.addJson(chatChunk('one'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      await done.future.timeout(const Duration(seconds: 2));
      expect(received, ['one']);
      expect(error, isA<OllamaCancelledException>());
      expect(body.cancelled, isTrue, reason: 'the HTTP body must be released');
    });

    test('breaking out of await-for aborts the HTTP request', () async {
      final body = ControlledBody();
      final server = FakeServer((_) => body.response());
      var aborted = false;
      final stream = server.ollama().askStream('x');
      body.addJson(generateChunk('a'));
      body.addJson(generateChunk('b'));
      await for (final text in stream) {
        expect(text, 'a');
        unawaited(server.last.abortTrigger!.then((_) => aborted = true));
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(aborted, isTrue);
      expect(body.cancelled, isTrue);
    });

    test('an already-cancelled token fails without sending', () async {
      final server = FakeServer.json({'version': '1'});
      final token = OllamaCancelToken()..cancel();
      await expectLater(server.ollama().version(cancelToken: token),
          throwsA(isA<OllamaCancelledException>()));
      expect(server.requests, isEmpty);
    });

    test('one token cancels several requests', () async {
      final server =
          FakeServer((_) => Completer<http.StreamedResponse>().future);
      final ollama = server.ollama();
      final token = OllamaCancelToken();
      final a = ollama.ask('a', cancelToken: token);
      final b = ollama.askStream('b', cancelToken: token).toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      await expectLater(a, throwsA(isA<OllamaCancelledException>()));
      await expectLater(b, throwsA(isA<OllamaCancelledException>()));
    });

    test(
        'close() aborts in-flight calls and rejects new ones, but does not '
        'close an injected http client', () async {
      final body = ControlledBody();
      var calls = 0;
      final server = FakeServer((_) {
        calls++;
        return body.response();
      });
      final ollama = server.ollama();
      final stream = ollama.askStream('x').toList();
      body.addJson(generateChunk('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ollama.close();
      expect(ollama.isClosed, isTrue);
      await expectLater(stream, throwsA(isA<OllamaCancelledException>()));
      await expectLater(
          ollama.version(), throwsA(isA<OllamaCancelledException>()));
      expect(calls, 1);

      // The shared client still works for others.
      final other = Ollama(httpClient: server.client);
      server.handler = (_) => jsonResponse({'version': '0.40.16'});
      expect(await other.version(), '0.40.16');
    });

    test('cancel during a retry back-off stops the retries', () async {
      final server =
          FakeServer((_) => jsonResponse({'error': 'busy'}, status: 503));
      final token = OllamaCancelToken();
      final future = server
          .ollama(
            retryPolicy: const OllamaRetryPolicy(
                maxRetries: 5, initialDelay: Duration(seconds: 10), jitter: 0),
          )
          .version(cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await expectLater(future, throwsA(isA<OllamaCancelledException>()));
      expect(server.requests, hasLength(1));
    });

    test('OllamaCancelToken.any and .after', () async {
      final a = OllamaCancelToken();
      final b = OllamaCancelToken();
      final any = OllamaCancelToken.any([a, null, b]);
      expect(any.isCancelled, isFalse);
      b.cancel('b');
      expect(any.isCancelled, isTrue);
      expect(any.reason, 'b');

      final timed = OllamaCancelToken.after(const Duration(milliseconds: 10));
      await timed.whenCancelled;
      expect(timed.isCancelled, isTrue);
      expect(timed.throwIfCancelled, throwsA(isA<OllamaCancelledException>()));
    });

    test('listeners can be removed and fire once', () {
      final token = OllamaCancelToken();
      var count = 0;
      final remove = token.addListener(() => count++);
      token.addListener(() => count += 10);
      remove();
      token
        ..cancel()
        ..cancel();
      expect(count, 10);
    });
  });
}
