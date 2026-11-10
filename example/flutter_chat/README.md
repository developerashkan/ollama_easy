# Ollama chat (Flutter example)

A small streaming chat app built with [`ollama_easy`](../../README.md):
model picker, connection status, token streaming with a **Stop** button
(cancel token), thinking models, history trimming and tokens-per-second.

```bash
cd example/flutter_chat
flutter create . --platforms=android,ios,web,macos,windows,linux   # generate platform folders
flutter run
```

- **Android emulator:** the app talks to the host at `10.0.2.2:11434`
  automatically.
- **Web:** browsers need CORS, so start Ollama with `OLLAMA_ORIGINS="*" ollama serve`.
- **iOS/macOS:** plain `http://` to localhost is allowed; for a LAN server
  add an App Transport Security exception. On macOS also enable the
  *Outgoing Connections (Client)* entitlement.

Tests use an in-memory fake server (`test/support/fake_ollama.dart`):

```bash
flutter test                                                        # widget tests
flutter test test/screenshots_test.dart --dart-define=CAPTURE=true  # README screenshots
```
