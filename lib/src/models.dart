import 'dart:async';
import 'dart:convert';

import 'json_utils.dart';
import 'options.dart';

/// The author of a chat message.
enum OllamaRole {
  system,
  user,
  assistant,
  tool;

  /// Parses a role. Unknown roles map to [assistant]; the original string is
  /// kept in `OllamaMessage.extra['role']` and sent back unchanged.
  static OllamaRole fromJson(Object? value) {
    final role = value?.toString();
    return OllamaRole.values.firstWhere(
      (item) => item.name == role,
      orElse: () => OllamaRole.assistant,
    );
  }
}

/// Helpers for multimodal (vision) input.
abstract final class OllamaImage {
  /// Encodes raw image bytes (PNG, JPEG, WebP, ...) for `images:`.
  static String fromBytes(List<int> bytes) => base64Encode(bytes);

  /// Strips a `data:image/...;base64,` prefix and whitespace, which Ollama
  /// rejects. Plain base64 is returned unchanged.
  static String normalize(String image) {
    var value = image.trim();
    if (value.startsWith('data:')) {
      final comma = value.indexOf(',');
      if (comma != -1) value = value.substring(comma + 1);
    }
    if (value.contains(RegExp(r'\s'))) {
      value = value.replaceAll(RegExp(r'\s'), '');
    }
    return value;
  }
}

/// One chat message.
class OllamaMessage {
  const OllamaMessage({
    required this.role,
    required this.content,
    this.thinking,
    this.images,
    this.toolCalls,
    this.toolName,
    this.toolCallId,
    this.extra,
  });

  const OllamaMessage.system(String content)
      : this(role: OllamaRole.system, content: content);

  /// A user message. [images] are base64 strings (see [OllamaImage]); data
  /// URLs are accepted too.
  const OllamaMessage.user(String content, {List<String>? images})
      : this(role: OllamaRole.user, content: content, images: images);

  const OllamaMessage.assistant(
    String content, {
    String? thinking,
    List<OllamaToolCall>? toolCalls,
  }) : this(
          role: OllamaRole.assistant,
          content: content,
          thinking: thinking,
          toolCalls: toolCalls,
        );

  /// A tool result. Set [toolName] to the called function's name so the model
  /// can match results to calls.
  const OllamaMessage.tool(String content,
      {String? toolName, String? toolCallId})
      : this(
          role: OllamaRole.tool,
          content: content,
          toolName: toolName,
          toolCallId: toolCallId,
        );

  /// A tool result for [call]. Non-string [result]s are JSON encoded.
  factory OllamaMessage.toolResult(OllamaToolCall call, Object? result) {
    return OllamaMessage.tool(
      encodeToolResult(result),
      toolName: call.name,
      toolCallId: call.id,
    );
  }

  final OllamaRole role;
  final String content;

  /// The model's reasoning, for thinking models with `think` enabled.
  final String? thinking;

  /// Base64 images (vision models).
  final List<String>? images;

  /// Tools the assistant wants to call.
  final List<OllamaToolCall>? toolCalls;

  /// For [OllamaRole.tool] messages: the function that produced the result.
  final String? toolName;

  /// For [OllamaRole.tool] messages: the id of the call being answered.
  final String? toolCallId;

  /// Fields this version does not know, preserved on round trips.
  final Map<String, Object?>? extra;

  static const _known = {
    'role', 'content', 'thinking', 'images', 'tool_calls', 'tool_name', //
    'tool_call_id',
  };

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  JsonMap toJson() => withoutNulls({
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'images': images?.map(OllamaImage.normalize).toList(),
        'tool_calls': toolCalls?.map((call) => call.toJson()).toList(),
        'tool_name': toolName,
        'tool_call_id': toolCallId,
        ...?extra,
      });

