# Sate — Lean iOS AI Client over Cloudflare AI Gateway: Architecture & Requirements

## Context

Build a native iOS AI assistant that is deliberately a **dumb terminal**: no LLM SDKs, no
provider-specific code, no backend of our own. Every model call goes to **Cloudflare AI
Gateway**, which owns provider keys (BYOK), routing, fallbacks, retries, rate limits, spend
limits, caching and logs. The app owns only what a broker physically cannot: the HTTP
request, SSE framing, the conversation history, on-device persistence, and rendering.

Design inspiration is the Pi agent harness (`badlogic/pi-mono`): a minimal harness whose
value comes from *not* dictating workflow, append-only JSONL sessions with an
`id`/`parentId` tree, a normalized stream-event vocabulary, partial-message preservation on
abort, and per-message usage/cost.

Repo `/Users/dhison/dev/projects/sate` is empty; this document is the founding spec.
First implementation task copies it to `docs/superpowers/specs/2026-08-25-sate-design.md`.

### Decisions locked with the operator

| Decision | Choice | Consequence |
|---|---|---|
| Tenancy | Personal / single operator | One Cloudflare token, entered at first launch, Keychain-only. No Access, no Worker. |
| Wire schema | OpenAI chat-completions | One codec serves both the REST endpoint and `dynamic/*` routes. |
| Agent scope v1 | Chat only, tool-ready parser | No tool loop; `StreamEvent` still models tool-call deltas and stop reasons. |
| Platform | iOS 26+, Swift 6 strict concurrency, SwiftUI | `@Observable`, Swift Testing, full `Sendable` checking. |
| Modality v1 | Text only | Content is still an array of parts so images slot in later. |

### Verified Cloudflare facts the design depends on (Aug 2026)

- **Universal REST API** (GA 2026-05-21): `POST https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1/chat/completions`, `Authorization: Bearer <CF API token>` (token needs *Account › Workers AI › Read*), model = `provider/model` (e.g. `anthropic/claude-opus-5`, `openai/gpt-5.2`), `stream: true` supported, optional `cf-aig-gateway-id` header (defaults to gateway `default`). Also `/ai/v1/messages` (Anthropic schema) and `/ai/v1/responses` — not used.
- **Legacy compat endpoint**: `POST https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/compat/chat/completions`, `cf-aig-authorization: Bearer <token>`. Docs mark it *deprecated for single-model calls* but it is **the only entry point for `dynamic/{route}`** (percentage / conditional / rate-limit / budget / model / fallback nodes).
- **BYOK**: provider keys stored in Cloudflare Secrets Store; client must *omit* provider auth headers. Requires an authenticated gateway. Credential precedence: key on request → BYOK `default` alias → Unified Billing.
- **Blast radius**: any token with *AI Gateway Run* can call **every** gateway in the account (cannot be scoped per gateway). Mitigate with spend limits + a dedicated account/gateway for this app.
- **Caching** (`cf-aig-cache-ttl` 60s–30d, `cf-aig-skip-cache`, `cf-aig-cache-key`, result in `cf-aig-cache-status: HIT|MISS`) applies **only to non-streaming text/image responses** — i.e. not to the chat stream.
- **Request handling headers**: `cf-aig-request-timeout` (ms), `cf-aig-max-attempts` (≤5), `cf-aig-retry-delay` (ms, ≤5000), `cf-aig-backoff` (`constant|linear|exponential`).
- **Rate limiting & spend limits** → `429 Too Many Requests`; spend limits can split budgets per `cf-aig-metadata` key; dynamic routes can fall back instead of 429.
- **Metadata**: `cf-aig-metadata` = JSON string, ≤5 keys, string/number/bool only; `cf.*` reserved.
- **Response headers worth surfacing**: `cf-aig-log-id`, `cf-aig-cache-status`, `cf-aig-step` (fallback index), `cf-ray`.
- Frontier-model REST rate limits: ~20 req/min (default) / ~50 req/min (prepaid credits).

---

## First-principles analysis: what a broker-dependent thin client buys and costs on mobile

