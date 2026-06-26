import 'dart:io';
import 'package:ollama_easy/ollama_easy.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run bin/ollama_easy.dart "<prompt>"');
    exit(0);
  }

  final ollama = Ollama.local();
  
  if (!await ollama.isRunning()) {
    print('Error: Ollama is not running at http://localhost:11434');
    exit(1);
  }

  final prompt = args.join(' ');
  print('Sending prompt to Ollama: $prompt\n');

  try {
    await for (final token in ollama.askStream(prompt)) {
      stdout.write(token);
    }
    print('\n');
  } catch (e) {
    print('\nError: $e');
    exit(1);
  } finally {
    ollama.close();
  }
}
