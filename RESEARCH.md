# Research: what the best Ollama client should have

November 2026. Written before the 1.0.0 rewrite. It compares the Ollama
REST API (server v0.40.16) with the leading clients, then lists what
`ollama_easy` does about each gap.

## Sources

- The Ollama Go source, which is the real schema; the OpenAPI spec leaves
  fields out:
  - [`api/types.go`](https://github.com/ollama/ollama/blob/main/api/types.go)
  - [`server/routes.go`](https://github.com/ollama/ollama/blob/main/server/routes.go)
- Official docs: [docs.ollama.com/api](https://docs.ollama.com/api),
  [`openapi.yaml`](https://docs.ollama.com/openapi.yaml), and the legacy
  [`docs/api.md`](https://github.com/ollama/ollama/blob/main/docs/api.md).
  Also the pages on errors, authentication, thinking, web search, OpenAI
  compatibility and the Modelfile.
- pub.dev clients: [`ollama_dart`](https://pub.dev/packages/ollama_dart) 5.0.0,
  [`ollama`](https://pub.dev/packages/ollama) 1.0.4,
  [`langchain_ollama`](https://pub.dev/packages/langchain_ollama) 0.5.0.
- Clients in other languages:
  [`ollama-python`](https://github.com/ollama/ollama-python) and
  [`ollama-js`](https://github.com/ollama/ollama-js).

## The API today

| Area | Endpoints and fields worth supporting |
|---|---|
| Generation | `POST /api/generate`, `POST /api/chat`. Request fields: `format` (`"json"` or a JSON schema), `think` (bool or a level string), `tools`, `images`, `options`, `keep_alive` (duration string or seconds; `0` unloads, `-1` keeps forever), `logprobs`/`top_logprobs`, `truncate`, `shift`, `suffix`, `raw`, `template` |
| Responses | `message.thinking`, `message.tool_calls[{id?, function{index, name, arguments}}]`, a tool-result message with `tool_name` (and `tool_call_id`), `done_reason` (an open set: `stop`, `length`, `load`, `unload`, …), metrics in nanoseconds including `prompt_eval_cached_count`, `remote_model`/`remote_host` for cloud models |
| Embeddings | `POST /api/embed`: `input` is a string or a list; also `truncate`, `dimensions`. The old `/api/embeddings` is legacy |
| Models | `tags`, `show` (`capabilities`, `model_info`, `thinking.values`), `create` (`from`, `files`, `system`, `parameters`, `messages`, `quantize`), `copy`, `DELETE delete`, `pull`/`push` with progress, `ps` (`size_vram`, `expires_at`, `context_length`), `HEAD`/`POST` `blobs/:digest`, `version` |
| Cloud | `https://ollama.com/api` with `Authorization: Bearer <OLLAMA_API_KEY>`. `web_search` and `web_fetch` are on the cloud; a local server proxies them at `/api/experimental/*` |
| Errors | The body is `{"error": "..."}`. 400 bad input, 401/403 auth, 404 model not found, 429 rate limit, 5xx. **Once a stream has started, the status stays 200 and the error arrives as one last NDJSON line**, so a client must check every line |
| Options | `num_ctx`, `num_predict`, `temperature`, `top_k`, `top_p`, `min_p`, `seed`, `stop`, the repeat/presence/frequency penalties, the `num_gpu`/`num_thread`/`num_batch` runner keys, `draft_num_predict`. Removed: mirostat, `tfs_z`, `penalize_newline`, … The server accepts unknown keys |

## How the clients compare

| Feature | ollama_easy 0.2 | ollama_dart 5 | ollama (pub) | ollama-python | ollama-js | **ollama_easy 1.0** |
|---|---|---|---|---|---|---|
| Chat/generate streaming | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Mid-stream error lines raise an error | ❌ (silently passed on as chunks) | ✅ | ? | ✅ | ? | ✅ typed |
| Tool definitions | ✅ | ✅ | ❌ | ✅ (auto schema) | ✅ | ✅ + schema builder |
| **Tool loop that runs your functions** | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ (`runTools`, `runToolsStream`) |
| Structured output | `askJson` | ✅ | ❌ | ✅ (Pydantic) | ✅ | ✅ typed decode + repair retry |
| Thinking levels | untyped | ✅ | ❌ | ✅ | ✅ | ✅ `OllamaThink` |
| Per-request cancel | ❌ | partial | ❌ | ❌ | ❌ (`abort()` aborts every stream) | ✅ tokens + unsubscribe |
| Retries / backoff | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ (honours `Retry-After`) |
| Timeouts | ❌ | ? | ❌ | via httpx | ❌ | ✅ total + stream idle |
| Interceptors / logging | ❌ | ? | ❌ | ❌ | custom fetch | ✅ (log interceptor redacts secrets) |
| Typed options | ❌ | ✅ | partial | ✅ | stale keys | ✅ `ModelOptions` (is a `Map`) |
| Model management with progress | partial | partial | ❌ | ✅ | ✅ | ✅ (pull/push/create, ps, show, blobs) |
| Conversation helper | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ turn-safe trimming |
| Stream accumulator | ❌ | ? | ❌ | ❌ | ❌ | ✅ `.collect()` |
| Web search/fetch | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ + ready-made tools |
| `OLLAMA_HOST` / `OLLAMA_API_KEY` | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ (same parsing rules) |
| Web platform, true streaming | ⚠️ (`http ^1.2` allowed buffered XHR) | ✅ | ? | n/a | ✅ | ✅ (fetch; tested in Chrome on real sockets) |
| Unknown fields preserved | `raw` only | ? | ❌ | ✅ | ❌ | ✅ `raw` + `extra`, forward-compatible enums |

## Gaps closed in 1.0.0

1. **Correctness first.** Error lines in a stream raise a typed error. A
   stream that ends without `done` is detected. UTF-8 is always decoded as
   UTF-8. Nested `null`s in schemas and tool arguments are kept. Aborts
   really close the socket.
2. **An agent loop no other client has.** `runTools` runs the tool calls in
   parallel. It reports handler errors to the model so it can recover, can
   ask you to approve each call, stops after a set number of iterations, and
   has a streaming variant with events for UI.
3. **Control.** Cancel tokens, cancel by unsubscribing, `close()`,
   timeouts, retries, interceptors, and a pluggable `http.Client`.
4. **Ergonomics.** `OllamaConversation`, `ModelOptions`, `OllamaSchema`,
   `askStructured<T>`, `embedMany`, `ensureModel` with progress, and
   capability checks (`supportsTools`, `thinkingValues`, `contextLength`).

## Planned for later

- An **OpenAI-compatible client** (`/v1/chat/completions`, `/v1/responses`)
  for LM Studio, vLLM and llama.cpp. It was left out of 1.0 because the
  native API is richer and better tested.
- **`createFromFile`**: hash a file, upload the blob, then call create. This
  needs a SHA-256 implementation, and pulling in `crypto` was not worth it
  for one helper.
- **Multimodal embedding input** (`{text, image, audio}` items) once the
  server documents it properly.
- **Cloud account endpoints** (`/api/me`, `/api/usage`, `/api/balance`) and
  the speech and transcription endpoints, once they stabilise.
- **Image-generation fields** (`width`, `height`, `steps`). Today's server
  rejects them, but the client can send them through `options` or an
  interceptor.
- **Schema generation from annotated Dart classes** (`build_runner`), like
  Pydantic in Python.
