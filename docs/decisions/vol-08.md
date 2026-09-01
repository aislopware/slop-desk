# DECISIONS vol-08 — 2026-08-13 … 2026-08-13

> Volume 8 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The whole workspace model is Rust, and the deletion is the part that needs a decision (2026-08-13)

Stage 12, and the first outside the video path: `rust/slopdesk-workspace` — geometry, canvas, snap,
non-overlap, split tree, layout solver, focus, tab ordering, templates, send-keys, tree ops,
workspace — plus, in `rust/slopdesk-wire`, `document::topology`, `document::apply` and
`document::state_file`. That is every one of the 34 files in `Sources/SlopDeskWorkspaceModel`. 336
tests in the domain crate and 271 + 11 golden in the wire crate, `cargo clippy --all-targets -- -D
warnings` clean in both.

**The dependency arrow is wire → domain, and it deleted six enums instead of doubling them.**
`SplitAxis`, `SplitWeight`, `VideoEndpoint`, `PaneKind`, `PaneDropEdge` and `NewTabPosition` existed
in both crates the moment the domain crate did. Pointing `slopdesk-wire` at `slopdesk-workspace` —
rather than the reverse, or a shared third crate — let the codec `pub use` the domain's copies and
delete its own. The eleven golden-vector tests passing afterwards is the proof it was byte-identical.
The domain crate stays a leaf with an empty `[dependencies]`, and the wire crate's supply-chain claim
became the more precise "zero THIRD-PARTY dependencies".

**`WorkspaceIntent.swift` was already ported and nobody noticed.** The plan listed it as work; the
crate already had every encode, decode and op byte in `document::intent`. The same catch as stages 10
and 11, for the third time: the Swift directory listing is not the inventory, the crate is. What was
actually missing was one enum — the applier's outcome — and the applier itself.

**Nothing changed IS the refusal, and the applier now says so.** The tree ops answer their input
unchanged when an op cannot apply, which reads as success to a caller that only checks for an error.
`move_pane`, `dock_pane_at_tab_edge` and `break_pane_to_tab` therefore assert on the RESULT — did the
pane end up where it was asked to go — rather than re-deriving each op's preconditions. Reporting
`Applied` for a document that never moved would retire a client's optimistic patch against a state
that does not exist, which is worse than any refusal.

**JSON is in the tree now, hand-written, and that is not a crack in the manual-binary rule.** Both
persistence files are JSON: the host's document cells and the client's canvas. `serde_json` would
have been one manifest line and the first third-party dependency in a crate whose whole
supply-chain story is that it has none — to read `{"version": 1}`. `crate::json` is a parser, a
writer and a depth cap in one screen, with `BTreeMap` making Swift's `.sortedKeys` a property of the
type rather than a flag somebody has to remember. It lives in the domain crate because both files are
domain values.

**The deletion is blocked on a decision, not on work.** The rule is that porting deletes the Swift in
the same change. It cannot here: 101 source files import `SlopDeskWorkspaceModel` in process — SwiftUI
views keyed by `PaneID`, an `@MainActor` store holding a `Canvas`, `WorkspaceStore` mutating a
`TreeWorkspace` — and a port ships over a socket, never FFI. So deleting the target means the client
reads its own arrangement over the workspace channel, which is an architecture change and the user's
call. Until then the Rust is complete and unused, and this entry is the record that it is deliberate
rather than forgotten.

## Agent detection splits on the clock, not on the language (2026-08-13)

Stage 13 ports `Sources/SlopDeskAgentDetect` — nine files, 2 152 lines of pure logic with no AppKit
and no SwiftUI anywhere in it — into `rust/slopdesk-agent`: `kind`, `job`, `process`, `status`,
`signal`, `screen`, `hold`, `input` and `machine`. 110 tests, zero dependencies,
`#![forbid(unsafe_code)]`, `cargo clippy --all-targets --all-features -- -D warnings` clean.

**The line between this crate and screend is the CLOCK, not the subject.** Both are agent detection,
so the obvious move was to fold this into `slopdesk-screend` and have one detection daemon. That is
wrong: screend's job is a per-byte loop over untrusted PTY output, and everything ported here is
temporal — a done→idle decay, a post-exit lockout that measures a teardown race, a dissent watchdog
on a ten-second window, two confirmation holds counting reads. Putting a clock inside the per-byte
loop would also mean screend holding per-pane state across connections, which is the property that
lets a malformed request from one pane blank only that pane. **screend owns everything that reads
the BYTES; this crate owns everything that reads the CLOCK.** They meet at one value,
`AgentScreenDetection`.

**The state machine has no clock, and that is what makes a detection bug reproducible.** Every
time-driven rule takes an absolute `now` argument — the same discipline `slopdesk-workspace` draws
around minting ids. A pane that got stuck blocked is then a list of signals and timestamps, replayable
on any machine, rather than something that happened once on someone's laptop at 11pm.

**Three Swift behaviours only became visible once the port had to state them.** `enter` clears the
dissent stopwatch, so a hook that CHANGES the status does reset the watchdog and only a hook that
leaves the contradiction standing does not — the test now says which. `bun run codex` identifies as
`bun`, because the argv walk takes the first positional whole and `run` is nobody. And
`hook_block_overridable` (the 1 s grace) is unreachable in practice under hook coverage, because the
10 s dissent window always subsumes it; it is kept for fidelity, and the test that used to claim to
exercise it now pins what is actually reachable instead of what reads well.

**The deletion is blocked the same way stage 12 is, for the same reason.** 66 source and test files
import `SlopDeskAgentDetect` in process — SwiftUI rail rows and status dots, `WorkspaceStore`
attention state, the host's `ClaudePaneDetector` and `PaneScreenScanner` — and a port ships over a
socket, never FFI. Unlike the workspace model, most of these are HOST-side, so the socket boundary
that would free them is smaller than a whole client channel; it is still an architecture change and
the user's call. The Rust is complete and unused, and `make agent-test` is what stands between it and
a silent drift away from the Swift it was ported from.

## The replay buffer is a wire fact, not a transport one (2026-08-13)

Stage 14 ports `Sources/SlopDeskTransport/ReplayBuffer.swift` (658 lines) and its
`AltScreenCutScanner.swift` (150 lines) into `rust/slopdesk-wire` as `replay` and `altscreen` —
40 tests on top of the crate's existing 314, `cargo clippy --all-targets --all-features -- -D
warnings` clean, and the pinned golden corpus still re-encodes byte-for-byte.

**It went into `slopdesk-wire` rather than a `slopdesk-transport` of its own, because everything the
buffer decides is denominated in wire terms.** The retained unit is a `WireMessage::Output` and its
`i64` seq; the re-chunker's hard ceiling is `MuxFlowControl::max_output_frame_payload_bytes`, the
window/2 credit-progress invariant that a 32 KiB payload violates by 13 bytes. A separate crate would
have had to depend on this one for both, which is a crate boundary drawn where there is no seam. What
is genuinely transport — `NWParameters`, the `NWListener`, `NWConnection+Async`, the channel
association preamble — is Network.framework and stays Swift under the SwiftUI/AppKit exemption.

**The ring and the tail are now different types, so "acked history is never lag" is structural.** The
Swift kept one `Entry` in both arrays and documented that ring entries carry a `cumulativeBefore` of
0 by convention — a convention that is only ever read by `retainedBytes(above:)`, the fan-out's
per-ack laggard check. `RingEntry` simply has no such field. The metric cannot read the ring by
accident, and the port needed no comment to say so.

**The `messages()` primitive borrows now, where the Swift copied.** It answers `Vec<(i64, &[u8])>`
against a buffer that legitimately holds up to 256 MiB, so the control-channel snapshot path no
longer materialises the whole retained tail to look at it. That is a change in kind, not a
micro-optimisation: the copy was the reason the lag metric had to exist as a separate O(log n)
primitive in the first place.

**The deletion is blocked exactly as stages 12 and 13 are.** `MuxChannelSession`, `HostServer`,
`PaneOutputStream` and `ScrollbackJournal` hold a `ReplayBuffer` as in-process state under the
session's replay lock, and a port ships over a socket, never FFI. Freeing it means the PTY drain
itself moves — the largest remaining host-side move, and the user's call. `make wire-test` is what
stands between the Rust and a silent drift away from the Swift it was ported from.

## The client reads the byte stream too, and that is a third crate (2026-08-13)

Stage 15 ports `Sources/SlopDeskClaudeCode` — `TerminalMode.swift`, `TerminalModeTracker.swift`,
`InputDedupRing.swift` and `InputBoxModel.swift`, 702 of its 749 lines — into a new
`rust/slopdesk-terminal` workspace as `mode`, `tracker`, `dedup` and `inputbox`. 50 tests, zero
dependencies, `#![forbid(unsafe_code)]`, `cargo clippy --all-targets --all-features -- -D warnings`
clean under the same maximal-strict lint table every other workspace carries.