  factory OllamaMessage.fromJson(Map<String, Object?> json) {
    final role = json['role']?.toString();
    final parsedRole = OllamaRole.fromJson(role);
    final extra = unknownFields(json, _known);
    if (role != null && role != parsedRole.name) extra['role'] = role;
    final toolCalls = json['tool_calls'];
    return OllamaMessage(
      role: parsedRole,
      content: json['content']?.toString() ?? '',
      thinking: asString(json['thinking']),
      images: asStringList(json['images']),
      toolCalls: toolCalls is List
          ? asJsonMapList(toolCalls).map(OllamaToolCall.fromJson).toList()
          : null,
      toolName: asString(json['tool_name']),
      toolCallId: asString(json['tool_call_id']),
      extra: extra.isEmpty ? null : extra,
    );
  }

  OllamaMessage copyWith({
    OllamaRole? role,
    String? content,
    String? thinking,
    List<String>? images,
    List<OllamaToolCall>? toolCalls,
    String? toolName,
    String? toolCallId,
    Map<String, Object?>? extra,
  }) {
    return OllamaMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      thinking: thinking ?? this.thinking,
      images: images ?? this.images,
      toolCalls: toolCalls ?? this.toolCalls,
      toolName: toolName ?? this.toolName,
      toolCallId: toolCallId ?? this.toolCallId,
      extra: extra ?? this.extra,
    );
  }

  @override
  String toString() {
    final calls = hasToolCalls ? ', toolCalls: $toolCalls' : '';
    return 'OllamaMessage(${role.name}: $content$calls)';
  }
}

/// Encodes a tool result for a `tool` message: strings as is, everything
/// else as JSON (falling back to `toString()`).
String encodeToolResult(Object? result) {
  if (result is String) return result;
  if (result == null) return 'null';
  try {
    return jsonEncode(result);
  } on JsonUnsupportedObjectError {
    return result.toString();
  }
}

/// Runs a tool call. Receives the decoded arguments and returns the result
/// (a String, or anything JSON encodable).
typedef OllamaToolHandler = FutureOr<Object?> Function(
    Map<String, Object?> arguments);

/// A function the model may call.
///
/// Give it a [handler] to let `runTools` and `OllamaConversation` execute it
/// automatically.
///
/// ```dart
/// final weather = OllamaTool.function(
///   name: 'get_weather',
///   description: 'Current weather for a city',
///   parameters: OllamaSchema.object({
///     'city': OllamaSchema.string(description: 'City name'),
///   }),
///   handler: (args) => {'city': args['city'], 'celsius': 21},
/// );
/// ```
class OllamaTool {
  const OllamaTool.function({
    required this.name,
    required this.parameters,
    this.description,
    this.handler,
  });

  /// Parses a tool definition in Ollama/OpenAI JSON form.
  factory OllamaTool.fromJson(Map<String, Object?> json,
      {OllamaToolHandler? handler}) {
    final function = asJsonMap(json['function']) ?? json;
    return OllamaTool.function(
      name: function['name']?.toString() ?? '',
      description: asString(function['description']),
      parameters: asJsonMap(function['parameters']) ??
          const {'type': 'object', 'properties': <String, Object?>{}},
      handler: handler,
    );
  }

  final String name;
  final String? description;

  /// A JSON schema object describing the arguments.
  final JsonMap parameters;

  /// Executes the tool. Not sent to the server.
  final OllamaToolHandler? handler;

  /// Returns a copy with [handler] attached.
  OllamaTool withHandler(OllamaToolHandler handler) => OllamaTool.function(
        name: name,
        parameters: parameters,
        description: description,
        handler: handler,
      );

  JsonMap toJson() => withoutNulls({
        'type': 'function',
        'function': withoutNulls({
          'name': name,
          'description': description,
          'parameters': parameters,
        }),
      });

  @override
  String toString() => 'OllamaTool($name)';
}

/// A tool call requested by the model.
class OllamaToolCall {
  const OllamaToolCall({
    required this.name,
    required this.arguments,
    this.description,
    this.id,
    this.index,
  });

  final String name;

  /// Kept for backward compatibility; Ollama does not send it.
  final String? description;

  /// Decoded arguments.
  final JsonMap arguments;

  /// Call id (newer servers and cloud models).
  final String? id;

  /// Position among parallel calls.
  final int? index;

