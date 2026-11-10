import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  group('error mapping', () {
    Future<Object> errorFor(int status, Object body,
        {Map<String, String> headers = const {}}) async {
      final server = FakeServer((_) => jsonResponse(body,
          status: status,
          headers: {'content-type': 'application/json', ...headers}));
      try {
        await server.ollama().chat([const OllamaMessage.user('x')]);
      } catch (error) {
        return error;
      }
      fail('expected an error');
    }

    test('404 → OllamaNotFoundException with the server message', () async {
      final error = await errorFor(404, {'error': "model 'llama9' not found"});
      expect(error, isA<OllamaNotFoundException>());
      error as OllamaNotFoundException;
      expect(error.message, "model 'llama9' not found");
      expect(error.statusCode, 404);
      expect(error.isModelNotFound, isTrue);
      expect(error.uri.toString(), 'http://localhost:11434/api/chat');
      expect(error.toString(), contains('HTTP 404'));
    });

    test('400 → OllamaBadRequestException', () async {
      expect(await errorFor(400, {'error': 'invalid format'}),
          isA<OllamaBadRequestException>());
    });

    test('401 and 403 → OllamaAuthenticationException', () async {
      expect(await errorFor(401, {'error': 'unauthorized', 'signin_url': 'x'}),
          isA<OllamaAuthenticationException>());
      expect(await errorFor(403, {'error': 'forbidden'}),
          isA<OllamaAuthenticationException>());
    });

    test('429 → OllamaRateLimitException with Retry-After', () async {
      final error = await errorFor(429, {'error': 'slow down'},
          headers: {'retry-after': '7'});
      expect(error, isA<OllamaRateLimitException>());
      expect((error as OllamaRateLimitException).retryAfter,
          const Duration(seconds: 7));
    });

    test('5xx → OllamaServerException; other codes → OllamaHttpException',
        () async {
      expect(await errorFor(500, {'error': 'out of memory'}),
          isA<OllamaServerException>());
      final teapot = await errorFor(418, {'error': 'teapot'});
      expect(teapot, isA<OllamaHttpException>());
      expect(teapot, isNot(isA<OllamaServerException>()));
      // Everything is still an OllamaException (backward compatible).
      expect(teapot, isA<OllamaException>());
    });

    test('plain-text and OpenAI-style error bodies give useful messages',
        () async {
      final plain = await errorFor(502, 'Bad Gateway from nginx');
      expect((plain as OllamaException).message, 'Bad Gateway from nginx');
      final openAi = await errorFor(400, {
        'error': {'message': 'bad things', 'type': 'invalid_request_error'}
      });
      expect((openAi as OllamaException).message, 'bad things');
      final empty = await errorFor(500, '');
      expect((empty as OllamaException).message, contains('HTTP 500'));
    });

    test('a non-2xx status on a streaming endpoint fails the stream', () async {
      final server = FakeServer(
          (_) => jsonResponse({'error': "model 'x' not found"}, status: 404));
      await expectLater(server.ollama().askStream('x').toList(),
          throwsA(isA<OllamaNotFoundException>()));
    });

    test('connection failures → OllamaConnectionException with the cause',
        () async {
      final client = MockClient(
          (_) async => throw http.ClientException('Connection refused'));
      final ollama =
          Ollama(httpClient: client, retryPolicy: OllamaRetryPolicy.none);
      await expectLater(
        ollama.version(),
        throwsA(isA<OllamaConnectionException>()
            .having((e) => e.message, 'message', contains('Connection refused'))
            .having((e) => e.cause, 'cause', isA<http.ClientException>())),
      );
      expect(await ollama.isRunning(), isFalse);
    });

    test('a non-JSON 200 body → OllamaResponseFormatException', () async {
      final server =
          FakeServer((_) => jsonResponse('<html>proxy login</html>'));
      await expectLater(server.ollama().version(),
          throwsA(isA<OllamaResponseFormatException>()));
      server.handler = (_) => jsonResponse([1, 2]);
      await expectLater(server.ollama().version(),
          throwsA(isA<OllamaResponseFormatException>()));
    });

    test('regression: UTF-8 JSON without a charset is not decoded as latin1',
        () async {
      final server = FakeServer((_) => http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({
              'model': 'm',
              'response': 'Grüße, سلام 😀',
              'done': true,
            }))),
            200,
            headers: {'content-type': 'text/plain'},
          ));
      expect(await server.ollama().ask('x'), 'Grüße, سلام 😀');
    });

    test('interceptor onError sees the final error once', () async {
      final errors = <OllamaException>[];
      final server =
          FakeServer((_) => jsonResponse({'error': 'nope'}, status: 503));
      final ollama = server.ollama(
        retryPolicy: const OllamaRetryPolicy(
            maxRetries: 2, initialDelay: Duration.zero, jitter: 0),
        interceptors: [
          OllamaCallbackInterceptor(onError: (error, _) => errors.add(error)),
        ],
      );
      await expectLater(
          ollama.version(), throwsA(isA<OllamaServerException>()));
      expect(server.requests, hasLength(3));
      expect(errors, hasLength(1));
    });

    test('OllamaException keeps its original public constructor', () {
      const error = OllamaException('boom', statusCode: 500);
      expect(error.message, 'boom');
      expect(error.toString(), 'OllamaException: HTTP 500. boom');
    });

    test('parseRetryAfter handles seconds and HTTP dates', () {
      expect(OllamaException.parseRetryAfter('1.5'),
          const Duration(milliseconds: 1500));
      expect(OllamaException.parseRetryAfter(null), isNull);
      expect(OllamaException.parseRetryAfter('Wed, 21 Oct 2015 07:28:00 GMT'),
          Duration.zero);
    });
  });
}
