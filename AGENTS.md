# AGENTS.md

## 1. Project Overview

Sate is a native iOS chat client for LLMs, deliberately built as a **dumb
terminal**: it carries no LLM SDKs and no provider-specific code. Every call goes
to Cloudflare AI Gateway, which owns provider keys, routing, fallbacks, retries,
rate limits, spend limits, and logging; the app owns only what a broker cannot —
the HTTP request, SSE framing, conversation state, on-device persistence, and
rendering. Stack: Swift 6 (strict concurrency `complete`), SwiftUI, iOS 26+,
Foundation only, zero third-party packages, Swift Testing (`@Test`/`#expect`).

## 2. Repository Architecture

Two build systems over one tree on purpose: `Package.swift` compiles
`Sources/SateCore` for fast macOS tests; `Sate.xcodeproj` attaches the same
directory plus `App/Sate` as `PBXFileSystemSynchronizedRootGroup`s — no file
lists, so new files need no project edit.

```
Package.swift                 SwiftPM: builds SateCore for macOS unit tests (no simulator)
Sate.xcodeproj/               hand-written pbxproj (objectVersion 77); do not hand-edit
Sources/SateCore/             Foundation-only engine — no SwiftUI, no UIKit, ever
  ├─ Streaming/               SSEParser, SSEEvent, DeltaCoalescer, ReasoningTagParser
  ├─ Networking/              GatewayClient (sole Cloudflare-aware type), ChatCompletionsCodec, GatewayRoute, GatewayError
  ├─ Model/                   Message, ContentPart, JSONValue, Usage, SessionEntry, MathFormatter
  ├─ Persistence/             ConversationStore, ConversationIndex, JSONLFile (additive-only schema)
  ├─ Context/                 ContextBuilder, TokenEstimator
  ├─ Search/                  ToolRunner, TavilySearchProvider, SearchResult
  └─ Settings/               SateSettings, ModelCatalog, SystemPrompt, SecretStore, ThinkingPolicy
App/Sate/                     SwiftUI app; compiles SateCore sources directly via synchronized group
  ├─ SateApp.swift            @main entry, typed SateRoute path
  ├─ State/                   ChatViewModel (sole @MainActor), ConversationSession, AppEnvironment, MockGatewayClient
  ├─ UI/                      ChatView, MessageBubble, InputBar, SettingsView, StreamingMessageView, MarkdownBlocks, MathBlockView, DebugPanel, SourcesView, ConversationListView, Typography
  └─ Platform/                KeychainSecretStore, Log, BackgroundTaskGuard
Tests/SateCoreTests/          Swift Testing suites + Fixtures/*.sse (captured, not invented)
scripts/                      build · test · lint · format · run · e2e · capture-fixtures
docs/                         bugs.md, superpowers/specs/ (design + proposals), reference/liquid-glass-ios26.md
NOTES.md                      current state and pending work
local/                        operator secrets (Tavily, Cloudflare token) — never commit
```

### Module dependency rules (load-bearing, strict)

- **Layering is one-directional.** The SSE parser knows nothing about JSON; the
  codec knows nothing about URLs; `SateCore` knows nothing about views.
  `Sources/SateCore` is **Foundation only — no SwiftUI, no UIKit, ever**.
- `GatewayClient` is the **sole** type that knows Cloudflare exists.
- `ChatViewModel` is the **only** `@MainActor` type in the chain.
- Generations are owned by the **store layer** so they outlive the view that
  started them.
- `App/Sate` may import `SateCore`; `SateCore` may not import `App`.

## 3. Developer & Agent Workflows (Commands)

```bash
./scripts/test.sh                     # swift test — SateCore on macOS, no simulator (~1.3s, 160 tests / 16 suites)
./scripts/lint.sh                     # swiftlint
./scripts/format.sh                   # swiftformat .
./scripts/build.sh                    # xcodebuild iOS app (scheme Sate, iOS 26.5 sim, shared DerivedData)
./scripts/run.sh                      # build + install + launch in simulator (live mode, SATE_MOCK=0)
./scripts/e2e.sh                      # boot sim → install → drive via SATE_DEMO → screenshot into artifacts/
./scripts/capture-fixtures.sh <model> # operator-run; needs SATE_CF_ACCOUNT + SATE_CF_TOKEN
```

**Setup / install.** No third-party packages. Install the two tools the scripts
depend on (not SwiftPM dependencies):

```bash
brew install swiftlint swiftformat
```