  JsonMap toJson() => withoutNulls({
        'id': id,
        'function': withoutNulls({
          'index': index,
          'name': name,
          'description': description,
          'arguments': arguments,
        }),
      });

  factory OllamaToolCall.fromJson(Map<String, Object?> json) {
    final function = asJsonMap(json['function']) ?? const <String, Object?>{};
    return OllamaToolCall(
      name: function['name']?.toString() ?? '',
      description: asString(function['description']),
      arguments: _decodeArguments(function['arguments']),
      id: asString(json['id']),
      index: asInt(function['index'] ?? json['index']),
    );
  }

  /// Arguments are an object in the native API but a JSON *string* in the
  /// OpenAI-compatible API and some proxies. Both are accepted.
  static JsonMap _decodeArguments(Object? arguments) {
    if (arguments is String) {
      if (arguments.trim().isEmpty) return {};
      try {
        final decoded = asJsonMap(jsonDecode(arguments));
        if (decoded != null) return decoded;
      } on FormatException {
        // Fall through.
      }
      return {'input': arguments};
    }
    return asJsonMap(arguments) ?? {};
  }

  @override
  String toString() => '$name(${jsonEncode(arguments)})';
}

/// One token's log probability.
class OllamaLogprob {
  const OllamaLogprob({
    required this.token,
    required this.logprob,
    this.bytes,
    this.topLogprobs = const [],
  });

  factory OllamaLogprob.fromJson(Map<String, Object?> json) {
    return OllamaLogprob(
      token: json['token']?.toString() ?? '',
      logprob: asDouble(json['logprob']) ?? 0,
      bytes: json['bytes'] is List
          ? [for (final b in json['bytes'] as List) asInt(b) ?? 0]
          : null,
      topLogprobs: asJsonMapList(json['top_logprobs'])
          .map(OllamaLogprob.fromJson)
          .toList(),
    );
  }

  final String token;
  final double logprob;
  final List<int>? bytes;
  final List<OllamaLogprob> topLogprobs;
}

/// Timing and token counts. Present on non-streaming responses and on the
/// final (`done`) chunk of a stream.
mixin OllamaMetrics {
  Duration? get totalDuration;
  Duration? get loadDuration;
  int? get promptEvalCount;
  Duration? get promptEvalDuration;
  int? get evalCount;
  Duration? get evalDuration;
  JsonMap get raw;

  /// Prompt tokens served from the cache (newer servers).
  int? get promptEvalCachedCount => asInt(raw['prompt_eval_cached_count']);

  /// Generation speed in tokens per second.
  double? get tokensPerSecond => _rate(evalCount, evalDuration);

  /// Prompt processing speed in tokens per second.
  double? get promptTokensPerSecond =>
      _rate(promptEvalCount, promptEvalDuration);

  /// Total tokens processed (prompt + output).
  int? get totalTokens => promptEvalCount == null && evalCount == null
      ? null
      : (promptEvalCount ?? 0) + (evalCount ?? 0);

  static double? _rate(int? count, Duration? duration) {
    if (count == null || duration == null || duration.inMicroseconds == 0) {
      return null;
    }
    return count / (duration.inMicroseconds / Duration.microsecondsPerSecond);
  }
}

/// A `/api/generate` response, or one chunk of a streamed response.
class OllamaGenerateResponse with OllamaMetrics {
  const OllamaGenerateResponse({
    required this.model,
    required this.done,
    required this.raw,
    this.createdAt,
    this.response = '',
    this.thinking,
    this.doneReason,
    this.totalDuration,
    this.loadDuration,
    this.promptEvalCount,
    this.promptEvalDuration,
    this.evalCount,
    this.evalDuration,
    this.logprobs,
    this.context,
    this.toolCalls,
  });

  final String model;
  final DateTime? createdAt;

  /// Generated text (a delta when streaming).
  final String response;

  /// Reasoning text (a delta when streaming).
  final String? thinking;
  final bool done;
  final String? doneReason;
  @override
  final Duration? totalDuration;
  @override
  final Duration? loadDuration;
  @override
  final int? promptEvalCount;
  @override
  final Duration? promptEvalDuration;
  @override
  final int? evalCount;
  @override
  final Duration? evalDuration;
  final List<Object?>? logprobs;

