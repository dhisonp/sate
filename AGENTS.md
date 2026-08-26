# AGENTS.md

Sate is a native iOS chat client for LLMs, deliberately built as a **dumb
terminal**: no LLM SDKs, no provider-specific code, no backend of our own. Every
call goes to Cloudflare AI Gateway, which owns provider keys, routing, fallbacks
and spend limits. The app owns only what a broker cannot — the HTTP request, SSE
framing, conversation state, persistence, rendering. A new dependency, a provider
SDK, or a server component contradicts the premise; raise it before building it.

## Stack

Swift 6 (strict concurrency `complete`), SwiftUI, iOS 26+, Foundation only.
Zero third-party packages. Swift Testing (`@Test`/`#expect`), not XCTest.

## Commands

```
./scripts/test.sh                     # swift test — SateCore on macOS, no simulator
./scripts/lint.sh                     # swiftlint
./scripts/format.sh                   # swiftformat
./scripts/build.sh                    # xcodebuild the iOS app
./scripts/run.sh                      # build, install, and launch in simulator (live mode, SATE_MOCK=0)
./scripts/e2e.sh                      # boot sim, install, drive via SATE_DEMO, screenshot
./scripts/capture-fixtures.sh <model> # operator-run; needs SATE_CF_ACCOUNT + SATE_CF_TOKEN
```

`xcodebuild -destination` cannot resolve a simulator on this machine (SDK/runtime
skew), so `build.sh` uses `-target Sate -sdk iphonesimulator`. Don't "fix" it
back. `simctl` forwards env vars only with a `SIMCTL_CHILD_` prefix.

## Architecture

Two build systems over one tree: `Package.swift` compiles `Sources/SateCore` for
fast macOS tests; `Sate.xcodeproj` attaches the same directory plus `App/Sate` as
`PBXFileSystemSynchronizedRootGroup`s — no file lists, so new files need no
project edit.

Layering is strict and load-bearing: the SSE parser knows nothing about JSON, the
codec nothing about URLs, `SateCore` nothing about views (Foundation only — no
SwiftUI, no UIKit, ever). `GatewayClient` is the sole type that knows Cloudflare
exists. `ChatViewModel` is the only `@MainActor` type in the chain, and
generations are owned by the store layer so they outlive the view that started them.

## Code style

- Modern Swift: `async`/`await`, actors, `@Observable`, value types by default.
  No Combine, no completion handlers, no `DispatchQueue`.
- Comments explain **why**, never what. No obvious comments, no restating the
  signature below, no section banners. If a comment only paraphrases the next
  line, delete it.
- No slop: no defensive code for impossible cases, no speculative abstraction,
  no options nobody asked for.
- Liquid Glass per `docs/reference/liquid-glass-ios26.md`: glass belongs to the
  navigation layer only — composer, chips, badges, banners. Content (transcript,
  bubbles, code) is never glass. Adjacent glass shares one `GlassEffectContainer`.

## Testing

Core logic is tested on macOS and must stay simulator-free. Network is stubbed
with `URLProtocol`, the filesystem with the `FileStore` protocol, time with an
injected `Clock` — never sleeps. Wire-format claims need a fixture in
`Tests/SateCoreTests/Fixtures/` captured from the real gateway, not written from
memory. A fix lands with the test that would have caught it (`docs/bugs.md`).

## Boundaries

- Streaming is metered and interruptible. Anything touching retry, cancellation,
  `max_tokens`, or which recovery button is shown is a **cost** change — reason
  about the bill, not just the code path.
- Never lose received text: every failure path commits the partial and leaves the
  JSONL loadable. The JSONL schema is additive-only; unknown types and keys are
  skipped, never fatal.
- Secrets stay in the Keychain and are redacted in traces. Never log a token, put
  one in a fixture, or send a provider `Authorization` header — BYOK supplies it
  at the gateway.
- Don't hand-edit `Sate.xcodeproj/project.pbxproj` unless the change genuinely
  cannot be made by adding a file.

`docs/superpowers/specs/` holds the design spec and open proposals; `NOTES.md`
holds current state and pending work.
