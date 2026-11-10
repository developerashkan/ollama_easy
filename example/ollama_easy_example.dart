// A tour of ollama_easy. Start Ollama, pull a small model, then run:
//
//   ollama pull qwen2.5:1.5b
//   dart run example/ollama_easy_example.dart            # all demos
//   dart run example/ollama_easy_example.dart tools      # one demo
//
// Set OLLAMA_HOST / OLLAMA_API_KEY to use a remote server or Ollama cloud, and
// OLLAMA_MODEL to pick another model.
import 'dart:io';

import 'package:ollama_easy/ollama_easy.dart';

final model = Platform.environment['OLLAMA_MODEL'] ?? 'qwen2.5:1.5b';

Future<void> main(List<String> args) async {
  final ollama = Ollama.fromEnvironment(defaultModel: model);
  if (!await ollama.isRunning()) {
    stderr.writeln('Ollama is not reachable at ${ollama.baseUrl}. '
        'Start it with `ollama serve`.');
    exit(1);
  }

  final demos = <String, Future<void> Function(Ollama)>{
    'pull': pullWithProgress,
    'stream': streamChat,
    'tools': toolLoop,
    'structured': structuredOutput,
    'conversation': conversation,
    'embeddings': embeddings,
    'cancel': cancelAfterOneSecond,
    'models': listModels,
  };
  final selected = args.isEmpty ? demos.keys : args;
  try {
    for (final name in selected) {
      final demo = demos[name];
      if (demo == null) {
        stderr.writeln('Unknown demo "$name". Try: ${demos.keys.join(', ')}');
        continue;
      }
      stdout.writeln('\n=== $name ===');
      await demo(ollama);
    }
  } on OllamaNotFoundException catch (error) {
    stderr.writeln('\n${error.message}. Run: ollama pull $model');
  } on OllamaException catch (error) {
    stderr.writeln('\n$error');
  } finally {
    ollama.close();
  }
}

/// Pulls the model if needed, printing a progress bar.
Future<void> pullWithProgress(Ollama ollama) async {
  await ollama.ensureModel(model, onProgress: (status) {
    final progress = status.progress;
    final bar = progress == null
        ? ''
        : ' [${'#' * (progress * 30).round()}${' ' * (30 - (progress * 30).round())}] '
            '${(progress * 100).toStringAsFixed(0)}%';
    stdout.write('\r${status.status}$bar'.padRight(80));
  });
  stdout.writeln('\n$model is ready.');
}

/// Streams a reply token by token, then prints the speed.
Future<void> streamChat(Ollama ollama) async {
  final accumulator = OllamaChatAccumulator();
  await for (final chunk in ollama.chatStream(
    [const OllamaMessage.user('Explain Dart isolates in two sentences.')],
    options: ModelOptions(temperature: 0.3),
  )) {
    accumulator.add(chunk);
    stdout.write(chunk.text);
  }
  final stats = accumulator.response;
  stdout.writeln('\n(${stats.evalCount} tokens, '
      '${stats.tokensPerSecond?.toStringAsFixed(1)} tok/s)');
}

/// Lets the model call Dart functions until it can answer.
Future<void> toolLoop(Ollama ollama) async {
  final weather = OllamaTool.function(
    name: 'get_weather',
    description: 'Get the current temperature for a city in Celsius',
    parameters: OllamaSchema.object({
      'city': OllamaSchema.string(description: 'City name, e.g. Paris'),
    }),
    handler: (args) => {'city': args['city'], 'celsius': 18},
  );
  final run = await ollama.runTools(
    [const OllamaMessage.user('What is the weather in Paris and in Tokyo?')],
    tools: [weather],
    onToolResult: (call) =>
        stdout.writeln('  ↳ ${call.call} = ${call.message.content}'),
  );
  stdout.writeln(run.text);
}

class Recipe {
  Recipe(this.name, this.minutes, this.ingredients);

  factory Recipe.fromJson(Map<String, Object?> json) => Recipe(
        json['name']! as String,
        (json['minutes']! as num).toInt(),
        (json['ingredients']! as List).cast<String>(),
      );

  final String name;
  final int minutes;
  final List<String> ingredients;
}

/// Gets JSON matching a schema, decoded into a Dart class.
Future<void> structuredOutput(Ollama ollama) async {
  final recipe = await ollama.askStructured(
    'Give me a quick pancake recipe.',
    schema: OllamaSchema.object({
      'name': OllamaSchema.string(),
      'minutes': OllamaSchema.integer(minimum: 1),
      'ingredients': OllamaSchema.array(OllamaSchema.string()),
    }),
    fromJson: Recipe.fromJson,
    options: ModelOptions(temperature: 0),
  );
  stdout.writeln('${recipe.name} (${recipe.minutes} min): '
      '${recipe.ingredients.join(', ')}');
}

/// A chat that remembers.
Future<void> conversation(Ollama ollama) async {
  final chat = ollama.conversation(
    system: 'You are a terse assistant.',
    maxMessages: 20,
  );
  stdout.writeln(await chat.send('My favourite colour is teal.'));
  await for (final delta in chat.sendStream('What is my favourite colour?')) {
    stdout.write(delta);
  }
  stdout.writeln();
}

/// Embeds texts and finds the closest match.
Future<void> embeddings(Ollama ollama) async {
  const embedModel = 'embeddinggemma';
  await ollama.ensureModel(embedModel);
  const docs = [
    'Flutter builds natively compiled apps.',
    'Pancakes need flour, eggs and milk.',
    'Ollama runs language models locally.',
  ];
  final vectors = await ollama.embedMany(docs, model: embedModel);
  final query = await ollama.embedText('How do I run an LLM on my laptop?',
      model: embedModel);
  final scores = [for (final v in vectors) cosineSimilarity(query, v)];
  final best = scores.indexOf(scores.reduce((a, b) => a > b ? a : b));
  stdout.writeln('Best match: "${docs[best]}"');
}

/// Cancels a long generation after one second.
Future<void> cancelAfterOneSecond(Ollama ollama) async {
  final token = OllamaCancelToken.after(const Duration(seconds: 1));
  try {
    await for (final text in ollama.askStream(
        'Write a very long story about a lighthouse.',
        cancelToken: token)) {
      stdout.write(text);
    }
  } on OllamaCancelledException {
    stdout.writeln('\n[cancelled]');
  }
}

/// Lists installed and loaded models.
Future<void> listModels(Ollama ollama) async {
  stdout.writeln('Server ${await ollama.version()}');
  for (final m in await ollama.models()) {
    stdout.writeln('  ${m.name.padRight(30)} '
        '${m.details?.parameterSize ?? ''} ${m.details?.quantizationLevel ?? ''}');
  }
  for (final m in await ollama.runningModels()) {
    stdout.writeln('  loaded: ${m.name} until ${m.expiresAt}');
  }
}
