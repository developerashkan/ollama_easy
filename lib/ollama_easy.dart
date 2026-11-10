/// A complete, typed Ollama client for Dart and Flutter: chat, generate,
/// streaming, tool-calling loops, structured outputs, thinking, vision,
/// embeddings, model management, cancellation, retries and interceptors.
///
/// Pure Dart: Android, iOS, web, macOS, Windows and Linux.
library;

export 'src/cancel_token.dart';
export 'src/conversation.dart';
export 'src/exceptions.dart';
export 'src/interceptors.dart';
export 'src/json_utils.dart' show JsonMap;
export 'src/models.dart';
export 'src/ollama_client.dart';
export 'src/options.dart';
export 'src/retry.dart';
export 'src/schema.dart';
export 'src/streams.dart';
export 'src/tools.dart' hide executeToolCalls;
