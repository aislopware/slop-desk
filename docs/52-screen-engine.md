# 52 — The screen engine (`slopdesk-screend`)

The VT terminal parser, the cold-reattach snapshot renderer, every byte pass of the scrollback
REPLAY transform and the whole screen tier of agent detection — the rule ladder, the manifests, the
region resolver, the OSC tracker and the synchronized-frame parser — in one Rust daemon on an
`AF_UNIX` socket. hostd holds the CLIENT end and no screen logic at all.

Read `docs/51-process-supervision.md` first for the daemon shape this follows, and
`docs/46-gates-env-paths.md` for the gate matrix.

---

## 1. Why it left Swift

`TerminalScreenModel.feed` was the hottest byte path in the tree, and about 90 % of
`TerminalReplaySnapshot.compose` — the whole cold-reattach state transfer. Measured on the
`slopdesk-replay-bench` corpus:

| implementation | throughput |
| --- | --- |
| Swift `TerminalScreenModel` | **17.9 MiB/s** |
| Rust `ScreenModel` (same corpus) | **186 MiB/s** |

The gap is structural, not tuning. `Cell.text` was a `String` and the grid was `[[Cell]]`, so every
printed character paid ARC traffic plus a uniqueness check on the outer array and then the inner
one. Rust's `Cell` is 24 bytes with the composed case boxed out of line (`CellText::Composed`), a
row is one flat allocation, and printing a character is a store.

The reason it MATTERS rather than merely being nice: **cold clients always snapshot**
(`MuxChannelSession.swift`). iOS drops TCP seconds after backgrounding, so every foreground
composes the entire retained ring — at 17.9 MiB/s a 64 MiB ring is 3.5 s of hostd's main work
before the first byte reaches the phone.

**17.9 MiB/s is the bar, not "Swift is slow".** The other per-byte Swift on a hot thread — the two
observers `MuxChannelSession.ingestPTYChunk` ran for every byte a pane produced — was measured on
the SAME corpus by `slopdesk-sniffbench` and came back at **614 MiB/s** (`HostOutputSniffer`),
**375 MiB/s** (`CommandBlockSegmenter`) and **232 MiB/s** for both together, against real pane output
in the single-digit MiB/s. On those numbers they stayed in Swift: a port that does not move a
measured ceiling is churn (`docs/DECISIONS.md`, 2026-08-12).

Both moved anyway, in 2026-08-13, and NOT on throughput — superd's pump became the first reader of
every byte, which made them a second pass over the same stream in a second language, and the block
ring they fed died on every hostd rebuild (`docs/51` §6.13–6.14). The numbers above are still the
right way to decide a port; `slopdesk-sniffbench` retired with the two machines it timed, because
hostd now runs no per-byte state machine on the read loop at all. The lesson it was kept for stands:
if a number looks like a language ceiling, read the code before you believe it.

The segmenter's two numbers are the point of this paragraph, not a typo. It first measured **115
MiB/s** — a 5× gap under its own sibling running the same grammar on the same thread — and that gap
was read, briefly, as evidence that Rust was owed the read loop. It was not the grammar: `ingest`
took `some Sequence<UInt8>`, so a `Data` chunk went through a non-specialized iterator into a
byte-at-a-time `append`. Giving it the sibling's shape — one `withUnsafeBytes`, a `memchr` run-scan
in `.ground`, a bulk append of everything between escapes — took it to 375 MiB/s and the read loop
to 232, with a differential test pinning the fast path byte-for-byte against the per-byte one. (That
test went to Rust with the segmenter — `blocks.rs` and `commandblocks.rs` — when the ring moved.)
**A slow Swift number is a claim about an implementation until you have read it.**

## 2. Shape

A daemon over a socket, and a LIBRARY beside it. The split is this repo's socket-vs-library rule
applied to what each half actually is: the screen model is stateful and keyed by pane, two processes
dial it, and it must outlive any one caller — a daemon. The replay passes are a pure function of
their bytes, so they are a linked crate, `rust/slopdesk-sanitize`, which screend and the app both
read (see §3a). Neither half means cargo runs inside `swift build`: the daemon is a binary, and the
library reaches Swift through the `make ffi` artifact like every other linked port (`docs/55`).

