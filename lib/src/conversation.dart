import 'dart:async';

import 'cancel_token.dart';
import 'models.dart';
import 'ollama_client.dart';
import 'streams.dart';
import 'tools.dart';

/// A stateful chat that keeps its own history.
///
/// ```dart
/// final chat = ollama.conversation(
///   system: 'You are a concise assistant.',
///   maxMessages: 20,
/// );
/// print(await chat.send('Hi! My name is Sam.'));
/// print(await chat.send('What is my name?'));
///
/// await for (final delta in chat.sendStream('Tell me a story')) {
///   stdout.write(delta);
/// }
/// ```
///
/// If any tool has a handler, tool calls are executed automatically.
///
/// History trimming keeps the system prompt and drops the oldest *turns*
/// (a user message with everything that answered it), so a tool result is
/// never left without its call.
class OllamaConversation {
  OllamaConversation({
    required this.client,
    this.model,
    this.system,
    this.tools = const [],
    this.think,
    this.keepAlive,
    this.options,
    this.maxMessages,
    this.maxChars,
    this.maxToolIterations = 8,
    List<OllamaMessage> history = const [],
  }) : _history = List.of(history) {
    _trim();
  }

  /// Restores a conversation saved with [toJson].
  factory OllamaConversation.fromJson(
    Map<String, Object?> json, {
    required Ollama client,
    List<OllamaTool> tools = const [],
  }) {
    final history = json['history'];
    return OllamaConversation(
      client: client,
      model: json['model']?.toString(),
      system: json['system']?.toString(),
      tools: tools,
      maxMessages:
          json['max_messages'] is int ? json['max_messages'] as int : null,
      maxChars: json['max_chars'] is int ? json['max_chars'] as int : null,
      history: history is List
          ? [
              for (final item in history)
                if (item is Map)
                  OllamaMessage.fromJson(
                      item.map((key, value) => MapEntry('$key', value))),
            ]
          : const [],
    );
  }

  final Ollama client;
  final String? model;

  /// Sent first on every request; never trimmed.
  String? system;
  final List<OllamaTool> tools;
  final Object? think;
  final Object? keepAlive;
  final Map<String, Object?>? options;

  /// Keep at most this many history messages (system prompt excluded).
  final int? maxMessages;

  /// Keep at most roughly this many characters of history (a cheap token
  /// budget: ~4 characters per token for English).
  final int? maxChars;

  /// Limit for the automatic tool loop.
  final int maxToolIterations;

  final List<OllamaMessage> _history;

  /// The last response (with metrics), if any.
  OllamaChatResponse? lastResponse;

  /// The history without the system prompt.
  List<OllamaMessage> get history => List.unmodifiable(_history);

  /// The messages sent with the next request.
  List<OllamaMessage> get messages => [
        if (system != null && system!.isNotEmpty) OllamaMessage.system(system!),
        ..._history,
      ];

  bool get _runsTools => tools.any((tool) => tool.handler != null);

  /// Sends [text] and returns the reply text.
  Future<String> send(
    String text, {
    List<String>? images,
    OllamaCancelToken? cancelToken,
  }) async {
    _history.add(OllamaMessage.user(text, images: images));
    try {
      if (_runsTools) {
        final run = await client.runTools(
          messages,
          tools: tools,
          model: model,
          think: think,
          keepAlive: keepAlive,
          options: options,
          maxIterations: maxToolIterations,
          cancelToken: cancelToken,
        );
        _replaceTail(run.messages);
        lastResponse = run.response;
        return run.text;
      }
      final response = await client.chat(
        messages,
        model: model,
        tools: tools.isEmpty ? null : tools,
        think: think,
        keepAlive: keepAlive,
        options: options,
        cancelToken: cancelToken,
      );
      _history.add(response.message ?? const OllamaMessage.assistant(''));
      lastResponse = response;
      return response.text;
    } catch (_) {
      _rollbackUnanswered();
      rethrow;
    } finally {
      _trim();
    }
  }

