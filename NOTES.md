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
