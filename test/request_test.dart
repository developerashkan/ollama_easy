import 'dart:convert';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

Map<String, Object?> chatDone([String text = 'ok']) =>
    {...chatChunk(text, done: true), ...doneStats};

void main() {
  group('base URL', () {
    test('variants all resolve to the right endpoint', () async {
      final cases = <Object, String>{
        Uri.parse('http://localhost:11434'):
            'http://localhost:11434/api/version',
        Uri.parse('http://localhost:11434/'):
            'http://localhost:11434/api/version',
        Uri.parse('http://localhost:11434/api'):
            'http://localhost:11434/api/version',
        Uri.parse('http://localhost:11434/api/'):
            'http://localhost:11434/api/version',
        Uri.parse('https://proxy.example.com/ollama/'):
            'https://proxy.example.com/ollama/api/version',
        Uri.parse('https://ollama.com/api'): 'https://ollama.com/api/version',
        // Regression: no scheme used to produce "localhost:11434/api/version".
        Uri.parse('localhost:11434'): 'http://localhost:11434/api/version',
        Uri.parse('http://0.0.0.0:11434'): 'http://127.0.0.1:11434/api/version',
      };
      for (final entry in cases.entries) {
        final server = FakeServer.json({'version': '1'});
        await server.ollama(baseUrl: entry.key as Uri).version();
        expect(server.last.url.toString(), entry.value, reason: '${entry.key}');
      }
    });

    test('parseHost follows OLLAMA_HOST rules', () {
      expect(
          Ollama.parseHost('localhost').toString(), 'http://localhost:11434');
      expect(
          Ollama.parseHost('10.0.0.5:8080').toString(), 'http://10.0.0.5:8080');
      expect(Ollama.parseHost('0.0.0.0').toString(), 'http://127.0.0.1:11434');
      expect(Ollama.parseHost('https://example.com').toString(),
          'https://example.com');
      expect(Ollama.parseHost('http://example.com/path/').toString(),
          'http://example.com/path');
      expect(Ollama.parseHost('[::1]:9000').toString(), 'http://[::1]:9000');
      expect(Ollama.parseHost('').toString(), 'http://localhost:11434');
      expect(() => Ollama(baseUrl: Uri.parse('ftp://x')), throwsArgumentError);
    });

    test('host: and factories', () async {
      final server = FakeServer.json({'version': '1'});
      await Ollama(host: 'gpu-box:8000', httpClient: server.client).version();
      expect(server.last.url.toString(), 'http://gpu-box:8000/api/version');
      await Ollama.androidEmulator(httpClient: server.client).version();
      expect(server.last.url.host, '10.0.2.2');
      await Ollama.local(httpClient: server.client, port: 1234).version();
      expect(server.last.url.toString(), 'http://localhost:1234/api/version');
      await Ollama.cloud(apiKey: 'k', httpClient: server.client).version();
      expect(server.last.url.toString(), 'https://ollama.com/api/version');
      expect(server.last.headers['Authorization'], 'Bearer k');
      await Ollama.fromEnvironment(httpClient: server.client).version();
      expect(server.requests, hasLength(5));
    });
  });

  group('request bodies', () {
    test('regression: nested nulls in schemas and arguments are preserved',
        () async {
      final server = FakeServer((_) => jsonResponse(chatDone('{}')));
      final schema = {
        'type': 'object',
        'properties': {
          'nickname': {
            'type': ['string', 'null'],
            'default': null,
          },
        },
      };
      await server.ollama().chat(
            [
              OllamaMessage.assistant('', toolCalls: [
                const OllamaToolCall(name: 'f', arguments: {'optional': null}),
              ]),
            ],
            format: schema,
            options: {'seed': null, 'temperature': 0},
          );
      final body = server.last.json;
      expect(body['format'], schema);
      final message = (body['messages'] as List).single as Map;
      expect(((message['tool_calls'] as List).single as Map)['function'], {
        'name': 'f',
        'arguments': {'optional': null}
      });
      // Top-level nulls are still dropped.
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('keep_alive'), isFalse);
    });

    test('think, format and keepAlive accept typed and plain values', () async {
      final server = FakeServer((_) => jsonResponse(chatDone()));
      final ollama = server.ollama();
      const messages = [OllamaMessage.user('x')];
      await ollama.chat(messages,
          think: OllamaThink.high,
          format: OllamaFormat.json,
          keepAlive: const Duration(minutes: 10));
      expect(server.last.json['think'], 'high');
      expect(server.last.json['format'], 'json');
      expect(server.last.json['keep_alive'], 600);
      await ollama.chat(messages,
          think: false,
          format: const OllamaFormat.schema({'type': 'object'}),
          keepAlive: '1h');
      expect(server.last.json['think'], false);
      expect(server.last.json['format'], {'type': 'object'});
      expect(server.last.json['keep_alive'], '1h');
      await ollama.chat(messages, keepAlive: const Duration(seconds: -1));
      expect(server.last.json['keep_alive'], -1);
      await ollama.chat(messages,
          keepAlive: const Duration(milliseconds: 1500));
      expect(server.last.json['keep_alive'], '1500ms');
      expect(() => ollama.chat(messages, think: 3), throwsArgumentError);
    });

    test('ModelOptions is a map, merges with defaultOptions', () async {
      final server = FakeServer((_) => jsonResponse(chatDone()));
      final ollama = server.ollama(
        defaultOptions: ModelOptions(numCtx: 8192, temperature: 0.8),
        defaultKeepAlive: '30m',
      );
      await ollama.chat([const OllamaMessage.user('x')],
          options: ModelOptions(
              temperature: 0.1, stop: ['\n\n'], extra: {'future_knob': 1}));
      expect(server.last.json['options'], {
        'num_ctx': 8192,
        'temperature': 0.1,
        'stop': ['\n\n'],
        'future_knob': 1,
      });
      expect(server.last.json['keep_alive'], '30m');
    });

    test('generate sends every documented field', () async {
      final server =
          FakeServer((_) => jsonResponse(generateChunk('x', done: true)));
      await server.ollama().generate(
            'def add(a, b):',
            model: 'codellama',
            suffix: '    return',
            system: 'sys',
            template: '{{ .Prompt }}',
            images: ['data:image/png;base64,QUJD\n'],
            raw: true,
            logprobs: true,
            topLogprobs: 3,
            truncate: false,
            shift: false,
            context: [1, 2],
          );
      expect(server.last.json, {
        'model': 'codellama',
        'prompt': 'def add(a, b):',
        'suffix': '    return',
        'system': 'sys',
        'template': '{{ .Prompt }}',
        'images': ['QUJD'],
        'raw': true,
        'stream': false,
        'logprobs': true,
        'top_logprobs': 3,
        'truncate': false,
        'shift': false,
        'context': [1, 2],
      });
    });

    test('images: bytes helper and data-URL stripping in messages', () async {
      final server = FakeServer((_) => jsonResponse(chatDone()));
      await server.ollama().chat([
        OllamaMessage.user('What is this?', images: [
          OllamaImage.fromBytes(utf8.encode('ABC')),
          'data:image/jpeg;base64,REVG',
        ]),
      ]);
      final message = (server.last.json['messages'] as List).single as Map;
      expect(message['images'], ['QUJD', 'REVG']);
    });

    test('tool results carry tool_name and tool_call_id', () async {
      final server = FakeServer((_) => jsonResponse(chatDone()));
      const call =
          OllamaToolCall(name: 'get_weather', arguments: {}, id: 'call_1');
      await server.ollama().chat([
        const OllamaMessage.user('weather?'),
        const OllamaMessage.assistant('', toolCalls: [call]),
        OllamaMessage.toolResult(call, {'celsius': 21}),
      ]);
      final tool = (server.last.json['messages'] as List).last as Map;
      expect(tool, {
        'role': 'tool',
        'content': '{"celsius":21}',
        'tool_name': 'get_weather',
        'tool_call_id': 'call_1',
      });
    });
  });

  group('headers and interceptors', () {
    test('API key, custom headers and accept headers are sent', () async {
      final server = FakeServer.json({'version': '1'});
      await server.ollama(apiKey: 'secret', headers: {'X-Team': 'a'}).version();
      expect(server.last.headers['Authorization'], 'Bearer secret');
      expect(server.last.headers['X-Team'], 'a');
      expect(server.last.headers['Accept'], contains('application/x-ndjson'));
      // Browsers forbid setting User-Agent, so it is only sent off the web.
      const isWeb = bool.fromEnvironment('dart.library.js_interop');
      expect(server.last.headers['User-Agent'],
          isWeb ? isNull : startsWith('ollama_easy/'));
    });

    test('interceptors can rewrite headers, uri and body; see responses',
        () async {
      final server = FakeServer.json({'version': '1'});
      final statuses = <int>[];
      await server.ollama(interceptors: [
        OllamaCallbackInterceptor(
          onRequest: (request) async {
            request.headers['Authorization'] = 'Bearer fresh';
            request.uri = request.uri.replace(queryParameters: {'trace': '1'});
          },
          onResponse: (response) => statuses.add(response.statusCode),
        ),
      ]).version();
      expect(server.last.headers['Authorization'], 'Bearer fresh');
      expect(server.last.url.queryParameters['trace'], '1');
      expect(statuses, [200]);
    });

    test('OllamaLogInterceptor redacts secrets and truncates bodies', () async {
      final lines = <String>[];
      final server = FakeServer((_) => jsonResponse(chatDone()));
      await server.ollama(apiKey: 'super-secret', interceptors: [
        OllamaLogInterceptor(
            logger: lines.add,
            logHeaders: true,
            logBody: true,
            maxBodyLength: 40),
      ]).chat([OllamaMessage.user('x' * 500)]);
      final log = lines.join('\n');
      expect(log, contains('--> POST http://localhost:11434/api/chat'));
      expect(log, contains('<-- 200'));
      expect(log, contains('Authorization: <redacted>'));
      expect(log, isNot(contains('super-secret')));
      expect(log, contains('chars)'));
    });
  });

  group('model management', () {
    test('hasModel matches implicit :latest (regression)', () async {
      final server = FakeServer.json({
        'models': [
          {'name': 'llama3:latest', 'model': 'llama3:latest'},
          {'name': 'hf.co/org/repo:Q4_K_M', 'model': 'hf.co/org/repo:Q4_K_M'},
        ],
      });
      final ollama = server.ollama();
      expect(await ollama.hasModel('llama3'), isTrue);
      expect(await ollama.hasModel('llama3:latest'), isTrue);
      expect(await ollama.hasModel('llama3:8b'), isFalse);
      expect(await ollama.hasModel('hf.co/org/repo:Q4_K_M'), isTrue);
      expect(Ollama.normalizeModelName('registry.io/ns/model'),
          'registry.io/ns/model:latest');
    });

    test('ensureModel pulls a missing model with progress', () async {
      final server = FakeServer((request) {
        if (request.path.endsWith('/tags')) return jsonResponse({'models': []});
        return ndjsonResponse([
          {'status': 'pulling manifest'},
          {
            'status': 'downloading',
            'digest': 'sha256:a',
            'total': 100,
            'completed': 50
          },
          {
            'status': 'downloading',
            'digest': 'sha256:a',
            'total': 100,
            'completed': 100
          },
          {'status': 'success'},
        ]);
      });
      final progress = <OllamaStatus>[];
      await server.ollama().ensureModel('qwen3', onProgress: progress.add);
      expect(server.last.path, '/api/pull');
      expect(server.last.json, {'model': 'qwen3', 'stream': true});
      expect(progress.map((s) => s.progress), [null, 0.5, 1.0, null]);
      expect(progress.last.isSuccess, isTrue);
    });

    test('show, ps, copy, delete, create, push, load, unload', () async {
      final server = FakeServer((request) {
        switch (request.path) {
          case '/api/show':
            return jsonResponse({
              'capabilities': ['completion', 'tools', 'thinking'],
              'model_info': {
                'general.architecture': 'qwen3',
                'qwen3.context_length': 40960
              },
              'parameters':
                  'temperature 0.6\nstop "<|im_end|>"\nstop "<|endoftext|>"',
              'thinking': {
                'values': [true, false],
                'default': true
              },
              'details': {'family': 'qwen3', 'quantization_level': 'Q4_K_M'},
            });
          case '/api/ps':
            return jsonResponse({
              'models': [
                {
                  'name': 'qwen3:latest',
                  'size': 1000,
                  'size_vram': 750,
                  'expires_at': '2026-11-10T12:00:00Z',
                  'context_length': 4096,
                }
              ]
            });
          case '/api/create':
          case '/api/push':
            return ndjsonResponse([
              {'status': 'working'},
              {'status': 'success'},
            ]);
          default:
            return jsonResponse('');
        }
      });
      final ollama = server.ollama();

      final info = await ollama.showModel('qwen3', verbose: true);
      expect(server.last.json, {'model': 'qwen3', 'verbose': true});
      expect(info.supportsTools, isTrue);
      expect(info.supportsVision, isFalse);
      expect(info.contextLength, 40960);
      expect(info.thinkingValues, [true, false]);
      expect(info.parameterMap, {
        'temperature': 0.6,
        'stop': ['<|im_end|>', '<|endoftext|>'],
      });
      expect(info.details?.quantizationLevel, 'Q4_K_M');

      final running = (await ollama.runningModels()).single;
      expect(running.gpuFraction, 0.75);
      expect(running.contextLength, 4096);
      expect(running.expiresAt, DateTime.utc(2026, 11, 10, 12));

      await ollama.copyModel('a', 'b');
      expect(server.last.json, {'source': 'a', 'destination': 'b'});
      await ollama.deleteModel('b');
      expect(server.last.method, 'DELETE');
      expect(server.last.json, {'model': 'b'});

      final statuses = <String>[];
      await ollama.createModel('mario',
          from: 'llama3.2',
          system: 'You are Mario.',
          parameters: {'temperature': 1},
          messages: [const OllamaMessage.user('hi')],
          onProgress: (s) => statuses.add(s.status));
      expect(server.last.json, {
        'model': 'mario',
        'from': 'llama3.2',
        'system': 'You are Mario.',
        'parameters': {'temperature': 1},
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'stream': true,
      });
      expect(statuses, ['working', 'success']);

      await ollama.push('me/mario', insecure: true);
      expect(server.last.json,
          {'model': 'me/mario', 'insecure': true, 'stream': true});

      await ollama.loadModel('qwen3', keepAlive: '1h');
      expect(server.last.json,
          {'model': 'qwen3', 'keep_alive': '1h', 'stream': false});
      await ollama.unloadModel('qwen3');
      expect(server.last.json,
          {'model': 'qwen3', 'keep_alive': 0, 'stream': false});
    });

    test('blobs: HEAD 404 is false, 200 is true; upload sends raw bytes',
        () async {
      var exists = false;
      final server = FakeServer((request) {
        if (request.method == 'HEAD') {
          return jsonResponse('', status: exists ? 200 : 404);
        }
        return jsonResponse('', status: 201);
      });
      final ollama = server.ollama();
      expect(await ollama.blobExists('sha256:abc'), isFalse);
      expect(server.last.url.path, '/api/blobs/sha256:abc');
      exists = true;
      expect(await ollama.blobExists('sha256:abc'), isTrue);
      await ollama.pushBlob('sha256:abc', [1, 2, 3]);
      expect(server.last.bodyBytes, [1, 2, 3]);
      expect(server.last.headers['Content-Type'], 'application/octet-stream');
    });

    test('web search uses the cloud path on ollama.com, the proxy locally',
        () async {
      final server = FakeServer((request) => request.path.contains('web_search')
          ? jsonResponse({
              'results': [
                {'title': 'T', 'url': 'https://x', 'content': 'C'}
              ]
            })
          : jsonResponse({
              'title': 'Page',
              'content': 'Body',
              'links': ['a']
            }));
      final cloud = Ollama.cloud(apiKey: 'k', httpClient: server.client);
      final hits = await cloud.webSearch('dart', maxResults: 2);
      expect(server.last.url.toString(), 'https://ollama.com/api/web_search');
      expect(server.last.json, {'query': 'dart', 'max_results': 2});
      expect(hits.single.title, 'T');
      final page = await cloud.webFetch('https://x');
      expect(page.links, ['a']);

      await server.ollama().webSearch('dart');
      expect(server.last.url.path, '/api/experimental/web_search');

      final tools = cloud.webTools();
      expect(tools.map((t) => t.name), ['web_search', 'web_fetch']);
      expect(await tools.first.handler!({'query': 'q'}), [
        {'title': 'T', 'url': 'https://x', 'content': 'C'}
      ]);
    });
  });

  group('embeddings', () {
    test('embed uses /api/embed with the default embedding model', () async {
      final server = FakeServer.json({
        'model': 'embeddinggemma',
        'embeddings': [
          [0.1, 0.2],
          [0.3, 0.4]
        ],
      });
      final result = await server
          .ollama()
          .embed(['a', 'b'], dimensions: 2, truncate: true);
      expect(server.last.path, '/api/embed');
      expect(server.last.json, {
        'model': 'embeddinggemma',
        'input': ['a', 'b'],
        'truncate': true,
        'dimensions': 2
      });
      expect(result.embeddings, hasLength(2));
      expect(result.dimensions, 2);
      expect(await server.ollama().embedText('a'), [0.1, 0.2]);
    });

    test('embedMany batches, keeps order and reports progress', () async {
      final server = FakeServer((request) {
        final input = (request.json['input'] as List).cast<String>();
        return jsonResponse({
          'embeddings': [
            for (final text in input) [double.parse(text)]
          ]
        });
      });
      final inputs = [for (var i = 0; i < 10; i++) '$i'];
      final progress = <int>[];
      final vectors = await server.ollama().embedMany(inputs,
          batchSize: 3,
          concurrency: 2,
          onProgress: (done, _) => progress.add(done));
      expect(vectors, [
        for (var i = 0; i < 10; i++) [i.toDouble()]
      ]);
      expect(server.requests, hasLength(4));
      expect(progress.last, 10);
      expect(await server.ollama().embedMany([]), isEmpty);
    });

    test('embedMany detects a short response', () async {
      final server = FakeServer.json({
        'embeddings': [
          [1.0]
        ]
      });
      await expectLater(server.ollama().embedMany(['a', 'b']),
          throwsA(isA<OllamaResponseFormatException>()));
    });

    test('cosineSimilarity', () {
      expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-9));
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0, 1e-9));
      expect(cosineSimilarity([1, 1], [-1, -1]), closeTo(-1, 1e-9));
      expect(() => cosineSimilarity([1], [1, 2]), throwsArgumentError);
    });
  });
}
