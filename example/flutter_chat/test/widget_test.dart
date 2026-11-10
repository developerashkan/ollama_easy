import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_chat_example/main.dart';

import 'support/fake_ollama.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('lists chat models and streams a reply with stats',
      (tester) async {
    final fake = FakeOllama();
    await tester.pumpWidget(ChatApp(ollama: fake.client()));
    await settle(tester);

    expect(find.text('qwen3:4b'), findsOneWidget);
    expect(find.text('Chat with a local model'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'What is a stream?');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump(const Duration(milliseconds: 130));
    expect(find.byKey(const Key('stop')), findsOneWidget, reason: 'streaming');

    await settle(tester);
    expect(find.textContaining('conveyor belt.'), findsOneWidget);
    expect(find.text('42 tokens · 35.0 tok/s'), findsOneWidget);
    expect(find.byKey(const Key('send')), findsOneWidget);
    expect(fake.chatRequests.single['model'], 'qwen3:4b');
  });

  testWidgets('stop cancels the stream and keeps the partial reply',
      (tester) async {
    final fake = FakeOllama(endless: true);
    await tester.pumpWidget(ChatApp(ollama: fake.client()));
    await settle(tester);

    await tester.enterText(find.byType(TextField), 'Count forever');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('stop')));
    await settle(tester);

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.byKey(const Key('send')), findsOneWidget);
  });

  testWidgets('thinking models show their reasoning', (tester) async {
    final fake = FakeOllama();
    await tester.pumpWidget(ChatApp(ollama: fake.client()));
    await settle(tester);

    await tester.tap(find.byTooltip('Thinking off'));
    await tester.pump();
    await tester.tap(find.text('Write a haiku about local AI'));
    await settle(tester);

    expect(fake.chatRequests.single['think'], isTrue);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.textContaining('conveyor belt works.'), findsOneWidget);
  });

  testWidgets('shows a retry banner when Ollama is offline', (tester) async {
    final fake = FakeOllama(online: false);
    await tester.pumpWidget(ChatApp(ollama: fake.client()));
    await settle(tester);
    expect(find.textContaining("Can't reach Ollama"), findsOneWidget);

    fake.online = true;
    await tester.tap(find.text('RETRY'));
    await settle(tester);
    expect(find.textContaining("Can't reach Ollama"), findsNothing);
    expect(find.text('qwen3:4b'), findsOneWidget);
  });
}