  /// Sends [text] and streams the reply text. The full reply is added to
  /// the history when the stream ends. If the stream is cancelled or fails
  /// part way, the partial reply is kept.
  Stream<String> sendStream(
    String text, {
    List<String>? images,
    OllamaCancelToken? cancelToken,
  }) async* {
    _history.add(OllamaMessage.user(text, images: images));
    if (_runsTools) {
      final buffer = StringBuffer();
      var completed = false;
      try {
        await for (final event in client.runToolsStream(
          messages,
          tools: tools,
          model: model,
          think: think,
          keepAlive: keepAlive,
          options: options,
          maxIterations: maxToolIterations,
          cancelToken: cancelToken,
        )) {
          if (event is OllamaToolRunTextDelta) {
            buffer.write(event.text);
            yield event.text;
          } else if (event is OllamaToolRunDone) {
            _replaceTail(event.run.messages);
            lastResponse = event.run.response;
            completed = true;
          }
        }
      } finally {
        if (!completed) _keepPartial(buffer.toString());
        _trim();
      }
      return;
    }

    final accumulator = OllamaChatAccumulator();
    var completed = false;
    try {
      await for (final chunk in client.chatStream(
        messages,
        model: model,
        tools: tools.isEmpty ? null : tools,
        think: think,
        keepAlive: keepAlive,
        options: options,
        cancelToken: cancelToken,
      )) {
        accumulator.add(chunk);
        if (chunk.text.isNotEmpty) yield chunk.text;
      }
      completed = true;
      _history.add(accumulator.message);
      lastResponse = accumulator.response;
    } finally {
      if (!completed) _keepPartial(accumulator.content);
      _trim();
    }
  }

  /// Appends a message (e.g. a restored or injected one).
  void add(OllamaMessage message) {
    _history.add(message);
    _trim();
  }

  /// Removes the last turn (the last user message and its answers).
  /// Returns the removed messages.
  List<OllamaMessage> undo() {
    final start = _history.lastIndexWhere((m) => m.role == OllamaRole.user);
    if (start == -1) return const [];
    final removed = _history.sublist(start);
    _history.removeRange(start, _history.length);
    return removed;
  }

  /// Clears the history (the system prompt is kept).
  void clear() {
    _history.clear();
    lastResponse = null;
  }

  /// Serializable state (tools are not included; pass them to [fromJson]).
  Map<String, Object?> toJson() => {
        if (model != null) 'model': model,
        if (system != null) 'system': system,
        if (maxMessages != null) 'max_messages': maxMessages,
        if (maxChars != null) 'max_chars': maxChars,
        'history': [for (final message in _history) message.toJson()],
      };

  void _replaceTail(List<OllamaMessage> fullRun) {
    // fullRun = [system?] + history + new messages.
    final offset = (system != null && system!.isNotEmpty) ? 1 : 0;
    final newMessages = fullRun.skip(offset + _history.length);
    _history.addAll(newMessages);
  }

  void _keepPartial(String partial) {
    if (partial.isEmpty) {
      _rollbackUnanswered();
    } else if (_history.isEmpty || _history.last.role == OllamaRole.user) {
      _history.add(OllamaMessage.assistant(partial));
    }
  }

  void _rollbackUnanswered() {
    if (_history.isNotEmpty && _history.last.role == OllamaRole.user) {
      _history.removeLast();
    }
  }

  void _trim() {
    bool tooLong() {
      if (maxMessages != null && _history.length > maxMessages!) return true;
      if (maxChars != null) {
        final chars = _history.fold<int>(0, (sum, m) => sum + m.content.length);
        if (chars > maxChars!) return true;
      }
      return false;
    }

    while (tooLong()) {
      // Drop the oldest turn: up to (not including) the next user message.
      final next = _history.indexWhere((m) => m.role == OllamaRole.user, 1);
      if (next == -1) break; // Only the latest turn is left; keep it.
      _history.removeRange(0, next);
    }
  }
}