**Three crates now read terminal bytes, and the line between them is whose bytes and for whom.**
screend reads the HOST's PTY output to decide what an agent is doing; `slopdesk-wire` reads the same
bytes as FRAMES, to decide what to retain and re-send; this reads the host→client stream on the
CLIENT, to decide what the input surface should offer. Folding it into either of the others would
have put a client-only concern behind a host daemon's socket, or a UI affordance inside the wire
codec. Its own workspace, as always, because cargo profiles are workspace-global.

**`TerminalModeStream` was deliberately not ported.** It is an `AsyncStream` façade over the
synchronous `consume` primitive — the Rust equivalent is a channel the caller already owns, so
porting it would have shipped an opinion about the caller's concurrency runtime in a crate that has
no runtime at all. The 47 lines stay Swift and stay a wrapper.

**The `onEvent` closure became a return value.** The Swift `InputBoxModel` stored a callback the UI
installed; the Rust `ingest_output` answers `Ingested { bytes, events }`. That removes a
`Box<dyn FnMut>` — and with it the reason `InputBoxModel` could not derive `Debug` or `Clone` — and
says the same thing: the caller already has to do something with the filtered bytes, and the events
are an answer to the same chunk.

**`precondition(capacity > 0)` became "0 is raised to 1".** `panic` is denied crate-wide, so a
zero-capacity dedup ring cannot be a trap; it is a configuration mistake, and the constructor
normalises it rather than representing a state where every recorded byte is evicted on arrival.

**The deletion is blocked exactly as stages 12, 13 and 14 are.** `SlopDeskWorkspaceCore`'s input and
terminal layers hold an `InputBoxModel` as in-process SwiftUI state, and a port ships over a socket,
never FFI. `make terminal-test` is what stands between the Rust and a silent drift away from the
Swift it was ported from.

## The CLI core splits four ways, because it was never one subject (2026-08-13)

Stage 16 ports `Sources/SlopDeskCLICore` (989 lines) and the `FolderFrecency` scorer it depended on.
It is the first stage where the Swift module did NOT survive as a Rust crate: what came out is a new
`rust/slopdesk-cli` plus three additions to crates that already existed. 47 new tests, `cargo clippy
--all-targets --all-features -- -D warnings` clean everywhere, and the golden corpus unmoved.

**The split is on what each file is ABOUT, not on which binary calls it.** `SlopDeskCLICore` held
seven files whose only shared property was that `main.swift` imported them. Sorted by subject they
land in four places: the flag parser, the completion scripts, the config-file validator and the
output tables are CLI facts and went to `slopdesk-cli`; the `OSC 9;4` and `OSC 777` byte builders
went to `slopdesk-wire::osc`; the `watch:claude` exit-code machine went to `slopdesk-agent::watch`;
jump resolution and the frecency scorer went to `slopdesk-workspace`. None of the four crates gained
a dependency on another, which is the check on whether the split was real.

**The `watch` emitter and the progress parser are now one module, and the round-trip is a test.**
The Swift had `ProgressOSCParser` in `SlopDeskProtocol` and `WatchProgress` in `SlopDeskCLICore`,
two modules apart, with nothing asserting that what one wrote the other would accept. In
`slopdesk-wire::osc` they are adjacent, and `what_the_watch_wrapper_emits_is_what_the_host_parses`
walks every canonical state through both.

**`slopdesk-cli` is a MEMBER of the root workspace, like `slopdesk-ctl` and unlike the five
daemons.** The daemons left because profiles are workspace-global and a long-lived per-byte server
wants `opt-level = 3` / `panic = "unwind"`. `slopdesk` is the third short-lived program: a user
types it, it does one thing, it exits. Startup is the whole cost, and the process IS the request, so
it wants the hook's profile exactly.

**`CLIVersion.version` was deliberately NOT transliterated.** `docs/49` names six version sites and
`bump-version.sh` owns all six because no gate can see most of them; a seventh in Rust would be one
the bump script does not know about and `package-release.sh` would not catch, because that gate asks
the built CLI binary and would keep asking the Swift one. So `version::summary` takes the number as
an argument. What was worth porting is the banner's shape and the build-hash branch — the part that
had a test.

**Two Swift `precondition`/trap surfaces became total functions.** `ProgressState`'s percent clamp
and `FolderFrecency`'s age reduction both relied on Swift traps that `panic = "deny"` forbids here,
so the clamps are explicit and the tests pin the corrupt-input behaviour: a `NaN` timestamp scores
as ancient, deterministically, rather than making the sort's contract undefined.

**The deletion is blocked exactly as stages 12 through 15 are.** `Sources/slopdesk/main.swift` and
two `SlopDeskClientUI` views import `SlopDeskCLICore` in process, and a port ships over a socket,
never FFI. `make cli-test` is what stands between the Rust and a silent drift away from the Swift.

## Each protocol's client end moves INTO the daemon that speaks it (2026-08-13)

Stage 17 of the Rust migration. The three remaining pure-logic Swift surfaces were the *client* ends
of protocols whose *server* ends are already Rust — `SlopDeskFileTransfer`'s request encoder and
reply frame decoder against dropd, `ScreenProtocol`'s reply decoder against screend — plus the
host's two pre-flight decisions about a listen port.

**The client end goes in the daemon's own crate, not a client crate.** `FileTransferProtocol.swift`
+ `FileTransferCodec.swift` + `FileTransferFrameDecoder.swift` became one
`rust/slopdesk-dropd/src/client.rs`, and screend's missing client pieces became four functions in
`rust/slopdesk-screend/src/protocol.rs`. The reason is not tidiness. With both ends in one crate the
round-trip is a *test* — `what_this_end_encodes_the_other_end_decodes`, and its mirror — where in
Swift it was an agreement two files kept by review. A wire skew now fails `make dropd-test` or `make
screend-test` in the same change that introduces it, which is the property the cross-language pair
never had.

**`split_detect_payload` moved out of `server.rs` into `protocol.rs`** and became
`decode_detect_payload`, so the new `encode_detect_payload` has a partner rather than a second
implementation of the same split. The server calls the moved function; it did not gain a copy.

**`Status::from_byte` is strict, not forward-tolerant.** Every other decode in this tree degrades an
unknown value to a benign default, because a future host sending a verb we do not know is not an
error. A status byte is the opposite: it is the answer to "did my request succeed?", and guessing
`ok` for an unrecognised byte hands the caller a payload it has no reason to trust. So an unknown
status is `DecodeError::UnknownStatus`, and `DecodeError` grew that variant.

**Port validation rejects rather than clamps.** `PortValidation.swift` became
`slopdesk-workspace::listen`, and the Rust keeps the Swift's refusal semantics for a reason worth
recording: clamping mapped `-5` to `0` — an OS-assigned port nobody asked for, then persisted — and
`99999` to `65535` while the field still read `99999`. Both desync the displayed value from the
bound one. `clamped_port` exists for a caller that genuinely wants to normalise, but `port()`
answers `None` and the Start button goes dark.

**The bind-conflict classifier is digit-bounded, and that is the whole point of porting it.**
`EADDRINUSE` is `48`, and a loose substring search for `"48"` fires on the port `4843`, the errno
`148`, and the buffer size `1048576`. `contains_standalone_number` requires a non-digit on both
sides. The companion rule — that `EADDRINUSE` is the ONE errno that is fatal while a listener is
parked in the framework's retryable *waiting* state — is now `waiting_errno_is_fatal_bind_conflict`,
one line and one test instead of a comment on a `switch`.

**The error enum's `errorDescription` strings deliberately did NOT move.** They are user-facing copy
read by a Swift `LocalizedError` conformance inside the Network.framework transport. Porting the
strings would create a second place they live and no consumer for it — the drift trap the
one-implementation rule exists to prevent. Only the *classifiers* moved; the copy stayed with the
code that displays it.

**What stays Swift, and why it is not a hedge.** `FileTransferChannel` and `FileTransferClient` are
`NWConnection` — Network.framework, no Rust equivalent inside this process. `TerminalRawMode` is
`termios` plus async-signal-safe handlers installed by a Swift executable. Moving either means
porting a whole binary, not a module, and a port ships over a socket, never FFI.

**The deletion is blocked exactly as stages 12 through 16 are**, and for the same reason: the Swift
callers are in-process SwiftUI and in-process transport. `make dropd-test`, `make screend-test` and
`make workspace-test` are what stand between the Rust and a silent drift away from it.

