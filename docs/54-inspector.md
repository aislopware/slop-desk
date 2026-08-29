# 54 — The inspector service (`slopdesk-inspectord`)

PATH 3's producing end, in a Rust daemon on its own TCP port. The client dials **it**, not hostd.
Both ENDS of the frame are Rust — `wire.rs` writes what it reads, and `Sources/SlopDeskInspector`
reaches it through `rust/slopdesk-ffi`'s `inspector` door. What Swift keeps is the event JSON: an
`InspectorEvent` is a document this daemon writes and the client reads, which is a protocol's two
ends rather than one capability written twice.

Read `docs/51-process-supervision.md` first for the daemon shape this follows, `docs/52` and
`docs/53` for the siblings that moved the same way, `docs/50-agent-detection-architecture.md` for
the path this is deliberately NOT (hooks are detection, not inspection), and
`docs/46-gates-env-paths.md` for the gate matrix.

---

## 1. Why it left Swift

The inspector's wire never went through hostd — the client has always dialled `terminalPort + 1`
directly (`LivePaneSession.subscribeInspector`). What hostd contributed was the **process**, and
that is what was wrong with it:

- **A host restart erased the session.** The transcript tail, the fold state and the whole replay
  window lived in hostd's address space. `just host-restart` is ~0.2 s and superd's children never
  notice it — but the inspector did, completely: after a rebuild a client reconnecting and asking
  for `subscribe(fromSeq: 0)` got an empty history for a session that was still running. The pane
  survived the restart; its inspector did not.
- **A per-turn JSON fold sat on the keystroke process.** Every transcript line was decoded,
  classified and folded on the daemon that owns every pane's flow control. It is not a large cost
  per line, but it is unbounded in the size of the line and it is on the wrong process.
- **A growing replay window was hostd's memory.** Bounded, but bounded at 50 000 events — of a
  session hostd otherwise has no reason to hold anything about.

Perf was not the argument and did not need to be: the standing rule is that parity is enough, and
what is bought here is a tail that outlives the daemon that started it.

## 2. Shape

A separate binary over a socket, **never FFI** (`CLAUDE.md`), so `swift build` on a clean checkout
still never sees cargo. Its OWN cargo workspace, for the reason superd, screend, dropd and androidd
are: profiles are workspace-global, and this one wants `opt-level = 3` and `panic = "unwind"` where
the hook wants `"z"` and `"abort"`.

```
Sources/SlopDeskInspector/   the CLIENT end: the event types, subscribe encode, frame + event decode,
                             InspectorClient, InspectorViewModel. Hook bodies are NOT here — §7
Sources/SlopDeskHost/InspectorServiceManager.swift   spawn-or-adopt + port re-learn (no bytes)
rust/slopdesk-inspectord/
  src/json.rs         accessors over serde_json::Value (sorted-key rendering, tolerant lookups)
  src/line.rs         one decoded transcript line
  src/parser.rs       JSONL text → TranscriptLine, never failing
  src/accumulator.rs  byte chunks → complete lines, bounded, CRLF-tolerant
  src/tailer.rs       follows one file: poll size, read delta, survive truncation AND rotation
  src/subagents.rs    watches subagents/, tails each agent-<hash>.jsonl
  src/builder.rs      the cross-line fold: tool-card pairing, todos, subagent attribution
  src/event.rs        the wire's event types, pinned to Swift's synthesized Codable shapes
  src/replay.rs       the bounded replay window + replay-then-live fan-out
  src/wire.rs         [u32 BE len][u8 tag][body] — encode 1/2, decode 3
  src/engine.rs       one thread owning the builder, polling both sources
  src/server.rs       accept loop, two threads per connection
  src/main.rs         --port / --transcript / --keep-alive-secs
```

Std threads, no async runtime. One **engine** thread owns the `EventBuilder`, which gives exactly
the serialisation the Swift actor gave with nothing to schedule it. Each connection gets **two**
threads — a reader and a pump — which is what makes a client disconnect observable at all: the Swift
`withTaskGroup` version needed the reader purely so the subscription could be dropped when the peer
went away.

## 3. hostd's job, which is not the bytes

`InspectorServiceManager` spawns-or-adopts inspectord as the superd pane `service:inspectord`,
exactly like dropd and the panel backends (`docs/51` §6.7): on a PTY, under a stable pane id, with
the port **re-learned by replaying the ring from offset 0** and reading the child's own announce
line —

```
inspectord: listening on 0.0.0.0:7701 (v0.1.0, transcript /Users/me/.claude/projects/…/session.jsonl)
```

