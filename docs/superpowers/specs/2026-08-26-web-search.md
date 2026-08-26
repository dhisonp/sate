# Spec — Web search for Sate

Status: **proposed, not implemented.** This document is the brief for the agent
that builds it. It assumes the shipped architecture in
`docs/superpowers/specs/2026-08-26-sate-design.md` and does not restate it.

## Why this exists

The default system prompt (`SystemPrompt.researchAssistant`) tells the model to
be current and to say what it last knew and when. That is honest but it is a
workaround: Sate has no retrieval, so "current" is capped at the model's training
cutoff. Every recency question — prices, releases, news, versions, anything dated
— is answered from memory or refused. This is the single largest gap between Sate
and the Perplexity-style behaviour the prompt is imitating.

## Constraint that shapes the whole design

Sate's founding premise is **no backend of our own**. Everything else follows:

- **Provider-native server-side search** (OpenAI `web_search`, Anthropic
  `web_search_20250305`) executes inside the provider — zero client work, no
  second key, first-class citations. But it is **not expressible in the
  OpenAI chat-completions schema Sate speaks.** It requires
  `/ai/v1/responses` or `/ai/v1/messages`, i.e. a second codec, a second event
  vocabulary, and a per-model branch on which one to use. It also excludes the
  `@cf` Workers AI models entirely.
- **A Cloudflare Worker** that owns a search key and exposes a tool would be
  clean, and is exactly the backend the project refused.
- **A client-side tool loop** — the model asks, the app searches, the app feeds
  results back — reuses the tool-call plumbing already in the parser
  (`StreamEvent.toolCallDelta`, joined on `tool_calls[i].index`), works on every
  model the gateway serves including `@cf`, and needs no new endpoint. Its cost
  is one more secret on the device and a real agent loop in a client that was
  deliberately built without one.

**Decision: build the client-side tool loop (v1).** Keep provider-native search
as the v2 path behind the same `SearchProvider` seam, to be taken when and if
Sate adopts the Responses codec.

## R1 — Search provider

1. `protocol SearchProvider: Sendable` in `Sources/SateCore/Search/`:
   `func search(_ query: String, limit: Int) async throws -> [SearchResult]`.
   `SearchResult { title, url, snippet, publishedAt: Date?, siteName }`.
2. First implementation: **Brave Search API** (`api.search.brave.com/res/v1/web/search`,
   `X-Subscription-Token`). Chosen because it is a plain REST endpoint, has a free
   tier, returns `page_age` for recency, and does not require an SDK. Exa and
   Tavily are drop-in alternatives behind the same protocol; do not hardcode
   Brave anywhere above the protocol.
3. The search key lives in the **same Keychain store as the Cloudflare token**,
   under its own account key, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
   It is redacted in `NetworkTrace` exactly like the gateway token.
4. Its own `URLSession` and a hard 8 s timeout. A search that fails or times out
   is **not** fatal: it returns a tool result saying so, and the model answers
   without it. A dead search API must never break chat.
5. Result bodies are **not** fetched. Snippets only. Fetching and extracting page
   text is a v2 question (`Readability`-class extraction, size caps, paywalls)
   and multiplies the token bill.

## R2 — Tool loop

1. New `ToolRunner` actor in `SateCore`, owning the loop; `ConversationSession`
   drives it. `ChatViewModel` gains no new responsibility beyond rendering.
2. The request gains `tools: [{type:"function", function:{name:"web_search",
   description:…, parameters:{query:string, limit:int}}}]` and
   `tool_choice: "auto"`, both sent **only when search is enabled** — a `tools`
   array is a token cost and a 400 risk on models that do not support it.
3. Loop: stream → if the turn ends `finish_reason: "tool_calls"`, append the
   assistant message *including* its `tool_calls`, run each call, append one
   `{role:"tool", tool_call_id, content}` message per call, re-send. Repeat.
4. **Hard bounds, all enforced client-side:** max 3 search rounds per user turn,
   max 4 calls per round, max 8 results per call, ~2 KB of snippet per result.
   Exceeding a bound is not an error — the runner returns a tool result saying
   the budget is spent and lets the model conclude. An unbounded tool loop on a
   metered gateway is the same class of bug as an unbounded `max_tokens`.
5. Parallel calls in one round run concurrently; results are appended in
   **`tool_calls[i].index` order**, not completion order, so the transcript is
   deterministic.
6. Malformed tool arguments (the model emits invalid JSON, which happens on
   smaller models) yield a tool result describing the parse failure rather than
   an error — one repair round is usually enough.
7. Cancellation cuts the whole loop, not just the current stream, and commits
   whatever rounds completed.