screend keeps its OWN cargo workspace for the reason superd does: profiles are workspace-global and
this one wants `opt-level = 3` where the hook wants `"z"`. `slopdesk-sanitize` keeps one too — it is
linked into an iOS app through `slopdesk-ffi`, which wants `panic = "abort"` where this daemon
insists on `unwind`.

```
Sources/SlopDeskScreen/         hostd's END: ScreenPaths, ScreenWire, ScreenSnapshot, ScreenClient
rust/slopdesk-sanitize/         NO dependencies, `forbid(unsafe_code)`, no I/O — pure bytes→bytes
  src/vtscan.rs      the shared escape-sequence skimmer every pass below reads through
  src/width.rs       scalar_width + the DEC graphic map
  src/boundary.rs    the chunk-boundary rules (a cut escape, a cut UTF-8 scalar)
  src/inputmode.rs   pass 1 — mouse / kitty / in-band-resize modes, and the net-state reassert
  src/altscreen.rs   pass 2 — closed alt-screen segments
  src/syncframe.rs   pass 3 — static synchronized-output frames
  src/overprint.rs   pass 4 — the CR-overprint churn collapser
  src/distill.rs     pass 5 — the B→C line-editor collapse (optional)
  src/query.rs       pass 6 — queries, echoed responses, stale colour state
  src/prompteol.rs   pass 7 — zsh PROMPT_SP clusters
  src/sanitize.rs    the ORDER of passes 1–7
rust/slopdesk-screend/
  src/cell.rs        Cell, CellStyle, CellText, SgrColor
  src/model.rs       ScreenModel — the VT parser and the grid
  src/render.rs      the snapshot renderer + the transcript renderer
  src/protocol.rs    the wire (the OTHER end of SlopDeskScreen/ScreenProtocol.swift)
  src/registry.rs    per-pane resident models + detection trackers, LRU, MAX_PANES = 256
  src/server.rs      the AF_UNIX loop, one thread per connection

  src/osc.rs         the retained OSC 0/2 title + OSC 9 progress, per pane
  src/syncwatch.rs   whether the bytes so far end INSIDE an open synchronized update
  src/manifest.rs    the manifest schema + validation (the `toml` crate parses it)
  src/region.rs      the region resolver — `prompt_box_body`, `after_last_horizontal_rule`, …
  src/rules.rs       the compiled rule ladder + the `explain` trace (the `regex` crate)
  src/detect.rs      the tier's entry point, the bundled catalogue, per-pane tracker state
  manifests/*.toml   herdr's nineteen manifests, VERBATIM, `include_str!`d
```

`main.rs` carries one subcommand, `explain`, which `slopdesk-herdr differential` runs next to
upstream's own `herdr agent explain --json`. It lives on this binary because the ladder does; it
replaced a whole Swift executable target that existed only because the ladder used to be in Swift.

## 3. The wire

```text
request  u32 len | u8 verb | u8 flags | u16 rows | u16 cols | u16 paneLen | pane… | raw…
reply    u32 len | u8 status | payload…
```

Big-endian, `len` counts everything after itself, 64 MiB frame ceiling on both ends.

| verb | stateful | payload |
| --- | --- | --- |
| `hello` 0 | – | `slopdesk-screend 1 <build>` — the pinned banner, then the RUNNING build's version |
| `snapshot` 1 | no | the grid, JSON |
| `feed` 2 | **yes**, keyed by `pane` | the grid, JSON |
| `forget` 3 | yes | empty |
| `compose` 4 | no | the rendered reattach stream |
| `transcript` 5 | no | the rendered plain transcript |
| `collapse` 6 | no | the collapsed stream |
| `promptEolMarks` 8 | no | pass 7 alone |
| `detect` 9 | **yes**, keyed by `pane` | the agent-state VERDICT, JSON |

**7 is RETIRED and stays unallocated.** It was `sanitize`; the passes are linked now (§3a). A
future verb takes 10, because a hostd built before the extraction would otherwise send a 7 meaning
"clean this replay" to a daemon that answers something else. `check-supervisor.sh` fails the build
if either enum allocates it again.