## The grid, the blocks, and the marks that segment them (2026-08-13)

Stage 18. Four modules, split by which side of the wire reads them: the CLIENT's two reads of the
rendered grid into `slopdesk-terminal`, the HOST's read of the mark stream into `slopdesk-screend`.

**`TerminalLinkDetector` measures in CLUSTERS, and that had to be built rather than borrowed.**
Swift iterated `Character`, which is a grapheme cluster, and took the width of its first scalar.
Iterating Rust `char`s instead would count a ZWJ family emoji four times over and slide every column
after it. A segmentation crate would bring a Unicode table to answer a question five lines answer:
a cluster is a base plus any zero-width scalars, plus the scalar after a ZWJ, plus a skin-tone
modifier, plus a paired regional indicator. That covers what a terminal actually renders.

**A flag is one cluster and one cell.** The regional indicators sit at U+1F1E6..U+1F1FF, BELOW the
emoji block the width table calls wide, so `🇻🇳` measures 1. Terminals disagree with each other
here and the Swift did the same thing; what matters is that the pair is not counted twice, because
that is what would slide the columns. Pinned by a test rather than left to be rediscovered.

**Percent-decoding is all-or-nothing on purpose.** `file:///tmp/a%ZZb` decodes to nothing and the
caller falls back to the undecoded text — the same contract Foundation's `removingPercentEncoding`
has, and the reason the fallback still means "this was not percent-encoded after all" instead of
"this is half-decoded".

**The block store split from its callbacks.** `TerminalBlockModel` was a `@MainActor @Observable`
class holding both a ring and a registry of escaping closures. The ring, the bookmark FIFO, the
jump-to-failed walk and the coalescing rules are here; the closures stay in Swift, where the
surface that owns them lives. `OutputRequests` answers `Send` or `Coalesced` and gates a timeout on
a generation — so the rule that a second copy of a block cannot be killed by the first copy's parked
timer is now a test, not a comment on a dictionary.

**The segmenter's string-swallow is a security property, not a nicety.** A DCS/SOS/PM/APC body is
consumed whole, so an `ESC ] 133 ; …` inside one cannot forge a command boundary or an exit code in
someone else's transcript. The test proves it by segmenting the same bytes twice — once in the open,
where they DO produce a block, and once wrapped, where they produce nothing.

**The segmenter takes the clock as an argument.** Swift injected a `() -> Date`; here `ingest` takes
the chunk's timestamp, like `slopdesk-agent::watch` and `slopdesk-workspace::frecency` before it. A
mis-segmentation is then reproducible from a transcript plus its timestamps, with nothing to mock.

**The synthetic spinner leaves as a verdict, not a frame.** The segmenter answers
`SyntheticProgress::Indeterminate` / `Clear` and the owner builds the wire message. screend does not
depend on `slopdesk-wire`, and this is why it does not need to: the byte reader says what happened,
and the protocol stays spelled in exactly one crate.

**`AutoProgressMatcher`'s built-in list is now the only copy of itself.** The client used to hold a
display mirror behind a settings row that nothing serialised down to the host, so the two could only
ever disagree.

**Deletion is blocked as in stages 12 through 17.** `make terminal-test` and `make screend-test`
stand between these and a silent drift away from the Swift they were read from.

## What reads the bytes, and what owns the child (2026-08-13)

Stage 19 moved two things out of hostd, on two different arguments, and deleted the Swift for one
of them outright.

**The fused out-of-band sniffer → screend.** `HostOutputSniffer` was one pass over the outbound PTY
stream finding titles, bells, OSC 133 command status, OSC 7 working directories and the three
notification protocols. screend already held `commandblocks`, which walks the SAME bytes with the
same eight-state machine — the two now share `parse_exit` and `duration_ms` rather than agreeing
about what a `133;D` field means, which is exactly the agreement that rots. Two smaller calls fell
out of it. The OSC 9;4 progress body is handed UP verbatim as `SniffEvent::ProgressBody` rather than
parsed here, because `slopdesk-wire::osc` already owns that grammar and screend must not grow a
second copy of the protocol; telling progress from a notification is a shape test (`4` or `4;…`),
not a parse. And the base64 decoder for kitty's `e=1` is twenty-five hand-written lines rather than
a dependency, strict about padding and alphabet — a payload that is not well-formed goes into a
desktop alert, so half-decoding it is worse than dropping it.

**The zsh shell-integration shim → superd, and the Swift is GONE.** This one is not about bytes. The
generated `ZDOTDIR` directory is a RESOURCE whose lifetime is exactly one child's, and superd is the
only process that both knows that lifetime and outlives a hostd restart. Held in hostd it needed
three cleanup sites — spawn failure, session teardown, orphan sweep — each re-deriving the
relinquish-versus-terminate distinction of `docs/51` §5.5 on its own, and none of them ran when
hostd was killed rather than stopped. So `make host-restart`, the common case, leaked one directory
and four files per open pane, permanently.

Note the deliberate contrast with the curated ENVIRONMENT, which superd still passes through whole:
curation is POLICY, it changes often, and a superd with opinions about it would need a rebuild every
time hostd learned a variable. The shim is not policy. `SpawnRequest.shellIntegration` keeps the one
genuinely hostd-shaped judgement — an interactive login shell wants prompt machinery, a `$SHELL -c …`
pane has no prompt cycles — and superd decides whether a shim is POSSIBLE (a non-zsh, an `/etc/zshenv`
that reassigns `ZDOTDIR`, a home with no startup files) where every rejection is a log line and a
working shell. `scripts/check-supervisor.sh` now ratchets both halves: no Swift file may generate rc
files again, and the flag must stay spelled at both ends or the shim silently never installs.

Two smaller consequences. `SLOPDESK_SHELL_INTEGRATION` had to JOIN the curated allowlist — it used
to be read from hostd's own environment, and reading it in superd would otherwise have killed the
opt-out; the three flags now live in one list, `HostEnvironment.shellIntegrationEnvKeys`, since all
three are read downstream of hostd. And two orphan-recovery tests used the shim dir disappearing as
their proof that teardown ran; they now watch `teardownCompletionsForTesting`, which says what they
were actually asserting instead of inferring it from a side effect.

**`OpenQuicklyModel` was considered and NOT ported.** It is 590 lines of client picker model, and
the parts that look pure — the stable rank, the section merge, the pill ring — are called from a
keystroke handler with SwiftUI-resident data. A port ships as a separate binary over a socket, never
FFI, so porting it means an IPC hop per keystroke on the one interaction where latency IS the
feature. The rest of the file is pill labels, SF Symbol names and badge text: UI copy, which stages
17 and 18 already ruled stays in Swift. It belongs with the unresolved question of how a ported
client-side model gets deleted at all, not ahead of it.

---

## The sniffer belongs to the reader that already has the bytes (2026-08-13)

`HostOutputSniffer` was 673 lines of Swift OSC state machine running over EVERY byte of EVERY pane,
on the read-loop thread, to find six facts: title, bell, the OSC 133 command marks, cwd,
notifications and the OSC 9;4 progress body. `slopdesk-sniffbench` measured it at 614 MiB/s, and an
earlier entry (2026-08-12) used that number to decide it should stay. That decision is now void, and
the reason is not throughput.

It is that `docs/51` §6.5 had already made superd's pump the first reader of every byte. From that
point the sniffer was a SECOND pass over the same stream, in a second language, one hop later — and
two readers of one stream drift. The title coalescing anchor is state; a hostd that restarts loses
it while the shell that set the title does not. Moving the scan into `Pump::publish` costs a state
machine on a thread that already touches the byte, and buys back the copy, the hop and the second
implementation. This is the same rule the port has followed throughout, applied to the last hot
reader hostd had: one implementation, in the process that owns the data.

The design decisions worth keeping, each of which was a real choice:

- **Events precede their bytes on the wire.** A `0x04` frame is written immediately BEFORE the
  `0x03` frame it describes, under one hold of the wire lock. superd sends one only when a chunk
  contained something, so a receiver cannot wait to find out whether one is coming — it can only
  hold what it already has. Events-first is what lets `PaneOutputStream` hand a batch to `onChunk`
  WITH its own chunk, which is the pairing hostd had when it did the scan itself.
- **OSC 9;4 crosses unparsed.** The progress grammar belongs to `ProgressOSCParser`, and a second
  copy inside the byte reader is exactly the drift being removed. Telling progress from a
  notification is a shape test, not a parse, and that much superd does.
- **A reattach replays the EVENTS, not a snapshot.** `subscribe` runs a fresh sniffer over the
  backlog and puts one batch ahead of the first chunk. A restarted hostd learned a pane's title by
  re-reading the replayed ring before; it still does, and no "current truth" exists to go stale.