There is no state file and no port handshake. If the adopted service turns out to be on the wrong
port (a hostd relaunched with a different `--port`), the manager terminates it and respawns once.

The `(v…` is the RUNNING build's version, first in the parenthetical so its position holds however
the rest of that text grows. It rides this line rather than the wire for the same reason the port
does — an adopted inspectord is one hostd did not start — and this wire has no handshake to add it
to. hostd compares it against `slopdesk-inspectord --version` on disk and restarts a stale one on
the same port and transcript (`docs/49`).

`HostServer.stop()` **relinquishes**: hostd goes away, inspectord keeps tailing, and the replay
window a client is about to ask for is still there when it asks. Only a deliberate stop terminates.

An inspectord that will not start is logged loudly and is **non-fatal** — it must not tear down a
healthy terminal server, exactly as a failed bind did not. There is then no inspector, and no
fallback: a Swift producer "just for when inspectord is missing" is the cross-language mirror the
tree forbids, and `rust/slopdesk-invariants` fails the build if one reappears.

## 4. The wire

Unchanged from the Swift server — same tags, same framing, same JSON — because a shipped client is
one end of it.

`[u32 BE payload length][u8 tag][body]`, the length counting the tag, capped at 16 MiB
(`SlopDesk.maxFramePayloadLength`).

| tag | direction | body |
| --- | --- | --- |
| 1 | inspectord → client | the event, as JSON |
| 2 | inspectord → client | empty (keep-alive) |
| 3 | client → inspectord | `fromSeq`, big-endian `i64` |

The exemption is the FRAME, and only the frame. Each end of it is written ONCE: `InspectorCodec`
encodes tag 3 and decodes tags 1–2; `wire.rs` does the mirror — a tag 3 arriving at the client
decodes as `unknownType`, not as a subscribe. That is the two-ENDS exemption to the
one-implementation rule, and §12 of `slopdesk-invariants` is what keeps the halves from drifting.

The BODY is not covered by it and never was. Until 2026-08-29 both ends deserialised the same eight
types out of the same bytes, which is the one-implementation rule broken rather than exempted — a
protocol's two ends read each other's messages, they do not each hold a private copy of the same
one. The taxonomy now lives once, in `event.rs`, and `slopdesk_inspectord::store` is its only
decoder; Swift carries the body across UNREAD as `InspectorWireMessage.event(Data)` and hands it to
the store through the FFI. Framing is Swift's, meaning is Rust's. See `docs/66`.

The event JSON is what Swift's **synthesized** `Codable` produced when the taxonomy was Swift's,
which is a real constraint rather than a style — a shipped daemon writes it and the golden vectors
pin it: a single unlabelled associated value serialises as `{"caseName":{"_0":{…}}}`, labelled cases
use their labels, and `nil` optionals are omitted entirely. `event.rs` reproduces that with serde
attributes, and `the_wire_shape_matches_swifts_synthesized_codable` pins it.

Both ends are tolerant BY DESIGN, and that is why §12 exists: an unknown tag is skipped and an
unparseable event body is skipped, precisely so one rogue frame cannot end a session's feed. Skew
the tags and nothing errors anywhere — the panel simply stays empty. The one unrecoverable decode
error is `frameTooLarge`, which comes from the length prefix before any bytes are consumed and
therefore means the stream is framing-desynced; the client finishes the feed and resubscribes.

## 5. What it reads, and what it refuses to invent

The transcript schema is stable only as a discriminated union on `type`; fields come and go between
versions. So every stage is tolerant, and the tolerance has a shape:

| input | answer |
| --- | --- |
| a `type` this build has never seen | surfaced as `unknownLine` with the raw text — never dropped, never guessed |
| `file-history-snapshot`, `queue-operation`, `rate_limit_event` | classified as ignored: internal bookkeeping, no event |
| unparseable JSON | `unknownLine`, and the tail keeps going |
| a `tool_use` with no `id` | dropped — a card with no key cannot be paired or updated |
| a `thinking` block with empty text | a PLACEHOLDER: presence and signature, never invented content |
| a line longer than 16 MiB with no newline | the accumulator skips that line rather than growing without bound |
| the file truncated, or rotated to a same-or-larger file | restart at 0 — the `(dev, ino)` check catches what a size check cannot |

The fold's own caps are bounded the same way: 100 000 processed keys, 4 096 pending results per
agent, 2 000 tracked agents (evicted to 1 500), 50 000 retained events (evicted to 37 500). None of
them is reachable by an honest session; all of them are reachable by a malformed feed.