  /// Deprecated by Ollama; prefer `chat` for multi-turn.
  final List<int>? context;
  final List<OllamaToolCall>? toolCalls;

  /// The full JSON, including fields this version does not model.
  @override
  final JsonMap raw;

  /// [doneReason] as a typed, forward-compatible value.
  OllamaDoneReason? get reason =>
      doneReason == null ? null : OllamaDoneReason(doneReason!);

  /// Typed [logprobs].
  List<OllamaLogprob> get tokenLogprobs =>
      asJsonMapList(logprobs).map(OllamaLogprob.fromJson).toList();

  /// For cloud models proxied by a local server.
  String? get remoteModel => asString(raw['remote_model']);
  String? get remoteHost => asString(raw['remote_host']);

  factory OllamaGenerateResponse.fromJson(Map<String, Object?> json) {
    return OllamaGenerateResponse(
      model: json['model']?.toString() ?? '',
      createdAt: asDateTime(json['created_at']),
      response: json['response']?.toString() ?? '',
      thinking: asString(json['thinking']),
      done: json['done'] == true,
      doneReason: asString(json['done_reason']),
      totalDuration: asNanoseconds(json['total_duration']),
      loadDuration: asNanoseconds(json['load_duration']),
      promptEvalCount: asInt(json['prompt_eval_count']),
      promptEvalDuration: asNanoseconds(json['prompt_eval_duration']),
      evalCount: asInt(json['eval_count']),
      evalDuration: asNanoseconds(json['eval_duration']),
      logprobs: json['logprobs'] is List ? json['logprobs'] as List : null,
      context: json['context'] is List
          ? [for (final t in json['context'] as List) asInt(t) ?? 0]
          : null,
      toolCalls: json['tool_calls'] is List
          ? asJsonMapList(json['tool_calls'])
              .map(OllamaToolCall.fromJson)
              .toList()
          : null,
      raw: Map<String, Object?>.from(json),
    );
  }

  @override
  String toString() => 'OllamaGenerateResponse($model, done: $done, '
      '"${response.length > 60 ? '${response.substring(0, 60)}…' : response}")';
}

/// A `/api/chat` response, or one chunk of a streamed response.
class OllamaChatResponse with OllamaMetrics {
  const OllamaChatResponse({
    required this.model,
    required this.done,
    required this.raw,
    this.createdAt,
    this.message,
    this.doneReason,
    this.totalDuration,
    this.loadDuration,
    this.promptEvalCount,
    this.promptEvalDuration,
    this.evalCount,
    this.evalDuration,
    this.logprobs,
  });

  final String model;
  final DateTime? createdAt;

  /// The assistant message (a delta when streaming).
  final OllamaMessage? message;
  final bool done;
  final String? doneReason;
  @override
  final Duration? totalDuration;
  @override
  final Duration? loadDuration;
  @override
  final int? promptEvalCount;
  @override
  final Duration? promptEvalDuration;
  @override
  final int? evalCount;
  @override
  final Duration? evalDuration;
  final List<Object?>? logprobs;

  /// The full JSON, including fields this version does not model.
  @override
  final JsonMap raw;

  /// The message text (empty if none).
  String get text => message?.content ?? '';

  /// The reasoning text, if any.
  String? get thinking => message?.thinking;

  /// Requested tool calls (empty if none).
  List<OllamaToolCall> get toolCalls => message?.toolCalls ?? const [];

  OllamaDoneReason? get reason =>
      doneReason == null ? null : OllamaDoneReason(doneReason!);

  List<OllamaLogprob> get tokenLogprobs =>
      asJsonMapList(logprobs).map(OllamaLogprob.fromJson).toList();

  String? get remoteModel => asString(raw['remote_model']);
  String? get remoteHost => asString(raw['remote_host']);