- **`forgetTitle` is a verb, fire-and-forget.** superd dedupes a title against the last one it
  emitted; hostd's detector is what knows an agent exited, and the next agent's opening title is
  very often byte-identical. The request sets an atomic the pump clears before its next scan, so
  losing the race costs a stale title rather than a wrong one.
- **Only a pane that asked for the shim is sniffed.** `SpawnRequest.shellIntegration` gates the scan
  as well as the shim: a `$SHELL -c …` pane and a panel backend have no prompt machinery. It is also
  what keeps the new tag inside the append-only rule — an older hostd never asks, so it never sees a
  `0x04`.

The frozen `hostOutputSniffer` golden key came with it. `rust/slopdesk-superd/tests/golden_sniffer.rs`
replays the committed vectors and asserts byte-identical FRAMES, with `slopdesk-wire` as a
DEV-dependency and nowhere else: superd does not know the protocol and must not, but a guard that
pins "these bytes produce these frames" has to know both ends, and no single crate owns both. The
Swift suites that used the sniffer as a fixture now drive the fold with explicit `[SniffedEvent]`
instead — no Swift sniffer survives as a test fake, which the one-implementation rule forbids by
name. `SupervisedSniffTests` covers the seam end to end against a real daemon and a real shell.

`CommandBlockSegmenter` is the last Swift reader of this stream and is next; `slopdesk-sniffbench`
retires with it.

🔁 **It went — 2026-08-13.** See "The block ring outlived the wrong process" below.


## The block ring outlived the wrong process (2026-08-13)

✅ **`CommandBlockSegmenter` + `CommandBlockTracker` + `AutoProgressMatcher` move into superd's pump;
the Swift originals, their suites and `slopdesk-sniffbench` are deleted.** The segmenter was the
second per-byte reader on hostd's read loop, and §6.13's argument applies to it unchanged: superd's
pump is already the first reader of every byte, so a Swift state machine over the same stream was a
second pass in a second language.

**But the deciding fact is the ring, not the scan.** `CommandBlockTracker` held every finished
command's captured output IN HOSTD, so it died on every `make host-restart` — 0.2 s during which
nothing else about the pane changed: the shell kept running, superd kept the pane, the PTY kept its
master. A client reattaching afterwards found an empty Commands panel for a shell that had never
stopped, and the only way to refill it was to run another command. That is the inspectord argument
(blast radius, not benchmarks), and it is why this was worth doing even though the measured numbers
were fine: the segmenter ran at 375 MiB/s after the `some Sequence<UInt8>` fix recorded above, and
it was never the ceiling.

The choices worth keeping:

- **A second frame tag (`0x05`), not a bigger `0x04` batch.** The two taps answer to DIFFERENT gates
  — `shellIntegration` and `blocks` — and what keeps a new tag inside the append-only rule is that
  each tag has exactly one thing to ask for. Order under one hold of the wire lock: sniff, blocks,
  bytes. An older hostd sets neither flag and sees neither frame.
- **One `now_ms()` shared by both readers.** `Pump::publish` takes the clock once, so a command's
  measured duration and a title found in the same chunk cannot disagree about when it arrived.
- **The auto-progress list crosses UNPARSED**, as `Option<String>` rather than a parsed `[String]`.
  superd owns the parse and the built-in slow-command list; hostd resolving either would put back
  the second copy the 2026-08-10 entry above removed. Unset ⇒ built-ins, empty ⇒ disabled, set ⇒
  those entries — all three still expressible.
- **`runningCommand` is a hostd-side LATCH; every other read is a verb.** `PaneLiveness.capture`
  runs for every pane on every reconciler tick and is documented as a handful of lock acquisitions,
  so a round trip there was the one read that could not be one. The `0x05` events already arrive,
  so the latch is fed from them. `blockOutput`, `blockSnapshot` and `blockControl` are verbs because
  each is a person or an agent asking once.
- **`blockControl` is ONE verb answering three questions.** The recent blocks, the running command
  and the `run --wait` baseline index are only consistent with each other if superd read them
  together; three verbs would let a command close between two of them.
- **Block output is base64 in a JSON reply, not a new binary frame.** It is a fetch a person asked
  for, capped at 256 KiB per block, so the encoded worst case sits an order of magnitude under the
  frame ceiling and every existing decode path handles it unchanged.
- **Absent ≠ empty.** A pane with no tap answers `nil` to all three reads — reported differently
  from "has run nothing yet" — while an unknown or evicted index on a tapped pane answers EMPTY.

`BlockEventDecodeTests` pins the JSON literals against `blocks.rs`'s own
`every_event_serialises_to_the_shape_the_client_decodes`, the same two-copies-of-the-same-bytes
discipline the golden corpus applies to the wire; the OSC 133 truth table went with the segmenter to
`blocks.rs`. `SupervisedBlocksTests` drives the seam end to end against a real daemon and a real
shell — including that the retained output is `one\r\n`, ONLCR and all, because a transcript superd
had tidied would be a transcript that lies. `check-supervisor.sh` gained a `blocks_revived` gate, the
`0x05` tag comparison, the spawn-flag check and a refusal of any hostd-side auto-progress parse.

With this hostd runs NO per-byte state machine on the read loop. `slopdesk-sniffbench` existed to
answer "is this path a language ceiling"; both machines it timed are gone, and it retires with them.

---

## The workbench profile is a decision about files, not about a child (2026-08-13)

✅ **The whole code-server PROFILE moves into `rust/slopdesk-codeseed`; `CodeServerManagerSeedHistory`
and `Sources/SlopDeskHost/Resources/` are deleted.** `CodeServerManager` was ~2.7k lines of Swift, and
almost none of it was about the process it supervised. It was about FILES: what a pristine
`settings.json` says, whether the one on disk is still a seed we wrote, which extension folders an
older hostd left behind, which registry entries the workbench may see, what argv and environment the
child needs. None of that wants a `HostServiceProcessHandle`, and all of it was string-building and
`JSONSerialization` — the work a language with sum types and one JSON vocabulary says in a third of
the space. What stayed in Swift is what holds the handle: `Instance`, `ensure`, the readiness probe,
the learned port, the prewarm, the lock. The file shrank 1445 → ~453 lines, its suite 1897 → ~911.

**A fork, not a socket** — the first port in this tree that is not a daemon. The rule is that a port
ships as a separate binary over a socket; the reason for the socket is a long-lived stream nobody
wants to re-establish per byte. There is no stream here. Every question is asked at most ONCE per
hostd lifetime — `launch-args`, `child-env`, `paths` and `missing-extensions` are cached in `static
let`s, `seed` runs before the first spawn — and the only repeatable one, `sync-font`, rides a verb a
client sends on connect or a preference change. `ensure`, the ~1 Hz poll, asks nothing. A daemon
holding a socket open to answer six questions a boot would be the heavier design, not the lighter one.

The choices worth keeping:

- **The refusal.** A host with no `slopdesk-codeseed` reports the code panel **unavailable** rather
  than spawning on guessed arguments. `--auth none` on a guessed port is not a degraded panel, it is
  a different program listening on a machine's network. `readProfile()` answering `nil` is what stops
  it, and it is the one failure in this port that is not a silent no-op.
- **Every other failure IS a silent no-op**, because a seed is a NICETY. No function in the crate
  returns an error; each answers whether it CHANGED something. A host that cannot write the theme
  comes up with an unthemed workbench, never with none — which is why the panic lints in its
  `Cargo.toml` are denials rather than warnings.
- **Manifests are written as TEXT, from a `format!` template — never serialized from a `Value`.** The
  file's BYTES are the upgrade signal: a manifest that differs is a re-seed. `serde_json`'s default
  `Map` is a `BTreeMap`, so serializing would alphabetize every key, and the first boot after this
  port would have looked like a change to every profile in existence. That same `BTreeMap` is what
  makes the registry comparison free: sorted-key output is exactly `.sortedKeys`, so the drift check
  reads the same on both sides. The `preserve_order` feature must stay OFF for both reasons.
- **The path resolvers take the environment as an ARGUMENT.** Sampling `std::env` would have
  reproduced a bug this code already had once — a gate-sandboxed hostd seeding the real user's
  settings while its children read the sandbox's, because the seeder asked the directory service for
  "home" instead of asking the environment. Passed in, the resolution is testable against a home
  directory the test machine does not have.
- **The obsolete-seed history came across whole** — all 32 raw strings. It is the only record of what
  a former seed looked like, and `is_pristine_former_seed` is what lets an upgrade replace a file the
  user never touched without ever replacing one they did. Dropping it would have made every old
  profile permanently un-upgradable, silently.

