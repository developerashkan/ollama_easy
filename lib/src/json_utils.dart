// Internal JSON helpers. Not exported from the public library.

typedef JsonMap = Map<String, Object?>;

/// Removes `null` values from the top level of [json] only.
///
/// Nested values (JSON schemas, tool arguments, user options) are left as is,
/// because `null` can be meaningful there (`"default": null`, nullable
/// arguments).
JsonMap withoutNulls(Map<String, Object?> json) {
  final cleaned = <String, Object?>{};
  for (final entry in json.entries) {
    if (entry.value != null) cleaned[entry.key] = entry.value;
  }
  return cleaned;
}

JsonMap? asJsonMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

List<JsonMap> asJsonMapList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (asJsonMap(item) case final map?) map,
  ];
}

List<String>? asStringList(Object? value) {
  if (value is! List) return null;
  return [for (final item in value) '$item'];
}

String? asString(Object? value) => value?.toString();

DateTime? asDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

/// Ollama reports durations as integer nanoseconds.
Duration? asNanoseconds(Object? value) {
  final number = asInt(value);
  if (number == null) return null;
  return Duration(microseconds: number ~/ 1000);
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

double? asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

bool? asBool(Object? value) {
  if (value is bool) return value;
  if (value == 'true') return true;
  if (value == 'false') return false;
  return null;
}

/// Returns the entries of [json] whose keys are not in [known].
JsonMap unknownFields(Map<String, Object?> json, Set<String> known) {
  return {
    for (final entry in json.entries)
      if (!known.contains(entry.key)) entry.key: entry.value,
  };
}
