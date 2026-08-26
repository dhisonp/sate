# Sate — Defect log

Every defect found during the build, with the failure it would actually have
caused, the fix, and the regression test that now pins it. All eleven are fixed
and covered; nothing here is outstanding. Open work lives in `NOTES.md`.

Sources: two adversarial reviewers on `SateCore` (streaming/networking and
persistence/context), a third on the app layer, plus one found while wiring the
persistence contract.

**Severity key** — *Critical*: crashes or corrupts. *Major*: silently loses data,
money, or correctness. *Minor*: misleading but bounded.

| # | Severity | Area | One line |
|---|---|---|---|
| [1](#1) | Critical | `JSONValue` | A number in a provider chunk could abort the process |
| [2](#2) | Major | Codec | Truncated answers reported as complete |
| [3](#3) | Major | Index | One conflict copy made the app unbootable |
| [4](#4) | Major | Networking | Offline send hung for minutes, then retried |
| [5](#5) | Major | Store | Failed leaf write duplicated the message on next launch |
| [6](#6) | Major | JSONL | A short write fused two entries and lost both |
| [7](#7) | Major | App | A free *Continue* was downgraded to a paid *Retry* |
| [8](#8) | Major | App | Background grace only covered the visible conversation |
| [9](#9) | Major | Model | `.truncated` did not round-trip through persistence |
| [10](#10) | Minor | Codec | `extra["max_tokens"] = null` unbounded the bill |
| [11](#11) | Minor | Docs | `SessionEntry.unknown` promised what it did not do |
| [12](#12) | Major | Secrets | Keychain write failure was swallowed and cached unconditionally |

---

<a id="1"></a>
## 1. A number in a provider chunk could abort the process

**Severity** Critical · **Where** `Sources/SateCore/Model/JSONValue.swift:73`

`intValue` narrowed the decoded `Double` with `Int(value)`. That initializer
**traps** — it is not a failable conversion — for any value outside `Int`'s range
or for a NaN.

**Failure scenario.** A usage trailer arrives as
`{"usage":{"prompt_tokens":1e30,"completion_tokens":8}}`. `Int(1e30)` traps and
`SIGILL`s the app mid-stream. Everything since the last 2-second checkpoint is
gone, and it recurs on every turn with that provider. The trigger is remote:
the app has no say in what a provider puts on the wire, and the gateway does not
normalize it.

**Fix.** `Int(exactly: value.rounded())`, returning `nil` on overflow, with the
usage decoder saturating rather than dropping the field.

**Test** `ChatCompletionsCodecTests.swift:226` — "A total_tokens that would
overflow saturates instead of trapping".

---

<a id="2"></a>
## 2. Truncated answers reported as complete

**Severity** Major · **Where** `Sources/SateCore/Networking/ChatCompletionsCodec.swift:159`

`decodeChunk` returned a single "reason" per chunk and let a later chunk
overwrite it. The `stream_options.include_usage` trailer has **empty `choices`**
and therefore no `finish_reason`, so a placeholder reason overwrote the real one.

**Failure scenario.** A model hits `max_tokens` and the provider sends
`finish_reason: "length"`, then the usage trailer. The trailer's absent reason
masks `length`; the answer is committed as a clean `stop`. The user sees a
sentence that stops mid-word with no *Continue* affordance and no "may be
incomplete" tag — and the obvious recovery, *Retry*, regenerates and re-bills
the whole answer. Providers that stream cumulative usage on **every** chunk hit
this on every generation, not just truncated ones.

**Fix.** `decodeChunk` returns `(events, ChunkTermination)` where
`termination.reason` is non-`nil` **only** when the chunk actually carried
`finish_reason`. The client keeps the first observed reason and lets any chunk
contribute usage. `MockGatewayClient` was moved onto the same call so the mock
path cannot drift back.

**Tests** `GatewayClientTests.swift:277`, `:299`, `:316` — usage trailer before
the finish chunk, after it, and cumulative usage on every chunk.

---

<a id="3"></a>
## 3. One conflict copy made the app unbootable

**Severity** Major · **Where** `Sources/SateCore/Persistence/ConversationIndex.swift:83`

The id → summary map was built with `Dictionary(uniqueKeysWithValues:)`, which
**traps** on a duplicate key.

**Failure scenario.** iCloud Drive resolves a sync conflict by writing a second
copy of a transcript; two entries now claim the same conversation id. The
conversation list is the launch screen, so the app crashes on launch, every
launch, with no path to the settings screen to fix it. Deliberate iCloud backup
inclusion (R2.1) makes this reachable in normal use.

**Fix.** `uniquingKeysWith: { _, new in new }` — last write wins, boot survives.

**Test** covered by the index round-trip suite in `ConversationStoreTests.swift`.

---

<a id="4"></a>
## 4. Offline send hung for minutes, then retried

**Severity** Major · **Where** `Sources/SateCore/Networking/GatewayClient.swift:32,406`

`waitsForConnectivity = true` (R1.1) suppresses `URLError.notConnectedToInternet`
entirely: the task parks until connectivity appears or
`timeoutIntervalForResource` (900 s) fires. The plan called for a 10 s client
budget; it was never implemented.

**Failure scenario.** Send in Airplane Mode. The composer spins for up to fifteen
minutes, then fails with `URLError.timedOut` — mapped to `.idleTimeout`, i.e.
"the model stopped responding", which is the wrong diagnosis and the wrong advice.
Worse, `.idleTimeout` with zero bytes received is on the auto-retry list (R1.9),
so the app immediately does it again.

**Fix.** `GatewayConfiguration.connectivityTimeout` (10 s default). If no bytes
have arrived and no response has been received when it expires, the task is
cancelled and the error is reported as `.offline` — which is not retried and
whose copy points at the network, not the model.

**Test** `GatewayClientTests.swift:436` — "A connect that never completes
surfaces as offline within the budget".

---

<a id="5"></a>
## 5. Failed leaf write duplicated the message on next launch

**Severity** Major · **Where** `Sources/SateCore/Persistence/ConversationStore.swift:267`

Commit order was: append message → append leaf → delete `.inflight`. If the
**leaf** append failed (disk full, data-protection window), the error propagated
before the sidecar was removed.

**Failure scenario.** Disk fills at the end of a long generation. The message
line is on disk and durable; the leaf line is not; the checkpoint sidecar
survives. Next launch, recovery sees a live `.inflight` and materializes it as an
interrupted assistant entry — beside the identical entry already in the file. The
user sees the same answer twice, and the duplicate is now part of the context
sent on the next turn.

**Fix.** Reordered to: message line durable (`F_FULLFSYNC`) → discard checkpoint →
append leaf. A leaf failure now leaves the message committed but the branch
pointer stale, which the last-leaf-wins loader tolerates. No duplication path
remains.

**Test** `ConversationStoreTests.swift:288` — "a leaf append that fails after the
message landed leaves no duplicate".

---

<a id="6"></a>
## 6. A short write fused two entries and lost both

**Severity** Major · **Where** `Sources/SateCore/Persistence/JSONLFile.swift:85,97`

R2.3 requires appends to be a single `write(2)` of `json + "\n"`. `write(2)` is
permitted to return a **short count**, and the code treated any non-negative
return as success.

**Failure scenario.** A large entry is written short — the trailing newline never
lands. The next append starts at the current offset, so the two JSON objects fuse
into one physical line. That line fails to parse, so the loader discards it:
**two** entries lost, not one, and the loss is silent because the append
"succeeded". Under `O_APPEND` the offset has already moved, so nothing self-heals.

**Fix.** Short and failed writes both roll back with `ftruncate(fd, start)` (or
`start + forced` for the newline-only remainder) and surface a real error. The
file is never left with a fusable tail.

**Test** `JSONLFileTests.swift:117` — "a short write is rolled back so it cannot
fuse onto the next append".

---

<a id="7"></a>
## 7. A free *Continue* was downgraded to a paid *Retry*

**Severity** Major · **Where** `App/Sate/State/ChatViewModel.swift:345`

Any non-cancel error set `phase = .failed(error)`, without asking whether a
partial answer had already been committed.

**Failure scenario.** Wi-Fi drops after 500 streamed tokens. The partial is
committed correctly, but the UI shows `.failed`, whose only action is *Retry* —
and *Retry* on an assistant turn regenerates the whole answer and pays for it
again. The cheap, correct action (*Continue*, which resumes from the partial) is
only offered by `.interrupted` and was unreachable. This is the single most
common mid-stream failure on mobile, so the cost is recurring, not theoretical.

**Fix.** `phase = outcome.committed != nil ? .interrupted : .failed(error)`. A
partial that reached disk always yields `.interrupted`.

---

<a id="8"></a>
## 8. Background grace only covered the visible conversation

**Severity** Major · **Where** `App/Sate/State/AppEnvironment.swift:160`

The scene-phase change was forwarded only to the on-screen `ChatViewModel`.
Generations are owned by the session, not the view (R2.8), so a generation left
running while the user navigates back to the list had no observer.

**Failure scenario.** Start a long answer, navigate back to the conversation
list, background the app. That generation takes no `beginBackgroundTask`
assertion and performs no deliberate interrupted-commit, so iOS suspends it
mid-stream. On foreground, `URLSession` may deliver a burst of buffered bytes or
a late error into a parser whose state was never wound down — exactly the
half-alive case R4 says to avoid. Best case the partial is lost; worst case it is
appended out of order.

**Fix.** `AppEnvironment.handleScenePhase` fans out to every live view model.

---

<a id="9"></a>
## 9. `.truncated` did not round-trip through persistence

**Severity** Major · **Where** `Sources/SateCore/Model/Message.swift:26`

`FinishReason.init(rawValue:)` mapped the wire vocabulary but not Sate's own
`"truncated"`, which the codec synthesizes for a stream that ends without a
`finish_reason` (R1.7). Persisted and reloaded, it came back as
`.unknown("truncated")`.

**Failure scenario.** A stream dies without a terminal chunk; the message is
correctly tagged *may be incomplete*. Relaunch: the tag is gone and the message
reads as a normal completed answer, because the recovery UI switches on
`.truncated` and gets `.unknown` instead. The user's own transcript now
misrepresents what happened, and *Continue* is not offered.

**Fix.** An explicit `case "truncated": self = .truncated` in the decoder, so
Sate's own persisted values survive the round trip.

---

<a id="10"></a>
## 10. `extra["max_tokens"] = null` unbounded the bill

**Severity** Minor · **Where** `Sources/SateCore/Networking/ChatCompletionsCodec.swift:81`

The provider-passthrough `extra` dictionary was merged over the body wholesale,
so it could overwrite `max_tokens` with `null`, `0`, or a negative number.

**Failure scenario.** `max_tokens` is the only bound on the worst-case bill
(R1.3) — client cancellation may not propagate upstream, so a Stop is a cost
event, not a stop. A `null` here removes that ceiling entirely and a runaway
generation bills to completion. `0` or a negative value is a guaranteed 400.

**Fix.** `isUsableTokenLimit` rejects null, zero, and negatives; the codec keeps
its own value. Legitimate positive overrides still apply, and `max_tokens` is
always serialized as an integer (some providers reject a float).

**Test** `ChatCompletionsCodecTests.swift:74` — "A positive extra max_tokens
overrides, a useless one does not".

---

<a id="11"></a>
## 11. `SessionEntry.unknown` promised what it did not do

**Severity** Minor · **Where** `Sources/SateCore/Model/SessionEntry.swift:21`

The doc comment said an unknown entry's raw JSON was preserved verbatim; the
implementation stored `raw: ""` and skipped it. Nothing was lost on disk — the
file is append-only and never rewritten — but a future migration written against
that comment would have found the payload empty.

**Fix.** Corrected the comment to state what actually happens: the entry is
skipped on load and left untouched on disk.

---

<a id="12"></a>
## 12. Keychain write failure was swallowed and cached unconditionally

**Severity** Major · **Where** `App/Sate/State/AppEnvironment.swift:196`, `App/Sate/Platform/KeychainSecretStore.swift:67`

`setToken` and `setSearchToken` used `try? secrets.setToken(...)` and unconditionally assigned `cachedToken = value`.

**Failure scenario.** A Keychain write failure was silently discarded. The in-memory cache was updated anyway, so the live client worked for the remainder of the session and Settings displayed a false "Saved in Keychain" status. On the next process launch (or after `build.sh`/`run.sh`), `AppEnvironment.init` read the unpopulated Keychain and returned `nil`, dropping all configured credentials.

**Fix.** Made `setToken` and `setSearchToken` throwing, update cache only after successful write, surfaced errors in `SettingsView`, hardened `KeychainSecretStore.set` to delete-then-add, eliminated double Keychain reads in `init`, and replaced per-process randomized `hashValue` in configuration signature with a deterministic token fingerprint.

**Test** `SecretStoreTests.swift` — token lifecycle, search token lifecycle, and error propagation under failing store.

---

## Patterns worth carrying forward

- **Trapping initializers on remote data.** `Int(Double)` and
  `Dictionary(uniqueKeysWithValues:)` are both traps, not throws, and both took
  their input from outside the app (#1, #3). Any narrowing or uniquing conversion
  fed by a provider chunk, a synced file, or a restored blob needs the failable
  form.
- **POSIX success is not success.** `write(2)` short counts (#6) and a failure
  *after* the durable part (#5) both need explicit rollback ordering.
- **The error path is a pricing decision.** #2, #7, and #10 each cost real money
  by picking the wrong recovery affordance or dropping the only bill ceiling. On
  a metered client, "which button do we show" is a correctness question.
- **Ownership mismatch.** #8 is the view-scoped observer of a session-scoped
  object. The plan says generations outlive views; anything driven by view
  lifecycle needs to be re-checked against that.