**Byte-identity was verified, not assumed.** The theme manifest, the bridge manifest, `extension.js`
and `alucard.json` written by the Rust seeder were diffed against the live deployed
`~/.local/share/code-server/` and came back IDENTICAL; `settings.json` differed only by the font sync
that had just run. The resources were `git mv`'d rather than copied, `resources: [.copy("Resources")]`
is gone from the manifest, and `scripts/monokai-sync.sh` now writes into the crate and cross-checks
its EXPECTED table against `extensions::THEMES` instead of a Swift array.

The seeder is deliberately NOT staged beside `hostd`: `RustServicePaths` finds it by walking up to
`rust/slopdesk-codeseed/target/`, so a `cargo clean` can never leave a stale copy behind that lies
about which profile the panel seeds. `check-supervisor.sh` §14 compares the six subcommand names as
sets from the two switches themselves — the drift here is quieter than any wire's, since a renamed
one is not a decode failure but `usage()`, a non-zero exit, and a panel that reports itself
unavailable with nothing logged — and refuses the return of any Swift seeder member or resource
bundle. 84 Rust tests carry over the design pins the Swift suite held: nothing casts, selection is a
tint and never an inversion, one light line draws the tab structure, the GPU renderer stays refused,
and Alucard still publishes `#FFFBEB`.

---

## The marker and the binary it names are one constant now (2026-08-13)

✅ **`AgentInstaller` moves into `rust/slopdesk-hook` as a second binary, `slopdesk-agenthooks`;
the Swift original and its two suites are deleted.** The install was a `settings.json` merge — read a
file the user also edits by hand, strip the entries carrying our sentinel, append one per event,
write it back sorted and pretty. Every line of it is a decision about JSON and a file, which is the
same shape as stage 22 and portable for the same reason.

**What decided the crate is the sentinel.** `hookMarker` was the string `"slopdesk-agent"`, and
`"slopdesk-agent"` is also the BASENAME the relay is installed under — which is why an installed
entry is recognisable at all. Those were two spellings of one name in two languages, and getting
them apart is silent: a marker that no longer matches the installed command turns uninstall into a
no-op and install into a duplicator, with no error anywhere and both suites still green. In Rust
`hook_path` joins `HOOK_MARKER` instead of spelling it again, so that drift is not caught — it is not
expressible. `check-supervisor.sh` §15 ratchets the construction.

**Two binaries, one crate, and the split is measured.** The relay is forked twice per tool call and
its whole cost is process startup, so its dependency list is a latency budget — the crate's manifest
has said "zero dependencies on purpose" since the relay was written. The installer needs
`serde_json`. Making it a subcommand of the relay would have put that in the relay's link graph for
an argv branch nobody on the agent's path takes; a separate crate would have put the marker back in
two places. A second `[[bin]]` in the same crate is neither. The claim was checked rather than
assumed:

| | relay binary | installer |
| --- | --- | --- |
| before | 286,272 B | — |
| `serde_json` reachable from the relay's `main` | 319,616 B, +~0.08 ms/exec | — |
| second binary (what shipped) | **286,272 B**, unchanged | 353,424 B |

Byte-for-byte identical, because nothing links what it cannot reach. §15 also refuses a `use serde…`
in the relay's own two files — the regression that would fail no build, no test and no lint, and
would just make every tool call slower.

The choices worth keeping:

- **The installer installs its SIBLING.** `install` copies the `slopdesk-hook` beside itself, found
  through `current_exe()`. The Swift version took the relay's path as an argument resolved from
  `Bundle.main`, which is one more place for a build to hand over a relay from a different version
  than the marker it was compiled against.
- **Staging survives, with a better reason.** Foundation's `copyItem` cannot overwrite, so the Swift
  copied to `<name>.staging` and then `replaceItemAt`. Rust's `fs::copy` *can* overwrite — and must
  not: the binary at that path may be mid-exec in another pane's hook this instant, and a write
  through the inode corrupts a running process. A staging copy plus one `rename` is now the whole
  step, and the two-branch "does it exist yet" fork is gone.
- **Under-reporting stayed the safe direction.** `is_installed` still means ALL of
  `INSTALLED_EVENTS`, not any — verified against the live settings file on this machine, which
  carries nine of the fourteen from an older build and correctly reports NOT installed.
- **The refusal.** A host with no `slopdesk-agenthooks` reports the hooks not installed and fails
  install rather than merging the file itself. Half an installer — one that wrote entries pointing
  at a relay it could not stage — looks installed and relays nothing.

One byte-level change, deliberate: Foundation's encoder escapes `/` as `\/` and `serde_json` does
not, so the installed command in a user's settings file is now a readable path. Both decode to the
same string, and nothing reads those bytes but a JSON parser. Everything else about the written file
— sorted keys, two-space pretty, no trailing newline — is what Foundation produced, and the entry
shape was diffed against the live `~/.claude/settings.json` before the Swift was deleted. 19 Rust
tests replace the 23 the two deleted suites held.

`slopdesk-agenthooks` is not in `scripts/package-release.sh`'s tarball, which ships `slopdesk`,
`slopdesk-hostd` and `slopdesk-ctl` — the same pre-existing gap the relay itself and every Rust
daemon sit in. Closing it is separate work touching every sidecar, not this change.


## The metadata probe forks once where it used to fork four times (2026-08-13)

`HostMetadataProbe` was the host metadata RPC's OS shim: ten `MetadataQuerying` methods answering a
pane's questions about its own cwd, its processes, its ports, its repo, its folders and its agent
transcripts. Five of the ten were subprocess and filesystem work with nothing behind them but a path,
and those five are now `rust/slopdesk-probe` — `git-status`, `git-diff`, `list-dir`,
`list-sessions`, `read-session`, one subcommand each, forked by `HostProbe` (stage 24).

**The seam is the fd, not the language.** What stayed in Swift stayed because a fork does not have
what it needs: `paneWorkingDirectory`, `processes` and `ports` are anchored to this pane's PTY master
fd (`tcgetpgrp`, `ptsname`) and to `proc_pidinfo` over every live pid, and `hostVitals` reads a CPU
baseline that has to outlive the request a fork would die with. `hostName` is one `ProcessInfo`
field and not worth a spawn. Passing a master fd across an exec to save four lines of Darwin call is
a trade nobody wants.

**Forking is cheaper here than not forking.** `gitStatus` — the verb the project-scoped
`RepoStatusWatcher` polls on a cadence, the dominant traffic on this RPC — forked `git` FOUR times
per request from hostd's own metadata queue: `status --porcelain -b`, `remote get-url origin`,
`rev-parse --show-toplevel`, `stash list`. It is now ONE spawn from hostd, which makes those four
inside itself. The other four verbs each ride a person: a folder someone expanded, a diff someone
opened, a session list someone asked for.

**What this actually bought: the parsing became testable.** The whole file carried the hang-safety
rule — a real `Process` on a live PTY may not be spun in a unit test — so the porcelain header
parser, the `XY` status packing, the Claude project-slug convention and the three-base diff ladder
were *compiled and code-reviewed only*, with a handful of pure helpers promoted to `internal` so a
test could reach them at all. In Rust they are ordinary functions over strings with the process
boundary at the edge: 42 tests, including the porcelain cap, the rename-vs-arrow-in-a-filename case,
the whole nibble table against its client inverse, and every session-root confinement refusal.

**A latent bug came out of the port.** `claudeProjectSlug` mapped Swift `Character`s — grapheme
clusters — to dashes, but the producer is Claude Code's JavaScript `replace(/[^a-zA-Z0-9]/g, '-')`,
which runs per UTF-16 code unit. For any astral character the Swift wrote ONE dash where Claude Code
writes two, so a project whose path contained one had sessions that were silently undiscoverable.
ASCII is identical either way, which is why nobody saw it. The Rust uses `encode_utf16()` and a test
pins `"😀"` → `"--"`.

**Empty is an answer; missing is an exit code.** Two subcommands reply in raw bytes, because their
answer IS bytes — a patch or a transcript, up to 15 MiB, that hostd forwards into an opaque payload
without looking inside. Wrapping those in JSON would escape every byte on the way out and unescape it
on the way in to move a blob neither side reads. So "nothing there" cannot be an empty reply (an
unchanged file has an empty diff) and is exit 3 instead. `check-supervisor.sh` §16 pins `askBytes`
against the tidy-up that writes `data.isEmpty ? nil : data` and turns every unchanged file into a
`.notFound`.

