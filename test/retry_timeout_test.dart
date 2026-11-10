import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

const fastRetry = OllamaRetryPolicy(
  maxRetries: 3,
  initialDelay: Duration(milliseconds: 1),
  jitter: 0,
);

void main() {
  group('retries', () {
    test('503 then success is retried transparently', () async {
      var calls = 0;
      final server = FakeServer((_) {
        calls++;
        return calls < 3
            ? jsonResponse({'error': 'loading'}, status: 503)
            : jsonResponse({'version': '0.40.16'});
      });
      expect(await server.ollama(retryPolicy: fastRetry).version(), '0.40.16');
      expect(calls, 3);
    });

    test('connection errors are retried, 400s are not', () async {
      var calls = 0;
      final flaky = FakeServer((_) {
        calls++;
        if (calls == 1) throw http.ClientException('reset by peer');
        return jsonResponse({'version': '1'});
      });
      expect(await flaky.ollama(retryPolicy: fastRetry).version(), '1');
      expect(calls, 2);

      final bad =
          FakeServer((_) => jsonResponse({'error': 'bad'}, status: 400));
      await expectLater(bad.ollama(retryPolicy: fastRetry).version(),
          throwsA(isA<OllamaBadRequestException>()));
      expect(bad.requests, hasLength(1));
    });

    test('gives up after maxRetries', () async {
      final server =
          FakeServer((_) => jsonResponse({'error': 'x'}, status: 502));
      await expectLater(server.ollama(retryPolicy: fastRetry).version(),
          throwsA(isA<OllamaServerException>()));
      expect(server.requests, hasLength(4));
    });

    test('Retry-After is honoured (clamped to maxDelay)', () async {
      var calls = 0;
      final server = FakeServer((_) {
        calls++;
        return calls == 1
            ? jsonResponse({'error': 'rate'},
                status: 429, headers: {'retry-after': '3600'})
            : jsonResponse({'version': '1'});
      });
      final stopwatch = Stopwatch()..start();
      await server
          .ollama(
              retryPolicy: const OllamaRetryPolicy(
                  maxDelay: Duration(milliseconds: 50), jitter: 0))
          .version();
      expect(stopwatch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 45)));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('streams retry before the first chunk but never after', () async {
      var calls = 0;
      final server = FakeServer((_) {
        calls++;
        if (calls == 1) return jsonResponse({'error': 'busy'}, status: 503);
        return ndjsonResponse([
          generateChunk('a'),
          {'error': 'crashed'}
        ]);
      });
      final received = <String>[];
      await expectLater(
        server
            .ollama(retryPolicy: fastRetry)
            .askStream('x')
            .forEach(received.add),
        throwsA(isA<OllamaStreamException>()),
      );
      expect(calls, 2, reason: 'one retry for the 503, none for the crash');
      expect(received, ['a']);
    });

    test('interceptors see every attempt number', () async {
      final attempts = <int>[];
      var calls = 0;
      final server = FakeServer((_) => ++calls == 1
          ? jsonResponse({'error': 'x'}, status: 503)
          : jsonResponse({'version': '1'}));
      await server.ollama(retryPolicy: fastRetry, interceptors: [
        OllamaCallbackInterceptor(onRequest: (r) => attempts.add(r.attempt)),
      ]).version();
      expect(attempts, [1, 2]);
    });

    test('delayFor grows exponentially and respects maxDelay and jitter', () {
      const policy = OllamaRetryPolicy(
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 350),
        jitter: 0,
      );
      const error = OllamaServerException('x', statusCode: 503);
      expect(policy.delayFor(1, error), const Duration(milliseconds: 100));
      expect(policy.delayFor(2, error), const Duration(milliseconds: 200));
      expect(policy.delayFor(3, error), const Duration(milliseconds: 350));
      const jittery = OllamaRetryPolicy(
          initialDelay: Duration(milliseconds: 100), jitter: 0.5);
      for (var i = 0; i < 20; i++) {
        final delay = jittery.delayFor(1, error, math.Random(i)).inMilliseconds;
        expect(delay, inInclusiveRange(50, 150));
      }
      expect(OllamaRetryPolicy.none.canRetry(error, 1), isFalse);
      expect(
          OllamaRetryPolicy(shouldRetry: (e, attempt) => attempt < 2).canRetry(
              const OllamaBadRequestException('x', statusCode: 400), 1),
          isTrue);
    });
  });

  group('timeouts', () {
    test('a server that never answers → OllamaTimeoutException', () async {
      final server =
          FakeServer((_) => Completer<http.StreamedResponse>().future);
      final stopwatch = Stopwatch()..start();
      await expectLater(
        server.ollama(timeout: const Duration(milliseconds: 50)).version(),
        throwsA(isA<OllamaTimeoutException>().having(
            (e) => e.timeout, 'timeout', const Duration(milliseconds: 50))),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(server.last.abortTrigger, isNotNull);
    });

    test('a slow body on a non-streaming call is bounded by the timeout',
        () async {
      final body = ControlledBody();
      final server = FakeServer((_) => body.response());
      await expectLater(
        server.ollama(timeout: const Duration(milliseconds: 50)).version(),
        throwsA(isA<OllamaTimeoutException>()),
      );
      expect(body.cancelled, isTrue);
    });

    test('a stalled stream → OllamaTimeoutException after the idle timeout',
        () async {
      final body = ControlledBody();
      final server = FakeServer((_) => body.response());
      final received = <String>[];
      final ollama = server.ollama(
          streamIdleTimeout: const Duration(milliseconds: 60),
          timeout: const Duration(seconds: 5));
      final future = ollama.askStream('x').forEach(received.add);
      for (var i = 0; i < 4; i++) {
        // Chunks arriving faster than the idle timeout keep the stream alive,
        // even though the total time exceeds it.
        body.addJson(generateChunk('$i'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await expectLater(future, throwsA(isA<OllamaTimeoutException>()));
      expect(received, ['0', '1', '2', '3']);
      expect(body.cancelled, isTrue);
    });

    test('a null timeout disables the limit', () async {
      final server = FakeServer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return jsonResponse({'version': '1'});
      });
      expect(await server.ollama(timeout: null).version(), '1');
    });

    test('isRunning returns false quickly for a hanging server', () async {
      final server =
          FakeServer((_) => Completer<http.StreamedResponse>().future);
      final stopwatch = Stopwatch()..start();
      expect(
          await server
              .ollama(timeout: null)
              .isRunning(timeout: const Duration(milliseconds: 50)),
          isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('timeouts are not retried by default', () async {
      final server =
          FakeServer((_) => Completer<http.StreamedResponse>().future);
      await expectLater(
        server
            .ollama(
                timeout: const Duration(milliseconds: 20),
                retryPolicy: fastRetry)
            .version(),
        throwsA(isA<OllamaTimeoutException>()),
      );
      expect(server.requests, hasLength(1));
    });
  });
}
