import 'dart:collection';

import 'json_utils.dart';

/// Typed model `options` (sampling and runner parameters).
///
/// `ModelOptions` *is* a `Map<String, Object?>`, so you can pass it anywhere
/// an `options` map is accepted and still use plain maps if you prefer:
///
/// ```dart
/// await ollama.chat(messages,
///     options: ModelOptions(temperature: 0.2, numCtx: 8192));
/// await ollama.chat(messages, options: {'temperature': 0.2}); // also fine
/// ```
///
/// Keys Ollama adds later can be sent through [extra] today.
class ModelOptions extends UnmodifiableMapView<String, Object?> {
  ModelOptions({
    this.numKeep,
    this.seed,
    this.numPredict,
    this.topK,
    this.topP,
    this.minP,
    this.typicalP,
    this.repeatLastN,
    this.temperature,
    this.repeatPenalty,
    this.presencePenalty,
    this.frequencyPenalty,
    this.stop,
    this.numCtx,
    this.numBatch,
    this.numGpu,
    this.mainGpu,
    this.useMmap,
    this.numThread,
    this.draftNumPredict,
    this.extra = const {},
  }) : super(_build(
          numKeep: numKeep,
          seed: seed,
          numPredict: numPredict,
          topK: topK,
          topP: topP,
          minP: minP,
          typicalP: typicalP,
          repeatLastN: repeatLastN,
          temperature: temperature,
          repeatPenalty: repeatPenalty,
          presencePenalty: presencePenalty,
          frequencyPenalty: frequencyPenalty,
          stop: stop,
          numCtx: numCtx,
          numBatch: numBatch,
          numGpu: numGpu,
          mainGpu: mainGpu,
          useMmap: useMmap,
          numThread: numThread,
          draftNumPredict: draftNumPredict,
          extra: extra,
        ));

  /// Reads options from a JSON map. Unknown keys land in [extra].
  factory ModelOptions.fromJson(Map<String, Object?> json) {
    return ModelOptions(
      numKeep: asInt(json['num_keep']),
      seed: asInt(json['seed']),
      numPredict: asInt(json['num_predict']),
      topK: asInt(json['top_k']),
      topP: asDouble(json['top_p']),
      minP: asDouble(json['min_p']),
      typicalP: asDouble(json['typical_p']),
      repeatLastN: asInt(json['repeat_last_n']),
      temperature: asDouble(json['temperature']),
      repeatPenalty: asDouble(json['repeat_penalty']),
      presencePenalty: asDouble(json['presence_penalty']),
      frequencyPenalty: asDouble(json['frequency_penalty']),
      stop: asStringList(json['stop']),
      numCtx: asInt(json['num_ctx']),
      numBatch: asInt(json['num_batch']),
      numGpu: asInt(json['num_gpu']),
      mainGpu: asInt(json['main_gpu']),
      useMmap: asBool(json['use_mmap']),
      numThread: asInt(json['num_thread']),
      draftNumPredict: asInt(json['draft_num_predict']),
      extra: unknownFields(json, knownKeys),
    );
  }

  /// Option keys with a typed field.
  static const Set<String> knownKeys = {
    'num_keep', 'seed', 'num_predict', 'top_k', 'top_p', 'min_p', //
    'typical_p', 'repeat_last_n', 'temperature', 'repeat_penalty',
    'presence_penalty', 'frequency_penalty', 'stop', 'num_ctx', 'num_batch',
    'num_gpu', 'main_gpu', 'use_mmap', 'num_thread', 'draft_num_predict',
  };

  /// Tokens kept from the initial prompt when the context shifts.
  final int? numKeep;

  /// Random seed. Use a fixed value (with temperature 0) for repeatable output.
  final int? seed;

  /// Max tokens to generate. `-1` = unlimited (the default).
  final int? numPredict;

  /// Sample only from the K most likely tokens (default 40).
  final int? topK;

  /// Nucleus sampling (default 0.9).
  final double? topP;

  /// Minimum probability relative to the top token (default 0.0).
  final double? minP;