`hello`'s reply carries two numbers that move for different reasons. `HELLO_BANNER` —
`slopdesk-screend 1` — is the PROTOCOL identity, a ratcheted constant `check-supervisor.sh` compares
against `ScreenWire.helloBanner`; it is matched as a **prefix**, never for equality. The third field
is the version of the screend process that answered. screend is a LaunchAgent
(`scripts/install-screend.sh`) and so outlives hostd's build: after an upgrade the binary on disk
and the process on the socket are routinely different code, and this field is what tells them apart
(`docs/49`). Nothing is done about a mismatch — screend exits after `SLOPDESK_SCREEND_IDLE_EXIT`
(2 minutes) of quiet and `ScreenClient` starts the installed one on the next verb, so the stale
window closes without anybody acting.

`detect` has a verb-local payload — `u16 agentLen | agent… | bytes…` — because the agent label is
its alone and the header is shared by eight. An EMPTY label folds the bytes and skips the ladder,
which is how a pane with no agent, a TUI still inside its startup grace and a quiescent idle pane
all keep their grid warm for nothing.

`flags` carries `FLAG_RESET` (0x01) for `feed` and `detect`: rebuild the resident model before appending. A
geometry CHANGE resets implicitly — a VT grid cannot be reflowed, so a model at the wrong size is
not a model to adjust, it is the wrong model. `FLAG_REASSERT_INPUT_MODES` (0x02) makes `compose`
append the stream's net input-mode state. `detect` adds two of its own: `FLAG_REBUILD_REPLAY` (0x08) says these bytes are a
scrollback replay, so the synchronized-frame parser restarts with them (its position is a position
in a STREAM, and a rebuild hands over a different one), and `FLAG_AGENT_CHANGED` (0x10) drops the
retained OSC evidence first, so a new foreground agent cannot inherit the old one's title. All three
are separate questions: a resize resets the GRID and must not reset the parser, because the stream
did not restart. `collapse` 6 and `promptEolMarks` 8 are GEOMETRY-FREE — `rows`/`cols`
are ignored, because none of those passes has a grid width and pretending otherwise would invite a
caller to send the wrong one.

### 3a. Why `sanitize` stopped being a verb

The passes were six Swift byte machines first, so a cold reattach rebuilt a `Data` seven times in
hostd; they became one verb, so the ring crossed this socket once and came back cleaned; they are a
LINKED crate now, so it crosses nothing. Each step deleted work, and the last one deleted a class of
failure rather than a cost:

- **A round trip over the whole retained history, twice.** The ring is the input and the cleaned
  ring is the output, so the socket carried it in both directions — megabytes, per pane, on the one
  path a person is watching (a cold reattach is a person waiting at a blank pane).
- **A C function pointer back into Swift.** `ReplayBuffer` fed the Rust ring a `slopdesk_distill_fn`
  callback so the ring could reach the daemon through hostd. That callback was the only re-entrant
  edge in `slopdesk-ffi`, and it needed two `unsafe impl Send + Sync` promises about a pointer this
  repo could not check. Both are gone; the ring calls `sanitize` directly.
- **A degraded path that could arm a client's input reporting.** "screend is absent" used to mean a
  fully RAW replay: a `?1002h` recorded inside a TUI replayed verbatim until the next prompt reset
  it (the `zsh: command not found: 18M65…` shape). There is no longer a "when screend is not
  there" for replay — the passes are in the binary, so the transform either ran or the process did
  not start.

The rule that decided it is `CLAUDE.md`'s own: a socket is for a component that must outlive its
caller, be `execve`d, or be dialled by two processes. `sanitize` is a pure function of its bytes and
is none of those. The screen MODEL still is all three, which is why the daemon did not follow.

What did NOT change is the ORDER, which is the load-bearing part, and it still lives in
`sanitize.rs`: input modes FIRST, on the raw stream (the net state must be computed in true
chronological order, and the distiller reorders bytes); `PROMPT_SP` clusters LAST (every earlier
pass only improves its `133;D`/`133;A` adjacency anchor).

The remaining verbs are a protocol's two ENDS, which the one-implementation rule allows: hostd encodes a request and
decodes a reply, screend does the mirror, one implementation each. What does NOT exist twice is any
screen logic. `detection_text` used to be the sharp case — derived from `lines`, and its only
consumer the Swift manifest engine, so it was computed on the Swift side of the socket. The engine
moved, and it went with it: `detect.rs` folds `lines` into the ladder's input directly, and nothing
derives it in Swift any more.

