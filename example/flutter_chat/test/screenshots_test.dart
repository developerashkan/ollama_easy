// Renders the README screenshots with real fonts:
//
//   flutter test test/screenshots_test.dart --dart-define=CAPTURE=true
//
// Output: ../../screenshots/*.png
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_chat_example/main.dart';

import 'support/capture.dart';
import 'support/fake_ollama.dart';

const _capture = bool.fromEnvironment('CAPTURE');
const _out = '../../screenshots';
const _shot = Key('shot');

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final steps = duration.inMilliseconds ~/ 20;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<ChatApp> _app(FakeOllama fake, ThemeMode mode) async =>
    ChatApp(ollama: fake.client(), themeMode: mode);

void main() {
  testWidgets('empty state (light)', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester);
    await tester.pumpWidget(RepaintBoundary(
        key: _shot, child: await _app(FakeOllama(), ThemeMode.light)));
    await _pumpFor(tester, const Duration(seconds: 1));
    await capturePng(tester, _shot, '$_out/empty_light.png');
  });

  testWidgets('finished reply with thinking and stats (light)', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester);
    final fake = FakeOllama(
      reply: 'Think of a Dart Stream as a conveyor belt: values arrive one '
          'after another, over time. You listen with `await for`, and the '
          'belt can end (done) or jam (error).',
      thinking: 'Simple analogy wanted. Conveyor belt: items over time, can '
          'stop or break.',
      wordDelay: const Duration(milliseconds: 10),
    );
    await tester.pumpWidget(
        RepaintBoundary(key: _shot, child: await _app(fake, ThemeMode.light)));
    await _pumpFor(tester, const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Thinking off'));
    await tester.enterText(
        find.byType(TextField), 'Explain Dart streams like I am five');
    await tester.tap(find.byKey(const Key('send')));
    await _pumpFor(tester, const Duration(seconds: 3));
    await capturePng(tester, _shot, '$_out/chat_light.png');
  });

  testWidgets('streaming with the stop button (dark)', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester);
    final fake = FakeOllama(
      reply: 'Day 1: Alfama and the castle at sunset. Day 2: Belém — the '
          'tower, the monastery and pastéis de nata. Day 3: a train to '
          'Sintra for the palaces, back for dinner in Bairro Alto.',
      wordDelay: const Duration(milliseconds: 30),
    );
    await tester.pumpWidget(
        RepaintBoundary(key: _shot, child: await _app(fake, ThemeMode.dark)));
    await _pumpFor(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('Plan a 3-day trip to Lisbon'));
    await _pumpFor(tester, const Duration(milliseconds: 900));
    await capturePng(tester, _shot, '$_out/streaming_dark.png');
    fake.chatRequests.clear();
    await _pumpFor(tester, const Duration(seconds: 3));
  });
}