  /// Locally typical sampling. Deprecated by Ollama but still accepted.
  final double? typicalP;

  /// How far back to look for repetition (default 64, `-1` = `num_ctx`).
  final int? repeatLastN;

  /// Creativity. Higher is more random (default 0.8).
  final double? temperature;

  /// Penalty for repeated tokens (default 1.0).
  final double? repeatPenalty;

  /// Penalty for tokens that already appeared.
  final double? presencePenalty;

  /// Penalty proportional to how often a token appeared.
  final double? frequencyPenalty;

  /// Stop sequences.
  final List<String>? stop;

  /// Context window size in tokens.
  final int? numCtx;

  /// Prompt processing batch size.
  final int? numBatch;

  /// Layers to offload to the GPU.
  final int? numGpu;

  /// GPU used for small tensors when splitting across GPUs.
  final int? mainGpu;

  /// Memory-map the model file.
  final bool? useMmap;

  /// CPU threads.
  final int? numThread;

  /// Tokens the draft model proposes per step (speculative decoding).
  final int? draftNumPredict;

  /// Extra or future options, sent as is.
  final Map<String, Object?> extra;

  /// Returns a copy where non-null values of [other] win.
  ModelOptions merge(Map<String, Object?>? other) {
    if (other == null || other.isEmpty) return this;
    return ModelOptions.fromJson({...this, ...other});
  }

  /// Returns a copy with the given fields replaced.
  ModelOptions copyWith({
    int? numKeep,
    int? seed,
    int? numPredict,
    int? topK,
    double? topP,
    double? minP,
    double? typicalP,
    int? repeatLastN,
    double? temperature,
    double? repeatPenalty,
    double? presencePenalty,
    double? frequencyPenalty,
    List<String>? stop,
    int? numCtx,
    int? numBatch,
    int? numGpu,
    int? mainGpu,
    bool? useMmap,
    int? numThread,
    int? draftNumPredict,
    Map<String, Object?>? extra,
  }) {
    return ModelOptions(
      numKeep: numKeep ?? this.numKeep,
      seed: seed ?? this.seed,
      numPredict: numPredict ?? this.numPredict,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      minP: minP ?? this.minP,
      typicalP: typicalP ?? this.typicalP,
      repeatLastN: repeatLastN ?? this.repeatLastN,
      temperature: temperature ?? this.temperature,
      repeatPenalty: repeatPenalty ?? this.repeatPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      stop: stop ?? this.stop,
      numCtx: numCtx ?? this.numCtx,
      numBatch: numBatch ?? this.numBatch,
      numGpu: numGpu ?? this.numGpu,
      mainGpu: mainGpu ?? this.mainGpu,
      useMmap: useMmap ?? this.useMmap,
      numThread: numThread ?? this.numThread,
      draftNumPredict: draftNumPredict ?? this.draftNumPredict,
      extra: extra ?? this.extra,
    );
  }

  /// The options as a JSON map (only non-null values).
  Map<String, Object?> toJson() => Map.of(this);

  static Map<String, Object?> _build({
    int? numKeep,
    int? seed,
    int? numPredict,
    int? topK,
    double? topP,
    double? minP,
    double? typicalP,
    int? repeatLastN,
    double? temperature,
    double? repeatPenalty,
    double? presencePenalty,
    double? frequencyPenalty,
    List<String>? stop,
    int? numCtx,
    int? numBatch,
    int? numGpu,
    int? mainGpu,
    bool? useMmap,
    int? numThread,
    int? draftNumPredict,
    Map<String, Object?> extra = const {},
  }) {
    return withoutNulls({
      ...extra,
      'num_keep': numKeep,
      'seed': seed,
      'num_predict': numPredict,
      'top_k': topK,
      'top_p': topP,
      'min_p': minP,
      'typical_p': typicalP,
      'repeat_last_n': repeatLastN,
      'temperature': temperature,
      'repeat_penalty': repeatPenalty,
      'presence_penalty': presencePenalty,
      'frequency_penalty': frequencyPenalty,
      'stop': stop,
      'num_ctx': numCtx,
      'num_batch': numBatch,
      'num_gpu': numGpu,
      'main_gpu': mainGpu,
      'use_mmap': useMmap,
      'num_thread': numThread,
      'draft_num_predict': draftNumPredict,
    });
  }
}

