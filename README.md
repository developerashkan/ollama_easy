# ollama_easy

A small Dart package for using Ollama from Flutter without hand-building HTTP
requests or parsing newline-delimited JSON yourself.

```dart
final ollama = Ollama.local(defaultModel: 'gemma4');

final answer = await ollama.ask('Explain Flutter isolates in one sentence.');

await for (final token in ollama.askStream('Write a tiny haiku.')) {
  stdout.write(token);
}

ollama.close();
```

## Why this package?

- One-line prompts with `ask()`
- Token streaming with `askStream()` and `chatTextStream()`
- Typed chat messages with `OllamaMessage.user()`, `.system()`, and `.assistant()`
- JSON helpers with `askJson()` for structured output
- Embeddings, model listing, pull progress, version checks, and model existence checks
- Works in Flutter and plain Dart because it only depends on `package:http`
- Supports local Ollama and Ollama cloud API keys

## Install

```yaml
dependencies:
  ollama_easy: ^0.1.0
```

For local development before publishing:

```yaml
dependencies:
  ollama_easy:
    git:
      url: https://github.com/developerashkan/ollama_easy.git
```

## Local Ollama

Ollama serves its local API at `http://localhost:11434/api` after it is
installed and running.

```dart
final ollama = Ollama.local(defaultModel: 'gemma4');

if (!await ollama.isRunning()) {
  throw StateError('Start Ollama first.');
}

await ollama.ensureModel('gemma4');

final text = await ollama.ask(
  'Give me three short app ideas for Flutter and local AI.',
);
```

## Chat

```dart
final reply = await ollama.chatText([
  const OllamaMessage.system('You answer like a helpful Flutter mentor.'),
  const OllamaMessage.user('How should I stream text into a Text widget?'),
]);
```

## Structured JSON

```dart
final json = await ollama.askJson(
  'Return a JSON object with "title" and "tags" for a note about Dart streams.',
);

print(json['title']);
```

You can also pass a JSON schema object:

```dart
final recipe = await ollama.askJson(
  'Create a simple tea recipe.',
  schema: {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'steps': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['title', 'steps'],
  },
);
```

## Embeddings

```dart
final result = await ollama.embed(
  'Flutter makes beautiful apps.',
  model: 'embeddinggemma',
);

final vector = result.first;
```

## Ollama cloud

```dart
final ollama = Ollama.cloud(
  apiKey: const String.fromEnvironment('OLLAMA_API_KEY'),
);

final answer = await ollama.ask('What changed in local AI recently?');
```

## Flutter notes

Mobile and desktop apps can usually reach a local Ollama server directly.
Flutter Web may need Ollama CORS configuration, because browser requests are
subject to the browser's security model.

## API surface

```dart
final ollama = Ollama();

await ollama.ask('...');
ollama.askStream('...');

await ollama.generate('...');
ollama.generateStream('...');

await ollama.chatText([const OllamaMessage.user('...')]);
await ollama.chat([...]);
ollama.chatTextStream([...]);
ollama.chatStream([...]);

await ollama.askJson('...');
await ollama.embed('...');
await ollama.models();
await ollama.hasModel('gemma4');
await ollama.ensureModel('gemma4');
await ollama.pull('gemma4');
ollama.pullStream('gemma4');
await ollama.version();
await ollama.isRunning();

ollama.close();
```
