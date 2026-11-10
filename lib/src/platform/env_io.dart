import 'dart:io';

String? readEnvironment(String name) {
  final value = Platform.environment[name];
  return value == null || value.trim().isEmpty ? null : value.trim();
}

String? platformUserAgent(String version) =>
    'ollama_easy/$version (dart ${Platform.version.split(' ').first}; '
    '${Platform.operatingSystem})';
