## 1.0.0

A rewrite for correctness, control and the current Ollama API (v0.40). It is
source compatible with 0.2; behaviour changes are listed under *Migrating*
in the README.

### Fixed
- `{"error": ...}` lines in a stream (after a crash, out of memory, or a
  failed pull) were silently passed on as empty chunks. They now throw
  `OllamaStreamException`.
- A stream cut off before its final `done` chunk (by a proxy, for example)
  went unnoticed. It is now reported.
- JSON responses whose `Content-Type` has no charset could be decoded as
  latin1. Responses are now always decoded as UTF-8.
- Nested `null`s were stripped from requests, which corrupted JSON schemas
  (`"default": null`, nullable types) and tool arguments.
- `hasModel('llama3')` / `ensureModel` missed `llama3:latest` and pulled
  again.
- There was no way to send `tool_name` with a tool result, so models could
  not match results to their calls.
- `Uri.parse('localhost:11434')` was treated as a URL with the scheme
  "localhost". Hosts without a scheme are now normalised, and `0.0.0.0`
  maps to loopback.
- Requests had no timeouts and could hang forever; `isRunning()` could hang
  on an unreachable host.
- Streams could not be aborted: closing the client or cancelling a
  subscription left the generation running.
- Requests never completed inside FakeAsync zones (Flutter widget tests),
  because a root-zone cancel future was awaited.
- The `http` constraint allowed versions that buffer streams on the web and
  cannot abort requests. It now requires `^1.5.0`.
- `flutter_test` was a dev dependency of a pure Dart package, so plain
  `dart test` failed.
- `pull()` used the non-streaming endpoint, so large downloads were bounded
  by a single request.

### Added
- **Tool loop:** `runTools` / `runToolsStream`, with `OllamaTool.handler`,
  parallel calls, approvals, error recovery, an iteration limit and typed
  events.
- **Structured outputs:** `askStructured<T>` / `chatStructured<T>` with a
  repair retry, the `OllamaSchema` builder, and lenient `decodeJsonObject`.
- **Cancellation:** `OllamaCancelToken` (`any`, `after`). Cancelling a
  subscription aborts the request, and `close()` aborts everything in
  flight.
- **Typed exceptions:** bad request, authentication, not found, rate limit
  (with `retryAfter`), server, connection, timeout, cancelled, stream and
  response format.
- `OllamaRetryPolicy` (exponential backoff with jitter, honours
  `Retry-After`), plus `timeout` and `streamIdleTimeout`.
- Interceptors, `OllamaCallbackInterceptor`, and an `OllamaLogInterceptor`
  that redacts secrets.
- `ModelOptions` (a typed `Map` with `extra`), plus `OllamaThink`,
  `OllamaFormat`, `OllamaDoneReason` and `OllamaCapability`; `keepAlive`
  accepts a `Duration`.
- `OllamaConversation`: history, turn-safe trimming, streaming, automatic
  tools, and JSON save/restore.
- `OllamaChatAccumulator`, `.collect()`, `.textDeltas` and
  `.thinkingDeltas`; metrics getters `tokensPerSecond` and
  `promptEvalCachedCount`; typed logprobs.
- **Model management:** `showModel` (capabilities, context length,
  thinking values, parameters), `createModel` / `push` (with progress
  streams), `copyModel`, `deleteModel`, `runningModels`,
  `loadModel` / `unloadModel`, `blobExists` / `pushBlob`, and `onProgress`
  for `pull` / `ensureModel`.
- `embedMany` (batching, concurrency, order preserved), `embedText` and
  `cosineSimilarity`.
- `webSearch`, `webFetch` and `webTools()` (Ollama cloud, or a signed-in
  local server).
- `Ollama.fromEnvironment` (`OLLAMA_HOST`, `OLLAMA_API_KEY`),
  `Ollama.androidEmulator`, `host:`, `Ollama.parseHost`, and
  `defaultOptions` / `defaultKeepAlive`.
- Generate: `template`, `truncate`, `shift` and `context`. Chat:
  `truncate` and `shift`. Messages: `toolName`, `toolCallId`, `extra`.
  Tool calls: `id` and `index`. Images are normalised (data URLs are
  accepted).
- Forward compatibility: unknown message fields and roles round-trip, and
  `raw` is kept on every model class.
- An interactive CLI (`dart pub global activate ollama_easy`), a CLI tour
  example, and a Flutter chat example with screenshots.
- 106 unit tests (a mock server, real sockets on the VM and in Chrome (fetch),
  FakeAsync), 7 gated integration tests and 4 Flutter widget tests.

## 0.2.0

- Added multi-platform support (Android, iOS, Windows, macOS, Linux, Web).
- Updated default model to `qwen2.5:1.5b` for better local performance.
- Added a full Flutter Chat UI in the example project.
- Added a CLI tool in `bin/ollama_easy.dart` for terminal testing.
- Added built-in support for Android Emulator IP (`10.0.2.2`).
- Added server connection status checks.
- Improved README documentation.

## 0.1.0

- Initial release.
- Add one-line prompt generation with `ask()` and `askStream()`.
- Add typed chat helpers, structured JSON helper, embeddings, model listing, pull progress, version checks, and local/cloud constructors.
