import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

void main() {
  group('forward compatibility', () {
    test('unknown message fields and roles survive a round trip', () {
      final message = OllamaMessage.fromJson({
        'role': 'developer',
        'content': 'hi',
        'future_field': {'x': 1},
      });
      expect(message.role, OllamaRole.assistant);
      expect(message.toJson(), {
        'role': 'developer',
        'content': 'hi',
        'future_field': {'x': 1},
      });
    });

    test('responses keep the raw JSON and expose newer fields', () {
      final response = OllamaChatResponse.fromJson({
        'model': 'gpt-oss:120b-cloud',
        'message': {'role': 'assistant', 'content': 'x'},
        'done': true,
        'done_reason': 'brand_new_reason',
        'remote_model': 'gpt-oss:120b',
        'remote_host': 'https://ollama.com:443',
        'prompt_eval_cached_count': 7,
        'something_new': true,
        'logprobs': [
          {
            'token': 'x',
            'logprob': -0.1,
            'top_logprobs': [
              {'token': 'y', 'logprob': -2.0}
            ]
          }
        ],
      });
      expect(response.reason, const OllamaDoneReason('brand_new_reason'));
      expect(response.reason!.isTruncated, isFalse);
      expect(const OllamaDoneReason('length').isTruncated, isTrue);
      expect(response.remoteModel, 'gpt-oss:120b');
      expect(response.remoteHost, isNotNull);
      expect(response.promptEvalCachedCount, 7);
      expect(response.raw['something_new'], isTrue);
      expect(response.tokenLogprobs.single.topLogprobs.single.token, 'y');
    });

    test('models, details and status parse leniently', () {
      final model = OllamaModel.fromJson({
        'name': 'gpt-oss:120b-cloud',
        'size': '384',
        'details': {'family': 'gptoss', 'context_length': 131072},
        'capabilities': ['completion', 'tools'],
      });
      expect(model.size, 384);
      expect(model.isRemote, isTrue);
      expect(model.capabilities, contains('tools'));
      expect(model.details?.contextLength, 131072);

      const status = OllamaStatus(status: 'x', raw: {}, total: 0, completed: 0);
      expect(status.progress, isNull);
      expect(
          OllamaStatus.fromJson(
              {'status': 'downloading', 'total': 4, 'completed': 1}).toString(),
          contains('25.0%'));
    });

    test('embed response first throws a descriptive StateError', () {
      const empty =
          OllamaEmbedResponse(model: 'llama3', embeddings: [], raw: {});
      expect(() => empty.first, throwsA(isA<StateError>()));
      expect(empty.dimensions, 0);
    });
  });

  group('ModelOptions', () {
    test('fromJson keeps unknown keys in extra; copyWith and merge', () {
      final options = ModelOptions.fromJson({
        'temperature': 0.5,
        'num_ctx': 4096,
        'brand_new': 'x',
      });
      expect(options.temperature, 0.5);
      expect(options.extra, {'brand_new': 'x'});
      expect(options['brand_new'], 'x');
      expect(options.copyWith(temperature: 1).temperature, 1);
      final merged = options.merge({'num_ctx': 8192, 'seed': 3});
      expect(merged.numCtx, 8192);
      expect(merged.seed, 3);
      expect(merged.temperature, 0.5);
      expect(ModelOptions(topK: 10).toJson(), {'top_k': 10});
      expect(() => (options as Map)['x'] = 1, throwsUnsupportedError);
    });
  });

  group('helpers', () {
    test('OllamaImage.normalize', () {
      expect(OllamaImage.normalize('data:image/png;base64,AAA='), 'AAA=');
      expect(OllamaImage.normalize(' AA\nA= '), 'AAA=');
      expect(OllamaImage.normalize('AAA='), 'AAA=');
    });

    test('encodeToolResult', () {
      expect(encodeToolResult('text'), 'text');
      expect(encodeToolResult(null), 'null');
      expect(
          encodeToolResult({
            'a': [1]
          }),
          '{"a":[1]}');
      expect(encodeToolResult(Object()), startsWith("Instance of"));
    });

    test('OllamaThink and OllamaFormat encoding', () {
      expect(OllamaThink.encode(OllamaThink.enabled), true);
      expect(OllamaThink.encode(const OllamaThink.level('max')), 'max');
      expect(OllamaThink.encode('low'), 'low');
      expect(OllamaThink.encode(null), isNull);
      expect(OllamaFormat.encode('json'), 'json');
      expect(encodeKeepAlive(300), 300);
      expect(() => encodeKeepAlive(true), throwsArgumentError);
    });
  });
}
