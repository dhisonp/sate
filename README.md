# Sate — ⚡️ Native iOS Dumb Terminal for LLMs

Sate is a native iOS chat client for large language models, deliberately designed as a **dumb terminal**. It carries no LLM SDKs, no provider-specific code, and no proprietary backend. Every call is brokered through **Cloudflare AI Gateway**, which manages provider keys, routing, fallbacks, rate limits, and spend caps at the edge—leaving the app to focus strictly on what a broker cannot: HTTP transport, SSE framing, conversation branching, on-device persistence, and rendering.

- 🚀 **Zero Third-Party Dependencies**: Built exclusively with Swift 6 (strict concurrency `complete`), SwiftUI, and Foundation. No vendor SDKs, no package bloat.
- 🌐 **Cloudflare AI Gateway as Broker**: Offloads provider auth (BYOK), multi-model routing, retries, and spend limits to the edge. Universal REST and dynamic route endpoints supported.
- 💾 **Resilient Append-Only Persistence**: JSONL-backed conversation sessions with an `id`/`parentId` branch tree. Partial messages are committed on abort or network drop—received text is never lost.
- 🧠 **Extended Thinking & Reasoning**: Native support for reasoning deltas, in-band `<think>` tag parsing, and configurable thinking budgets.
- 🔍 **Live Web Search**: Tool-assisted web retrieval powered by Tavily with source attribution.
- 📐 **High-Performance Streaming UI**: Delta coalescing, paragraph-frozen Markdown rendering to eliminate layout recalculations during high-velocity token generation, and LaTeX math formatting.
- 🎨 **Liquid Glass Navigation**: iOS 26 glass effects confined to navigation elements (composer, chips, badges, banners) over solid content bubbles.
- 💰 **Cost-Aware & Transparent**: Live token and usage tracking, Cloudflare trace inspection (`cf-aig-log-id`, `cf-ray`, `cf-aig-step`), and distinct Continue (free) vs. Retry (paid) failure recovery.
- 🧪 **Dual Build System**: Foundation-only `SateCore` runs simulator-free unit tests on macOS in ~1s; `Sate.xcodeproj` binds the iOS app using synchronized root groups with zero file-list drift.

## Architecture

| Layer | Path | Responsibilities | Constraints |
|---|---|---|---|
| **Core** | `Sources/SateCore/` | SSE framing, codecs, gateway transport, JSONL persistence, context builder, search tools, settings | Foundation only. No SwiftUI, no UIKit. macOS & iOS testable. |
| **App** | `App/Sate/` | View hierarchy, `ChatViewModel` (`@MainActor`), Liquid Glass chrome, Keychain secret storage, background lifecycle | SwiftUI + SateCore. |

## Requirements

- **iOS Deployment Target**: iOS 26.0+
- **Development**: macOS 15+, Xcode 16+, Swift 6.0+
- **Tools**: `brew install swiftlint swiftformat`
- **Gateway**: A Cloudflare account with AI Gateway enabled and BYOK provider keys configured.

## Quick Start

### 1. Run Tests

Unit tests run natively on macOS via SwiftPM with zero simulator overhead:

```bash
./scripts/test.sh
```

### 2. Build & Run in Simulator

Build and launch the app in the iOS simulator:

```bash
./scripts/build.sh
./scripts/run.sh
```

### 3. Configure Credentials

In the app's **Settings**:
1. Enter your **Cloudflare Account ID** and **API Token** (requires `Workers AI > Read` and `AI Gateway > Run` permissions).
2. Select your default model (e.g. `anthropic/claude-opus-5`, `openai/gpt-5.2`, or a custom gateway route).
3. *(Optional)* Add a **Tavily API Key** to enable live web search.

All keys are stored securely in the on-device Keychain and are never logged or exported in request traces.

## Development Workflows

```bash
./scripts/test.sh                     # Run SateCore unit tests on macOS (~1s, 220+ tests)
./scripts/lint.sh                     # Run SwiftLint
./scripts/format.sh                   # Format Swift sources
./scripts/build.sh                    # Build the iOS app via xcodebuild
./scripts/run.sh                      # Build and launch live in simulator
./scripts/e2e.sh                      # Run headless simulator UI tests and capture screenshots
./scripts/capture-fixtures.sh <model> # Capture live gateway SSE frames into test fixtures
```

## Documentation

- [`VISION.md`](VISION.md) — System philosophy, core tenets, and architectural non-goals.
- [`AGENTS.md`](AGENTS.md) — Repository architecture, subagent delegation contracts, and developer workflows.
- [`NOTES.md`](NOTES.md) — Operator knowledge, Cloudflare gateway setup, and open roadmap.
- [`docs/bugs.md`](docs/bugs.md) — Defect history and regression test index.
- [`docs/reference/liquid-glass-ios26.md`](docs/reference/liquid-glass-ios26.md) — Liquid Glass UI design specifications.

## License

MIT
