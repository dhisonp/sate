# Sate — overnight build handoff

*Status as of the core milestone; UI layer, review pass, Liquid Glass pass and
prompt work are appended below as they land.*

## What this is

A native iOS AI chat client that is deliberately a **dumb terminal**. It carries
no LLM SDK and no provider code: every request goes to **Cloudflare AI Gateway**,
which holds the provider keys (BYOK) and owns routing, fallbacks, retries, rate
limits, spend limits and logging. The app owns only what a broker physically
cannot — the HTTP request, SSE framing, conversation history, on-device
persistence, and rendering.

Design lineage is the Pi agent harness: minimal harness, append-only JSONL
sessions with an `id`/`parentId` branch tree, a normalized stream-event
vocabulary, and partial-message preservation on abort.

## Layout

```
Package.swift          SwiftPM: builds Sources/SateCore for macOS unit tests
Sate.xcodeproj         hand-written pbxproj (objectVersion 77)
Sources/SateCore/      Foundation-only engine — no SwiftUI, no UIKit
App/Sate/              SwiftUI app; compiles SateCore sources directly
Tests/SateCoreTests/   Swift Testing suites + .sse fixtures
scripts/               build.sh · test.sh · e2e.sh · capture-fixtures.sh
docs/superpowers/specs/2026-08-26-sate-design.md   the full design spec
docs/reference/liquid-glass-ios26.md               iOS 26 glass API notes
```

Two build systems over one source tree, on purpose: `swift test` runs the engine
on macOS in under a second (no simulator), while the Xcode target attaches
`Sources/SateCore` and `App/Sate` as file-system-synchronized groups — so there
are no file lists in the project to drift as files are added.

## Commands

```bash
./scripts/test.sh              # SateCore unit suite (macOS, fast)
./scripts/build.sh             # build the app for the simulator
./scripts/e2e.sh               # build → boot → install → launch → screenshot
SATE_CF_ACCOUNT=... SATE_CF_TOKEN=... ./scripts/capture-fixtures.sh anthropic/claude-opus-5
```

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

---

# Overnight result

## Status: working app, end to end

The app builds, runs in the simulator, and streams a full response with live
token rendering, markdown-on-commit, persistence and the error paths. It has
**never been run against real Cloudflare** — that needs your account ID and a
token, and is the first thing to do in the morning (see *Pending*, item 1).

- **160 tests in 15 suites passing** (`./scripts/test.sh`, ~1.3s, no simulator).
- **`** BUILD SUCCEEDED **`** for the iOS app under Swift 6 strict concurrency.
- Screenshots of every path in `artifacts/` — launch, mid-stream, completed,
  error, truncated, unauthorized, settings.

## What was built

**SateCore** (Foundation only, no dependencies):
- `SSEParser` — byte-level SSE framing: CRLF / lone-CR, multibyte split across
  chunk boundaries, BOM, keepalive comments, multi-line `data:`, per-event caps.
  UTF-8 is decoded per assembled line, never per chunk.
- `ChatCompletionsCodec` — OpenAI chat-completions in, normalized
  `StreamEvent`s out. Handles `reasoning_content`/`reasoning`, tool-call deltas
  joined on `index`, the empty-`choices` usage trailer, and in-stream errors.
- `GatewayClient` — both Cloudflare routes behind one codec, full error mapping,
  a connectivity budget, and a retry policy that never re-bills a partially
  delivered generation.
- `ConversationStore` — append-only JSONL with an `id`/`parentId` branch tree,
  `F_FULLFSYNC` commits, partial-tail recovery, `.inflight` checkpoints.
- `ContextBuilder` / `TokenEstimator` — oldest-first trimming that never splits
  a turn pair, with per-model chars-per-token calibrated from returned `usage`.

**App** (SwiftUI, iOS 26): conversation list, chat with live streaming, branch
navigation, edit-and-resend, Continue/Retry, settings, debug panel, Keychain
token storage, background-task guard, and an offline mock.

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
  code blocks — must not be glass.

## Bugs found by review and fixed