/// The `think` parameter: turn reasoning on/off or pick an effort level.
///
/// Wherever `think:` is accepted you can pass a `bool`, a level `String`, or
/// one of these constants. Levels are model specific; `showModel` reports the
/// values a model supports in `OllamaModelInfo.thinkingValues`.
class OllamaThink {
  const OllamaThink._(this.value);

  /// A custom level (forward compatible with levels added later).
  const OllamaThink.level(String level) : value = level;

  static const OllamaThink enabled = OllamaThink._(true);
  static const OllamaThink disabled = OllamaThink._(false);
  static const OllamaThink low = OllamaThink._('low');
  static const OllamaThink medium = OllamaThink._('medium');
  static const OllamaThink high = OllamaThink._('high');

  /// `true`, `false` or a level string.
  final Object value;

  /// Encodes a user supplied `think` argument.
  static Object? encode(Object? think) {
    if (think == null) return null;
    if (think is OllamaThink) return think.value;
    if (think is bool || think is String) return think;
    if (think is Enum) return think.name;
    throw ArgumentError.value(
        think, 'think', 'Use a bool, a level string or OllamaThink');
  }

  @override
  bool operator ==(Object other) =>
      other is OllamaThink && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'OllamaThink($value)';
}

/// The `format` parameter for structured outputs.
///
/// Wherever `format:` is accepted you can pass `'json'`, a JSON schema `Map`,
/// or one of these.
class OllamaFormat {
  const OllamaFormat._(this.value);

  /// Any valid JSON.
  static const OllamaFormat json = OllamaFormat._('json');

  /// Output that must match [schema] (a JSON schema object).
  const OllamaFormat.schema(Map<String, Object?> schema) : value = schema;

  final Object value;

  /// Encodes a user supplied `format` argument.
  static Object? encode(Object? format) {
    if (format is OllamaFormat) return format.value;
    return format;
  }
}

/// Encodes a `keep_alive` value.
///
/// Accepts a [Duration] (sent as whole seconds; negative = keep loaded
/// forever, zero = unload now), a number of seconds, or an Ollama duration
/// string such as `"10m"` or `"1h"`.
Object? encodeKeepAlive(Object? keepAlive) {
  if (keepAlive == null) return null;
  if (keepAlive is Duration) {
    if (keepAlive.isNegative) return -1;
    if (keepAlive.inMicroseconds % Duration.microsecondsPerSecond == 0) {
      return keepAlive.inSeconds;
    }
    return '${keepAlive.inMilliseconds}ms';
  }
  if (keepAlive is num || keepAlive is String) return keepAlive;
  throw ArgumentError.value(
      keepAlive, 'keepAlive', 'Use a Duration, a number or a string like "5m"');
}

/// Why generation stopped. Unknown values from newer servers are kept as is
/// in [value].
class OllamaDoneReason {
  const OllamaDoneReason(this.value);

  static const stop = OllamaDoneReason('stop');
  static const length = OllamaDoneReason('length');
  static const load = OllamaDoneReason('load');
  static const unload = OllamaDoneReason('unload');

  final String value;

  /// The model hit `num_predict` or the context limit: output may be cut off.
  bool get isTruncated => this == length;

  @override
  bool operator ==(Object other) =>
      other is OllamaDoneReason && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Capabilities reported by `/api/show` and `/api/tags`. Unknown values are
/// kept as plain strings in the model's `capabilities` list.
abstract final class OllamaCapability {
  static const completion = 'completion';
  static const tools = 'tools';
  static const vision = 'vision';
  static const thinking = 'thinking';
  static const embedding = 'embedding';
  static const insert = 'insert';
}
