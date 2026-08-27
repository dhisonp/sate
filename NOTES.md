# Sate — NOTES

Living status and operator knowledge. Architecture, commands, conventions,
and philosophy live in [`AGENTS.md`](AGENTS.md) and [`VISION.md`](VISION.md);
defects and their regression tests live in [`docs/bugs.md`](docs/bugs.md). This
file holds what neither of those covers: how to actually point Sate at a real
gateway, design decisions worth knowing before touching the seams they protect,
and the current open-work list.

## Status

- **225 tests in 23 suites passing** (`./scripts/test.sh`, ~1s, macOS, no
  simulator).
- iOS app builds under Swift 6 strict concurrency; every path screenshotted in
  `artifacts/` via `./scripts/e2e.sh` (mock mode through the real parser/codec).
- **Never exercised against real Cloudflare** — that is open-work item 1.
- Web search (Tavily), thinking-policy + in-band reasoning parsing, the
  `ModelCatalog` picker, the app icon, and the Keychain/main-thread startup fixes
  are all landed since the original handoff.
- 13 defects logged in `docs/bugs.md`, all fixed with regression tests.

## To actually use it against Cloudflare

1. Create (ideally) a dedicated Cloudflare account or gateway, and enable an
   **authenticated gateway**.
2. Store provider keys with **BYOK under the `default` alias**. On the REST and
   unified endpoints only `default` is consulted, and a *missing* key silently
   falls through to Unified Billing (Cloudflare credits, +5% fee) — a quiet cost
   leak worth knowing about.
3. Create one API token carrying **both** `Account > Workers AI > Read` (the REST
   endpoint) **and** `AI Gateway > Run` (the compat endpoint that `dynamic/*`
   routes require). A token with only one scope returns 401 on the other route.
4. Set a **hard spend limit** and a rate limit. The token is account-wide and
   cannot be scoped to a single gateway — the spend limit is the real backstop.
5. Enter the account ID and token in the app's Settings. The token is written
   only to the Keychain.

## Design decisions worth knowing

- **The generation is owned by `ConversationSession`, not a SwiftUI `.task`.**
  `.task` cancels on view disappear, so navigating back would abort a response
  you already paid for.
- **`Draft` is a separate `@Observable` object and `ChatView` never reads its
  text.** Otherwise `@Observable` re-renders the whole transcript on every
  token flush.
- **The transcript is `ScrollView` + `LazyVStack`, deliberately not `List`** —
  `List` re-measures a mutating row on every change and visibly jumps.
- **In-flight text renders as plain text; markdown is parsed at commit.**
  Completed paragraphs are frozen with stable ids so only the trailing paragraph
  re-lays out — otherwise a 20k-character answer is O(n²) layout.
- **Glass is confined to the navigation layer** (composer, chips, banners,
  badges). Apple's guidance is explicit that content — the transcript, bubbles,
  code blocks — must not be glass. Adjacent glass shares one
  `GlassEffectContainer`; glass cannot sample other glass.
- **`{{CURRENT_DATE}}` is substituted at request-build time**, not when the
  prompt is saved, so the model always knows today's real date. The default
  prompt is a research-assistant voice: direct answer first, length matched to
  the question, and for time-sensitive claims the model must state *what it
  last knew and roughly when* rather than asserting a possibly-stale fact as
  current.
- **`ModelCatalog` is static on purpose.** There is no unauthenticated endpoint
  that enumerates gateway-reachable models; a settings screen that can fail to
  populate is worse than a short list plus a **Custom** row for any other
  `provider/model` the gateway resolves. The two hosts spell Workers AI models
  differently (REST: bare `@cf/author/model`; compat: `workers-ai/@cf/...`); the
  catalog stores the REST form and `GatewayRoute.wireModel(_:)` rewrites it.
- **Workers AI on REST requires `cf-aig-gateway-id`.** The client falls back to
  `default` for `@cf` models when no gateway id is set, so a fresh install works.

## Open work — suggested order

