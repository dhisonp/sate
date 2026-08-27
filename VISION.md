# VISION.md

## 1. System Philosophy & Core Tenets

Sate is a **dumb terminal** for LLMs. The app deliberately carries no
intelligence about models: no LLM SDK, no provider client, no routing logic, no
fallback, no retry policy of its own, no backend of its own. Cloudflare AI
Gateway is the broker; the app is the terminal. Foundational tenets:

- **Zero-dependency core.** `Sources/SateCore` is Foundation only — no SwiftUI,
  no UIKit, no third-party packages, ever. What compiles on macOS in under a
  second and runs in an iOS app is the same code, twice.
- **Two build systems, one tree, on purpose.** `swift test` runs the engine on
  macOS with no simulator; `Sate.xcodeproj` attaches the same `Sources/SateCore`
  directory plus `App/Sate` as file-system-synchronized groups so file lists
  never drift. Fast core tests and a real iOS build share one source of truth.
- **The app owns only what a broker physically cannot.** The HTTP request, SSE
  framing, conversation history, on-device persistence, and rendering. Anything
  a broker *can* own — keys, routing, retries, spend limits — the app does not.
- **Streaming is metered and interruptible.** Cost is a first-class concern;
  the bill is reasoned about alongside the code path, never after it.
- **Never lose received text.** A failure path that drops a partial answer is a
  data-loss bug, not a UX bug. The JSONL store is the source of truth and is
  loadable after any failure.
- **Minimal harness, lineage from the Pi agent harness.** Append-only JSONL
  sessions with an `id`/`parentId` branch tree, a normalized stream-event
  vocabulary, and partial-message preservation on abort.

## 2. Domain Model & Boundaries

### Entities

- **`Message`** — a node in the conversation tree (`id`/`parentId`), branching
  rather than linear. Content is composed of `ContentPart`s (text, reasoning,
  tool calls); `Usage` tracks tokens; finish state distinguishes complete,
  truncated, and errored.
- **`SessionEntry`** — the additive JSONL record type. Unknown types and keys
  are skipped, never fatal, so old logs load on new builds.
- **`StreamEvent`** — normalized vocabulary produced by the codec from
  provider-specific SSE; consumed by `ChatViewModel` for live rendering and by
  the store for persistence.
- **`GatewayConfiguration`** — everything needed to reach one operator's
  gateway; the token lives here and is never copied into a trace, log, or error.
- **`GatewayClient`** — the **sole** type that knows Cloudflare exists. Everything
  upstream is provider-agnostic.

### Lifecycle flows

- **Send:** `ChatViewModel` (only `@MainActor`) → store-owned generation →
  `GatewayClient` → SSE → `SSEParser` (bytes→frames) → `ChatCompletionsCodec`
  (frames→`StreamEvent`) → `DeltaCoalescer` → view + store. Generations are owned
  by the store layer so they outlive the view that started them.
- **Persist:** streamed deltas commit to additive JSONL; on abort or error the
  partial is committed and the record stays loadable.
- **Recover:** a failed/truncated/unauthorized leaf decides which button is
  shown — *Continue* (free, same branch) vs *Retry* (paid) — by reasoning about
  cost, not just the code path.

### System boundaries

- **Core → App:** one-directional. `App/Sate` may import `SateCore`; never the
  reverse.
- **Parser → Codec → Client:** the SSE parser knows nothing about JSON; the
  codec knows nothing about URLs; `GatewayClient` is the only Cloudflare-aware
  seam.
- **App ↔ Cloudflare:** the app sends the HTTP request and reads SSE; it never
  holds provider keys (BYOK at the gateway), never sends a provider
  `Authorization` header, and never logs a token.
- **Tests ↔ World:** core tests are simulator-free; network is stubbed with
  `URLProtocol`, the filesystem with the `FileStore` protocol, time with an
  injected `Clock`. Wire-format claims are pinned by fixtures captured from the
  real gateway, not invented.

## 3. Non-Goals

Sate intentionally does **not** do the following; raise a flag before building
any of them:

- No LLM SDK, provider-specific client, or provider routing/fallback logic in
  the app.
- No backend of our own. The gateway is the backend.
- No third-party packages. New dependencies contradict the premise.
- No new server component.
- No provider `Authorization` header; secrets never leave the Keychain un-redacted.
- No Combine, completion handlers, or `DispatchQueue` — modern Swift concurrency
  only.
- No hand-editing `Sate.xcodeproj/project.pbxproj` beyond adding a file when
  unavoidable.
- No defensive code for impossible cases, no speculative abstraction, no options
  nobody asked for.
- No loss of received text: failure paths commit the partial; the JSONL schema
  stays additive-only and never fatal on unknown input.
- No content rendered as Liquid Glass — glass is the navigation layer only
  (composer, chips, badges, banners).

## 4. Roadmap & Evolution

Open work lives in `NOTES.md`; defects and their regression tests in
`docs/bugs.md`; design and proposals in `docs/superpowers/specs/`.

- **Phases.** The core milestone (Foundation-only engine, streaming, persistence,
  error/truncated/unauthorized paths, Liquid Glass UI, web search via tools)
  is landed and verified in the simulator. It has not yet been exercised against
  real Cloudflare — that is the first operator step, via `capture-fixtures.sh`
  and live credentials under `local/`.
- **Extensibility hooks.** Provider coverage expands by teaching the
  `ChatCompletionsCodec` new wire shapes, not by adding SDKs. Tools extend via
  `ToolRunner` + a `SearchProvider`-style seam. Settings extend via
  `SateSettings`/`ModelCatalog` without touching the streaming core.
- **Future subagent ecosystem.** Delegations split by the layer contract above
  — Architect (specs/layering), Core Implementer (Foundation engine), App
  Implementer (SwiftUI, glass), Test Engineer (fixtures + macOS suites), Doc
  Writer (`NOTES.md`/`bugs.md`). Each delegation stays within one layer and
  ships the test or fixture that pins its change; streaming, persistence, and
  secrets are the high-risk seams that always re-read prior defects first.