The reads stay bounded at the SOURCE, as before: at most `cap + 1` bytes, so the builder's
`cappedOpaque()` still trims an already-bounded tail and its truncation signal survives. Verified on
this machine — a 15 MiB session transcript comes back as exactly 15,728,641 bytes. The one
subprocess left in Swift is `lsof`, and its drain keeps the same budgeted loop for the same reason.

`slopdesk-probe` is not in `scripts/package-release.sh`'s tarball, which ships `slopdesk`,
`slopdesk-hostd` and `slopdesk-ctl` — the same pre-existing gap the relay, the installer, the seeder
and every Rust daemon sit in. Closing it is separate work touching every sidecar, not this change.


## The TERM decision is about two strings, not about an enum (2026-08-13)

`TerminfoResolver` decided which `TERM` to advertise into a spawned PTY: keep `xterm-ghostty` when
the host can resolve the entry, fall back to `xterm-256color` when it cannot (Ghostty #54700). The
search order, both on-disk layouts, the `infocmp` authority and the decision table are now
`rust/slopdesk-probe`'s sixth subcommand (stage 25). It joined the probe rather than getting its own
binary for the obvious reason: it is one `stat` sweep and one subprocess, asked about the machine
hostd is running on, which is what that program is.

**The fallback became a parameter, and that is the design change.** The Swift resolver's decision was
written in terms of `ClaudeCodeProfile.Term` — a two-case enum it had to agree with. The probe is
handed two names and knows neither: `terminfo --requested T --fallback F` answers
`{"term": …, "fellBack": …}`, and "a request that IS the fallback is authoritative" replaces the
special case for `.xterm256` without naming it. hostd maps the answer back to its enum and owns which
two names it sends. One fewer thing spelled in two languages.

**What is left in Swift is the degradation, and it is the interesting half.** A host with no probe
cannot check whether the entry exists, so advertising it would be a guess — and guessing wrong is
every TUI app on that host starting broken. `resolve` answers the fallback AND reports `fellBack:
true`, which is what puts it in the one diagnostic the operator gets. Under-reporting it would leave
a silently degraded terminal with nothing in the log.

**`explicitOverride` stayed an unused parameter, deliberately.** A `.ghostty` request must
auto-fall back on a host that cannot resolve it whether it was chosen or defaulted; an explicit
`.xterm256` already wins by BEING the fallback. The parameter keeps the override semantics visible at
the call site and gives a future "force ghostty even if unresolvable" lever a home.

Fourteen Rust tests replace the fifteen the deleted Swift suite held, over the same conventions: the
ncurses search order, the empty `$TERMINFO_DIRS` element that must not become a search of `/`, a
`$HOME` with a trailing slash, a relative directory that must stay relative, and both the `x/` and
the `78/` layouts — the hex one is what macOS's ncurses writes, and checking only the letter one
reports "unresolvable" on a machine that resolves it perfectly well. Three Swift tests remain for the
two paths that reach an answer without the probe saying anything; neither spawns.

The `--xterm256` short-circuit is now in both places on purpose: the probe returns before it stats
anything, and hostd returns before it forks. The second one is not redundancy, it is the fork it
saves.


## The chunk boundary is read out of the bytes, so it belongs to screend (2026-08-13)

Two functions survived every earlier screend stage on one shared claim: that holding back the
trailing half of a chunk-cut sequence is the HOST's bookkeeping, because the host is the one that
cut the chunk. `ScrollbackReplayTransform.splitTrailingIncompleteEscape` guarded escape sequences on
the ring/tail seam; `TerminalReplaySnapshot.splitTrailingIncompleteUTF8` guarded multi-byte scalars
on the same seam. Both pre-split, called screend with the head, and re-attached the tail themselves.

Reading them says otherwise. Neither takes an offset, a sequence number or a ring position; both scan
backwards over at most a few KiB and decide from the bytes alone — a lone `ESC`, a CSI or DCS/APC/PM
opener with no final byte, an OSC with no `BEL`/`ST`, a UTF-8 lead byte followed by fewer
continuation bytes than its length promises. "The host knows where the edge is" was never load-
bearing; the bytes carry it.

What the split location DID cost was real. The reassert ordering — `sanitize`'s re-armed input modes
must land BEFORE the dangling half, never between it and the live tail's continuation bytes, or the
split sequence aborts and the continuation prints as literal text — was a convention two call sites
had to remember, enforced by a test in hostd over a rule implemented in Rust. Now it is an invariant
of the reply: `sanitize` appends the dangling half after everything, including the reassert, and
there is no ordering left to get wrong at the call site.

And the two compose verbs genuinely disagree about the dangling half, which is the clearest sign it
belongs with the verb. `compose` re-attaches it: the stream is a live pane's history and the
un-acked tail will complete it within milliseconds. `transcript` DROPS it: that stream ended with the
process that wrote it, the continuation bytes do not exist and never will, so emitting a half-open
CSI into a fresh shell hands it a sequence that will swallow the next thing the user types. In Swift
that difference lived in two call sites' comments; in `boundary.rs` it lives in the two verbs.

`ScrollbackReplayTransform` is now one `sanitize` call and an env flag; `TerminalReplaySnapshot` is
two calls and a `?? raw`. Thirteen Rust tests replace the Swift ones, including the round-trip
property that the two halves always reconstruct the input — which is the whole safety claim, and was
never asserted in Swift. `check-supervisor.sh` §9 fails the build if either function name or
`trailingEscapeScanBytes` reappears under `Sources/`.

## The journal moves to superd after all, because the objection that stopped it was about a pane (2026-08-13)

Reverses **"The scrollback journal stays in hostd; its resume point becomes crash-exact"**
(2026-08-12), above. That entry rejected moving the disk journal into superd on one reading, and the
reading was wrong.

The objection: the journal "is keyed by the **client session UUID**. superd is keyed by **pane id**,
and its panes die with the machine. After a reboot superd has no pane to hang that transcript on, so
the archive would have nowhere to live." Every clause is true and the conclusion does not follow.
The archive does not live in superd; it lives in a **file**, and it always did. What the entry
actually established is that the *lookup* cannot go through superd's pane table — so it doesn't.
`journal_info`, `journal_delete` and `journal_sweep` take a directory and a session id and touch the
filesystem; not one of them consults the registry. They answer for a session whose pane died with
the machine exactly as they answer for a live one, which is the same thing hostd's own store did
with the same `<uuid>.scrollback` path. A daemon that dies with the machine can write a file that
outlives it, because that is what files are for.

The second objection has expired rather than been refuted: journal compaction must not cut inside an
open alt-screen segment, and in 2026-08-12 that scanner existed only in Swift, so superd would have
needed a second copy in Rust. It has existed in Rust since stage 14. Stage 27 lifted it into
`rust/slopdesk-altscreen`, a dependency-free crate both consumers share — superd's `journal` and the
wire crate's `replay` — so the move needed no new implementation of anything. (The Swift
`AltScreenCutScanner`/`ReplayBuffer` pair is still live under the in-process mux; that duplication
predates this stage and is tracked with the rest of the ported-but-not-deleted Swift, not created
here.)

**What the move deletes is the entire class of problem the 08-12 entry then had to solve in place.**
That entry's own fix was a `<uuid>.scrollback.resume` sidecar, a `spawnedAt` pane-life stamp on it,
a 250 ms re-claim on the flush path so a killed hostd still left a boundary, and a documented rule
about which of two non-atomic writes was allowed to be stale. All four exist only because *one
process was journaling another process's stream*. With superd doing both, "how much of the stream is
on disk" is `JournalStore::head` — a field advanced under the same lock that appends the bytes, so
it cannot lag them, returned by `journal_info`. No sidecar, no stamp, no cadence, no trade. A `head`
that could be stale would belong to a pane superd had forgotten, and superd forgetting a pane means
superd died, which takes every pane with it.

The split that remains is writing vs policy, and it falls where ownership does. superd decides
nothing: it writes where it is told, caps at the number it is given, and sweeps with the age and
count that ride in on every `journal_sweep` call. hostd keeps the directory, the cap, whether a pane
is journaled at all (`SpawnRequest.journal`, absent for the zero session sentinel and for panel
backends), which end of life deletes (deliberate close only — a link drop, a TTL eviction and a
daemon stop all keep the file), and what the bytes MEAN: `ScrollbackTranscripts` renders them
through the snapshot composer or the distiller, next to the reattach path that answers the same
question. Two things had to move with the writer for correctness rather than tidiness: the delete,
because superd may still hold the file open and an unlink under an open writer is a pane journaling
the rest of its life into an unreachable inode; and the sweep, because "which file is a live pane
still writing" is the one thing a sweep must not get wrong and only the writer knows it.