## 4. Who calls it

| call site | verb | fallback when screend is absent |
| --- | --- | --- |
| `TerminalReplaySnapshot.compose` (cold reattach) | `compose` | replay the RAW bytes |
| `TerminalReplaySnapshot.composeTranscript` (journal restore) | `transcript` | replay the RAW bytes |
| `AgentControlListener.stripPromptEOLTail` (`last-output`) | `promptEolMarks` | the tail as captured |
| `PaneScreenScanner` (detection, ~300 ms/pane) | `detect` / `forget` | publish nothing this tick |
| ctl `screen` verb | `snapshot` | an error response |

`ScrollbackReplayTransform` (ring + journal replay) is absent from that table on purpose: it calls
`slopdesk_sanitize` in-process and has no fallback column, because there is nothing to fall back
from.

Every fallback is a PASSTHROUGH or a refusal, never a second parser. That is deliberate: a Swift
renderer standing by "just in case" is the cross-language mirror this tree forbids, and it is
exactly what this daemon was built to delete.

**The widest passthrough is gone, not narrowed.** An absent screend used to mean a fully raw
replay — see §3a for what that could arm. The four verbs left in the table degrade to a passthrough
or a refusal of something a person can see is missing (an unrendered reattach, a tick with no
detection verdict), never to a stream that changes the client's state behind their back. Every one
is still a PASSTHROUGH or a refusal and never a second parser: a Swift renderer standing by "just
in case" is the cross-language mirror this tree forbids. `scripts/check-supervisor.sh` §9 fails the
build if any of the six pass declarations reappears under `Sources/`.

**The chunk boundary is a linked rule, since stage 26.** Holding back the trailing half of an
escape sequence cut by PTY chunking (`ScrollbackReplayTransform`, `sanitize`, linked) or of a cut UTF-8
scalar (`TerminalReplaySnapshot`, `compose` / `transcript`) was the last byte machine hostd kept, on
the theory that the ring boundary is the host's own bookkeeping. It is not: every rule is read out
of the bytes — a lone `ESC`, a CSI with no final byte, an OSC with no `BEL`/`ST`, a UTF-8 lead with
fewer continuation bytes than its length promises — and none of it needs to know where the chunk
came from. Keeping it in hostd cost two real things: "append the reassert BEFORE the dangling half"
was a convention two call sites had to remember rather than an invariant of the reply, and `compose`
vs `transcript` disagree about whether the dangling half survives at all — `compose` re-attaches it
because a live tail will complete it, `transcript` DROPS it because that stream ended with the
process that wrote it. Both are now decided where the verb is. `boundary.rs` holds the rules;
§9 fails the build if `splitTrailingIncompleteEscape`, `splitTrailingIncompleteUTF8` or
`trailingEscapeScanBytes` reappears under `Sources/`.

### 4b. The detection tier — where the line is drawn

`detect` is the one verb that answers a QUESTION rather than a screen, and it exists because the
old shape was four walks of the same chunk: the grid across this socket, then the OSC tracker, the
frame parser and ~20 `NSRegularExpression`s in hostd, over a whole grid shipped back as JSON every
~300 ms per pane (≈10 KB at 50×200). Now the bytes go one way, three walks happen on this side, and
~150 bytes of verdict come back. The regexes also stopped being a hazard on the way: the manifests
match against text a foreign program drew into a PTY, and ICU backtracking on that is a liability
the `regex` crate's finite automaton does not have.

**The split is not "hot code".** It is: *screend owns everything that reads the BYTES, hostd owns
everything that reads the CLOCK.* So the rule ladder, the region resolver, the OSC tracker and the
frame parser moved; the startup grace, the working→idle hold, the blocked→idle confirmation count,
the cap on an open frame and the scan cadence did NOT — they live in `AgentDetectionHold` /
`PaneScreenScanner`, next to the timer that measures them. `Verdict` therefore reports `frameOpen`
and `frameGeneration` as FACTS and lets hostd draw the deadline. Tier 1 (hooks, ctl `report`) never
touched this path and still does not (`docs/50`).

Two consequences worth knowing:

