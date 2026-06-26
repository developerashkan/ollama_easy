import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class Ollama {
  Ollama({
    Uri? baseUrl,
    String? apiKey,
    this.defaultModel = 'qwen2.5:1.5b',
    http.Client? httpClient,
    Map<String, String>? headers,
  })  : baseUrl = baseUrl ?? Uri.parse('http://localhost:11434'),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _headers = {
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
          ...?headers,
        };

  factory Ollama.local({
    String defaultModel = 'qwen2.5:1.5b',
    http.Client? httpClient,
  }) {
    return Ollama(defaultModel: defaultModel, httpClient: httpClient);
  }

  factory Ollama.cloud({
    required String apiKey,
    String defaultModel = 'gpt-oss:20b',
    http.Client? httpClient,
  }) {
    return Ollama(
      baseUrl: Uri.parse('https://ollama.com/api'),
      apiKey: apiKey,
      defaultModel: defaultModel,
      httpClient: httpClient,
    );
  }

  final Uri baseUrl;
  final String defaultModel;
  final http.Client _client;
  final bool _ownsClient;
  final Map<String, String> _headers;

  Future<String> ask(
    String prompt, {
    String? model,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    String? keepAlive,
    Map<String, Object?>? options,
  }) async {
    final result = await generate(
      prompt,
      model: model,
      system: system,
      images: images,
      format: format,
      think: think,
      raw: raw,
      keepAlive: keepAlive,
      options: options,
    );
    return result.response;
  }

  Stream<String> askStream(
    String prompt, {
    String? model,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    String? keepAlive,
    Map<String, Object?>? options,
  }) {
    return generateStream(
      prompt,
      model: model,
      system: system,
      images: images,
      format: format,
      think: think,
      raw: raw,
      keepAlive: keepAlive,
      options: options,
    ).map((event) => event.response).where((text) => text.isNotEmpty);
  }

  Future<Map<String, Object?>> askJson(
    String prompt, {
    String? model,
    String? system,
    Map<String, Object?>? schema,
    Object? think,
    String? keepAlive,
    Map<String, Object?>? options,
  }) async {
    final text = await ask(
      prompt,
      model: model,
      system: system,
      format: schema ?? 'json',
      think: think,
      keepAlive: keepAlive,
      options: options,
    );
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    throw OllamaException('Expected a JSON object but received $decoded.');
  }

  Future<OllamaGenerateResponse> generate(
    String prompt, {
    String? model,
    String? suffix,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    String? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
  }) async {
    final json = await _postJson('generate', {
      'model': model ?? defaultModel,
      'prompt': prompt,
      'suffix': suffix,
      'system': system,
      'images': images,
      'format': format,
      'think': think,
      'raw': raw,
      'keep_alive': keepAlive,
      'options': options,
      'stream': false,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
    });
    return OllamaGenerateResponse.fromJson(json);
  }

  Stream<OllamaGenerateResponse> generateStream(
    String prompt, {
    String? model,
    String? suffix,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    String? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
  }) {
    return _postJsonStream('generate', {
      'model': model ?? defaultModel,
      'prompt': prompt,
      'suffix': suffix,
      'system': system,
      'images': images,
      'format': format,
      'think': think,
      'raw': raw,
      'keep_alive': keepAlive,
      'options': options,
      'stream': true,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
    }).map(OllamaGenerateResponse.fromJson);
  }

  Future<String> chatText(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    String? keepAlive,
    Map<String, Object?>? options,
  }) async {
    final result = await chat(
      messages,
      model: model,
      tools: tools,
      format: format,
      think: think,
      keepAlive: keepAlive,
      options: options,
    );
    return result.message?.content ?? '';
  }

  Stream<String> chatTextStream(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    String? keepAlive,
    Map<String, Object?>? options,
  }) {
    return chatStream(
      messages,
      model: model,
      tools: tools,
      format: format,
      think: think,
      keepAlive: keepAlive,
      options: options,
    )
        .map((event) => event.message?.content ?? '')
        .where((text) => text.isNotEmpty);
  }

  Future<OllamaChatResponse> chat(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    String? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
  }) async {
    final json = await _postJson('chat', {
      'model': model ?? defaultModel,
      'messages': messages.map((message) => message.toJson()).toList(),
      'tools': tools?.map((tool) => tool.toJson()).toList(),
      'format': format,
      'think': think,
      'keep_alive': keepAlive,
      'options': options,
      'stream': false,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
    });
    return OllamaChatResponse.fromJson(json);
  }

  Stream<OllamaChatResponse> chatStream(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    String? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
  }) {
    return _postJsonStream('chat', {
      'model': model ?? defaultModel,
      'messages': messages.map((message) => message.toJson()).toList(),
      'tools': tools?.map((tool) => tool.toJson()).toList(),
      'format': format,
      'think': think,
      'keep_alive': keepAlive,
      'options': options,
      'stream': true,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
    }).map(OllamaChatResponse.fromJson);
  }

  Future<OllamaEmbedResponse> embed(
    Object input, {
    String model = 'embeddinggemma',
    bool? truncate,
    int? dimensions,
    String? keepAlive,
    Map<String, Object?>? options,
  }) async {
    final json = await _postJson('embed', {
      'model': model,
      'input': input,
      'truncate': truncate,
      'dimensions': dimensions,
      'keep_alive': keepAlive,
      'options': options,
    });
    return OllamaEmbedResponse.fromJson(json);
  }

  Future<List<OllamaModel>> models() async {
    final json = await _getJson('tags');
    final models = json['models'];
    if (models is! List) {
      return const [];
    }
    return models
        .whereType<Map>()
        .map((model) => OllamaModel.fromJson(Map<String, Object?>.from(model)))
        .toList();
  }

  Future<bool> hasModel(String model) async {
    final available = await models();
    return available.any((item) => item.name == model || item.model == model);
  }

  Future<void> ensureModel(String model) async {
    if (await hasModel(model)) {
      return;
    }
    await pull(model);
  }

  Future<void> pull(String model, {bool insecure = false}) async {
    await _postJson('pull', {
      'model': model,
      'insecure': insecure ? true : null,
      'stream': false,
    });
  }

  Stream<OllamaStatus> pullStream(String model, {bool insecure = false}) {
    return _postJsonStream('pull', {
      'model': model,
      'insecure': insecure ? true : null,
      'stream': true,
    }).map(OllamaStatus.fromJson);
  }

  Future<String> version() async {
    final json = await _getJson('version');
    return json['version']?.toString() ?? '';
  }

  Future<bool> isRunning() async {
    try {
      await version();
      return true;
    } on Object {
      return false;
    }
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<JsonMap> _getJson(String endpoint) async {
    final uri = _uri(endpoint);
    final response = await _client.get(uri, headers: _requestHeaders());
    return _decodeResponse(response, uri);
  }

  Future<JsonMap> _postJson(String endpoint, Map<String, Object?> body) async {
    final uri = _uri(endpoint);
    final response = await _client.post(
      uri,
      headers: _requestHeaders(contentType: 'application/json'),
      body: jsonEncode(_clean(body)),
    );
    return _decodeResponse(response, uri);
  }

  Stream<JsonMap> _postJsonStream(
    String endpoint,
    Map<String, Object?> body,
  ) async* {
    final uri = _uri(endpoint);
    final request = http.Request('POST', uri)
      ..headers.addAll(_requestHeaders(contentType: 'application/json'))
      ..body = jsonEncode(_clean(body));

    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final responseBody = await response.stream.bytesToString();
      throw _exceptionFromBody(responseBody, response.statusCode, uri);
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty);

    await for (final line in lines) {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        yield Map<String, Object?>.from(decoded);
      }
    }
  }

  JsonMap _decodeResponse(http.Response response, Uri uri) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFromBody(response.body, response.statusCode, uri);
    }
    final decoded =
        response.body.isEmpty ? <String, Object?>{} : jsonDecode(response.body);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    throw OllamaException(
      'Expected a JSON object but received ${decoded.runtimeType}.',
      statusCode: response.statusCode,
      uri: uri,
      body: response.body,
    );
  }

  OllamaException _exceptionFromBody(String body, int statusCode, Uri uri) {
    String message = 'Ollama request failed.';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) {
        message = decoded['error'].toString();
      }
    } on FormatException {
      if (body.trim().isNotEmpty) {
        message = body.trim();
      }
    }
    return OllamaException(
      message,
      statusCode: statusCode,
      uri: uri,
      body: body,
    );
  }

  Uri _uri(String endpoint) {
    final existing = baseUrl.pathSegments.where((part) => part.isNotEmpty);
    final hasApiSegment = existing.isNotEmpty && existing.last == 'api';
    final segments = [...existing, if (!hasApiSegment) 'api', endpoint];
    return baseUrl.replace(pathSegments: segments);
  }

  Map<String, String> _requestHeaders({String? contentType}) {
    return {
      'Accept': 'application/json, application/x-ndjson',
      if (contentType != null) 'Content-Type': contentType,
      ..._headers,
    };
  }

  Object? _clean(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.fromEntries(
        value.entries.where((entry) => entry.value != null).map(
              (entry) => MapEntry(entry.key.toString(), _clean(entry.value)),
            ),
      );
    }
    if (value is Iterable) {
      return value.map(_clean).toList();
    }
    return value;
  }
}
