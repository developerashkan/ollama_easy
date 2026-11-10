// A tiny Ollama chat CLI.
//
//   dart run ollama_easy "Tell me a joke"           # one prompt
//   dart run ollama_easy                            # interactive chat
//   dart run ollama_easy -m llama3.2 --think "..."  # pick a model, show reasoning
//
// Honors OLLAMA_HOST and OLLAMA_API_KEY.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ollama_easy/ollama_easy.dart';

const _usage = '''
Usage: dart run ollama_easy [options] [prompt]

Without a prompt, starts an interactive chat (/clear, /exit).

Options:
  -m, --model <name>   Model to use (default: qwen2.5:1.5b or OLLAMA_MODEL)
  -s, --system <text>  System prompt
      --think          Show the model's reasoning (thinking models)
      --host <url>     Server URL (default: OLLAMA_HOST or localhost:11434)
  -h, --help           Show this help''';

Future<void> main(List<String> args) async {
  String? model = Platform.environment['OLLAMA_MODEL'];
  String? system;
  String? host;
  var think = false;
  final words = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next() {
      if (i + 1 >= args.length) _fail('Missing value for $arg');
      return args[++i];
    }

    switch (arg) {
      case '-h' || '--help':
        stdout.writeln(_usage);
        return;
      case '-m' || '--model':
        model = next();
      case '-s' || '--system':
        system = next();
      case '--host':
        host = next();
      case '--think':
        think = true;
      default:
        words.add(arg);
    }
  }

  final ollama = host == null
      ? Ollama.fromEnvironment(defaultModel: model ?? 'qwen2.5:1.5b')
      : Ollama(host: host, defaultModel: model ?? 'qwen2.5:1.5b');
  if (!await ollama.isRunning()) {
    _fail(
        'Ollama is not running at ${ollama.baseUrl}. Start it with `ollama serve`.');
  }

  final chat = ollama.conversation(system: system, think: think ? true : null);
  try {
    if (words.isNotEmpty) {
      await _reply(chat, words.join(' '), think);
      return;
    }
    stdout.writeln(
        'Chatting with ${ollama.defaultModel} — /clear resets, /exit quits.');
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    stdout.write('\n> ');
    await for (final line in lines) {
      final input = line.trim();
      if (input == '/exit') break;
      if (input == '/clear') {
        chat.clear();
        stdout.write('(history cleared)\n> ');
        continue;
      }
      if (input.isNotEmpty) await _reply(chat, input, think);
      stdout.write('\n> ');
    }
  } on OllamaNotFoundException catch (error) {
    _fail(
        '${error.message}\nPull it first: ollama pull ${ollama.defaultModel}');
  } on OllamaException catch (error) {
    _fail('$error');
  } finally {
    ollama.close();
  }
}

Future<void> _reply(OllamaConversation chat, String prompt, bool think) async {
  if (!think) {
    await for (final delta in chat.sendStream(prompt)) {
      stdout.write(delta);
    }
    stdout.writeln();
    return;
  }
  // With --think, stream the reasoning dimmed, then the answer.
  final stream = chat.client.chatStream(
    [...chat.messages, OllamaMessage.user(prompt)],
    model: chat.model,
    think: true,
  );
  final accumulator = OllamaChatAccumulator();
  await for (final chunk in stream) {
    accumulator.add(chunk);
    if (chunk.thinking?.isNotEmpty ?? false) {
      stdout.write('\x1B[2m${chunk.thinking}\x1B[0m');
    }
    stdout.write(chunk.text);
  }
  chat
    ..add(OllamaMessage.user(prompt))
    ..add(accumulator.message);
  stdout.writeln();
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