### 1. Run it against real Cloudflare (do this first)
Everything risky is downstream of this. Set up the gateway per above, then:
```bash
SATE_CF_ACCOUNT=... SATE_CF_TOKEN=... ./scripts/capture-fixtures.sh anthropic/claude-opus-5
```
That prints the real SSE and response headers and saves a fixture. Repeat for an
OpenAI and a Google model — OpenAI-schema translation to non-OpenAI providers is
the single biggest unknown. Then enter the account ID and token in Settings and
send a real message.

### 2. Verify the reasoning-model path
The weakest point. Anthropic thinking deltas may be dropped entirely by the
OpenAI-compat translation, and cellular NAT drops idle flows around 60s while the
Cloudflare edge returns 524 near 100s time-to-first-byte. Send a hard prompt to
an extended-thinking model on cellular and watch what happens. If it bites, the
options are (a) prefer models that emit an early chunk, (b) bound the reasoning
budget via `extra`, (c) switch the codec to the Anthropic-schema REST endpoint
for thinking models.

### 3. Conversation titles
`GatewayClient` has no non-streaming `complete()`, so a cheap auto-title call
(`cf-aig-cache-ttl: 86400`) is unimplemented. Titles are currently derived
locally from the first user line — decide whether the model-generated version is
worth the tokens.

### 4. Dynamic routes
`GatewayRoute.compat` and the `dynamic/*` model prefix are implemented and unit
tested but have never hit a real dynamic route. Create one in the dashboard
(primary → budget-limit node → cheaper fallback) and confirm `cf-aig-step` shows
up in the debug panel and the footer says "served by fallback".

### 5. Performance measurement
No Instruments run has been done. Profile a 10k-token stream with the Hangs and
Time Profiler templates on the oldest device you care about; the target is zero
main-thread hangs over 50ms. (The earlier main-thread startup costs —
`SecItemCopyMatching` in `AppEnvironment` init and `F_FULLFSYNC` in
`ConversationStore.create` — are already off the main path; see bug history.)

### 6. Real-device checks the simulator cannot give you
VoiceOver (announcements fire, streaming text not re-read per flush), Dynamic
Type at XXXL, Reduce Motion, backgrounding mid-stream, Airplane Mode mid-stream,
and killing the app mid-stream to confirm `.inflight` recovery.

### 7. The app layer has no tests
All 225 tests cover `SateCore`; `App/Sate/**` has none — which is why the
Continue-vs-Retry and background-grace defects (bugs #7–8) needed a human read
to find. The app layer was built to be testable (`LLMStreaming` injectable,
`ConversationStore` takes a directory, the coalescer takes a `Clock`), so a
small suite around `ChatViewModel`'s error matrix and `ConversationSession`'s
commit paths would guard the parts where mistakes cost money. Needs an
XCUITest/unit target in the Xcode project or moving that logic into SateCore.

### 8. Smaller items
- `JSONLFile.shortWriteInjector` is an `internal` test seam added to prove two
  crash-safety fixes (ENOSPC is process-global and unusable in a parallel test
  suite). Invisible to the app, one nil check per line — keep it or drop it with
  those two tests.
- `MockGatewayClient` triggers error/truncate paths on those words appearing
  anywhere in the prompt. Intentional for demos, surprising otherwise.
- iPad multi-scene (two windows on one conversation) is designed for — the store
  is an actor and the JSONL is append-only — but untested.
- Conversation list at scale: `index.json` avoids parsing bodies, but nothing has
  been tried with hundreds of conversations.
- v2 hooks deliberately left in place: images (`ContentPart` is an array),
  compaction (`ContextBuilder` is a seam), iCloud sync.

## Done since the original handoff

Web search (Tavily `SearchProvider` + `ToolRunner`, spec
[`docs/superpowers/specs/2026-08-26-web-search.md`](docs/superpowers/specs/2026-08-26-web-search.md));
in-band `<think>` reasoning parsing fix (bug #13); `ThinkingPolicy`/`ThinkingLevel`
selector; `ModelCatalog` picker with real context windows and the REST/compat
model-name rewrite; app icon; Keychain reads moved off the main thread and
header-line `F_FULLFSYNC` skipped (see bug #12); structured `OSLog` logging;
AttributedString caching; launch screen.
