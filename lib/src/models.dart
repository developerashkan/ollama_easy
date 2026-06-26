import 'dart:convert';

typedef JsonMap = Map<String, Object?>;

enum OllamaRole {
  system,
  user,
  assistant,
  tool;

  static OllamaRole fromJson(Object? value) {
    final role = value?.toString();
    return OllamaRole.values.firstWhere(
      (item) => item.name == role,
      orElse: () => OllamaRole.assistant,
    );
  }
}

class OllamaMessage {
  const OllamaMessage({
    required this.role,
    required this.content,
    this.thinking,
    this.images,
    this.toolCalls,
  });

  const OllamaMessage.system(String content)
      : this(role: OllamaRole.system, content: content);

  const OllamaMessage.user(String content, {List<String>? images})
      : this(role: OllamaRole.user, content: content, images: images);

  const OllamaMessage.assistant(String content, {String? thinking})
      : this(role: OllamaRole.assistant, content: content, thinking: thinking);

  final OllamaRole role;
  final String content;
  final String? thinking;
  final List<String>? images;
  final List<OllamaToolCall>? toolCalls;

  JsonMap toJson() => _withoutNulls({
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'images': images,
        'tool_calls': toolCalls?.map((call) => call.toJson()).toList(),
      });

  factory OllamaMessage.fromJson(Map<String, Object?> json) {
    final toolCalls = json['tool_calls'];
    return OllamaMessage(
      role: OllamaRole.fromJson(json['role']),
      content: json['content']?.toString() ?? '',
      thinking: json['thinking']?.toString(),
      images: (json['images'] as List?)?.map((item) => '$item').toList(),
      toolCalls: toolCalls is List
          ? toolCalls
              .whereType<Map>()
              .map(
                (item) =>
                    OllamaToolCall.fromJson(Map<String, Object?>.from(item)),
              )
              .toList()
          : null,
    );
  }
}

class OllamaTool {
  const OllamaTool.function({
    required this.name,
    required this.parameters,
    this.description,
  });

  final String name;
  final String? description;
  final JsonMap parameters;

  JsonMap toJson() => _withoutNulls({
        'type': 'function',
        'function': _withoutNulls({
          'name': name,
          'description': description,
          'parameters': parameters,
        }),
      });
}

class OllamaToolCall {
  const OllamaToolCall({
    required this.name,
    required this.arguments,
    this.description,
  });

  final String name;
  final String? description;
  final JsonMap arguments;

  JsonMap toJson() => _withoutNulls({
        'function': _withoutNulls({
          'name': name,
          'description': description,
          'arguments': arguments,
        }),
      });

  factory OllamaToolCall.fromJson(Map<String, Object?> json) {
    final function = json['function'];
    final functionJson = function is Map
        ? Map<String, Object?>.from(function)
        : const <String, Object?>{};
    final arguments = functionJson['arguments'];
    return OllamaToolCall(
      name: functionJson['name']?.toString() ?? '',
      description: functionJson['description']?.toString(),
      arguments: arguments is Map ? Map<String, Object?>.from(arguments) : {},
    );
  }
}

class OllamaGenerateResponse {
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
  });

  final String model;
  final DateTime? createdAt;
  final String response;
  final String? thinking;
  final bool done;
  final String? doneReason;
  final Duration? totalDuration;
  final Duration? loadDuration;
  final int? promptEvalCount;
  final Duration? promptEvalDuration;
  final int? evalCount;
  final Duration? evalDuration;
  final List<Object?>? logprobs;
  final JsonMap raw;

  factory OllamaGenerateResponse.fromJson(Map<String, Object?> json) {
    return OllamaGenerateResponse(
      model: json['model']?.toString() ?? '',
      createdAt: _dateTime(json['created_at']),
      response: json['response']?.toString() ?? '',
      thinking: json['thinking']?.toString(),
      done: json['done'] == true,
      doneReason: json['done_reason']?.toString(),
      totalDuration: _nanoseconds(json['total_duration']),
      loadDuration: _nanoseconds(json['load_duration']),
      promptEvalCount: _int(json['prompt_eval_count']),
      promptEvalDuration: _nanoseconds(json['prompt_eval_duration']),
      evalCount: _int(json['eval_count']),
      evalDuration: _nanoseconds(json['eval_duration']),
      logprobs: json['logprobs'] is List ? json['logprobs'] as List : null,
      raw: Map<String, Object?>.from(json),
    );
  }
}