Two adversarial reviewers read the core; a third read the app layer. The
substantive finds, all now fixed with regression tests:

1. **A remotely-triggerable crash.** `JSONValue.intValue` used `Int(Double)`,
   which *traps*. A chunk containing `"prompt_tokens": 1e30` — or any provider
   emitting an oversized integer — aborted the process mid-stream, losing
   everything since the last checkpoint.
2. **Truncated answers reported as clean.** A usage-only trailer arriving before
   the finish chunk masked the real `finish_reason`, so a response cut off at
   `max_tokens` looked complete and never offered *Continue*. Providers that
   stream cumulative usage on every chunk hit this on *every* generation.
3. **An unbootable app.** `ConversationIndex` used `Dictionary(uniqueKeysWithValues:)`,
   which traps on duplicates — one iCloud conflict-copy transcript crashed the
   conversation list on launch.
4. **A 30-minute hang on a bad network.** `waitsForConnectivity` suppressed the
   offline error, so an offline send blocked against the 900s resource timeout,
   surfaced as "The model stopped responding", and then *retried*.
5. **A duplicate message** when the leaf write failed after the message landed.
6. **Silent double data loss** when a short write fused onto the next append.

## Liquid Glass pass

Applied per Apple's iOS 26 guidance (`docs/reference/liquid-glass-ios26.md`),
deliberately conservative:

| Element | Treatment |
|---|---|
| Composer field | `.glassEffect(.regular, in: .capsule)` |
| Send | `.buttonStyle(.glassProminent)`, circle + `.clipShape` (documented artifact) |
| Stop | `.buttonStyle(.glass)`, ≥44pt |
| Status pill, recovery row, debug panel | `.glassEffect(.regular, …)` |
| Error banner | `.regular.tint(.orange…)` — tint carries state, not decoration |
| MOCK badge, new-tokens chip | glass capsule |

The opaque bottom bar and its divider are gone; content now flows under floating
chrome with the system scroll-edge effect. All adjacent glass shares a single
`GlassEffectContainer` — glass cannot sample other glass, so uncontained
siblings render inefficiently and sample inconsistently.

**Not glassed, on purpose:** message bubbles, transcript, reasoning blocks, code
blocks, completion footer. Those are the content layer, and glassing them is the
specific anti-pattern Apple calls out. Reduced Transparency / Increased Contrast /
Reduced Motion are handled by the system — nothing overrides them.

## System prompt

The default is now a concise, professional research-assistant voice:
direct answer first, length matched to the question, no filler, no closing
offers of help.

**An honest caveat about "latest data".** Sate is a pure LLM client — no web
search, no retrieval. A prompt cannot make the model fetch current information.
What it does instead:

- `{{CURRENT_DATE}}` is substituted at **request-build time** (not when the
  prompt is saved), so the model always knows today's real date instead of
  reasoning from its training cutoff.
- The prompt requires the model to state *what it last knew and roughly when*
  for anything time-sensitive, and to flag it for verification — rather than
  asserting a possibly-stale fact as current.

If you want genuinely live answers, that needs a retrieval step — see *Pending*,
item 7. Editable in Settings, with a **Restore Default Prompt** action.

## Environment blocker (worked around, not fixed)

`xcodebuild` refuses to enumerate **any** simulator destination on this machine:
Xcode 26.6 ships the iOS 26.5 SDK but only the iOS 26.2 runtime is installed, so
`-destination 'platform=iOS Simulator,…'` fails with "Unable to find a
destination matching the provided destination specifier".

Workaround, in `scripts/build.sh`: build with `-target … -sdk iphonesimulator`,
which bypasses the destination resolver, then drive the simulator with `simctl`.
This works completely — build, install, launch, screenshot. Installing the iOS
26.5 simulator runtime (Xcode ▸ Settings ▸ Components) would restore the normal
`-destination` flow and let an XCUITest target run.

## Verifying it yourself

```bash
./scripts/test.sh     # 160 tests, ~1.3s
./scripts/e2e.sh      # rebuilds and regenerates every screenshot in artifacts/
```