  factory OllamaChatResponse.fromJson(Map<String, Object?> json) {
    final message = asJsonMap(json['message']);
    return OllamaChatResponse(
      model: json['model']?.toString() ?? '',
      createdAt: asDateTime(json['created_at']),
      message: message == null ? null : OllamaMessage.fromJson(message),
      done: json['done'] == true,
      doneReason: asString(json['done_reason']),
      totalDuration: asNanoseconds(json['total_duration']),
      loadDuration: asNanoseconds(json['load_duration']),
      promptEvalCount: asInt(json['prompt_eval_count']),
      promptEvalDuration: asNanoseconds(json['prompt_eval_duration']),
      evalCount: asInt(json['eval_count']),
      evalDuration: asNanoseconds(json['eval_duration']),
      logprobs: json['logprobs'] is List ? json['logprobs'] as List : null,
      raw: Map<String, Object?>.from(json),
    );
  }

  @override
  String toString() => 'OllamaChatResponse($model, done: $done, $message)';
}

/// A `/api/embed` response.
class OllamaEmbedResponse {
  const OllamaEmbedResponse({
    required this.model,
    required this.embeddings,
    required this.raw,
    this.totalDuration,
    this.loadDuration,
    this.promptEvalCount,
  });

  final String model;

  /// One vector per input, in input order.
  final List<List<double>> embeddings;
  final Duration? totalDuration;
  final Duration? loadDuration;
  final int? promptEvalCount;
  final JsonMap raw;

  factory OllamaEmbedResponse.fromJson(Map<String, Object?> json) {
    final embeddings = json['embeddings'];
    return OllamaEmbedResponse(
      model: json['model']?.toString() ?? '',
      embeddings: embeddings is List
          ? [
              for (final vector in embeddings.whereType<List>())
                [for (final value in vector) asDouble(value) ?? 0.0],
            ]
          : const [],
      totalDuration: asNanoseconds(json['total_duration']),
      loadDuration: asNanoseconds(json['load_duration']),
      promptEvalCount: asInt(json['prompt_eval_count']),
      raw: Map<String, Object?>.from(json),
    );
  }

  /// The first vector. Throws [StateError] if the server returned none.
  List<double> get first {
    if (embeddings.isEmpty) {
      throw StateError('The embed response contained no embeddings. '
          'Is "$model" an embedding model?');
    }
    return embeddings.first;
  }

  /// Vector dimensions (0 if empty).
  int get dimensions => embeddings.isEmpty ? 0 : embeddings.first.length;
}

/// An installed model from `/api/tags`.
class OllamaModel {
  const OllamaModel({
    required this.name,
    required this.model,
    required this.raw,
    this.modifiedAt,
    this.size,
    this.digest,
    this.details,
  });

  final String name;
  final String model;
  final DateTime? modifiedAt;

  /// Size on disk in bytes.
  final int? size;
  final String? digest;
  final OllamaModelDetails? details;
  final JsonMap raw;

  /// Capabilities, when the server lists them here (newer servers).
  List<String> get capabilities =>
      asStringList(raw['capabilities']) ?? const [];

  /// Set for cloud models proxied by a local server.
  String? get remoteModel => asString(raw['remote_model']);
  String? get remoteHost => asString(raw['remote_host']);

  /// Whether this is a cloud model.
  bool get isRemote => remoteHost != null || name.endsWith('-cloud');

  factory OllamaModel.fromJson(Map<String, Object?> json) {
    final details = asJsonMap(json['details']);
    return OllamaModel(
      name: json['name']?.toString() ?? json['model']?.toString() ?? '',
      model: json['model']?.toString() ?? json['name']?.toString() ?? '',
      modifiedAt: asDateTime(json['modified_at']),
      size: asInt(json['size']),
      digest: asString(json['digest']),
      details: details == null ? null : OllamaModelDetails.fromJson(details),
      raw: Map<String, Object?>.from(json),
    );
  }

  @override
  String toString() => 'OllamaModel($name)';
}

/// Model metadata shared by tags, show and ps.
class OllamaModelDetails {
  const OllamaModelDetails({
    this.format,
    this.family,
    this.families,
    this.parameterSize,
    this.quantizationLevel,
    this.parentModel,
    this.raw = const {},
  });

  final String? format;
  final String? family;
  final List<String>? families;

