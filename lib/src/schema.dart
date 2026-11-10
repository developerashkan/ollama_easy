import 'dart:convert';

import 'exceptions.dart';
import 'json_utils.dart';

/// A small JSON schema builder for tool parameters and structured outputs.
///
/// Every builder returns a plain `Map<String, Object?>`, so you can mix it
/// with hand-written schemas.
///
/// ```dart
/// final schema = OllamaSchema.object({
///   'name': OllamaSchema.string(),
///   'age': OllamaSchema.integer(minimum: 0),
///   'tags': OllamaSchema.array(OllamaSchema.string()),
///   'mood': OllamaSchema.enumeration(['happy', 'sad']),
/// });
/// ```
abstract final class OllamaSchema {
  /// An object. By default every property is required, which gives the most
  /// reliable structured output; pass [required] to change that.
  static JsonMap object(
    Map<String, Map<String, Object?>> properties, {
    List<String>? required,
    String? description,
    bool additionalProperties = false,
  }) {
    return withoutNulls({
      'type': 'object',
      'description': description,
      'properties': properties,
      'required': required ?? properties.keys.toList(),
      'additionalProperties': additionalProperties,
    });
  }

  static JsonMap string({
    String? description,
    List<String>? enumValues,
    String? format,
    String? pattern,
    int? minLength,
    int? maxLength,
  }) =>
      withoutNulls({
        'type': 'string',
        'description': description,
        'enum': enumValues,
        'format': format,
        'pattern': pattern,
        'minLength': minLength,
        'maxLength': maxLength,
      });

  static JsonMap integer({String? description, num? minimum, num? maximum}) =>
      withoutNulls({
        'type': 'integer',
        'description': description,
        'minimum': minimum,
        'maximum': maximum,
      });

  static JsonMap number({String? description, num? minimum, num? maximum}) =>
      withoutNulls({
        'type': 'number',
        'description': description,
        'minimum': minimum,
        'maximum': maximum,
      });

  static JsonMap boolean({String? description}) =>
      withoutNulls({'type': 'boolean', 'description': description});

  static JsonMap array(
    Map<String, Object?> items, {
    String? description,
    int? minItems,
    int? maxItems,
  }) =>
      withoutNulls({
        'type': 'array',
        'description': description,
        'items': items,
        'minItems': minItems,
        'maxItems': maxItems,
      });

  /// A string restricted to [values].
  static JsonMap enumeration(List<String> values, {String? description}) =>
      string(description: description, enumValues: values);

  /// A value that may also be `null`.
  static JsonMap nullable(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is String) {
      return {
        ...schema,
        'type': [type, 'null'],
      };
    }
    return {
      'anyOf': [
        schema,
        {'type': 'null'},
      ],
    };
  }

  /// Any of [schemas].
  static JsonMap anyOf(List<Map<String, Object?>> schemas,
          {String? description}) =>
      withoutNulls({'anyOf': schemas, 'description': description});
}

/// Decodes a JSON object from model output, tolerating Markdown code fences
/// and text around the object.
///
/// Throws [OllamaResponseFormatException] when no JSON object is found.
JsonMap decodeJsonObject(String text) {
  final decoded = decodeJsonValue(text);
  final map = asJsonMap(decoded);
  if (map == null) {
    throw OllamaResponseFormatException(
      'Expected a JSON object but the model returned '
      '${decoded.runtimeType}.',
      body: text,
    );
  }
  return map;
}

/// Like [decodeJsonObject] but returns any JSON value.
Object? decodeJsonValue(String text) {
  final trimmed = text.trim();
  final candidates = <String>[trimmed];
  final fence =
      RegExp(r'```(?:json|JSON)?\s*([\s\S]*?)```').firstMatch(trimmed);
  if (fence != null) candidates.add(fence.group(1)!.trim());
  for (final pair in const [('{', '}'), ('[', ']')]) {
    final start = trimmed.indexOf(pair.$1);
    final end = trimmed.lastIndexOf(pair.$2);
    if (start != -1 && end > start) {
      candidates.add(trimmed.substring(start, end + 1));
    }
  }
  FormatException? lastError;
  for (final candidate in candidates) {
    if (candidate.isEmpty) continue;
    try {
      return jsonDecode(candidate);
    } on FormatException catch (error) {
      lastError = error;
    }
  }
  throw OllamaResponseFormatException(
    trimmed.isEmpty
        ? 'The model returned an empty response instead of JSON.'
        : 'The model output was not valid JSON.',
    body: text,
    cause: lastError,
  );
}