**Single-test execution (Swift Testing).** Tests are `@Test func name()` inside
`struct` suites; filter by suite or test name:

```bash
swift test --filter SSEParserTests                       # whole suite
swift test --filter SSEParserTests/openAIBasicStreamFrames  # one test
swift test --filter GatewayClientTests                    # network (stubbed via URLProtocol)
```

**Simulator env.** `simctl` forwards env to the app only with the
`SIMCTL_CHILD_` prefix (see `e2e.sh`, `run.sh`). Device/OS defaults:
`SATE_DEVICE=iPhone 17 Pro`, `SATE_OS=26.5`.

## 4. Codebase Conventions & Constraints

- **Modern Swift only.** `async`/`await`, actors, `@Observable`, value types by
  default. No Combine, no completion handlers, no `DispatchQueue`.
- **Comments explain why, never what.** No obvious comments, no restating the
  signature, no section banners. If a comment only paraphrases the next line,
  delete it.
- **No slop.** No defensive code for impossible cases, no speculative
  abstraction, no options nobody asked for.
- **Format/lint config.** `.swiftformat` (`--indent 4`, `--trim-whitespace
  always`, `--disable redundantSelf`); `.swiftlint.yml` (opt-in: `empty_count`,
  `force_unwrapping`, `fatal_error_message`, `line_length`, etc.; scope
  `Sources`, `App`, `Tests`).
- **Liquid Glass** per `docs/reference/liquid-glass-ios26.md`: glass belongs to
  the **navigation layer only** — composer, chips, badges, banners. Content
  (transcript, bubbles, code) is never glass. Adjacent glass shares one
  `GlassEffectContainer`.

### Non-negotiables

- **Streaming is metered and interruptible.** Anything touching retry,
  cancellation, `max_tokens`, or which recovery button is shown is a **cost**
  change — reason about the bill, not just the code path.
- **Never lose received text.** Every failure path commits the partial and
  leaves the JSONL loadable. The JSONL schema is **additive-only**; unknown types
  and keys are skipped, never fatal.
- **Secrets stay in the Keychain** and are redacted in traces. Never log a
  token, put one in a fixture, or send a provider `Authorization` header —
  BYOK supplies it at the gateway.
- **Wire-format claims need a real fixture** in `Tests/SateCoreTests/Fixtures/`,
  captured from the gateway via `capture-fixtures.sh` — not written from memory.
  A fix lands with the test that would have caught it (`docs/bugs.md`).
- **Core tests stay simulator-free.** Network is stubbed with `URLProtocol`,
  the filesystem with the `FileStore` protocol, time with an injected `Clock` —
  never sleeps.
- **A new dependency, a provider SDK, or a server component contradicts the
  premise** — raise it before building it.
- **Do not hand-edit `Sate.xcodeproj/project.pbxproj`** unless the change
  genuinely cannot be made by adding a file.

## 5. Subagent Specializations & Delegation Rules

When work is delegated, match the role to the layer and keep the contract below.

| Role | Owns | Boundary |
|---|---|---|
| **Architect** | `docs/superpowers/specs/`, layering rules, cost/streaming semantics | Foundation-only `SateCore`; no SwiftUI/UIKit in core; no new deps without sign-off |
| **Implementer (Core)** | `Sources/SateCore/{Streaming,Networking,Model,Persistence,Context,Search,Settings}` | Foundation only; `GatewayClient` is the only Cloudflare-aware type; tests on macOS, simulator-free |
| **Implementer (App)** | `App/Sate/{State,UI,Platform}` | `ChatViewModel` is the only `@MainActor`; glass = navigation layer only; never break core layering |
| **Test Engineer** | `Tests/SateCoreTests/`, `Fixtures/` | Real fixtures for wire claims; `URLProtocol`/`FileStore`/`Clock` stubs; a fix ships with the test that catches it |
| **Doc Writer** | `NOTES.md`, `docs/bugs.md`, `AGENTS.md`, `VISION.md`, specs | Keep `bugs.md` an entry-per-defect log; keep `NOTES.md` current state |

**Handoff format.** State the layer being touched, the contract being preserved
(additive JSONL, redacted secrets, metered streaming), the test/fixture that
pins the change, and any cost implication. Do not cross layers in one handoff:
core work lands with its macOS test before an app-layer change consumes it.

**Context limits.** Prefer one layer per delegation; pass only the file paths
and invariants a role needs, not the whole tree. Re-read `docs/bugs.md` and
`NOTES.md` before touching streaming, persistence, or secrets — those areas are
where every prior defect lived.
