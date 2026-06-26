# ollama_easy

A small, Flutter-friendly client for Ollama. Use local AI models in your apps with one-line prompts, typed chat, streaming, and built-in support for Android emulators.

```dart
final ollama = Ollama.local(defaultModel: 'qwen2.5:1.5b');

// Simple one-line prompt
final answer = await ollama.ask('Explain Flutter isolates in one sentence.');

// Real-time token streaming
await for (final token in ollama.askStream('Write a tiny haiku.')) {
  stdout.write(token);
}

ollama.close();
```

## Features

- **Multi-Platform**: Support for Windows, Web, Android, iOS, macOS, and Linux.
- **Easy Streaming**: Built-in support for `Stream<String>` tokens.
- **Android Emulator Support**: Easily switch to `10.0.2.2` for emulator testing.
- **Typed Chat**: Structured messages with `system`, `user`, and `assistant` roles.
- **JSON Mode**: Get structured output easily with `askJson()`.
- **Model Helpers**: Pull, check, and list models with progress streams.
- **CLI Tool**: Run prompts directly from your terminal.

## Install

```yaml
dependencies:
  ollama_easy: ^0.2.0
```

## Getting Started

Ensure the Ollama server is running on your machine before executing your code.

### Local Ollama

```dart
final ollama = Ollama.local(defaultModel: 'qwen2.5:1.5b');

if (!await ollama.isRunning()) {
  throw StateError('Start Ollama first.');
}
```

### Android Emulator

When running in an Android emulator, `localhost` refers to the emulator itself. To reach the host machine where Ollama is running, use:

```dart
final ollama = Ollama(baseUrl: Uri.parse('http://10.0.2.2:11434'));
```

## Usage

### Chat

```dart
final reply = await ollama.chatText([
  const OllamaMessage.system('You answer like a helpful Flutter mentor.'),
  const OllamaMessage.user('How should I stream text into a Text widget?'),
]);
```

### Structured JSON

```dart
final json = await ollama.askJson(
  'Return a JSON object with "title" and "tags" for a note about Dart streams.',
);

print(json['title']);
```

### Embeddings

```dart
final result = await ollama.embed(
  'Flutter makes beautiful apps.',
  model: 'qwen2.5:1.5b',
);

final vector = result.first;
```

## CLI Tool

You can use `ollama_easy` directly from your terminal to test prompts:

```bash
dart run bin/ollama_easy.dart "Tell me a joke"
```

## Flutter Web

Flutter Web requires Ollama to have CORS configured. Start Ollama with the following environment variable:

```bash
OLLAMA_ORIGINS="*" ollama serve
```

## API Summary

```dart
final ollama = Ollama();

await ollama.ask('...');
ollama.askStream('...');

await ollama.generate('...');
ollama.generateStream('...');

await ollama.chatText([...]);
await ollama.chat([...]);
ollama.chatTextStream([...]);
ollama.chatStream([...]);

await ollama.askJson('...');
await ollama.embed('...');
await ollama.models();
await ollama.hasModel('qwen2.5:1.5b');
await ollama.ensureModel('qwen2.5:1.5b');
await ollama.pull('qwen2.5:1.5b');
ollama.pullStream('qwen2.5:1.5b');
await ollama.version();
await ollama.isRunning();

ollama.close();
```