A **subscriber's replay snapshot is undroppable.** The queue drops oldest under backpressure, but
the leading unconsumed replay entries are exempt: a client that reconnects and stalls gets a
truncated LIVE tail, never a truncated history. The Swift `.bufferingNewest` policy could not express
that distinction and dropped the snapshot first, which is the one thing a reconnect exists to get.

`fromSeq` arithmetic is fully saturating — an unauthenticated peer sending `i64::MIN` gets a full
replay, not a panic.

## 6. Paths and env

| name | meaning |
| --- | --- |
| `SLOPDESK_INSPECTORD_BIN` | which binary hostd spawns |
| `--inspector` / `--transcript` (hostd argv) | whether PATH 3 comes up at all, and the file it follows |

The port is `terminalPort + 1`, computed identically on both sides and never negotiated. `--port 0`
binds an OS-chosen port and announces the real one, which is what the tests use. Without
`--transcript` the daemon still binds and serves: a client can connect and subscribe, and the replay
window stays empty — the honest state of an inspector with nothing to inspect yet.

The `subagents/` directory is derived, not configured: it is the sibling of the transcript path,
which is where Claude Code puts it. It need not exist.

## 7. What LEFT instead: the hook body

A hook record was read here once — a `HookIngest` file in this target holding a typed `HookPayload`
enum that modelled the JSON, with a `mapToHookEvent` adapter a module away in `SlopDeskHost` turning
a payload into the event the status machine folds. Both halves are gone. The
reading is `rust/slopdesk-hookevent`, and Swift marshals nothing at all: the body crosses as the
raw bytes it arrived as, into the same `slopdesk_agent_detector_hook` call that folds it.

It is worth being explicit about why it was ever here, because the file lived in the inspector's
target and its types were named after transcript blocks. It never fed the inspector's event stream:
a hook record is an **agent-detection** signal (`docs/50`), folded into `ClaudeStatusMachine`. The
Swift `EventBuilder` had an `ingest(hook:)` fold and nothing in production ever called it, so it was
deleted rather than ported. A separate daemon could not receive one anyway — the hook socket is
bound by superd and served by hostd, and inspectord is not in that path.

What DID stay is the hash scheme: `slopdesk_inspectord::subagents::agent_hash` is what makes a node
linked by a `SubagentStop` and one discovered by the directory watcher the same node. The
`SubagentStop` half has no reader left — the status machine ignores a subagent's identity entirely
(`rust/slopdesk-agent/src/machine.rs`) — so the scheme now lives in exactly one place, on the side
that watches the directory.

## 8. Gates

| command | what it covers |
| --- | --- |
| `just inspectord` | build (release) |
| `just inspectord-test` | 98 unit tests + the 2 corpus tests below |
| `just lint-rust` | clippy `-D warnings` + `rustfmt --check`, sixth workspace |
| `rust/slopdesk-invariants` | §12 — the three tags, the 16 MiB cap, the announce line, no Swift producer |
| `swift test --filter InspectorTransportTests` | the client end against hand-built wire bytes |
| `swift test --filter InspectorServiceManagerTests` | 8 — argv with and without a transcript, the announce parse, a missing binary, a survivor on the wrong port, a child that never announces, relinquish vs shutdown |
| `swift test --filter InspectorGlueTests` | the view-model fold and `LivePaneSession` glue over the loopback |
| `just test` / `just test-touched` | all of it, and they BUILD inspectord first |

The unit tests split 18 builder, 13 replay, 12 parser, 11 wire, 10 accumulator, 8 server, 7 json, 7
tailer, 6 subagents, 4 engine, 2 event.

`tests/corpus.rs` folds `tests/fixtures/main-session.jsonl` and its `subagents/` sibling end to end —
tailer → parser → builder → replay → subscriber — and pins the exact event sequence. That corpus
moved here from the Swift suite with the code that reads it; it is a
deliberately awkward session (a thinking placeholder, a result two lines after its call, a
`TodoWrite`, a failed call, an ignored internal type, a type from a future version, a concurrent
subagent), and it is the only test that can prove the stages compose.

The Swift suites pin the client END: the bytes it emits, the frames it decodes, how it survives a
rogue one, and how the panel folds what arrives. Host→client frames in those tests are **hand-built
to the wire spec** rather than produced by a Swift encoder — a round trip through one codebase's own
encoder and decoder passes just as happily when both have drifted, which is exactly the failure mode
a two-language protocol has.