  /// e.g. `8.0B`.
  final String? parameterSize;

  /// e.g. `Q4_K_M`.
  final String? quantizationLevel;
  final String? parentModel;
  final JsonMap raw;

  int? get contextLength => asInt(raw['context_length']);
  int? get embeddingLength => asInt(raw['embedding_length']);

  factory OllamaModelDetails.fromJson(Map<String, Object?> json) {
    return OllamaModelDetails(
      format: asString(json['format']),
      family: asString(json['family']),
      families: asStringList(json['families']),
      parameterSize: asString(json['parameter_size']),
      quantizationLevel: asString(json['quantization_level']),
      parentModel: asString(json['parent_model']),
      raw: Map<String, Object?>.from(json),
    );
  }
}

/// `/api/show` details for one model.
class OllamaModelInfo {
  const OllamaModelInfo({
    required this.raw,
    this.modelfile,
    this.parameters,
    this.template,
    this.system,
    this.license,
    this.details,
    this.modelInfo = const {},
    this.capabilities = const [],
    this.modifiedAt,
  });

  factory OllamaModelInfo.fromJson(Map<String, Object?> json) {
    final details = asJsonMap(json['details']);
    final license = json['license'];
    return OllamaModelInfo(
      modelfile: asString(json['modelfile']),
      parameters: asString(json['parameters']),
      template: asString(json['template']),
      system: asString(json['system']),
      license: license is List ? license.join('\n') : asString(license),
      details: details == null ? null : OllamaModelDetails.fromJson(details),
      modelInfo: asJsonMap(json['model_info']) ?? const {},
      capabilities: asStringList(json['capabilities']) ?? const [],
      modifiedAt: asDateTime(json['modified_at']),
      raw: Map<String, Object?>.from(json),
    );
  }

  final String? modelfile;

  /// Default parameters, one per line (`temperature 0.7`).
  final String? parameters;
  final String? template;
  final String? system;
  final String? license;
  final OllamaModelDetails? details;

  /// Architecture metadata, e.g. `llama.context_length`.
  final JsonMap modelInfo;

  /// e.g. `completion`, `tools`, `vision`, `thinking`, `embedding`.
  final List<String> capabilities;
  final DateTime? modifiedAt;
  final JsonMap raw;

  bool supports(String capability) => capabilities.contains(capability);
  bool get supportsTools => supports(OllamaCapability.tools);
  bool get supportsVision => supports(OllamaCapability.vision);
  bool get supportsThinking => supports(OllamaCapability.thinking);
  bool get supportsEmbedding => supports(OllamaCapability.embedding);
  bool get supportsCompletion => supports(OllamaCapability.completion);
  bool get supportsInsert => supports(OllamaCapability.insert);

  /// The architecture, e.g. `llama` or `qwen2`.
  String? get architecture => asString(modelInfo['general.architecture']);

  /// The trained context length, read from [modelInfo].
  int? get contextLength {
    final arch = architecture;
    if (arch != null && modelInfo['$arch.context_length'] != null) {
      return asInt(modelInfo['$arch.context_length']);
    }
    for (final entry in modelInfo.entries) {
      if (entry.key.endsWith('.context_length')) return asInt(entry.value);
    }
    return details?.contextLength;
  }

  /// Supported `think` values (e.g. `[true, false]` or `['low', 'high']`).
  List<Object?> get thinkingValues {
    final thinking = asJsonMap(raw['thinking']);
    final values = thinking?['values'];
    return values is List ? List.unmodifiable(values) : const [];
  }

  /// Default parameters parsed from [parameters].
  Map<String, Object?> get parameterMap {
    final result = <String, Object?>{};
    for (final line in const LineSplitter().convert(parameters ?? '')) {
      final match = RegExp(r'^\s*(\S+)\s+(.+?)\s*$').firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!;
      var value = match.group(2)!;
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      final parsed = num.tryParse(value) ?? asBool(value) ?? value;
      final existing = result[key];
      if (existing == null) {
        result[key] = parsed;
      } else if (existing is List) {
        existing.add(parsed);
      } else {
        result[key] = [existing, parsed];
      }
    }
    return result;
  }
}

