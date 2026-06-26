import 'dart:io';

import 'package:ollama_easy/ollama_easy.dart';

Future<void> main() async {
  final ollama = Ollama.local(defaultModel: 'gemma4');

  try {
    final answer = await ollama.ask(
      'Explain isolates in Dart in two friendly sentences.',
    );
    print(answer);

    print('\nStreaming:');
    await for (final token in ollama.askStream('Write a one-line haiku.')) {
      stdout.write(token);
    }

    final chat = await ollama.chatText([
      const OllamaMessage.system('You are concise and practical.'),
      const OllamaMessage.user('Give me one Flutter state management tip.'),
    ]);
    print('\n\n$chat');
  } finally {
    ollama.close();
  }
}
