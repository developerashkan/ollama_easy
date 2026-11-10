import 'dart:async';

import 'package:http/http.dart' as http;

import 'cancel_token.dart';
import 'conversation.dart';
import 'exceptions.dart';
import 'interceptors.dart';
import 'json_utils.dart';
import 'models.dart';
import 'options.dart';
import 'platform/env_stub.dart' if (dart.library.io) 'platform/env_io.dart'
    as platform;
import 'retry.dart';
import 'schema.dart';
import 'streams.dart';
import 'tools.dart';
import 'transport.dart';

/// A client for the Ollama REST API: local servers, remote servers and
/// Ollama cloud.
///
/// ```dart
/// final ollama = Ollama.local(defaultModel: 'qwen2.5:1.5b');
/// print(await ollama.ask('Why is the sky blue?'));
/// ollama.close();
/// ```
///
/// Works on every platform (pure Dart, `package:http`). Every request method
/// accepts an [OllamaCancelToken]; every stream aborts its HTTP request when
/// you cancel the subscription.
class Ollama {
  /// Creates a client.
  ///
  /// - [baseUrl] or [host]: the server, default `http://localhost:11434`.
  ///   [host] accepts `OLLAMA_HOST`-style values (`localhost`, `10.0.0.5:8080`,
  ///   `https://ollama.example.com/prefix`). A trailing `/api` is optional.
  /// - [apiKey]: sent as `Authorization: Bearer <apiKey>` (Ollama cloud or an
  ///   authenticating proxy).
  /// - [headers]: extra headers for every request.
  /// - [httpClient]: bring your own `http.Client` (e.g. `cupertino_http`,
  ///   `cronet_http`, or a `MockClient` in tests). It is not closed by
  ///   [close].
  /// - [timeout]: for non-streaming calls, the limit for the whole request;
  ///   for streams, the limit for the first response. `null` = no limit.
  /// - [streamIdleTimeout]: the longest allowed gap between streamed chunks.
  /// - [retryPolicy]: automatic retries (connection errors, 429, 502-504).
  /// - [interceptors]: hooks for logging, auth, metrics.
  /// - [defaultOptions] / [defaultKeepAlive]: applied to every generation
  ///   request unless overridden per call.
  Ollama({
    Uri? baseUrl,
    String? host,
    String? apiKey,
    this.defaultModel = 'qwen2.5:1.5b',
    this.defaultEmbeddingModel = 'embeddinggemma',
    http.Client? httpClient,
    Map<String, String>? headers,
    Duration? timeout = const Duration(minutes: 10),
    Duration? streamIdleTimeout = const Duration(minutes: 5),
    OllamaRetryPolicy retryPolicy = const OllamaRetryPolicy(),
    List<OllamaInterceptor> interceptors = const [],
    this.defaultOptions,
    this.defaultKeepAlive,
  })  : baseUrl = baseUrl != null
            ? normalizeBaseUrl(baseUrl)
            : parseHost(host ?? 'http://localhost:11434'),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    final userAgent = platform.platformUserAgent(packageVersion);
    _transport = Transport(TransportConfig(
      client: _client,
      headers: {
        'Accept': 'application/json, application/x-ndjson',
        if (userAgent != null) 'User-Agent': userAgent,
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
        ...?headers,
      },
      timeout: timeout,
      streamIdleTimeout: streamIdleTimeout,
      retryPolicy: retryPolicy,
      interceptors: List.unmodifiable(interceptors),
    ));
  }

  /// A client for a server on this machine (`http://localhost:11434`).
  factory Ollama.local({
    String defaultModel = 'qwen2.5:1.5b',
    http.Client? httpClient,
    int port = 11434,
    Map<String, String>? headers,
    OllamaRetryPolicy retryPolicy = const OllamaRetryPolicy(),
    List<OllamaInterceptor> interceptors = const [],
  }) {
    return Ollama(
      baseUrl: Uri(scheme: 'http', host: 'localhost', port: port),
      defaultModel: defaultModel,
      httpClient: httpClient,
      headers: headers,
      retryPolicy: retryPolicy,
      interceptors: interceptors,
    );
  }

  /// A client for the host machine from an Android emulator (`10.0.2.2`).
  factory Ollama.androidEmulator({
    String defaultModel = 'qwen2.5:1.5b',
    http.Client? httpClient,
    int port = 11434,
  }) {
    return Ollama(
      baseUrl: Uri(scheme: 'http', host: '10.0.2.2', port: port),
      defaultModel: defaultModel,
      httpClient: httpClient,
    );
  }

  /// A client for Ollama cloud (`https://ollama.com`). Create a key at
  /// https://ollama.com/settings/keys.
  factory Ollama.cloud({
    required String apiKey,
    String defaultModel = 'gpt-oss:20b',
    http.Client? httpClient,
    OllamaRetryPolicy retryPolicy = const OllamaRetryPolicy(),
    List<OllamaInterceptor> interceptors = const [],
  }) {
    return Ollama(
      baseUrl: Uri.parse('https://ollama.com/api'),
      apiKey: apiKey,
      defaultModel: defaultModel,
      httpClient: httpClient,
      retryPolicy: retryPolicy,
      interceptors: interceptors,
    );
  }

  /// A client configured from `OLLAMA_HOST` and `OLLAMA_API_KEY`, like the
  /// official CLI and Python/JS libraries. On the web (no environment) the
  /// defaults are used.
  factory Ollama.fromEnvironment({
    String defaultModel = 'qwen2.5:1.5b',
    http.Client? httpClient,
    List<OllamaInterceptor> interceptors = const [],
  }) {
    return Ollama(
      host: platform.readEnvironment('OLLAMA_HOST'),
      apiKey: platform.readEnvironment('OLLAMA_API_KEY'),
      defaultModel: defaultModel,
      httpClient: httpClient,
      interceptors: interceptors,
    );
  }

  /// This package's version, sent in the `User-Agent` header (not on web).
  static const String packageVersion = '1.0.0';

  /// The server URL (without the `/api` suffix unless you supplied it).
  final Uri baseUrl;

  /// Model used when a call does not name one.
  final String defaultModel;

  /// Model used by [embed] and [embedMany] when a call does not name one.
  final String defaultEmbeddingModel;

  /// Options merged into every generation request (per-call options win).
  final Map<String, Object?>? defaultOptions;

  /// `keep_alive` for every generation request unless overridden.
  final Object? defaultKeepAlive;

  final http.Client _client;
  final bool _ownsClient;
  late final Transport _transport;

  /// Whether [close] was called.
  bool get isClosed => _transport.isClosed;

  // ---------------------------------------------------------------------------
  // Generate

  /// One-shot prompt; returns the generated text.
  Future<String> ask(
    String prompt, {
    String? model,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
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
      cancelToken: cancelToken,
    );
    return result.response;
  }

  /// One-shot prompt; streams text deltas.
  Stream<String> askStream(
    String prompt, {
    String? model,
    String? system,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
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
      cancelToken: cancelToken,
    ).textDeltas;
  }

  /// One-shot prompt that returns a JSON object. Pass a JSON [schema] for
  /// structured output; without one, any JSON object is accepted.
  Future<Map<String, Object?>> askJson(
    String prompt, {
    String? model,
    String? system,
    Map<String, Object?>? schema,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
  }) async {
    final text = await ask(
      prompt,
      model: model,
      system: system,
      format: schema ?? 'json',
      think: think,
      keepAlive: keepAlive,
      options: options,
      cancelToken: cancelToken,
    );
    return decodeJsonObject(text);
  }

  /// One-shot prompt decoded into your type with [fromJson].
  ///
  /// ```dart
  /// final city = await ollama.askStructured(
  ///   'Describe Paris.',
  ///   schema: OllamaSchema.object({
  ///     'name': OllamaSchema.string(),
  ///     'population': OllamaSchema.integer(),
  ///   }),
  ///   fromJson: City.fromJson,
  /// );
  /// ```
  ///
  /// If the output cannot be decoded (or [fromJson] throws), the request is
  /// repeated up to [repairAttempts] times.
  Future<T> askStructured<T>(
    String prompt, {
    required Map<String, Object?> schema,
    required T Function(Map<String, Object?> json) fromJson,
    String? model,
    String? system,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    int repairAttempts = 1,
    OllamaCancelToken? cancelToken,
  }) async {
    return chatStructured(
      [
        if (system != null) OllamaMessage.system(system),
        OllamaMessage.user(prompt),
      ],
      schema: schema,
      fromJson: fromJson,
      model: model,
      think: think,
      keepAlive: keepAlive,
      options: options,
      repairAttempts: repairAttempts,
      cancelToken: cancelToken,
    );
  }

  /// `POST /api/generate` (non-streaming).
  Future<OllamaGenerateResponse> generate(
    String prompt, {
    String? model,
    String? suffix,
    String? system,
    String? template,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
    List<int>? context,
    OllamaCancelToken? cancelToken,
  }) async {
    final json = await _transport.json(
      'POST',
      _uri('generate'),
      'generate',
      body: _generateBody(
        prompt,
        stream: false,
        model: model,
        suffix: suffix,
        system: system,
        template: template,
        images: images,
        format: format,
        think: think,
        raw: raw,
        keepAlive: keepAlive,
        options: options,
        logprobs: logprobs,
        topLogprobs: topLogprobs,
        truncate: truncate,
        shift: shift,
        context: context,
      ),
      cancelToken: cancelToken,
    );
    return OllamaGenerateResponse.fromJson(json);
  }

  /// `POST /api/generate` (streaming). The last chunk has `done: true` and
  /// the metrics. Use `.collect()` to merge the chunks.
  Stream<OllamaGenerateResponse> generateStream(
    String prompt, {
    String? model,
    String? suffix,
    String? system,
    String? template,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
    List<int>? context,
    OllamaCancelToken? cancelToken,
  }) {
    return _transport
        .ndjson(
          'POST',
          _uri('generate'),
          'generate',
          body: _generateBody(
            prompt,
            stream: true,
            model: model,
            suffix: suffix,
            system: system,
            template: template,
            images: images,
            format: format,
            think: think,
            raw: raw,
            keepAlive: keepAlive,
            options: options,
            logprobs: logprobs,
            topLogprobs: topLogprobs,
            truncate: truncate,
            shift: shift,
            context: context,
          ),
          cancelToken: cancelToken,
          requireDone: true,
        )
        .map(OllamaGenerateResponse.fromJson);
  }

  // ---------------------------------------------------------------------------
  // Chat

  /// Chat and return only the reply text.
  Future<String> chatText(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
  }) async {
    final result = await chat(
      messages,
      model: model,
      tools: tools,
      format: format,
      think: think,
      keepAlive: keepAlive,
      options: options,
      cancelToken: cancelToken,
    );
    return result.text;
  }

  /// Chat and stream only the reply text deltas.
  Stream<String> chatTextStream(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
  }) {
    return chatStream(
      messages,
      model: model,
      tools: tools,
      format: format,
      think: think,
      keepAlive: keepAlive,
      options: options,
      cancelToken: cancelToken,
    ).textDeltas;
  }

  /// `POST /api/chat` (non-streaming).
  ///
  /// - [tools]: functions the model may call; see [runTools] to execute them
  ///   automatically.
  /// - [format]: `'json'`, a JSON schema map, or [OllamaFormat].
  /// - [think]: `true`/`false`, a level (`'low'`, `'medium'`, `'high'`) or
  ///   [OllamaThink].
  /// - [keepAlive]: a [Duration], seconds, or a string like `'10m'`.
  /// - [options]: a map or [ModelOptions].
  Future<OllamaChatResponse> chat(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
    OllamaCancelToken? cancelToken,
  }) async {
    final json = await _transport.json(
      'POST',
      _uri('chat'),
      'chat',
      body: _chatBody(
        messages,
        stream: false,
        model: model,
        tools: tools,
        format: format,
        think: think,
        keepAlive: keepAlive,
        options: options,
        logprobs: logprobs,
        topLogprobs: topLogprobs,
        truncate: truncate,
        shift: shift,
      ),
      cancelToken: cancelToken,
    );
    return OllamaChatResponse.fromJson(json);
  }

  /// `POST /api/chat` (streaming). Chunks carry content and thinking deltas;
  /// tool calls arrive in a chunk of their own; the final chunk has the
  /// metrics. Use `.collect()`, `.textDeltas` or `.thinkingDeltas`.
  Stream<OllamaChatResponse> chatStream(
    List<OllamaMessage> messages, {
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
    OllamaCancelToken? cancelToken,
  }) {
    return _transport
        .ndjson(
          'POST',
          _uri('chat'),
          'chat',
          body: _chatBody(
            messages,
            stream: true,
            model: model,
            tools: tools,
            format: format,
            think: think,
            keepAlive: keepAlive,
            options: options,
            logprobs: logprobs,
            topLogprobs: topLogprobs,
            truncate: truncate,
            shift: shift,
          ),
          cancelToken: cancelToken,
          requireDone: true,
        )
        .map(OllamaChatResponse.fromJson);
  }

  /// Chat with structured output decoded into your type.
  ///
  /// The schema is sent as `format`. If decoding fails, the model is shown
  /// its output and the error and asked again, up to [repairAttempts] times.
  Future<T> chatStructured<T>(
    List<OllamaMessage> messages, {
    required Map<String, Object?> schema,
    required T Function(Map<String, Object?> json) fromJson,
    String? model,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    int repairAttempts = 1,
    OllamaCancelToken? cancelToken,
  }) async {
    final history = List.of(messages);
    for (var attempt = 0;; attempt++) {
      final response = await chat(
        history,
        model: model,
        format: schema,
        think: think,
        keepAlive: keepAlive,
        options: options,
        cancelToken: cancelToken,
      );
      try {
        return fromJson(decodeJsonObject(response.text));
      } catch (error) {
        if (attempt >= repairAttempts) {
          if (error is OllamaException) rethrow;
          throw OllamaResponseFormatException(
            'Could not convert the model output: $error',
            body: response.text,
            cause: error,
          );
        }
        history
          ..add(OllamaMessage.assistant(response.text))
          ..add(OllamaMessage.user(
            'That output could not be used ($error). Reply again with only '
            'a JSON object that matches the schema.',
          ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tools

  /// Runs a tool-calling loop: chat, execute the requested tools (via each
  /// tool's `handler`), send the results back, and repeat until the model
  /// answers without calling a tool.
  ///
  /// ```dart
  /// final run = await ollama.runTools(
  ///   [const OllamaMessage.user('Weather in Paris?')],
  ///   tools: [weatherTool],
  /// );
  /// print(run.text);
  /// ```
  ///
  /// - [maxIterations]: chat requests allowed before
  ///   [OllamaToolLoopException] is thrown.
  /// - [parallel]: run multiple calls from one turn concurrently.
  /// - [approve]: return `false` to refuse a call (the model is told).
  /// - [rethrowToolErrors]: by default handler errors are reported to the
  ///   model as `Error: ...` so it can recover; set to rethrow instead.
  Future<OllamaToolRun> runTools(
    List<OllamaMessage> messages, {
    required List<OllamaTool> tools,
    String? model,
    Object? think,
    Object? format,
    Object? keepAlive,
    Map<String, Object?>? options,
    int maxIterations = 8,
    bool parallel = true,
    bool rethrowToolErrors = false,
    OllamaToolApproval? approve,
    OllamaToolErrorFormatter? formatToolError,
    void Function(OllamaToolInvocation invocation)? onToolResult,
    OllamaCancelToken? cancelToken,
  }) async {
    OllamaToolRun? run;
    await runToolsStream(
      messages,
      tools: tools,
      model: model,
      think: think,
      format: format,
      keepAlive: keepAlive,
      options: options,
      maxIterations: maxIterations,
      parallel: parallel,
      rethrowToolErrors: rethrowToolErrors,
      approve: approve,
      formatToolError: formatToolError,
      cancelToken: cancelToken,
      stream: false,
    ).forEach((event) {
      if (event is OllamaToolRunCallFinished) {
        onToolResult?.call(event.invocation);
      }
      if (event is OllamaToolRunDone) run = event.run;
    });
    return run!;
  }

  /// Streaming version of [runTools]: emits text and thinking deltas, each
  /// tool call as it starts and finishes, and finally [OllamaToolRunDone].
  Stream<OllamaToolRunEvent> runToolsStream(
    List<OllamaMessage> messages, {
    required List<OllamaTool> tools,
    String? model,
    Object? think,
    Object? format,
    Object? keepAlive,
    Map<String, Object?>? options,
    int maxIterations = 8,
    bool parallel = true,
    bool rethrowToolErrors = false,
    OllamaToolApproval? approve,
    OllamaToolErrorFormatter? formatToolError,
    OllamaCancelToken? cancelToken,
    bool stream = true,
  }) async* {
    final registry = {for (final tool in tools) tool.name: tool};
    final history = List.of(messages);
    final invocations = <OllamaToolInvocation>[];
    for (var iteration = 1; iteration <= maxIterations; iteration++) {
      final OllamaChatResponse response;
      if (stream) {
        final accumulator = OllamaChatAccumulator();
        await for (final chunk in chatStream(
          history,
          model: model,
          tools: tools,
          think: think,
          format: format,
          keepAlive: keepAlive,
          options: options,
          cancelToken: cancelToken,
        )) {
          accumulator.add(chunk);
          if (chunk.thinking?.isNotEmpty ?? false) {
            yield OllamaToolRunThinkingDelta(chunk.thinking!);
          }
          if (chunk.text.isNotEmpty) yield OllamaToolRunTextDelta(chunk.text);
        }
        response = accumulator.response;
      } else {
        response = await chat(
          history,
          model: model,
          tools: tools,
          think: think,
          format: format,
          keepAlive: keepAlive,
          options: options,
          cancelToken: cancelToken,
        );
      }
      final message = response.message ?? const OllamaMessage.assistant('');
      history.add(message);
      if (!message.hasToolCalls) {
        yield OllamaToolRunDone(OllamaToolRun(
          response: response,
          messages: List.unmodifiable(history),
          invocations: List.unmodifiable(invocations),
          iterations: iteration,
        ));
        return;
      }
      final events = StreamController<OllamaToolRunEvent>();
      Object? failure;
      StackTrace? failureStack;
      final execution = executeToolCalls(
        message.toolCalls!,
        registry,
        parallel: parallel,
        rethrowErrors: rethrowToolErrors,
        approve: approve,
        formatError: formatToolError,
        cancelToken: cancelToken,
        onStart: (call) => events.add(OllamaToolRunCallStarted(call)),
        onFinish: (invocation) =>
            events.add(OllamaToolRunCallFinished(invocation)),
      ).then<List<OllamaToolInvocation>>((results) => results,
          onError: (Object error, StackTrace stackTrace) {
        // Held until the events are drained, so it is never unhandled.
        failure = error;
        failureStack = stackTrace;
        return const <OllamaToolInvocation>[];
      }).whenComplete(events.close);
      yield* events.stream;
      final results = await execution;
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      invocations.addAll(results);
      history.addAll(results.map((result) => result.message));
    }
    throw OllamaToolLoopException(
      'The model was still calling tools after $maxIterations requests.',
      messages: List.unmodifiable(history),
    );
  }

  /// Starts a stateful chat that keeps (and trims) its own history.
  OllamaConversation conversation({
    String? model,
    String? system,
    List<OllamaTool> tools = const [],
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    int? maxMessages,
    int? maxChars,
    List<OllamaMessage> history = const [],
  }) {
    return OllamaConversation(
      client: this,
      model: model,
      system: system,
      tools: tools,
      think: think,
      keepAlive: keepAlive,
      options: options,
      maxMessages: maxMessages,
      maxChars: maxChars,
      history: history,
    );
  }

  // ---------------------------------------------------------------------------
  // Embeddings

  /// `POST /api/embed`. [input] is a `String` or a `List<String>`.
  Future<OllamaEmbedResponse> embed(
    Object input, {
    String? model,
    bool? truncate,
    int? dimensions,
    Object? keepAlive,
    Map<String, Object?>? options,
    OllamaCancelToken? cancelToken,
  }) async {
    final json = await _transport.json(
      'POST',
      _uri('embed'),
      'embed',
      body: withoutNulls({
        'model': model ?? defaultEmbeddingModel,
        'input': input,
        'truncate': truncate,
        'dimensions': dimensions,
        'keep_alive': encodeKeepAlive(keepAlive ?? defaultKeepAlive),
        'options': options,
      }),
      cancelToken: cancelToken,
    );
    return OllamaEmbedResponse.fromJson(json);
  }

  /// Embeds one text and returns its vector.
  Future<List<double>> embedText(
    String text, {
    String? model,
    int? dimensions,
    OllamaCancelToken? cancelToken,
  }) async {
    final result = await embed(text,
        model: model, dimensions: dimensions, cancelToken: cancelToken);
    return result.first;
  }

  /// Embeds many texts in batches of [batchSize], running up to
  /// [concurrency] batches at once. Vectors are returned in input order.
  Future<List<List<double>>> embedMany(
    List<String> inputs, {
    String? model,
    int batchSize = 64,
    int concurrency = 1,
    bool? truncate,
    int? dimensions,
    Object? keepAlive,
    void Function(int done, int total)? onProgress,
    OllamaCancelToken? cancelToken,
  }) async {
    if (batchSize < 1) throw ArgumentError.value(batchSize, 'batchSize');
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
    final results = List<List<double>?>.filled(inputs.length, null);
    final batches = <int>[
      for (var start = 0; start < inputs.length; start += batchSize) start,
    ];
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (next < batches.length) {
        final start = batches[next++];
        final end = (start + batchSize).clamp(0, inputs.length);
        final response = await embed(
          inputs.sublist(start, end),
          model: model,
          truncate: truncate,
          dimensions: dimensions,
          keepAlive: keepAlive,
          cancelToken: cancelToken,
        );
        if (response.embeddings.length != end - start) {
          throw OllamaResponseFormatException(
            'Expected ${end - start} embeddings but got '
            '${response.embeddings.length}.',
          );
        }
        for (var i = 0; i < response.embeddings.length; i++) {
          results[start + i] = response.embeddings[i];
        }
        done += end - start;
        onProgress?.call(done, inputs.length);
      }
    }

    final workers = batches.isEmpty ? 0 : concurrency.clamp(1, batches.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return [for (final vector in results) vector!];
  }

  // ---------------------------------------------------------------------------
  // Models

  /// `GET /api/tags`: installed models.
  Future<List<OllamaModel>> models({OllamaCancelToken? cancelToken}) async {
    final json = await _transport.json('GET', _uri('tags'), 'tags',
        cancelToken: cancelToken);
    return asJsonMapList(json['models']).map(OllamaModel.fromJson).toList();
  }

  /// Whether [model] is installed. `llama3` matches `llama3:latest`.
  Future<bool> hasModel(String model, {OllamaCancelToken? cancelToken}) async {
    final available = await models(cancelToken: cancelToken);
    final wanted = normalizeModelName(model);
    return available.any((item) =>
        normalizeModelName(item.name) == wanted ||
        normalizeModelName(item.model) == wanted);
  }

  /// Pulls [model] if it is not installed yet.
  Future<void> ensureModel(
    String model, {
    bool insecure = false,
    void Function(OllamaStatus status)? onProgress,
    OllamaCancelToken? cancelToken,
  }) async {
    if (await hasModel(model, cancelToken: cancelToken)) return;
    await pull(model,
        insecure: insecure, onProgress: onProgress, cancelToken: cancelToken);
  }

  /// `POST /api/show`: details, template, parameters and capabilities.
  Future<OllamaModelInfo> showModel(
    String model, {
    bool verbose = false,
    OllamaCancelToken? cancelToken,
  }) async {
    final json = await _transport.json(
      'POST',
      _uri('show'),
      'show',
      body: {'model': model, if (verbose) 'verbose': true},
      cancelToken: cancelToken,
    );
    return OllamaModelInfo.fromJson(json);
  }

  /// Downloads [model] and completes when it is ready. Progress events go to
  /// [onProgress]. Uses the streaming endpoint, so large downloads are only
  /// subject to the idle timeout.
  Future<void> pull(
    String model, {
    bool insecure = false,
    void Function(OllamaStatus status)? onProgress,
    OllamaCancelToken? cancelToken,
  }) async {
    await pullStream(model, insecure: insecure, cancelToken: cancelToken)
        .forEach((status) => onProgress?.call(status));
  }

  /// `POST /api/pull` with progress events.
  Stream<OllamaStatus> pullStream(
    String model, {
    bool insecure = false,
    OllamaCancelToken? cancelToken,
  }) {
    return _statusStream(
        'pull',
        {
          'model': model,
          if (insecure) 'insecure': true,
          'stream': true,
        },
        cancelToken);
  }

  /// Uploads [model] to a registry (`namespace/model:tag`).
  Future<void> push(
    String model, {
    bool insecure = false,
    void Function(OllamaStatus status)? onProgress,
    OllamaCancelToken? cancelToken,
  }) async {
    await pushStream(model, insecure: insecure, cancelToken: cancelToken)
        .forEach((status) => onProgress?.call(status));
  }

  /// `POST /api/push` with progress events.
  Stream<OllamaStatus> pushStream(
    String model, {
    bool insecure = false,
    OllamaCancelToken? cancelToken,
  }) {
    return _statusStream(
        'push',
        {
          'model': model,
          if (insecure) 'insecure': true,
          'stream': true,
        },
        cancelToken);
  }

  /// Creates a model, e.g. a preset with its own system prompt:
  ///
  /// ```dart
  /// await ollama.createModel('mario', from: 'llama3.2',
  ///     system: 'You are Mario from Super Mario Bros.');
  /// ```
  ///
  /// [files] maps file names to blob digests (see [pushBlob]).
  Future<void> createModel(
    String model, {
    String? from,
    Map<String, String>? files,
    Map<String, String>? adapters,
    String? template,
    Object? license,
    String? system,
    Map<String, Object?>? parameters,
    List<OllamaMessage>? messages,
    String? quantize,
    void Function(OllamaStatus status)? onProgress,
    OllamaCancelToken? cancelToken,
  }) async {
    await createModelStream(
      model,
      from: from,
      files: files,
      adapters: adapters,
      template: template,
      license: license,
      system: system,
      parameters: parameters,
      messages: messages,
      quantize: quantize,
      cancelToken: cancelToken,
    ).forEach((status) => onProgress?.call(status));
  }

  /// `POST /api/create` with progress events.
  Stream<OllamaStatus> createModelStream(
    String model, {
    String? from,
    Map<String, String>? files,
    Map<String, String>? adapters,
    String? template,
    Object? license,
    String? system,
    Map<String, Object?>? parameters,
    List<OllamaMessage>? messages,
    String? quantize,
    OllamaCancelToken? cancelToken,
  }) {
    return _statusStream(
      'create',
      withoutNulls({
        'model': model,
        'from': from,
        'files': files,
        'adapters': adapters,
        'template': template,
        'license': license,
        'system': system,
        'parameters': parameters,
        'messages': messages?.map((message) => message.toJson()).toList(),
        'quantize': quantize,
        'stream': true,
      }),
      cancelToken,
    );
  }

  /// `POST /api/copy`.
  Future<void> copyModel(
    String source,
    String destination, {
    OllamaCancelToken? cancelToken,
  }) async {
    await _transport.raw('POST', _uri('copy'), 'copy',
        body: {'source': source, 'destination': destination},
        cancelToken: cancelToken);
  }

  /// `DELETE /api/delete`.
  Future<void> deleteModel(String model,
      {OllamaCancelToken? cancelToken}) async {
    await _transport.raw('DELETE', _uri('delete'), 'delete',
        body: {'model': model}, cancelToken: cancelToken);
  }

  /// `GET /api/ps`: models currently loaded in memory.
  Future<List<OllamaRunningModel>> runningModels(
      {OllamaCancelToken? cancelToken}) async {
    final json = await _transport.json('GET', _uri('ps'), 'ps',
        cancelToken: cancelToken);
    return asJsonMapList(json['models'])
        .map(OllamaRunningModel.fromJson)
        .toList();
  }

  /// Loads [model] into memory so the first real request is fast.
  Future<void> loadModel(
    String model, {
    Object? keepAlive,
    OllamaCancelToken? cancelToken,
  }) async {
    await _transport.json('POST', _uri('generate'), 'generate',
        body: withoutNulls({
          'model': model,
          'keep_alive': encodeKeepAlive(keepAlive ?? defaultKeepAlive),
          'stream': false,
        }),
        cancelToken: cancelToken);
  }

  /// Unloads [model] from memory now.
  Future<void> unloadModel(String model,
      {OllamaCancelToken? cancelToken}) async {
    await _transport.json('POST', _uri('generate'), 'generate',
        body: {'model': model, 'keep_alive': 0, 'stream': false},
        cancelToken: cancelToken);
  }

  /// `HEAD /api/blobs/:digest`: whether the server has a blob.
  Future<bool> blobExists(String digest,
      {OllamaCancelToken? cancelToken}) async {
    final result = await _transport.raw(
      'HEAD',
      _uri('blobs/$digest'),
      'blobs',
      cancelToken: cancelToken,
      acceptStatus: (status) => status == 404,
    );
    return result.statusCode >= 200 && result.statusCode < 300;
  }

  /// `POST /api/blobs/:digest`: uploads a file for [createModel]. [digest]
  /// is `sha256:<hex>` of [bytes].
  Future<void> pushBlob(
    String digest,
    List<int> bytes, {
    OllamaCancelToken? cancelToken,
  }) async {
    await _transport.raw(
      'POST',
      _uri('blobs/$digest'),
      'blobs',
      bodyBytes: bytes,
      contentType: 'application/octet-stream',
      cancelToken: cancelToken,
      timeout: null,
    );
  }

  /// `GET /api/version`.
  Future<String> version({OllamaCancelToken? cancelToken}) async {
    final json = await _transport.json('GET', _uri('version'), 'version',
        cancelToken: cancelToken);
    return json['version']?.toString() ?? '';
  }

  /// Whether the server answers within [timeout]. Never throws.
  Future<bool> isRunning(
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      await _transport.json('GET', _uri('version'), 'version',
          timeout: timeout, retryPolicy: OllamaRetryPolicy.none);
      return true;
    } on Object {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Cloud

  /// Web search (Ollama cloud, or a signed-in local server). Requires an API
  /// key for ollama.com.
  Future<List<OllamaWebSearchResult>> webSearch(
    String query, {
    int? maxResults,
    OllamaCancelToken? cancelToken,
  }) async {
    final endpoint = _isCloud ? 'web_search' : 'experimental/web_search';
    final json = await _transport.json('POST', _uri(endpoint), endpoint,
        body: {
          'query': query,
          if (maxResults != null) 'max_results': maxResults
        },
        cancelToken: cancelToken);
    return asJsonMapList(json['results'])
        .map(OllamaWebSearchResult.fromJson)
        .toList();
  }

  /// Fetches a web page as text (Ollama cloud, or a signed-in local server).
  Future<OllamaWebFetchResult> webFetch(
    String url, {
    OllamaCancelToken? cancelToken,
  }) async {
    final endpoint = _isCloud ? 'web_fetch' : 'experimental/web_fetch';
    final json = await _transport.json('POST', _uri(endpoint), endpoint,
        body: {'url': url}, cancelToken: cancelToken);
    return OllamaWebFetchResult.fromJson(json);
  }

  /// Ready-made tools that let a model search and read the web (Ollama
  /// cloud). Pass them to [runTools].
  List<OllamaTool> webTools({int maxResults = 5}) => [
        OllamaTool.function(
          name: 'web_search',
          description: 'Search the web for up-to-date information.',
          parameters: OllamaSchema.object({
            'query': OllamaSchema.string(description: 'The search query'),
          }),
          handler: (args) async => [
            for (final hit
                in await webSearch('${args['query']}', maxResults: maxResults))
              {'title': hit.title, 'url': hit.url, 'content': hit.content},
          ],
        ),
        OllamaTool.function(
          name: 'web_fetch',
          description: 'Fetch the text content of a web page.',
          parameters: OllamaSchema.object({
            'url': OllamaSchema.string(description: 'The page URL'),
          }),
          handler: (args) async {
            final page = await webFetch('${args['url']}');
            return {'title': page.title, 'content': page.content};
          },
        ),
      ];

  // ---------------------------------------------------------------------------

  /// Closes the client. In-flight requests and streams fail with
  /// [OllamaCancelledException]; later calls fail the same way. The
  /// `http.Client` is closed only if this client created it.
  void close() {
    if (_transport.isClosed) return;
    _transport.close();
    if (_ownsClient) {
      // Give aborted requests a chance to settle before closing sockets.
      scheduleMicrotask(_client.close);
    }
  }

  bool get _isCloud =>
      baseUrl.host == 'ollama.com' || baseUrl.host == 'www.ollama.com';

  JsonMap _generateBody(
    String prompt, {
    required bool stream,
    String? model,
    String? suffix,
    String? system,
    String? template,
    List<String>? images,
    Object? format,
    Object? think,
    bool raw = false,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
    List<int>? context,
  }) {
    return withoutNulls({
      'model': model ?? defaultModel,
      'prompt': prompt,
      'suffix': suffix,
      'system': system,
      'template': template,
      'images': images?.map(OllamaImage.normalize).toList(),
      'format': OllamaFormat.encode(format),
      'think': OllamaThink.encode(think),
      'raw': raw ? true : null,
      'keep_alive': encodeKeepAlive(keepAlive ?? defaultKeepAlive),
      'options': _options(options),
      'stream': stream,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
      'truncate': truncate,
      'shift': shift,
      'context': context,
    });
  }

  JsonMap _chatBody(
    List<OllamaMessage> messages, {
    required bool stream,
    String? model,
    List<OllamaTool>? tools,
    Object? format,
    Object? think,
    Object? keepAlive,
    Map<String, Object?>? options,
    bool logprobs = false,
    int? topLogprobs,
    bool? truncate,
    bool? shift,
  }) {
    return withoutNulls({
      'model': model ?? defaultModel,
      'messages': messages.map((message) => message.toJson()).toList(),
      'tools': tools == null || tools.isEmpty
          ? null
          : tools.map((tool) => tool.toJson()).toList(),
      'format': OllamaFormat.encode(format),
      'think': OllamaThink.encode(think),
      'keep_alive': encodeKeepAlive(keepAlive ?? defaultKeepAlive),
      'options': _options(options),
      'stream': stream,
      'logprobs': logprobs ? true : null,
      'top_logprobs': topLogprobs,
      'truncate': truncate,
      'shift': shift,
    });
  }

  Map<String, Object?>? _options(Map<String, Object?>? options) {
    final defaults = defaultOptions;
    if (defaults == null || defaults.isEmpty) {
      return options == null || options.isEmpty ? null : Map.of(options);
    }
    return {...defaults, ...?options};
  }

  Stream<OllamaStatus> _statusStream(
    String endpoint,
    JsonMap body,
    OllamaCancelToken? cancelToken,
  ) {
    return _transport
        .ndjson('POST', _uri(endpoint), endpoint,
            body: body, cancelToken: cancelToken)
        .map(OllamaStatus.fromJson);
  }

  Uri _uri(String endpoint) {
    final existing = baseUrl.pathSegments.where((part) => part.isNotEmpty);
    final hasApiSegment = existing.isNotEmpty && existing.last == 'api';
    return baseUrl.replace(pathSegments: [
      ...existing,
      if (!hasApiSegment) 'api',
      ...endpoint.split('/'),
    ]);
  }

  /// Parses an `OLLAMA_HOST`-style value into a base URL, using the same
  /// rules as the official clients:
  ///
  /// - no scheme → `http`, default port 11434 (`localhost` →
  ///   `http://localhost:11434`)
  /// - an explicit scheme keeps its standard port (`https://example.com`)
  /// - `0.0.0.0` / `::` (bind-all addresses) → `127.0.0.1` / `::1`
  /// - paths are kept for reverse proxies; trailing slashes are removed
  static Uri parseHost(String host) {
    var value = host.trim();
    if (value.isEmpty) value = 'http://localhost:11434';
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
    var uri = Uri.parse(hasScheme ? value : 'http://$value');
    if (!hasScheme && !uri.hasPort) uri = uri.replace(port: 11434);
    return normalizeBaseUrl(uri);
  }

  /// Fixes common base URL mistakes: a missing scheme (`localhost:11434`
  /// parses as scheme `localhost`), bind-all hosts, trailing slashes.
  static Uri normalizeBaseUrl(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      // e.g. Uri.parse('localhost:11434') has the scheme "localhost".
      final text = uri.toString();
      if (text.contains('://')) {
        throw ArgumentError.value(uri, 'baseUrl', 'Use an http or https URL');
      }
      return parseHost(text);
    }
    var host = uri.host;
    if (host == '0.0.0.0') host = '127.0.0.1';
    if (host == '::') host = '::1';
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    return uri.replace(host: host, pathSegments: segments).removeFragment();
  }

  /// `llama3` → `llama3:latest`; names with a tag are unchanged.
  static String normalizeModelName(String name) {
    final trimmed = name.trim();
    final slash = trimmed.lastIndexOf('/');
    final last = trimmed.substring(slash + 1);
    return last.contains(':') ? trimmed : '$trimmed:latest';
  }
}