### What genuinely moves to the broker
Provider auth, provider API drift (Cloudflare's translation absorbs schema churn), model/provider switching (a string or a dashboard edit — no app release), fallbacks, pre-first-byte retries, rate & spend enforcement, request logging/analytics, response caching for *non-stream* calls.

### The irreducible client (what cannot be pushed to Cloudflare)
1. **Conversation state.** Chat-completions is stateless; the gateway stores logs, not conversations. The client is the database.
2. **Context-window policy.** The gateway forwards whatever you send. Trimming/compaction is a client decision.
3. **Stream framing & decoding.** SSE bytes → events → UI.
4. **Lifecycle.** iOS suspends the process; nobody else can save the partial answer.
5. **Rendering** (markdown, scroll, accessibility) and **secret storage**.
Everything else is either Cloudflare's job or YAGNI. Pi's lesson: keep each of these five small and separately testable rather than eliminating them.

### Trade-offs accepted
| Benefit | Cost we accept | Mitigation |
|---|---|---|
| Zero SDK weight & supply chain | Lowest-common-denominator schema: reasoning/thinking, `cache_control`, provider extras are non-standard or lost | Codec tolerates `reasoning_content`/`reasoning` fields; unknown response fields ignored; unknown request extras passthrough via an `extra` dictionary |
| Provider keys never on device | The one CF token is account-wide | Keychain-only, dedicated account/gateway, hard spend limit, token rotation UX |
| Routing/fallback in dashboard | Single point of failure; no direct-to-provider path by design | Accepted for personal use; clear "gateway unreachable" UX |
| Gateway retries/timeouts | Only help **before first byte**; mid-stream failures are the client's problem; caching is irrelevant to the main stream | Client owns partial-preservation + resume UX; use gateway cache only for auxiliary non-stream calls (title generation) |
| Dynamic routes for A/B & budget fallback | Only reachable via the deprecated compat endpoint (different host + auth header) | `EndpointMode` enum with two URL/header builders behind one codec |
| Extra hop | +tens of ms; negligible vs. model latency | — |

### Mobile-specific realities that drive requirements
- **Backgrounding kills streams.** Foreground URLSession tasks survive only for the `beginBackgroundTask` grace (~30 s); background `URLSession` cannot stream to memory. → Partial preservation and "interrupted" state are first-class, not error paths.
- **Network path changes** (Wi‑Fi↔cellular, VPN toggles) drop TCP mid-stream; HTTP/3 migration helps only sometimes. → Distinguish "nothing received" (safe single retry) from "partially received" (never auto-retry: duplicate cost, duplicate text).
- **Silence ≠ failure.** Reasoning models can emit nothing for 60–120 s before the first token; `timeoutIntervalForRequest` is an *inter-byte idle* timeout. → Generous idle timeout + a UI "thinking…" state driven by elapsed time, and an explicit `cf-aig-request-timeout` so the gateway, not the socket, is the authority.
- **Main-thread budget.** 100–300 deltas/s × naive `String +=` on an `@Observable` property × SwiftUI invalidation = dropped frames. → Coalesce on the stream actor; flush ≤ display refresh; isolate the in-flight view.
- **Radio/battery.** SSE holds the radio awake; acceptable for a foreground chat app; no background polling of any kind.

---

## Architecture

```
┌──────────────────────────── App target (SwiftUI) ────────────────────────────┐
│ ConversationListView · ChatView · StreamingMessageView · SettingsView        │
│ ChatViewModel (@MainActor @Observable) — coalesces deltas, owns draft state  │
└───────────────┬──────────────────────────────────────────────────────────────┘
                │ AsyncThrowingStream<StreamEvent>
┌───────────────▼──────────── SateCore (local SwiftPM package) ─────────────────┐
│ GatewayClient      — EndpointMode (rest | compatDynamic), URL+headers, HTTP  │
│                      status → GatewayError mapping, cf-aig-* echo            │
│ ChatCompletionsCodec — Encodable request; SSE `data:` JSON → StreamEvent     │
│ SSEClient          — URLSession.bytes → spec-correct SSE framing (bytes)     │
│ ContextBuilder     — history + system prompt → messages[], trimming policy   │
│ SessionStore       — JSONL tree per conversation, inflight checkpoint        │
│ SecretStore        — Keychain wrapper (token only)                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

Layer rules: `SSEClient` knows nothing about JSON; `ChatCompletionsCodec` knows nothing about URLs; `GatewayClient` is the only place that knows Cloudflare exists; `ChatViewModel` is the only `@MainActor` type in the chain; `SateCore` has zero UI imports and is fully testable with a `URLProtocol` stub.

### Core types (names are binding for the plan; shapes are indicative)

```swift
enum StreamEvent: Sendable {
  case started(responseID: String?, model: String?)
  case textDelta(String)
  case reasoningDelta(String)                        // reasoning_content / reasoning if present
  case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
  case finished(reason: FinishReason, usage: Usage?) // stop | length | toolCalls | contentFilter | unknown(String)
}

enum GatewayError: Error, Sendable {
  case offline, connectionLost(bytesReceived: Int), idleTimeout(bytesReceived: Int), cancelled
  case unauthorized            // 401/403 – token
  case notFound(String)        // 404 – account/gateway/model
  case badRequest(String)      // 400 – schema / context length
  case rateLimited(retryAfter: TimeInterval?)   // 429 (rate or spend limit)
  case upstream(status: Int, body: String)      // 5xx / 502 / 504 / 524
  case protocolError(String)   // malformed SSE/JSON, missing [DONE]
  case inStreamError(code: String?, message: String) // {"error":{...}} inside the stream
}

struct SessionEntry: Codable { id: UUID; parentID: UUID?; timestamp; kind: .user | .assistant | .system | .meta;
                               content: [ContentPart]; stopReason?; usage?; model?; interrupted: Bool; logID? }
```

---

## Requirements

### R1 — Networking (GatewayClient / SSEClient)

1. **Single `URLSession`** (`.default` config, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, `waitsForConnectivity = true`, `timeoutIntervalForRequest = 120 s` (idle), `timeoutIntervalForResource = 900 s`). HTTP/2 or HTTP/3 negotiated automatically. Note `timeoutIntervalForResource` **includes** the `waitsForConnectivity` wait, so the client enforces its own 10 s connectivity budget. If a delegate is used for `URLSessionTaskMetrics` (protocol, TTFB for the debug panel) it must be `Sendable`-safe and the session must `invalidateAndCancel()` on teardown (sessions retain delegates).
2. **Route config, not a mode flag: one codec, two `GatewayRoute`s.** `GatewayRoute { baseURL, authHeaderName, requiredTokenScope, supportsDynamic }`:
   - `rest(accountID, gatewayID?)` → `api.cloudflare.com/client/v4/accounts/{id}/ai/v1/chat/completions`, `Authorization: Bearer`, optional `cf-aig-gateway-id`; token scope *Account › Workers AI › Read*.
   - `compat(accountID, gatewayID)` → `gateway.ai.cloudflare.com/v1/{id}/{gw}/compat/chat/completions`, `cf-aig-authorization: Bearer`; token scope *AI Gateway › Run*.
   Route is chosen per request from the model string: `dynamic/*` ⇒ compat, else rest. The **single operator token must carry both scopes**; an AI-Gateway-only token gets `401` (error code 10000) on REST — 401 UX must say "token lacks scope or is invalid", not "expired". Never send a provider `Authorization`/`x-api-key` (BYOK supplies it; sending one breaks unified billing).
3. **Request body**: `model`, `messages`, `stream: true`, `stream_options: {include_usage: true}` (**per-model toggle** — some compat providers 400 on it), **always `max_tokens`** (client cancel may not propagate upstream; `max_tokens` bounds the worst-case bill), optional `temperature`, plus an opaque `extra: [String: JSONValue]` merged at top level for provider passthrough. Headers: `Accept: text/event-stream`, `Content-Type: application/json`, **`Accept-Encoding: identity`** (URLSession's default gzip/br decoders buffer and delay token delivery).
4. **Gateway control headers on every request**: `cf-aig-request-timeout: 180000` — this is **time-to-first-byte only**; once the first chunk arrives the gateway waits indefinitely, so the client's idle timeout is the sole mid-stream guard. `cf-aig-max-attempts: 2`, `cf-aig-retry-delay: 1000`, `cf-aig-backoff: exponential` — gateway retries help only before first byte. `cf-aig-metadata`: `{app:"sate", conversation:<id>, device:<hashed idfv>, build:<n>}` (≤5 keys). Optional `cf-aig-collect-log-payload: false` (settings) to keep prompts out of gateway logs.
5. **Status & Content-Type before stream**: call `session.bytes(for:)`; inspect `HTTPURLResponse.statusCode` and `Content-Type` before iterating. Non-2xx → read body (cap 64 KiB; may be `text/html` for edge 52x — never hand HTML to `JSONDecoder`) → `GatewayError`. `2xx` + `application/json` → the model doesn't stream: parse the whole body as a single completion and emit one `textDelta` + `finished`. `2xx` + `text/event-stream` → SSE path.
6. **SSE framing on raw bytes** (do not rely on `AsyncBytes.lines` blank-line semantics; framing parser is a **nonisolated value type owned by the streaming `Task`** — feeding an actor byte-by-byte is a per-byte hop): accumulate `UInt8`, line terminators are `\n`, `\r\n`, **or lone `\r`**; dispatch on empty line; strip exactly one leading space after `data:`; concatenate multiple `data:` lines with `\n`; `data:` with empty value is valid; ignore `:` comments (keepalives), `id:`, `retry:`; honor `event:` if present; strip a UTF‑8 BOM at stream start only; decode UTF‑8 per assembled event (never mid-chunk); an unterminated final event at EOF is **discarded** per spec (logged); hard cap of 1 MiB per event buffer → `protocolError`.
7. **Decoding** happens off the main actor; each `data:` payload → `JSONDecoder` → zero or more `StreamEvent`s. **Completeness is keyed on `finish_reason`, not `[DONE]`**: `finish_reason` present ⇒ complete even if `[DONE]` never arrives; EOF without `finish_reason` ⇒ `finished(.unknown("truncated"))` + "may be incomplete" flag. `data: [DONE]` (tolerate trailing whitespace) just ends iteration. A payload with top-level `error` → `inStreamError`, stream terminates. The `stream_options.include_usage` final chunk has **empty `choices`** and only `usage` — valid, never index `choices[0]` blindly. `delta` may be `{}` or `content: null`. Unknown `delta` keys ignored; `reasoning_content`/`reasoning` → `reasoningDelta`. Tool-call fragments **join on `tool_calls[i].index`** (not array position; `id`/`function.name` only in the first fragment; parallel calls interleave; missing `index` ⇒ 0).
8. **Cancellation** is cooperative: `Task.cancel()` → `withTaskCancellationHandler` / `AsyncThrowingStream.onTermination` → `URLSessionTask.cancel()`. No orphaned sockets when a view disappears (a dismissed view that keeps generating is a **cost bug**). Cancellation surfaces as **both** `CancellationError` (before headers) and `URLError.cancelled` (after) — both map to `.cancelled`, not an error. Single terminal path (`finished` *or* thrown error); the producer never `yield`s after `finish` and coalesces on the producer side so the `.unbounded` buffer cannot grow.
9. **Retry policy (client)**: at most one automatic retry, only when `bytesReceived == 0` and error ∈ {offline-then-online, connectionLost, idleTimeout, upstream 502/503}; 1 s jittered delay. Retries are **not idempotent** (the provider may have accepted the request before the gateway 502'd) — hence the hard cap of one. **Never** auto-retry `524` (edge TTFB timeout: the upstream request likely completed and was billed), `504`, or `429` (spend-limit 429 is not transient); show `retryAfter` countdown when the header exists. Any generation that has produced ≥1 delta is never retried.
10. **Auxiliary non-stream call** (`complete(request) async throws -> ChatCompletion`) for conversation titles; sends `cf-aig-cache-ttl: 86400`; uses a cheap model string from settings.
11. **Echo gateway headers** (`cf-aig-log-id`, `cf-aig-cache-status`, `cf-aig-step`, `cf-ray`, status, TTFB, bytes, duration) into a per-message `NetworkTrace` stored with the assistant entry for the debug panel.
12. **No certificate pinning, no custom ATS exceptions, no proxies** (YAGNI; Cloudflare TLS is sufficient for a personal client).

### R2 — Streaming pipeline & state (ContextBuilder / SessionStore / ChatViewModel)

1. **Source of truth = JSONL tree per conversation** in `Application Support/Sate/Conversations/<uuid>.jsonl`, file protection `.completeUntilFirstUserAuthentication` (**not** `.complete` — appends after device lock would fail with `EACCES` mid-stream), included in iCloud backup deliberately. First line is a `header` entry (`version`, title, created, model). Every later line is a `SessionEntry` with `id`/`parentID` and a discriminated `type`; **unknown `type`s and unknown keys are skipped, never fatal** (additive-only schema; `Codable` enums carry an `unknown` case so future files don't brick old builds).
2. **Branching**: edit-and-resend or regenerate appends a new entry whose `parentID` is the edited message's parent (siblings). The **current leaf** is an appended `{"type":"leaf","id":…}` entry — last-leaf-wins on load — so the file remains the single writer/single source of truth. Load builds a `parent → children` map, not just the leaf path, so the UI can show "n/m" sibling navigation at each fork; "delete" a branch = switch leaf (append-only, no physical removal).
3. **Write discipline**: appends are single `write(2)` calls of `json + "\n"`; commits (not checkpoints) are followed by `fcntl(fd, F_FULLFSYNC)` (`FileHandle.synchronize()` is not durable on APFS). On open, a trailing partial line (crash) is discarded and the file truncated to the last valid newline before appending. Assistant entries are appended **once** — on completion, cancel, error, or background expiry — with `interrupted: true` when not `finish_reason: stop`. Reasoning text is stored in its own field and **never resent** in history (backends reject/ignore it and it inflates token estimates).
4. **In-flight checkpoint**: while streaming, the draft is written to `<uuid>.inflight` via temp+rename (atomic) at most every 2 s, and deleted **in the same actor turn** as the final commit (otherwise recovery duplicates the message). On next launch, a surviving `.inflight` becomes an `interrupted` assistant entry so nothing the user paid for is lost.
5. **Per-conversation write serialization**: `SessionStore` is an `actor` keyed by file URL; all appends, checkpoints and leaf switches for one conversation go through it. **Fork-mid-stream** (editing an earlier message while streaming) is an ordered sequence: cancel → commit interrupted node → append new user node → start new generation. Max one in-flight generation per conversation.
6. **Conversation index**: `index.json` (id, title, updatedAt, leaf, model) maintained by the store so the list screen never parses JSONL bodies; rendered `AttributedString`s are cached per message id and evicted when leaving a conversation.
7. **ContextBuilder** produces `messages[]` = system prompt + current-branch history, trimmed oldest-first (never splitting a user/assistant pair) to a per-model input budget. Context size is a **user-editable field per model string** (model strings are free-form). Estimator = chars/token **EMA per model** calibrated from returned `usage.prompt_tokens` (CJK/code differ 2–3× from English). Never drops the system prompt or the latest user turn. **Empty interrupted assistant turns are skipped** (several backends 400 on empty assistant content). Compaction (LLM summary of dropped turns, Pi-style) is a v2 hook behind the same protocol.
8. **Generation lifecycle is owned by the store layer, not a view**: a `ConversationSession` object (one per open conversation, held by the store) runs the stream `Task`; SwiftUI `.task` is **not** used because it cancels on disappear — navigating back must not abort the response. `ChatViewModel (@MainActor @Observable)` projects `messages: [Message]` (committed) and `phase: idle | sending | awaitingFirstToken | streaming | interrupted | failed(GatewayError)`; the in-flight text lives in a **separate tiny `@Observable` `Draft` leaf object** (text, reasoning, elapsed, TTFB) so parents that read `phase` don't re-evaluate per flush.
9. **Delta coalescing** (`DeltaCoalescer`, `Clock`-injected): accumulate on the producer side; flush to the main actor when ≥ 16 ms since last flush or ≥ 256 chars; a **trailing-edge timer** flushes the tail when the model pauses; `finished`/error force a final flush.
10. **One active generation per conversation**; Send is disabled while streaming *that* conversation; switching conversations does *not* cancel — the generation completes into its own store while the list shows a badge. iPad multi-scene: both scenes observe the same `ConversationSession` via the store actor.
11. **Settings** (`UserDefaults` except the token): account ID, gateway ID, endpoint preferences, default model string, per-model budget table, system prompt, temperature, title-model string, debug panel toggle. Token in Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — consequence: a new device/restore requires re-entering the token, which is the intended behavior), never logged, redacted in traces.

### R3 — UI responsiveness during streaming

1. **View isolation**: committed messages render in a `ScrollView + LazyVStack` keyed by stable `id` — **not `List`** (UICollectionView self-sizing re-measures on every change of a mutating row and causes scroll jumps). The in-flight message is a **separate** `StreamingMessageView` observing only the `Draft` leaf object; on commit it keeps the same `id` and view type so the swap doesn't jump. Send/Stop state lives in the input bar's own view, so the chat container's `body` reads neither `draft` nor `isStreaming`.
2. **Flush cadence** ≤ 1 per frame (16 ms; 120 Hz not needed for text) with trailing-edge flush (R2.9). Target: zero main-thread hangs > 50 ms during a 10k-token stream on the oldest supported device (Instruments "Hangs" + "SwiftUI" templates).
3. **Rendering strategy — avoid O(n²) layout**: the streaming message is a stack of **frozen, stable-ID paragraph `Text` views** plus one mutating trailing paragraph; paragraph splitting is **fence-aware** (blank lines inside ``` blocks are not boundaries). Markdown: `AttributedString(markdown:)` only yields *inline* intents for `Text` (bold/italic/code/link/strike); headings, fences, lists, tables arrive as `presentationIntent` runs that a small `MarkdownBlocks` renderer walks into SwiftUI views; use `.inlineOnlyPreservingWhitespace` (default `.full` collapses newlines). Unclosed fences in partial text must never throw or blank the view; full block render at commit, cached per message.
4. **Scroll**: `defaultScrollAnchor(.bottom)` + `onScrollGeometryChange` for at-bottom detection using `visibleRect` (raw offset misreads keyboard inset changes) + `onScrollPhaseChange` so "user scrolled away" is set only when phase is `.interacting`/`.decelerating` (geometry callbacks also fire for programmatic scrolls). Unpinned → "↓ new tokens" chip; no `withAnimation` on token updates.
5. **Input bar**: always interactive; Send ⇄ Stop (≥ 44 pt); text field retains draft on failure; keyboard avoidance works while content grows.
6. **Feedback**: "Sending" → "Thinking… (Ns)" until first token (elapsed timer drives the state, not the socket) → tokens → completion haptic (`.success`) and a footer with model, tokens in/out, TTFB, duration; `cf-aig-step > 0` shows a "served by fallback" note.
7. **Accessibility**: streaming `Text` is `.accessibilityHidden(true)` (or `.updatesFrequently`) so VoiceOver doesn't re-read every flush; post "response complete"/"response interrupted" announcements; `.textSelection(.enabled)` only on committed messages (selection resets/flickers under rapid updates); Dynamic Type through XXXL; Reduce Motion disables scroll animation.
8. **Recovery UX**: interrupted messages show an "Interrupted" tag and a **Continue** action that sends the partial as a completed assistant turn plus a user turn "Continue exactly where you left off" (no assistant prefill — rejected by current Anthropic models); failed sends show the mapped error and a Retry action.

### R4 — Error handling matrix

| Condition | Detection | User state | Automatic action |
|---|---|---|---|
| Offline at send | `URLError.notConnectedToInternet` / `NWPathMonitor` | "You're offline" inline, Send stays enabled | `waitsForConnectivity` up to 10 s, then fail |
| Connection lost, 0 bytes | `URLError.networkConnectionLost` | brief "Reconnecting…" | one retry |
| Connection lost, >0 bytes | same, `bytesReceived>0` | message committed as *Interrupted* | none; offer Continue |
| Idle > 120 s | `URLError.timedOut` | "No response from model" / Interrupted | one retry only if 0 bytes |
| 401 / 403 | status | "Cloudflare token rejected" → link to Settings | none |
| 404 | status | "Account, gateway or model not found: <model>" | none |
| 400 | status + body | show gateway/provider message | if context-length pattern (nothing generated → safe), ContextBuilder re-trims to 75 % and retries **once**, then lowers that model's budget |
| 429 | status (+`retry-after`) | "Rate/spend limit reached — try in Ns" | none (never auto) |
| 502 / 503 | status | "Gateway error (status)" | one retry if 0 bytes |
| 504 / 524 / other 5xx | status (524 body is HTML) | "Model took too long before responding" — note it may have been billed | none |
| Silent > ~60 s before first token | elapsed timer | "Still thinking… (Ns)" with Stop; warn that carriers may drop idle connections | none (client idle timeout 120 s is the guard) |
| User cancel | `CancellationError` **or** `URLError.cancelled` | partial committed, "Stopped" tag | none |
| In-stream `error` object | codec | committed partial + error text | none |
| Missing `[DONE]` / truncated | codec | *May be incomplete* tag | none |
| `finish_reason: length` | codec | "Hit max length" + Continue | none |
| `finish_reason: content_filter` | codec | "Filtered by provider" | none |
| App backgrounded mid-stream | `scenePhase` | continue ≤ ~25 s via `beginBackgroundTask`; then commit *Interrupted* | cancel **decisively** at expiry (don't leave the parser half-alive: on foreground URLSession may deliver a burst of buffered bytes or a late error into a state you've discarded) |
| Crash mid-stream | `.inflight` present at launch | recovered *Interrupted* entry | none |

Every failure path (a) never loses received text, (b) leaves the JSONL in a loadable state, (c) records `cf-aig-log-id` when available so the operator can find the request in the Cloudflare log viewer.

### R5 — Security & operator setup (gateway side, no app code)

1. Create a **dedicated Cloudflare account or at minimum a dedicated gateway**; enable **authenticated gateway**; store provider keys via **BYOK under the `default` alias** — on REST/unified endpoints only `default` is consulted, and a missing key **silently falls through to Unified Billing** (Cloudflare credits, +5 % fee, 200 req/60 s/gateway cap). Surface the billing source in the debug panel if any response header exposes it.
2. Create **one API token carrying both** *Account › Workers AI › Read* (REST) **and** *AI Gateway › Run* (compat/dynamic). Verify exact permission names in the dashboard at implementation time. Rotate from the app's Settings.
3. Configure a **hard spend limit** (e.g., $/day) and a **rate limit** as the leak backstop — the token is account-wide.
4. Optional **dynamic route** `dynamic/assistant`: primary model → budget-limit node → fallback cheaper model; the app exposes it as just another model string.
5. Logging: keep metadata logging on; consider `cf-aig-collect-log-payload: false` from the app if prompts should not be stored.
6. App side: token only in Keychain; JSONL under data protection; token redacted in `NetworkTrace`; no analytics SDKs; no third-party code at all.

### R6 — Testing

- **Swift Testing** for `SateCore`. SSE fixtures: CRLF, multi-line `data:`, comments/keepalives, event split across arbitrary byte boundaries (fuzz the chunking), BOM, invalid UTF‑8, `[DONE]` missing, `{"error":…}` mid-stream, oversized event.
- Codec fixtures captured **once via `curl` against the real gateway** for each provider family (Anthropic, OpenAI, Google, Workers AI) and committed under `Tests/Fixtures/` — including their `usage` chunk and `reasoning_content` variants.
- `URLProtocol` stub for `GatewayClient`: 401, 404, 429 (+`retry-after`), 5xx, slow-chunk delivery, mid-stream disconnect, non-SSE 200.
- `SessionStore`: append/load round-trip, sibling branches + leaf switching, unknown entry `type` tolerated, truncated last line, `.inflight` recovery (and no duplicate after normal commit), fork-mid-stream ordering, concurrent appends from two tasks. `FileStore` protocol with an in-memory implementation.
- `DeltaCoalescer` / `ConversationSession`: injected `() -> AsyncThrowingStream<StreamEvent>` and a manual `Clock`; coalescing cadence incl. trailing flush; cancel → committed interrupted entry; error → committed partial; usage chunk with empty `choices` → footer populated. `@Observable` models are `@MainActor`, so these tests are too.
- `MarkdownBlocks`: fence-aware paragraph splitting, unclosed fence, headings/lists/tables via `presentationIntent`, inline-only fallback.
- Opt-in integration smoke test (`SATE_CF_TOKEN` env) hitting the gateway with a 5-token prompt.

---

## Out of scope for v1 (explicit hooks kept)
Tool execution loop (parser already emits `toolCallDelta`), images/files (`ContentPart` array), compaction (`ContextBuilder` protocol), iCloud sync (per-conversation files are sync-friendly), WebSocket transport (Cloudflare offers it; SSE chosen for simplicity), Siri/App Intents, widgets, macOS Catalyst.

## Repository layout (binding — agents must not invent alternatives)

```
/Users/dhison/dev/projects/sate/
  Package.swift                       # SateCore library + SateCoreTests (macOS-runnable: swift test)
  Sources/SateCore/
    Model/         Message.swift  ContentPart.swift  Usage.swift  SessionEntry.swift  JSONValue.swift
    Streaming/     SSEParser.swift  SSEEvent.swift  StreamEvent.swift  DeltaCoalescer.swift
    Networking/    GatewayRoute.swift  GatewayError.swift  ChatCompletionsCodec.swift
                   GatewayClient.swift  NetworkTrace.swift
    Persistence/   JSONLFile.swift  ConversationStore.swift  ConversationIndex.swift
    Context/       ContextBuilder.swift  TokenEstimator.swift
    Settings/      SateSettings.swift  SecretStore.swift      # SecretStore is a protocol here
  Tests/SateCoreTests/            + Tests/SateCoreTests/Fixtures/*.sse
  App/
    Sate.xcodeproj/project.pbxproj      # hand-written, objectVersion 77, synchronized groups
    Sate/  SateApp.swift  Info.plist
           UI/     ConversationListView.swift  ChatView.swift  StreamingMessageView.swift
                   MessageBubble.swift  MarkdownBlocks.swift  InputBar.swift  SettingsView.swift
                   DebugPanel.swift
           State/  ChatViewModel.swift  ConversationSession.swift  AppEnvironment.swift
           Platform/ KeychainSecretStore.swift  BackgroundTaskGuard.swift
  docs/superpowers/specs/2026-08-26-sate-design.md
  scripts/  build.sh  test.sh  e2e.sh  capture-fixtures.sh
  NOTES.md                              # handoff summary + pending items
```

Two build systems over one source tree, deliberately: `Package.swift` compiles `Sources/SateCore`
for fast macOS unit tests; the Xcode project attaches the *same* directory plus `App/Sate` as two
`PBXFileSystemSynchronizedRootGroup`s, so no file lists exist to drift and no SwiftPM product
linking is required. `SateCore` imports Foundation only — no SwiftUI, no UIKit.

## Implementation phases

Ordering is dependency-driven; phases 2A–2D are parallelizable once phase 1's shared types exist.

1. **Scaffold + shared model types** (done by the lead, not delegated): `Package.swift`,
   `.xcodeproj`, `scripts/`, and every type in `Sources/SateCore/Model/` plus the *signatures* of
   `StreamEvent`, `GatewayError`, `GatewayRoute`. These are contracts for the parallel phase.
2. **Parallel core implementation** (four independent agents, no shared files):
   - **2A Streaming**: `SSEParser` (byte framing, R1.6), `SSEEvent`, `DeltaCoalescer` + tests.
   - **2B Networking**: `GatewayRoute`, `ChatCompletionsCodec` (R1.3, R1.7), `GatewayClient`
     (R1.1–1.9), `NetworkTrace` + `URLProtocol` tests.
   - **2C Persistence**: `JSONLFile` (single-`write` append, `F_FULLFSYNC`, truncated-tail
     recovery), `ConversationStore` actor (tree, leaf entries, `.inflight`), `ConversationIndex`
     + tests.
   - **2D Context**: `ContextBuilder`, `TokenEstimator` (per-model EMA) + tests.
3. **App layer** (single agent, needs 2A–2D): `ConversationSession`, `ChatViewModel`,
   SwiftUI views per R3, `KeychainSecretStore`, `BackgroundTaskGuard`, Settings.
4. **Review & simplify**: parallel reviewers (bug hunt + simplification) → apply findings.
5. **Build & test**: `swift test` (unit), `xcodebuild` for the app, boot simulator, install, launch.
6. **Handoff**: `NOTES.md` with results, blockers, and the pending-work queue.

## Verification (end-to-end)
1. `swift test` — all `SateCore` suites green on macOS (no simulator needed).
2. `xcodebuild -project App/Sate.xcodeproj -scheme Sate -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` builds clean under Swift 6 strict concurrency.
3. Boot simulator, install, `simctl launch`; screenshot the empty state and Settings.
4. **Offline E2E without a Cloudflare token**: a build-flag-gated `MockGatewayClient` (`SATE_MOCK=1`
   launch env) replays a bundled `.sse` fixture with realistic inter-chunk delays, so streaming UI,
   coalescing, persistence, interruption and error states are all exercisable in CI/simulator.
   This is the primary automated E2E path.
5. Live path (operator-run, needs the token): `scripts/capture-fixtures.sh` `curl -N`s the REST
   endpoint, confirms SSE shape + `usage` chunk + `cf-aig-log-id`, and saves fixtures.
6. Failure drills once live: invalid token → 401 copy; unknown model → 404; Airplane Mode
   mid-stream → *Interrupted* + loadable JSONL; kill app mid-stream → `.inflight` recovery.

## Open risks to watch during implementation
- REST translation fidelity for OpenAI schema → non-OpenAI providers (system role handling, `max_tokens` required by Anthropic, `reasoning_content` presence, whether `stream_options.include_usage` is honored). Capture fixtures early.
- Compat endpoint deprecation timeline vs. dynamic-route support on REST; `GatewayRoute` isolates this.
- Long silent reasoning is the weakest point of the whole stack: cellular NAT/middleboxes drop idle flows around 60 s, the Cloudflare edge returns 524 near 100 s TTFB, and **Anthropic thinking deltas may be dropped entirely by the OpenAI-compat translation**. Test explicitly with an extended-thinking model; mitigations are (a) prefer models/routes that emit an early chunk, (b) bounded `max_tokens`/reasoning budgets via `extra`, (c) a v2 switch of the codec to the Anthropic-schema REST endpoint for thinking models.
- Client cancel may not abort the upstream generation; treat Stop as a cost event and rely on `max_tokens`.
- Token permission names (*Workers AI Read* vs *AI Gateway Run*) may shift; keep them in the operator checklist, not in code.
- Hand-written pbxproj is the main scaffolding risk; if `xcodebuild` rejects it, fall back to
  generating the project with a small Ruby/`xcodeproj`-free script or ship `SateCore` tests only
  and record the blocker in `NOTES.md` rather than burning the night on it.