/// A model loaded in memory, from `/api/ps`.
class OllamaRunningModel {
  const OllamaRunningModel({
    required this.name,
    required this.model,
    required this.raw,
    this.size,
    this.sizeVram,
    this.digest,
    this.details,
    this.expiresAt,
    this.contextLength,
  });

  factory OllamaRunningModel.fromJson(Map<String, Object?> json) {
    final details = asJsonMap(json['details']);
    return OllamaRunningModel(
      name: json['name']?.toString() ?? json['model']?.toString() ?? '',
      model: json['model']?.toString() ?? json['name']?.toString() ?? '',
      size: asInt(json['size']),
      sizeVram: asInt(json['size_vram']),
      digest: asString(json['digest']),
      details: details == null ? null : OllamaModelDetails.fromJson(details),
      expiresAt: asDateTime(json['expires_at']),
      contextLength: asInt(json['context_length']),
      raw: Map<String, Object?>.from(json),
    );
  }

  final String name;
  final String model;

  /// Memory used, in bytes.
  final int? size;

  /// Of [size], bytes in GPU memory.
  final int? sizeVram;
  final String? digest;
  final OllamaModelDetails? details;

  /// When the model will be unloaded.
  final DateTime? expiresAt;

  /// The context length it was loaded with.
  final int? contextLength;
  final JsonMap raw;

  /// Fraction of the model on the GPU (0..1), if known.
  double? get gpuFraction =>
      size == null || size == 0 || sizeVram == null ? null : sizeVram! / size!;
}

/// A progress event from pull, push or create.
class OllamaStatus {
  const OllamaStatus({
    required this.status,
    required this.raw,
    this.digest,
    this.total,
    this.completed,
  });

  /// e.g. `pulling manifest`, `downloading sha256:...`, `success`.
  final String status;
  final String? digest;

  /// Bytes in the current layer.
  final int? total;

  /// Bytes done in the current layer.
  final int? completed;
  final JsonMap raw;

  /// Progress of the current layer (0..1), or `null` when not applicable.
  double? get progress {
    if (total == null || total == 0 || completed == null) return null;
    return (completed! / total!).clamp(0.0, 1.0);
  }

  /// Whether this is the final `success` event.
  bool get isSuccess => status == 'success';

  factory OllamaStatus.fromJson(Map<String, Object?> json) {
    return OllamaStatus(
      status: json['status']?.toString() ?? '',
      digest: asString(json['digest']),
      total: asInt(json['total']),
      completed: asInt(json['completed']),
      raw: Map<String, Object?>.from(json),
    );
  }

  @override
  String toString() {
    final pct =
        progress == null ? '' : ' ${(progress! * 100).toStringAsFixed(1)}%';
    return 'OllamaStatus($status$pct)';
  }
}

/// One web search hit (Ollama cloud `web_search`).
class OllamaWebSearchResult {
  const OllamaWebSearchResult({
    required this.title,
    required this.url,
    required this.content,
    required this.raw,
  });

  factory OllamaWebSearchResult.fromJson(Map<String, Object?> json) {
    return OllamaWebSearchResult(
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      raw: Map<String, Object?>.from(json),
    );
  }

  final String title;
  final String url;

  /// Relevant page text.
  final String content;
  final JsonMap raw;
}

/// A fetched web page (Ollama cloud `web_fetch`).
class OllamaWebFetchResult {
  const OllamaWebFetchResult({
    required this.title,
    required this.content,
    required this.links,
    required this.raw,
  });

  factory OllamaWebFetchResult.fromJson(Map<String, Object?> json) {
    return OllamaWebFetchResult(
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      links: asStringList(json['links']) ?? const [],
      raw: Map<String, Object?>.from(json),
    );
  }

  final String title;
  final String content;
  final List<String> links;
  final JsonMap raw;
}

/// Decodes JSON text. Kept for backward compatibility; see also
/// `decodeJsonObject` for lenient decoding of model output.
Object? decodeOllamaJsonText(String value) => jsonDecode(value);