## R3 — Persistence

1. Two new `SessionEntry` kinds: `.toolCall` (id, name, arguments, round) and
   `.toolResult` (tool_call_id, results, error, latency). The schema is
   additive-only and old builds skip unknown types (R2.1), so no migration.
2. Tool entries are part of the branch and **are** replayed into context —
   dropping them makes the assistant's own `tool_calls` message unparseable to
   the provider, which 400s.
3. `ContextBuilder` trims a tool-call/tool-result pair as **one unit**, never
   splitting it, and never leaves a `tool_calls` assistant message without its
   results. Trim oldest search rounds before trimming conversation turns —
   snippets age worse than dialogue.
4. The in-flight checkpoint covers the loop, not just the current stream: a crash
   during round 2 must recover with round 1's results intact.

## R4 — UI

1. A **Search** toggle in the composer (glass capsule, sits beside Send),
   persisted per-conversation, defaulting from a global setting. Off means the
   `tools` array is not sent at all.
2. While searching, the status pill reads `Searching "<query>"` — the query is
   the single most reassuring thing to show during the dead time, and it is the
   Perplexity affordance being imitated.
3. Sources render as a collapsed row of favicon + domain chips under the answer,
   expanding to title + snippet + link. Chips are navigation-layer chrome, so
   they may be glass; the answer text may not.
4. Inline citations: the prompt asks for `[1]`-style markers, and
   `MarkdownBlocks` links them to the sources row. If a model ignores the
   convention the answer must still render — treat citations as a bonus, never a
   parse requirement.
5. A failed search shows a quiet inline note ("Search unavailable — answered
   from the model's own knowledge"), not an error banner. The turn succeeded.

## R5 — Prompt

`SystemPrompt` gains a second template, `researchAssistantWithSearch`, selected
when the toggle is on. Differences from the current one:

- Search first for anything dated, versioned, priced, or "latest"; answer
  directly from knowledge when the question is stable (definitions, code, maths).
- One focused query per distinct fact; do not decompose a simple question into
  four searches — each is a round trip the user waits through.
- Cite with `[n]` markers tied to the sources actually used; never cite a source
  that was not returned.
- When results conflict, say so and prefer the more recent, and give the date.
- When search returns nothing useful, say that and fall back to knowledge with
  the existing "as of my cutoff" framing. **Never** present a snippet as
  first-hand knowledge or invent a URL.

The `{{CURRENT_DATE}}` substitution stays and matters more, not less: it is what
lets the model judge whether a `page_age` is recent.

## R6 — Settings

Search key field (masked, same treatment as the Cloudflare token) · provider
picker (Brave for now) · default-on toggle · max rounds · results per query ·
"Search only when the model asks" vs "always search the first turn". Keep the
last one behind the debug section until there is evidence it is wanted.

## R7 — Testing

- `SearchProvider` fixtures: normal results, empty results, rate-limited (429),
  malformed JSON, timeout. A stubbed provider for every loop test — no live
  network in unit tests.
- `ToolRunner`: single call, parallel calls in one round, three-round cap,
  malformed arguments then repair, provider error mid-round, cancellation mid-round.
- Codec: `finish_reason: "tool_calls"`, fragments interleaved across `index`,
  `id`/`name` present only in the first fragment, a `tool` role message
  round-tripping through the request encoder.
- `ContextBuilder`: a trim that would orphan a `tool_calls` message must drop the
  pair instead; search rounds evicted before dialogue.
- `ConversationStore`: tool entries round-trip; an old build reading a file with
  them skips cleanly; crash during round 2 recovers round 1.
- E2E: extend the mock gateway with a fixture that emits a tool call, so the
  toggle, the searching pill, the sources row and the citation links are all
  exercisable offline.

## Open questions for the implementer

1. **Do the `@cf` models hold the tool contract?** Gemma 4 and Qwen 3.8 both
   advertise function calling, but small models are the ones that emit malformed
   arguments and phantom tool names. Verify against both before wiring the
   toggle on by default for Workers AI models.
2. **Does the gateway pass `tools` through unchanged on the REST route** for
   every provider family, or does the translation drop it for some? Capture a
   fixture per family before building on it.
3. **Is one more device-side secret acceptable?** It is a reversal of "provider
   keys never on device", justified by a Brave key being low-value and
   independently revocable. If the answer is no, the only remaining option is a
   Worker — which is the backend the project refused, and that trade should be
   made deliberately rather than discovered halfway through.
4. **Cost visibility.** A search turn can be 3–5× a normal turn in tokens. The
   per-message footer should show rounds and total tokens, or the bill will
   surprise.