`ScrollbackJournal.swift` (732 lines) is gone; `ScrollbackTranscripts.swift` (200) is what replaced
it, and none of it touches a file descriptor. `MuxChannelSession` lost its journal property, its two
`recordWindowSize` calls (superd stamps the geometry from the same `spawn`/`resize` requests that
reach the kernel) and `recordResumePointForTheNextDaemon` entirely — `relinquish()` now stops the
stream and tears down. superd gained `journal.rs`: one writer thread for all panes, appends that are
a `memcpy` under an uncontended mutex on the pump thread so no `write(2)` ever lands on the PTY
reader, and 13 tests. Protocol minor 7.

## The FFI ban was never the user's rule, and it is gone (2026-08-13, user-directed)

`CLAUDE.md`'s porting rule read *"A port ships as a separate binary over a socket, never FFI — no
foreign build system in the `swift build` graph."* The user removed the first half today, with the
correction that matters most about it: *"bạn tự thêm rule cấm vào chứ tôi không cấm"* — the ban was
written by the assistant during this migration, not handed down. `git log -S 'never FFI' --
CLAUDE.md` returns nothing: the line exists only in this migration's uncommitted working tree. It
had never been a project invariant; it had been a working preference that then got cited as an
invariant, including by the uniffi review above, which is exactly the failure mode a rule file is
supposed to prevent.

**What was actually load-bearing, and stays.** Not "never FFI" — *cargo never runs inside
`swift build`*. That is what keeps a clean checkout building and `swift test` running headless
without a Rust toolchain, and it is satisfied by a prebuilt artifact just as well as by a socket.
The tree already proves it: `ThirdParty/ghostty/libghostty.xcframework` ships `ios-arm64`,
`ios-arm64-simulator` and `macos-arm64` slices built by Zig, is linked into both app targets by
XcodeGen (`Apps/ClientApp-iOS/project.yml:53`, `embed: true`), and `Package.swift` never mentions
it — the files needing `import CGhostty` are deliberately not members of any SwiftPM target. A Rust
`.xcframework` would occupy the identical slot. `CSlopDeskSIMD`, a C NEON kernel linked straight into
the client, has always been the same shape and nobody ever called it controversial.

**So the rule is now about lifetime, not mechanism.** A component that must outlive its caller
(`superd`), be `execve`d (`slopdesk-hook`), or be dialled by two unrelated processes (`screend`,
`dropd`, `inspectord`, `androidd`) is a binary on a socket — the table in the uniffi entry above is
still correct and none of it was about FFI being forbidden. A component that is in-process by
necessity and lifetime-coupled to its caller may be a linked library.

**What this unblocks, and what it does not.** Three modules are currently implemented twice —
`SlopDeskWorkspaceModel` ↔ `slopdesk-workspace`, `SlopDeskAgentDetect` ↔ `slopdesk-agent`,
`ReplayBuffer`/`AltScreenCutScanner` ↔ `slopdesk-wire::replay`/`slopdesk-altscreen`. Every one is
consumed in-process by `SlopDeskClientUI`, so the socket shape could never reach them, and the iOS
client cannot host a sidecar daemon at all. They are the first candidates the 08-12 review never
looked at, because that review enumerated the six daemons and stopped there.