`e2e.sh` drives the app with `SATE_DEMO=1` + `SATE_MOCK=1` rather than synthetic
taps: coordinate clicking against the Simulator window is brittle and silently
wrong when the window moves. The mock replays a bundled SSE fixture through the
**real** parser and codec, so everything except the socket is exercised.

---

# Pending — suggested order

### 1. Run it against real Cloudflare (do this first)
Everything below is downstream of this. Set up the gateway per *To actually use
it* above, then:
```bash
SATE_CF_ACCOUNT=... SATE_CF_TOKEN=... ./scripts/capture-fixtures.sh anthropic/claude-opus-5
```
That prints the real SSE and the response headers, and saves a fixture. Repeat
for an OpenAI and a Google model — **the codec has only ever been tested against
fixtures I wrote**, and OpenAI-schema translation to non-OpenAI providers is the
single biggest unknown in the design. Then enter the account ID and token in
Settings and send a real message.

### 2. Verify the reasoning-model path
The weakest point in the whole stack. Anthropic thinking deltas may be dropped
entirely by the OpenAI-compat translation, and cellular NAT drops idle flows
around 60s while the Cloudflare edge returns 524 near 100s time-to-first-byte.
Send a hard prompt to an extended-thinking model on cellular and watch what
happens. If it bites, the options are (a) prefer models that emit an early
chunk, (b) bound the reasoning budget via `extra`, (c) switch the codec to the
Anthropic-schema REST endpoint for thinking models.

### 3. Conversation titles
`GatewayClient` has no non-streaming `complete()`, so R1.10 (a cheap
auto-title call with `cf-aig-cache-ttl: 86400`) is unimplemented. Titles are
currently derived locally from the first user line, which costs nothing and
works — decide whether the model-generated version is worth the tokens.

### 4. Dynamic routes
`GatewayRoute.compat` and the `dynamic/*` model prefix are implemented and unit
tested but have never hit a real dynamic route. Create one in the dashboard
(primary model → budget-limit node → cheaper fallback) and confirm `cf-aig-step`
shows up in the debug panel and the footer says "served by fallback".

### 5. Performance measurement
The R3 architecture is built for it but **no Instruments run has been done**.
Profile a 10k-token stream with the Hangs and Time Profiler templates on the
oldest device you care about; the target is zero main-thread hangs over 50ms.

### 6. Real-device checks the simulator cannot give you
VoiceOver (announcements fire, streaming text is not re-read per flush),
Dynamic Type at XXXL, Reduce Motion, backgrounding mid-stream, Airplane Mode
mid-stream, and killing the app mid-stream to confirm `.inflight` recovery.

### 7. If you want genuinely live answers
The current prompt manages the model's *honesty* about recency; it cannot create
knowledge. Real currency needs retrieval — either a provider with server-side
search, or a Cloudflare Worker that does the search and injects results. Note
that the second one breaks the "no backend of our own" premise, which is a real
architectural decision rather than a small feature.

### 8. Smaller items
- `JSONLFile.shortWriteInjector` is an `internal` test seam added to prove two
  crash-safety fixes (ENOSPC is process-global and unusable in a parallel test
  suite). It is invisible to the app and costs one nil check per line written —
  keep it or drop it with those two tests.
- `MockGatewayClient` triggers its error/truncate paths on those words appearing
  anywhere in the prompt. Intentional for demos, surprising otherwise.
- No app icon; `ASSETCATALOG_COMPILER_APPICON_NAME` points at a catalog that
  does not exist yet.
- iPad multi-scene (two windows on one conversation) is designed for — the store
  is an actor and the JSONL is append-only — but untested.
- Conversation list at scale: `index.json` avoids parsing bodies, but nothing
  has been tried with hundreds of conversations.
- v2 hooks deliberately left in place: tool-execution loop (`StreamEvent`
  already carries `toolCallDelta`), images (`ContentPart` is an array),
  compaction (`ContextBuilder` is a seam), iCloud sync.