class OllamaChatResponse {
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
  final OllamaMessage? message;
  final bool done;
  final String? doneReason;
  final Duration? totalDuration;
  final Duration? loadDuration;
  final int? promptEvalCount;
  final Duration? promptEvalDuration;
  final int? evalCount;
  final Duration? evalDuration;
  final List<Object?>? logprobs;
  final JsonMap raw;

  factory OllamaChatResponse.fromJson(Map<String, Object?> json) {
    final message = json['message'];
    return OllamaChatResponse(
      model: json['model']?.toString() ?? '',
      createdAt: _dateTime(json['created_at']),
      message: message is Map
          ? OllamaMessage.fromJson(Map<String, Object?>.from(message))
          : null,
      done: json['done'] == true,
      doneReason: json['done_reason']?.toString(),
      totalDuration: _nanoseconds(json['total_duration']),
      loadDuration: _nanoseconds(json['load_duration']),
      promptEvalCount: _int(json['prompt_eval_count']),
      promptEvalDuration: _nanoseconds(json['prompt_eval_duration']),
      evalCount: _int(json['eval_count']),
      evalDuration: _nanoseconds(json['eval_duration']),
      logprobs: json['logprobs'] is List ? json['logprobs'] as List : null,
      raw: Map<String, Object?>.from(json),
    );
  }
}

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
          ? embeddings
              .whereType<List>()
              .map(
                (vector) => vector
                    .whereType<num>()
                    .map((value) => value.toDouble())
                    .toList(),
              )
              .toList()
          : const [],
      totalDuration: _nanoseconds(json['total_duration']),
      loadDuration: _nanoseconds(json['load_duration']),
      promptEvalCount: _int(json['prompt_eval_count']),
      raw: Map<String, Object?>.from(json),
    );
  }

  List<double> get first => embeddings.first;
}

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
  final int? size;
  final String? digest;
  final OllamaModelDetails? details;
  final JsonMap raw;

  factory OllamaModel.fromJson(Map<String, Object?> json) {
    final details = json['details'];
    return OllamaModel(
      name: json['name']?.toString() ?? '',
      model: json['model']?.toString() ?? json['name']?.toString() ?? '',
      modifiedAt: _dateTime(json['modified_at']),
      size: _int(json['size']),
      digest: json['digest']?.toString(),
      details: details is Map
          ? OllamaModelDetails.fromJson(Map<String, Object?>.from(details))
          : null,
      raw: Map<String, Object?>.from(json),
    );
  }
}

class OllamaModelDetails {
  const OllamaModelDetails({
    this.format,
    this.family,
    this.families,
    this.parameterSize,
    this.quantizationLevel,
  });

  final String? format;
  final String? family;
  final List<String>? families;
  final String? parameterSize;
  final String? quantizationLevel;

  factory OllamaModelDetails.fromJson(Map<String, Object?> json) {
    return OllamaModelDetails(
      format: json['format']?.toString(),
      family: json['family']?.toString(),
      families: (json['families'] as List?)?.map((item) => '$item').toList(),
      parameterSize: json['parameter_size']?.toString(),
      quantizationLevel: json['quantization_level']?.toString(),
    );
  }
}

class OllamaStatus {
  const OllamaStatus({
    required this.status,
    required this.raw,
    this.digest,
    this.total,
    this.completed,
  });

  final String status;
  final String? digest;
  final int? total;
  final int? completed;
  final JsonMap raw;

  factory OllamaStatus.fromJson(Map<String, Object?> json) {
    return OllamaStatus(
      status: json['status']?.toString() ?? '',
      digest: json['digest']?.toString(),
      total: _int(json['total']),
      completed: _int(json['completed']),
      raw: Map<String, Object?>.from(json),
    );
  }
}

class OllamaException implements Exception {
  const OllamaException(this.message, {this.statusCode, this.uri, this.body});

  final String message;
  final int? statusCode;
  final Uri? uri;
  final String? body;

  @override
  String toString() {
    final code = statusCode == null ? '' : ' HTTP $statusCode.';
    final target = uri == null ? '' : ' $uri';
    return 'OllamaException:$code $message$target'.trim();
  }
}

Object? decodeOllamaJsonText(String value) => jsonDecode(value);

JsonMap _withoutNulls(Map<String, Object?> json) {
  final cleaned = <String, Object?>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (value == null) {
      continue;
    }
    cleaned[entry.key] = value;
  }
  return cleaned;
}

DateTime? _dateTime(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

Duration? _nanoseconds(Object? value) {
  final number = _int(value);
  if (number == null) {
    return null;
  }
  return Duration(microseconds: number ~/ 1000);
}

int? _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
