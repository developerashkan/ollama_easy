import 'dart:math' as math;

import 'json_utils.dart';
import 'models.dart';

/// Merges streamed chat chunks into one response: content, thinking,
/// tool calls and logprobs are concatenated; metrics come from the final
/// chunk.
class OllamaChatAccumulator {
  final StringBuffer _content = StringBuffer();
  final StringBuffer _thinking = StringBuffer();
  final List<OllamaToolCall> _toolCalls = [];
  final List<Object?> _logprobs = [];
  final List<String> _images = [];
  OllamaChatResponse? _last;
  OllamaRole _role = OllamaRole.assistant;
  Map<String, Object?>? _extra;

  /// Adds one chunk.
  void add(OllamaChatResponse chunk) {
    _last = chunk;
    final message = chunk.message;
    if (message != null) {
      _role = message.role;
      _content.write(message.content);
      if (message.thinking != null) _thinking.write(message.thinking);
      if (message.toolCalls != null) _toolCalls.addAll(message.toolCalls!);
      if (message.images != null) _images.addAll(message.images!);
      if (message.extra != null) _extra = {...?_extra, ...message.extra!};
    }
    if (chunk.logprobs != null) _logprobs.addAll(chunk.logprobs!);
  }

  /// Text received so far.
  String get content => _content.toString();

  /// Reasoning received so far.
  String get thinking => _thinking.toString();

  /// Tool calls received so far.
  List<OllamaToolCall> get toolCalls => List.unmodifiable(_toolCalls);

  /// Whether the final chunk arrived.
  bool get isDone => _last?.done ?? false;

  /// The merged message.
  OllamaMessage get message => OllamaMessage(
        role: _role,
        content: content,
        thinking: _thinking.isEmpty ? null : thinking,
        toolCalls: _toolCalls.isEmpty ? null : List.of(_toolCalls),
        images: _images.isEmpty ? null : List.of(_images),
        extra: _extra,
      );

  /// The merged response (metrics from the last chunk).
  OllamaChatResponse get response {
    final last = _last;
    final raw = <String, Object?>{...?last?.raw, 'message': message.toJson()};
    if (_logprobs.isNotEmpty) raw['logprobs'] = _logprobs;
    return OllamaChatResponse(
      model: last?.model ?? '',
      done: last?.done ?? false,
      raw: raw,
      createdAt: last?.createdAt,
      message: message,
      doneReason: last?.doneReason,
      totalDuration: last?.totalDuration,
      loadDuration: last?.loadDuration,
      promptEvalCount: last?.promptEvalCount,
      promptEvalDuration: last?.promptEvalDuration,
      evalCount: last?.evalCount,
      evalDuration: last?.evalDuration,
      logprobs: _logprobs.isEmpty ? null : List.of(_logprobs),
    );
  }
}

/// Merges streamed generate chunks into one response.
class OllamaGenerateAccumulator {
  final StringBuffer _response = StringBuffer();
  final StringBuffer _thinking = StringBuffer();
  final List<OllamaToolCall> _toolCalls = [];
  final List<Object?> _logprobs = [];
  OllamaGenerateResponse? _last;

  void add(OllamaGenerateResponse chunk) {
    _last = chunk;
    _response.write(chunk.response);
    if (chunk.thinking != null) _thinking.write(chunk.thinking);
    if (chunk.toolCalls != null) _toolCalls.addAll(chunk.toolCalls!);
    if (chunk.logprobs != null) _logprobs.addAll(chunk.logprobs!);
  }

  String get text => _response.toString();
  String get thinking => _thinking.toString();
  bool get isDone => _last?.done ?? false;

  OllamaGenerateResponse get response {
    final last = _last;
    final JsonMap raw = {
      ...?last?.raw,
      'response': text,
      if (_thinking.isNotEmpty) 'thinking': thinking,
    };
    return OllamaGenerateResponse(
      model: last?.model ?? '',
      done: last?.done ?? false,
      raw: raw,
      createdAt: last?.createdAt,
      response: text,
      thinking: _thinking.isEmpty ? null : thinking,
      doneReason: last?.doneReason,
      totalDuration: last?.totalDuration,
      loadDuration: last?.loadDuration,
      promptEvalCount: last?.promptEvalCount,
      promptEvalDuration: last?.promptEvalDuration,
      evalCount: last?.evalCount,
      evalDuration: last?.evalDuration,
      logprobs: _logprobs.isEmpty ? null : List.of(_logprobs),
      context: last?.context,
      toolCalls: _toolCalls.isEmpty ? null : List.of(_toolCalls),
    );
  }
}

/// Helpers for streamed chat responses.
extension OllamaChatStreamX on Stream<OllamaChatResponse> {
  /// Waits for the stream to finish and returns the merged response.
  Future<OllamaChatResponse> collect() async {
    final accumulator = OllamaChatAccumulator();
    await forEach(accumulator.add); // not `await for`; see _readAll
    return accumulator.response;
  }

  /// Only the non-empty content deltas.
  Stream<String> get textDeltas =>
      map((chunk) => chunk.text).where((text) => text.isNotEmpty);

  /// Only the non-empty reasoning deltas.
  Stream<String> get thinkingDeltas =>
      map((chunk) => chunk.thinking ?? '').where((text) => text.isNotEmpty);
}

/// Helpers for streamed generate responses.
extension OllamaGenerateStreamX on Stream<OllamaGenerateResponse> {
  /// Waits for the stream to finish and returns the merged response.
  Future<OllamaGenerateResponse> collect() async {
    final accumulator = OllamaGenerateAccumulator();
    await forEach(accumulator.add); // not `await for`; see _readAll
    return accumulator.response;
  }

  Stream<String> get textDeltas =>
      map((chunk) => chunk.response).where((text) => text.isNotEmpty);

  Stream<String> get thinkingDeltas =>
      map((chunk) => chunk.thinking ?? '').where((text) => text.isNotEmpty);
}

/// Cosine similarity of two vectors of equal length (−1..1).
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) {
    throw ArgumentError('Vectors differ in length: ${a.length} vs ${b.length}');
  }
  var dot = 0.0, normA = 0.0, normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}