It does not, by itself, decide that they move. The old reopen clause demanded a *measured ceiling*,
and these have none — they are not slow. The justification here is the other rule, the one the user
did write: **one implementation, never two languages.** That is a different argument and it has to be
made on its own evidence, which is why the next step is a spike (per-slice binary size on iOS,
whether uniffi can express the workspace model's tree-ops surface, added CI time) rather than a
port. `docs/DECISIONS.md` line 38 has listed "iOS XCFramework binary size" as an owed spike since
the very first planning round.

One cost is real and unchanged from the note in the uniffi entry: a `binaryTarget` holding our OWN
source as a committed or checksum-fetched blob is not the same as pinning a third party's, and it
has to be rebuilt on every Rust change. That is the thing the spike has to price, not wish away.

## The `.xcframework` spike came back cheap, and the boundary is bytes, not bindings (2026-08-13)

Measured, not argued. `rust/slopdesk-workspace` (14,287 lines) was built as a `staticlib` behind a
scratch crate that pins ~40 of its public entry points in a `#[used]` table, so `-dead_strip` and
thin-LTO keep the surface a real binding would keep, then linked against a one-line C `main` on each
Apple slice. Profile: `opt-level = 3`, `lto = "thin"`, `codegen-units = 1`, `panic = "abort"`,
`strip = "symbols"`.

| | added to the linked binary |
| --- | --- |
| `aarch64-apple-darwin` | `__TEXT` +376,832 B · file +574,416 B |
| `aarch64-apple-ios` | file +570,176 B |
| `aarch64-apple-ios-sim` | file +574,704 B |

**≈560 KB per slice, and there is no fixed Rust tax hiding in it.** A `staticlib` containing nothing
but one `extern "C" fn` links in at **+48 bytes** over the C-only baseline (16,888 vs 16,840), so the
560 KB is the domain code plus exactly the `std` it reaches — not a runtime that would be amortised
by a second crate. The `.a` on disk is 6.2 MB per slice; that number is meaningless, the linker
discards nearly all of it.

Against that sits **9,742 lines of Swift deleted** (`Sources/SlopDeskWorkspaceModel`), which is not
free in the app today either. The net is smaller than 560 KB and was not measured, because measuring
it means doing the port.

**CI: +18 s.** A clean release build of all three slices, LTO and one codegen unit, is 17.9 s wall.

**uniffi is the wrong question.** The crate's surface is not value-in/value-out: `separate`,
`make_space`, `successor_after_close` and `bucketed_by_project` are generic over the caller's id type
or take an `impl Fn`, and `normalizing_active(&self, mint: &mut impl IdSource) -> Self` threads a
mutable id source through. None of those can be named as a function pointer, let alone described in a
UDL. But they do not need to be: the document already has a byte form on both sides — `persist.rs`
encodes it and `slopdesk-wire::workspace` already carries the intent envelope over the socket. The
FFI shape is therefore `(doc bytes, intent bytes) → doc bytes`, one entry point, no generated
bindings and no object model crossing the boundary.

**One structural consequence.** `slopdesk-workspace` is `unsafe_code = "forbid"`, and `forbid` cannot
be lifted downstream — that is the point of choosing it over `deny`. `#[unsafe(no_mangle)]` therefore
cannot live in that crate, so the shim is a separate crate that depends on it. That is the right
shape anyway: the domain stays unable to leave safety, and the one place that must is small enough to
read in a sitting.

## Every `unsafe` moves to one crate, because `deny` was never the guarantee it read as (2026-08-13)

Prompted by the user in as many words: *"tách ra những crates unsafe riêng để cô lập tối đa unsafe
code đi"*. The audit that followed found the surface is smaller than the file layout suggested — all
of it, five sites, was in `slopdesk-superd`. Twelve crates already had zero `unsafe`; four of them
were nonetheless sitting at `deny`.

**The defect was `deny` itself.** superd's manifest said the exemption was one module, `spawn.rs`,
and that was true about intent. It was false about effect: `deny` is liftable by a single `#[allow]`
anywhere in the crate, so the process holding every live pane's master fd was one attribute away
from unsafety in any of its eleven thousand lines, with nothing to say so. `forbid` cannot be lifted
downstream — that is the entire difference, and it is why the fix is a crate boundary rather than a
comment.

`rust/slopdesk-posix` now holds the `fork`/`execve` window, `SCM_RIGHTS` adoption, the `fcntl` flag
helpers, `setsockopt` and the `SIGPIPE` disposition. Every other crate in the tree is
`forbid(unsafe_code)`, superd included. `slopdesk-posix` itself stays at `deny`, deliberately:
`forbid` there would make the per-site `#[expect(unsafe_code, reason = …)]` impossible, and those
exemptions are the point — each one is argued, and an `#[expect]` that stops being needed fails the
build.

**Two sites turned out not to need the crate at all**, which is what applying the admission test
rather than moving files mechanically bought: `pump`'s `BorrowedFd` helper was working around an
import collision (`OwnedFd` already implements `AsFd`), and `frame`'s existed only because that
module's API took raw integers — it takes `BorrowedFd<'_>` now, and the helper vanished with the
reason for it.

**Two shapes were rejected.** A `posix::fork()` primitive: `fork(2)` is always sound to call and
what is unsound is the window afterwards, so the primitive would hand its caller an obligation
covering instructions the *compiler* emits — undischargeable by anyone writing Rust. And a
`posix::adopt(RawFd) -> OwnedFd`: the proof that a descriptor is unowned exists only in the
instruction after `recvmsg` returns, so a safe signature would be a lie and an `unsafe fn` would
push the obligation straight back where it came from. `fdpass::recv_tagged` does the receive and the
adoption together instead, and the raw integer is never visible.

**`docs/51` §6.9 became a compiler error.** `TIOCSWINSZ` is hostd's alone, but superd's tests must
stand in for hostd to check the `resize` verb records a truthful size. The setter is behind a
`winsize-set` feature superd enables only in `[dev-dependencies]`, so `cargo build --release` does
not compile it and a production caller fails to link.

Gated in `scripts/check-supervisor.sh` against the MANIFESTS, not the source: rustc enforces
`forbid` per crate already, and what it cannot notice is a new crate spelling `deny` or stating no
policy at all. Both gates were verified to fire against planted files.

## The FFI boundary is a crate with one convention, and the artifact is gitignored (2026-08-13)

Three Swift modules were still implemented twice — in Swift and in Rust — because the Rust had no
way to reach an in-process Swift caller. A daemon was not available to them: the iOS client cannot
host a sidecar at all, and scrollback eviction runs inside the retainer on the output path. So the
port is linked, and stage 29 built the mechanism and proved it on the smallest of the three pairs:
`AltScreenCutScanner`'s 150 lines of Swift scanner are now a wrapper over
`slopdesk_altscreen_reopen`, and that module's existing tests — unchanged, same public signature —
pass against the Rust. `docs/55-ffi-boundary.md` is the reference.

**Committing the artifact was measured and rejected.** 5.7 MB per slice, 17 MB for three, rewritten
by every Rust edit. What the app pays is +384 KB linked after `-dead_strip`, so the runtime cost was
never the question — the git history was. It is gitignored and built by `scripts/build-ffi.sh`,
following `libghostty.xcframework`.

**It is in the SwiftPM graph anyway, unlike libghostty**, and that is a real cost accepted for a
real reason: a clean checkout must run `make ffi` once. The reason is the one-implementation rule.
Rust that `swift test` cannot reach would leave the Swift version as the thing actually under test,
so "delete the original in the same change" would be unverifiable. cargo still never runs inside
`swift build`.

**cbindgen was rejected**: it would have to run either inside `swift build` (forbidden) or in a step
that can silently not have run. The header is written by hand and `build-ffi.sh` checks every symbol
it declares against every assembled slice, so header drift fails the build, not the app.

**One convention for every entry point**, so there is no per-function ABI to get wrong: `(ptr, len)`
inputs, a `(out, cap)` output, return = bytes needed, `0` = None, `n > cap` = nothing written, retry.
No allocation crosses the boundary, so there is no free function and no leak that could be a
Swift-side mistake. This is affordable only because every wrapped function is pure; a stateful entry
point needs a different convention and that is a decision, not a patch.

**The stale-artifact failure mode is the one a socket port does not have.** A daemon either answers
or does not; a linked archive can be last week's logic with every test green. `sources.sha256` is
written last, hashes every input crate, and `build-ffi.sh --check` runs inside
`scripts/check-supervisor.sh`, so `make lint` fails on a stale artifact.

`extern "C"` is gated to `rust/slopdesk-ffi` alone — a C entry point inside a domain crate would put
pointer marshalling next to the logic it marshals and force that crate off `forbid(unsafe_code)`.
That makes two isolated-unsafe crates, and only two: posix argues about syscalls, ffi argues about
pointer liveness. A third would dissolve the isolation.

## The replay buffer crosses as a handle, and the cold-reattach cost is recorded, not hidden (2026-08-13)

Stage 30 deleted the second implementation of `ReplayBuffer` — 658 lines of Swift keeping the same
invariants as `rust/slopdesk-wire`'s `replay::ReplayBuffer` in the same repository. The 48
`ReplayBufferTests` are unchanged and now exercise the Rust through the C ABI.

**A socket was never available to it.** Appending happens per PTY chunk and the `should_pause_drain`
answer after that append is what stops the host reading the master; a round trip there is not a
design, it is a stall. **And the pure convention was not available either**, because the buffer is
not a function — it holds up to 256 MiB. So `docs/55` gained §4b: Rust owns the object, Swift holds
an opaque token, and answers still come back through `(out, cap) -> needed`, so "nothing is
allocated on one side and freed on the other" survives. Producers fill one of three slots on the
handle and the caller reads items out one at a time, which keeps peak memory at one message instead
of a second copy of the whole replay. A THIRD convention would be a design change, not a patch.

**The Swift type became a reference type**, which is the one semantic change. Nothing relied on
copying it — the owning session holds exactly one under `replayLock` — and a silent copy of a
256 MiB buffer was never something anyone meant to write. The lock is now load-bearing for a second
reason: overlapping calls on one handle are aliasing UB, not a lost update.

**Measured, against the implementation being deleted** (release, 32 KiB chunks, 64 MiB ring): append
+ ack over 640 MiB is 446 ms vs 531 ms — Rust FASTER; the per-ack lag probe is at parity; a warm
reconnect costs +8 µs; a cold reattach costs **+30 ms**. That last one is a real regression and is
recorded as one. It is one memcpy of the history through the distiller callback each way plus one
out of the message slot, and it sits inside an operation whose compose step renders 64 MiB at a
measured 17.9 MiB/s — 3.5 s. 0.85%.

**The fix is to delete the callback, not to optimise it.** `sanitize` is a library function in
`rust/slopdesk-screend`; linking it into the shim removes both memcpys AND the 64 MiB AF_UNIX round
trip that BOTH implementations pay today, putting the cold path ahead of the Swift original. Held
back because it also removes screend's absent-engine identity policy and grows the artifact.

The A/B benchmark that produced these numbers was scratch and is deliberately NOT in the tree: it
had to hold the deleted Swift buffer to compare against, which is precisely the cross-language
mirror fixture the one-implementation rule forbids. Re-create it from git history when a follow-up
needs the number again.

## Agent detection crosses as a vocabulary plus a rule set, not as one or the other (2026-08-13)

The third and last double implementation. `Sources/SlopDeskAgentDetect` (2,152 lines, nine files)
mirrored `rust/slopdesk-agent` (4,637 lines, eleven modules) one-for-one, and unlike the replay
buffer it could not simply become a handle: a pane's status is an `enum` a SwiftUI `switch` reads,
so something had to stay in Swift.

**The line, which is now gated rather than argued.** The CASE LIST stays — `AgentKind`,
`ClaudeStatus`, `AgentScreenState`, `ClaudeSignal`, `ClaudeHookEvent`. Declaring the same cases in
two type systems is one vocabulary, not two implementations, and marshalling an enum through C buys
nothing. Every TABLE and every WALK moved: the alias table, the wrapper basenames, the keystroke
classes, the rollup rank (`ClaudeStatus.urgency` looks like a property and is really the total order
the wire depends on), the display labels, the temporal hold's counters, the job-identify ladder, the
900-line status machine. A one-line identity predicate like `isBlocked` stays, because routing
`self == .needsPermission` through C would add a boundary crossing to restate the case list.

What crosses is therefore a DISCRIMINANT, which makes the case lists a cross-language contract:
`check-supervisor.sh` compares the Swift case counts against `AgentKind::ALL` and
`ClaudeStatus::ALL`, so a reordered enum fails the build instead of reporting `working` for
`blocked`.

**Two ABI shapes were added, both to avoid unreadable Swift.** A hook event carries up to six
optional strings; six `(ptr, len)` pairs would be six nested `withUnsafeBytes` per call, so they ride
in ONE buffer as bounds-checked `(offset, len, present)` spans. And a foreground job — a pgid plus N
processes, each with three optional strings and a whole argv — is STAGED on a handle
(`push_process` / `push_argv` / `identify` / read the answer slot), the same shape the replay
buffer's input slot already uses.

**It found a live bug, which is the argument for having done it.** `process::basename` used
`rsplit('/').next()` where the Swift used `split(separator:).last`, so `/usr/local/bin/claude/`
answered NOT-claude in Rust and claude in Swift. The two had disagreed since the port and neither
side could see it, because neither ran the other's tests. One function now, with the Swift test's
own case pinned to it.

Cost: 2,152 Swift lines → 1,236, of which ~260 is marshalling. The 135 tests in
`SlopDeskAgentDetectTests` are unchanged and now exercise the crate.

**Also fixed here, and it was a latent version of the failure `docs/55` §3 exists to prevent:**
`INPUT_CRATES` in `build-ffi.sh` still listed only `slopdesk-ffi` and `slopdesk-altscreen`, so the
staleness stamp had been blind to `slopdesk-wire` since stage 30. Both it and `slopdesk-agent` are
listed now.