- **hostd caches the verdict.** It is a pure function of (grid, OSC evidence, agent), so a tick that
  folds no bytes asks nothing at all. That is strictly less work than the Swift engine did — a
  quiescent WORKING pane used to re-run the whole ladder every tick against a snapshot it had
  already cached.
- **The trackers evict with the pane.** They live in this daemon's bounded registry now, so a pane
  dropped at the 256-pane cap loses its retained OSC title where the Swift trackers (in hostd, never
  evicted) would have kept it. It self-heals on the agent's next title emission, and at that cap it
  is theoretical.

A grid RESET deliberately does not reset the trackers: the title survives a resize because the agent
that emitted it is still running, and the frame parser survives because the stream did not restart.
Only `FLAG_REBUILD_REPLAY` restarts the parser, and only the caller knows which it is sending.

## 5. Absent screend is recoverable, unlike absent superd

superd holds every pane's PTY master, so losing it costs the panes. screend holds **nothing
durable** — its per-pane grids are a cache the next repaint refills. So:

- `ScreenClient` STARTS one if nothing is listening (rate-limited to one attempt per 2 s across
  every caller, waits 3 s for the bind), which superd's client deliberately does not do.
- `scripts/install-screend.sh` installs a `KeepAlive` LaunchAgent anyway, so the first cold
  reattach of the day does not pay the spawn — but it asks no confirmation, because restarting it
  costs nothing.
- A request that fails is retried ONCE on a fresh connection: the overwhelmingly likely cause is a
  pooled socket whose screend was replaced between calls. A REJECTION (`badRequest`) is not
  retried — screend answered, and asking the same malformed question again changes nothing.

## 6. Paths and env

| name | meaning |
| --- | --- |
| `SLOPDESK_SCREEND_SOCKET` | where screend binds and the client connects. Default `$TMPDIR/slopdesk-screend.sock` |
| `SLOPDESK_SCREEND_BIN` | which binary the client starts, and which one the test fixture uses |
| `SLOPDESK_SCREEND_IDLE_EXIT` | seconds screend stays up holding NO connection before exiting, default 120, `0` = never. Read by screend itself |

No pid in the socket name — the rule `scripts/check-supervisor.sh` ratchets for every socket here.
`$TMPDIR` on macOS is already per-user and `0700`, which is what makes an un-suffixed name safe.

**The idle exit is what keeps an on-demand daemon from accumulating.** The criterion is an OPEN
connection, not a recent request: a live hostd keeps pooled sockets open and is therefore never
mistaken for an idle engine, while a dead client's sockets are closed by the kernel however it died.
`swift test --parallel` gives every worker process its own private engine, so without this a single
`make test` would leave a dozen daemons alive for the rest of the machine's uptime. Losing a
resident pane grid to the exit is the same non-event as losing one to eviction — the next `feed`
rebuilds from a blank screen (`registry.rs`). The LaunchAgent sets `0`, because launchd owns that
copy's lifetime and `KeepAlive` would otherwise turn every idle period into a respawn.

## 7. Gates

| command | what it covers |
| --- | --- |
| `make screend` | build (release) |
| `make screend-test` | 364 Rust tests: 180 unit (the parser, the passes, and the ladder / regions / trackers / manifests), 42 model, 53 replay passes, 34 render, 44 overprint, 8 cross-region gate, 3 idle-exit (which run the real binary) |
| `make lint-rust` | clippy `-D warnings` + `rustfmt --check`, third workspace |
| `swift test --filter SlopDeskScreenTests` | hostd's wire end, the paths, the unavailable path |
| `make test` / `make test-touched` | both, and they BUILD screend first |

The Swift tests that drive the engine (`MuxChannelSessionSnapshotReplayTests`, the three
`PaneScreenScanner` suites, `LineOverprintCollapserTests`) go through `ScreendFixture`, which skips
BY NAME when the binary is absent rather than passing vacuously — the same discipline as
`SuperdFixture`, for the same reason.

The behaviour of the engine is pinned in Rust and only in Rust: the 300-seed render idempotence
fuzz, the 2000-stream overprint differential against the model, every VT vocabulary test, and the
deliberate herdr divergences (`tests/cross_region_gate.rs`). The Swift
suite pins the WIRE and the fallbacks, which is what a client end is answerable for.
