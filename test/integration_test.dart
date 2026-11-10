// Runs against a real Ollama server. Skipped automatically when none is
// reachable.
//
//   ollama serve &
//   ollama pull qwen2.5:0.5b            # any small chat model
//   OLLAMA_TEST_MODEL=qwen2.5:0.5b dart test -t integration
//
// OLLAMA_HOST overrides the server (default http://localhost:11434).
// OLLAMA_TEST_EMBED_MODEL enables the embedding test.
@Tags(['integration'])
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

void main() {
  late Ollama ollama;
  String? skipReason;
  String? chatModel;
  String? embedModel;

  setUpAll(() async {
    ollama = Ollama.fromEnvironment();
    if (!await ollama.isRunning()) {
      skipReason = 'No Ollama server at ${ollama.baseUrl}';
      return;
    }
    final installed = await ollama.models();
    chatModel = Platform.environment['OLLAMA_TEST_MODEL'] ??
        installed
            .where((m) => !m.name.contains('embed') && !m.isRemote)
            .map((m) => m.name)
            .firstOrNull;
    embedModel = Platform.environment['OLLAMA_TEST_EMBED_MODEL'] ??
        installed
            .where((m) => m.name.contains('embed'))
            .map((m) => m.name)
            .firstOrNull;
    if (chatModel == null) skipReason = 'No local chat model installed';
  });

  tearDownAll(() => ollama.close());

  bool skipped([String? need]) {
    final reason = skipReason ??
        (need == 'embed' && embedModel == null ? 'No embedding model' : null);
    if (reason != null) markTestSkipped(reason);
    return reason != null;
  }

  test('version and model list', () async {
    if (skipped()) return;
    expect(await ollama.version(), isNotEmpty);
    expect(await ollama.hasModel(chatModel!), isTrue);
    final info = await ollama.showModel(chatModel!);
    expect(info.capabilities, isNotEmpty);
  });

  test('streaming chat produces text and final metrics', () async {
    if (skipped()) return;
    final response = await ollama.chatStream(
      [const OllamaMessage.user('Reply with the single word: pong')],
      model: chatModel,
      options: ModelOptions(temperature: 0, numPredict: 20),
    ).collect();
    expect(response.text.toLowerCase(), contains('pong'));
    expect(response.done, isTrue);
    expect(response.evalCount, greaterThan(0));
  });

  test('cancelling a stream stops it', () async {
    if (skipped()) return;
    final token = OllamaCancelToken();
    var chunks = 0;
    await expectLater(
      ollama.chatTextStream([const OllamaMessage.user('Count from 1 to 500.')],
          model: chatModel, cancelToken: token).forEach((_) {
        if (++chunks == 3) token.cancel();
      }),
      throwsA(isA<OllamaCancelledException>()),
    );
    expect(chunks, 3);
  });

  test('structured output', () async {
    if (skipped()) return;
    final json = await ollama.askJson(
      'Give the capital of France.',
      model: chatModel,
      schema: OllamaSchema.object({'capital': OllamaSchema.string()}),
      options: ModelOptions(temperature: 0),
    );
    expect('${json['capital']}'.toLowerCase(), contains('paris'));
  });

  test('tool loop (if the model supports tools)', () async {
    if (skipped()) return;
    final info = await ollama.showModel(chatModel!);
    if (!info.supportsTools) {
      markTestSkipped('$chatModel does not support tools');
      return;
    }
    final run = await ollama.runTools(
      [const OllamaMessage.user('What is 1234 + 4321? Use the add tool.')],
      model: chatModel,
      options: ModelOptions(temperature: 0),
      tools: [
        OllamaTool.function(
          name: 'add',
          description: 'Adds two integers',
          parameters: OllamaSchema.object({
            'a': OllamaSchema.integer(),
            'b': OllamaSchema.integer(),
          }),
          handler: (args) => (args['a'] as num) + (args['b'] as num),
        ),
      ],
    );
    expect(run.text, contains('5555'));
  });

  test('embeddings', () async {
    if (skipped('embed')) return;
    final vectors = await ollama
        .embedMany(['cat', 'kitten', 'car'], model: embedModel, batchSize: 2);
    expect(vectors, hasLength(3));
    expect(cosineSimilarity(vectors[0], vectors[1]),
        greaterThan(cosineSimilarity(vectors[0], vectors[2])));
  });

  test('unknown model maps to OllamaNotFoundException', () async {
    if (skipped()) return;
    await expectLater(
      ollama.chat([const OllamaMessage.user('x')],
          model: 'definitely-not-a-model:1'),
      throwsA(isA<OllamaNotFoundException>()),
    );
  });
}
