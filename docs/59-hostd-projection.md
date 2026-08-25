# 59 — Dissolving `MuxChannelSession` and `HostServer`

`Sources/SlopDeskHost/MuxChannelSession.swift` (4,665 lines) and `Sources/SlopDeskHost/HostServer.swift`
(3,221) are 15% of the non-UI Swift that has no Rust door. They do not yield to the rule-table port
that moved the workspace store's decisions — they are socket and session machinery. This is the
boundary redesign `CLAUDE.md` asks for when non-UI Swift "cannot port": the coupling is evidence the
boundary is wrong, not a reason to leave the logic in Swift.

## 1. What is already ported — do not re-port

Most of what LOOKS portable in these two files already moved and already has a face.

| Swift face | Rust owner |
| --- | --- |
| `Sources/SlopDeskTransport/ReplayBuffer.swift` (441) | `rust/slopdesk-wire/src/replay.rs` (1,801) |
| `Sources/SlopDeskHost/PaneResizeFold.swift` (173) | `rust/slopdesk-muxsession/src/resize_fold.rs`, doors in `rust/slopdesk-ffi/src/mux_resize.rs` |
| `Sources/SlopDeskProtocol/Mux/MuxFlowControl.swift` — every capacity is `slopdesk_mux_flow_constant(n)` | `rust/slopdesk-wire/src/mux/flow.rs` |
| `Sources/SlopDeskProtocol/Mux/ChannelTable.swift`, `Sources/SlopDeskTransport/Mux/MuxRoutingCore.swift` | `mux/channels.rs` via `slopdesk_channel_table_route` |
| `Sources/SlopDeskSupervisor/*` | `rust/slopdesk-superwire` |
| `ClaudePaneDetector`, `ProjectKey`, `MetadataResponseBuilder` | `slopdesk-agent`, `slopdesk-git::project_key`, the ffi metadata doors |

The flow-control numbers are single-sourced through doors already. Know that before "porting the
constants".

## 2. The finding — the same PTY bytes are buffered four times, and hostd owns two

1. **superd's `OutputRing`** — `rust/slopdesk-superd/src/ring.rs`. 4 MiB, addressed by ABSOLUTE
   OFFSETS, eviction ANNOUNCED through the subscribe reply as `Resume { start, head, bytes }` with
   `is_lossy(requested)`. Drained continuously by `pump.rs` for the pane's whole life, attached or not.
2. **superd's on-disk journal** — `rust/slopdesk-superd/src/journal.rs`, answered over `journalInfo`
   (docs/51 §6.8). The durable copy. hostd already reads it (`HostServer.swift:1085`, `:2099`).
3. **hostd's `ReplayBuffer`** — `MuxChannelSession.swift:518`. Up to 256 MiB, SEQ-addressed.
   Legitimate: keyed by wire seq, not byte offset, and it is what makes `hello.lastReceivedSeq`
   resume byte-exact. Rust already owns it.
4. **hostd's `outFIFO`** — `MuxChannelSession.swift:559`, with `fifoHead` at `:569`. 64 KiB attached,
   **64 MiB detached** (`MuxFlowControl.detachedHostQueueCapacityBytes`, applied at `:4366`).

Copy #4 should not exist, and an entire Swift subsystem exists only to manage it:
`compactDetachedBacklogForColdClient()` `:685-714` · `scheduleDetachedRingFold()` `:2018` ·
`spliceFoldedRing(_:from:)` `:2038` · `pendingDetachedBacklogBytes()` `:2059` ·
`peekDetachedBacklog()` `:2071` · `consumeDetachedBacklog(_:)` `:2089` and `DetachedBacklogPeek` ·
the detached branch of `applyQueueCapacityForPopulation()` `:4364-4380` · `detach`'s fold trigger
`:1678-1686` · `rebindRelay`'s `transformDetachedBacklog` branch `:1799` · the warm/cold threshold
arithmetic in `admitJoiner` `:1966`, `:1976`, `:1997`.

superd's ring IS this buffer, one process away, with two properties hostd's FIFO does not have:
absolute-offset addressing and announced lossy eviction. The fold itself is already Rust —
`ReplayBuffer.RingFoldSource` is a `slopdesk-wire` compose. What Swift contributes is a VERDICT
("warm or cold; splice raw or compose-fold") wrapped in 350 lines of buffer bookkeeping.

**The honest retention delta.** The detached FIFO is 64 MiB; the ring is 4 MiB. For a COLD returning
client the FIFO is pure duplication — `HostServer.swift:2099` already gates on
`open.lastReceivedSeq == 0` and serves the journal. For a WARM client the FIFO covers 4–64 MiB of
detached output the ring would have evicted. Step 1 either raises `SLOPDESK_PANE_RING_BYTES` to make
the ring the retention contract, or accepts an announced lossy resume in that window. Either way it
is a decision recorded in `docs/DECISIONS.md`, not a silent regression.

## 3. Socket or linked library — linked library, both files

`CLAUDE.md`: *a component that must outlive its caller, be `execve`d, or be dialled by two processes
is a binary on a socket; one that is in-process by necessity and lifetime-coupled to its caller is an
`.xcframework`.* All three socket triggers fail here.

- **Must outlive its caller.** Every part of this subsystem that must has ALREADY moved, and moved to
  a socket — that is what superd is. `PaneOutputStream.swift`'s header records why: `PTYReadLoop` was
  a blocking `read()` in this process, nobody read the fd between hostd's exit and the next hostd's
  `adopt`, and the agent froze. What is LEFT in `MuxChannelSession` is precisely the state that must
  NOT outlive hostd: `Subscriber`'s three `Task`s (`:78-154`), the `MuxSubChannel` pair over live
  `NWConnection`s, the `ReplayBuffer` keyed to THIS hostd's seq space, the `PaneResizeFold`'s
  contributor map keyed by THIS hostd's subscriber ids. On restart each is correctly destroyed and
  rebuilt from superd — `adoptSurvivingPanes` (`HostServer.swift:968`), `resumePointForSurvivor`
  (`:1166`).
- **Be `execve`d.** `HostServer` has exactly one production construction site:
  `Sources/slopdesk-hostd/main.swift:146`.
- **Dialled by two processes.** hostd the PROCESS is; `MuxChannelSession` is not — it is reached only
  through `HostServer`, reached only through `main.swift:146` and 18 test files. A socket here puts a
  serialization hop between `HostServer` and its own session objects, on the keystroke path.

The linked-library trigger is met literally: `MuxChannelSession` holds a duplicated PTY master fd
(`SCM_RIGHTS`, docs/51 §5), writes `TIOCSWINSZ` through it, and holds `NWConnection`s. docs/55 §4d
settled that descriptors do not cross, and `PaneResizeFold`'s header states the same conclusion for
exactly this state: *the descriptor and the `Task` belong to the session, because a descriptor cannot
cross and a `Task` should not.*

**The horizon, excluded from the steps on purpose.** Three Rust daemons already bind and serve clients
directly — `rust/slopdesk-inspectord/src/server.rs:91`, `rust/slopdesk-dropd/src/server.rs:46`,
`rust/slopdesk-androidd/src/net.rs:47`. `Sources/SlopDeskHost` imports AppKit in 2 of 46 files. The end
state where `slopdesk-hostd` is a Rust binary and `Sources/SlopDeskHost` is gone is reachable, and it
is reachable THROUGH the steps below, because each moves state out from under Network.framework. But a
rewrite is not independently landable. It is the destination the steps arrive at, not a step.

## 4. The boundary shape

**Not one session handle.** docs/55 §4b: *a handle with a large surface is a law you moved without
moving its sequencing.* Instead, six narrow handles, **each covering the state under exactly one
existing `NSLock`** — the `PaneResizeFold` discipline.

**Verdicts, not payloads.** docs/55 §4b: *the test is not how big the value is, it is whether the far
side READS the part that is big.* For the FIFO and the fan-out, Rust reads LENGTHS, KINDS and SEQS and
never the bytes. `Data` payloads stay in Swift, indexed by a slot the verdict names. This is the direct
avoidance of the two memcpys behind the recorded +30 ms cold-reattach regression in docs/55 §4c.

New logic lands in `rust/slopdesk-muxsession` (`forbid(unsafe_code)`); doors land in
`rust/slopdesk-ffi/src/`, beside `mux_resize.rs`. No fourth unsafe crate.
`rust/slopdesk-ffi/src/mux_host.rs` already shows the ownership pattern for subscribers: *the flow id
is the caller's, not ours* — an `NWConnection` crosses as an opaque `uint64_t` the caller assigns.

| Handle | Module | Serialized by | Rust owns | Swift keeps | What crosses |
| --- | --- | --- | --- | --- | --- |
| `PaneOutbox` | `muxsession::outbox` | `fifoLock` `:558` | queue of `(slot, len, kind)`, head cursor, capacity, `BoundedQueuePolicy` accounting | `[UInt64: Data]` slot map, `PausableQueueGate`, the bytes | in `append(slot, len, kind)`; out `MergeVerdict { slots, split_at, pause }` |
| `PaneFanout` | `muxsession::fanout` | `fanoutLock` `:183` | roster, per-subscriber `lastAckedSeq`/`lastSentSeq`, eviction rule, retention floor | `Subscriber`'s `Task`s, `MuxSubChannel`s, `dataWake` | in `join`/`ack`/`sent`/`remove`; out `FanoutVerdict { deliver_to, evict, retain_from }` |
| `PaneTruths` | `muxsession::truths` | one lock replacing seven | title + anchor + retire rule, progress grammar, exit/duration latches, `runningCommand` latch, block fold, project key | the probes (`tcgetpgrp`, `tcgetattr`) | in `ingest(&[SniffedEvent], &[BlockEvent], chunk_len)`; out counted-buffer `[WireMessageDescriptor]` |
| `PaneLifecycle` | `muxsession::lifecycle` | one lock replacing `taskLock`+`eofLock`+`exitSentLock` | the detach/rebind/teardown ladder; the reattach re-assert ORDER (`.commandStatus` before `.title`) | the `Task`s, timeouts, ioctl | in `detach`/`rebind`/`eof`/`exit`; out `LadderStep` + `[ReassertMessage]` |
| `MuxOpenRouter` | `muxsession::open_router` | `HostServer.lock` | the 4-path decision `alreadyLive`/`liveElsewhere`→JOIN/claim→SPAWN/→REATTACH; the `min(lastReceivedSeq, highestAssignedSeq)` adopted-pane clamp (`HostServer.swift:1990`) | the `store.claim`, the ack write, the connections | in `OpenFacts`; out `OpenRoute` |
| `HostSessionRegistry` | `muxsession::registry` | `HostServer.lock` `:125`–`:338` | session/subscriber/connection/hook-sink/workspace/project maps as id→id relations | the `MuxChannelSession` object map | in link-down/leave/reap/evict; out counted-buffer `[SessionAction]` |

Direction is one-way in every row: Swift calls, Rust answers. **No callbacks into Swift** — the one
that exists (`ReplayBuffer`'s `sanitize`) is exactly what cost 30 ms per reattach.

## 5. Independently landable steps

**Step 0 — reconcile.** Read `rust/slopdesk-muxsession/src/lib.rs` for new `pub mod` lines before
starting; a concurrent pane-runtime port may already cover the truths latches, in which case step 4
folds into it rather than competing.

**Step 1 — delete the detached FIFO; resume from superd's ring offset. LANDED.** *(~350 Swift lines)*
`detach` records the last delivered BYTE OFFSET instead of folding into 64 MiB. `rebindRelay`
re-subscribes through `PaneOutputStream(initialOffset:)` — superd-mediated, so no new reader. Cold
clients keep going through `ScrollbackTranscripts.restored` (`HostServer.swift:2099`), already
journal-backed. `Resume::is_lossy` becomes the announced gap. Deletes `:685-714`, `:2018-2100`,
`:1678-1686`, `:1799`, `:4364-4380`, `DetachedBacklogPeek`, `:1966-1997`. No new Rust logic —
subtraction plus one env decision. Record the ring-bytes choice in `docs/DECISIONS.md`.

**Step 2 — `PaneOutbox`. LANDED.** *(~150 removed, ~120 face added)* `outFIFO`, `fifoHead`,
`fifoCompactThresholdSlots`, `advanceFIFOHead()`, `takeMergedFrame()`, `MergedFrame` and `OutputItem`
are gone; the cap, the over-cap head split and the greedy multi-chunk merge are
`rust/slopdesk-muxsession`'s `outbox`, behind `rust/slopdesk-ffi/src/pane_outbox.rs`. The face is
`Sources/SlopDeskHost/PaneOutbox.swift`; `MuxChannelSession` keeps `fifoLock`, the wake and a
`nextOutboundFrame()` that is four lines.

Two shapes worth carrying into steps 3–7:

- **The slot is minted on the RUST side.** It is a queue coordinate, not an identity — nothing outside
  names it and it dies with the frame that ships it. Minting it there buys the property the verdict is
  built on: chunk slots are CONSECUTIVE (`.exit` takes none), so a merged run is
  `first_slot ..< first_slot + slots` and the verdict is four scalars rather than a counted buffer.
  This is docs/55 §4b's "identity mints near-side" read the right way round; `mux_host.rs`'s "the flow
  id is the caller's" is about an `NWConnection` Swift owns, which a queue coordinate is not.
- **The cap is read in the DOOR, per pop.** `max_output_frame_payload_bytes` is `slopdesk-wire`'s, and
  `slopdesk-muxsession` deliberately has no edge to the protocol crate — so the fold takes it as an
  argument and `pane_outbox.rs` supplies it. The number stays spelled once and
  `SLOPDESK_MUX_WINDOW`/`SLOPDESK_MUX_MERGE_CAP` stay live, with no constant crossing and nothing for
  `shared_constants` to ratchet.

Bytes never cross: the door reads lengths, Swift holds a slot→`Data` map and does the concatenation
where the `Data` already is. The single-slot fast path returns the chunk unchanged, so the interactive
steady state is byte-identical work. `BoundedQueuePolicy` was already Rust; the accounting and the
queue are now on the same side of the door.

**Step 3 — `PaneFanout`. LANDED.** *(~70 removed from the session, ~150 face added)* Every
NUMBER about a member — `lastAckedSeq`, `lastSentSeq`, `exitDelivered`, `evicting`, whether a sender
exists — plus the roster, its order, the id mint and all three folds over them are
`rust/slopdesk-muxsession`'s `fanout`, behind `rust/slopdesk-ffi/src/pane_fanout.rs`. The face is
`Sources/SlopDeskHost/PaneFanout.swift`. `nextSubscriberID`, `mintSubscriberIDLocked` and
`subscriberLagBytes` are gone; `subscriberList()`, `subscriberCount`, `acknowledge`, `noteSent`,
`fanoutBacklog`, `evictLaggingSubscribers`, `releaseRetentionToMinimum` and `hasPendingExitDelivery`
survive as marshallers of two or three lines.

Ids cross as `uint64_t` — `MuxSubscriberID`'s own width, not docs/59's original `uint32_t` guess, so
this door and `mux_resize`'s agree — and they are CALLER-minted, which is the opposite of step 2's
slot and for the reason step 2 gave: a subscriber id is an IDENTITY (a channel key names it before
the member exists, so a link dropping in that window stays attributable to the joiner), where a slot
is a queue coordinate nothing outside names. `reserve_id` is on the handle so the counter is not a
second piece of state, but the ORDER — reserve, register the key, then join — stays the caller's.

Three shapes worth carrying into steps 4–7:

- **The handle is serialized by ONE lock, and it is the one those fields already lived under.**
  `subscribersLock`, this file's innermost, never `fanoutLock`: `noteSent` runs per MESSAGE on every
  member's sender and takes only `subscribersLock` today, so putting the handle under the drain's
  ordering lock would be a lock-order and contention change wearing a port's clothes. `fanoutActive`
  and the join ordering therefore stay Swift under `fanoutLock`, which is exactly right — they are
  about a drain's mode, not about a member.
- **Two handles never hold each other; values cross instead.** The laggard rule needs
  `replay.retainedBytes(above:)`, which lives behind the ReplayBuffer under `replayLock`. A fanout
  handle holding a replay-handle pointer would alias state its own lock says nothing about and break
  `held()`'s "no other reference live for the duration of the call". So the ladder is two calls:
  `_lagging` answers WHICH cursors are behind the frontier (empty for a set of one, and empty for a
  disabled threshold, so an empty answer costs no O(history) walk at all), Swift prices each under
  `replayLock`, and `_evict` applies the threshold and claims the one-shot latch. Both halves of the
  RULE are in Rust; only the QUERY is not.
- **A parallel table is the failure mode, so the split is by SHAPE, not by convenience.** Swift keeps
  `[MuxSubscriberID: Subscriber]` because a channel pair, four `Task`s and two `AsyncStream`
  continuations have no C ABI shape — and it keeps `retired`, because that latch is about an object's
  tasks being cancelled and it deliberately outlives membership (`shutdown()` cancels without
  retiring the set). Everything else is one table. The population, the order, the count and "is it
  emptied" all come from the door; `subscribers.values`/`.keys` never appear again, and the ratchet
  in §8 rule 3 says so.

One latent bug fell out: `admitJoiner` took `replayLock` while HOLDING `subscribersLock`, nesting
outward from the lock its own doc comment calls innermost. The seed is now read before the section,
which is exact because `fanoutLock` is held across both.

**Step 4 — `PaneTruths`. LANDED.** *(~370 removed from the session, ~390 face added)* Every latched
TRUTH about a pane — the title and its stamp, the anchor retirements and the coalescing reset, the
progress badge, the command edge with its exit code and duration, the running command line, the echo
anchor and the finished-turn counter — is `rust/slopdesk-muxsession`'s `truths`, behind
`rust/slopdesk-ffi/src/pane_truths.rs`. The face is `Sources/SlopDeskHost/PaneTruths.swift`.
`latchProgress`, `wireMessages(from:)` ×2, `commandBlockMessage` and `EchoModeDetector` are gone;
`ingestPTYChunk` builds one row table, folds once, and routes what comes back. **Seven `NSLock`s
collapsed into one** (`titleLock`, `progressLock`, `completionLock`, `commandExitLock`, `blocksLock`,
`echoDetectLock`, `agentDetectLock` → `truthsLock`) — they were separate because the FIELDS were
separate, never because the truths are, and the writer is serial, so seven acquisitions bought no
concurrency and cost readers a torn view. docs/51 §6.13 is satisfied: the grammar stays in hostd's
PROCESS, it leaves hostd's LANGUAGE.

Two more shapes for steps 5–7, both about how a BATCH crosses:

- **Text crosses once, by reference; verdicts name a fact by INDEX.** The sniffed batch is already
  decoded into a row table plus a byte arena, so a `Fact<'arena>` BORROWS its text and a `Verdict`
  carries a `u32` fact index, not a payload. A chunk carrying ten titles allocates nothing on either
  side. Only the two truths that OUTLIVE the batch — the title and the running command — are copied,
  and a non-UTF-8 span reads empty rather than allocating a replacement.
- **A mutating door does not retry.** The two-call `deliver` convention is for READS; a fold answers
  at most one verdict per fact, so the caller lends `count` slots and the write always fits. Suppressed
  notifications drop out with no verdict at all, and the survivors still name their ORIGINAL index.

`agentDetector` did not re-parent into the handle — its ~25 doors would have doubled for no
behavioural gain — but it moved UNDER `truthsLock`, which is what actually retires the seventh lock,
and `suppressesChildNotifications` crosses as a `bool` parameter rather than as a second handle
(step 3's "two handles never hold each other").

**Step 5 — the project truths and the reattach ladder. LANDED.** *(~80 removed from the session,
~110 face added)* The eighth latch cluster — the freshest cwd, the By-Project key it resolved to,
and the warm-up gate in front of both — joined `truths`, and `projectKeyLock` went with it. The cwd
derivation crosses as a TWO-CALL ladder with a syscall between the halves: `open_cwd_gate` says
whether a batch has anything to derive and whether the prompt-edge `proc_pidinfo` probe gets a say,
Swift makes the probe with no lock held, and `latch_cwd` dedupes what came back. That window is
exactly the window the Swift original had — it unlocked to probe too — so it is parity, not a new
race. `latch_project_key` re-qualifies a resolver walk against the cwd it was started for, so a walk
a later `cd` superseded is dropped rather than published.

`reestablishActivityOnReattach` is the other half, and the more interesting one: its ORDER was only
ever a comment, which docs/55 §8 names as its own failure mode. The ladder now crosses as two lists
of discriminants — `reestablish_head`, the detector's own re-assert, `reestablish_tail` — so the
rule that the title must land AFTER the command stamp its freshness is judged against is a Rust
test rather than a paragraph. Two doors rather than one because the detector splices between them
and two handles never hold each other. The function that used to be forty lines of hand-ordered
appends is now six.

**Step 5b — `PaneLifecycle`.** *(~500 Swift lines)* `detach(onDetachedExit:)` `:1643-1686` ·
`rebindRelay(...)` `:1723-1894` · the `exitTask` ladder inside `startRelay()` `:1240-1346`. The two
`reestablish…OnReattach` halves are NOT here any more — step 4 took the echo re-anchor and step 5
took the activity ladder, so what is left is the detach/rebind I/O itself. **Depends on step 3**: the documented
`fanoutLock` → `taskLock` order in `rebindRelay` stops existing once the roster is a handle, rather
than being re-encoded.

**Step 6 — `MuxOpenRouter`. LANDED.** *(~90 removed from the server, ~155 face added)* The seven
exits of `spawnMuxChannel` — workspace, decline, refuse-while-stopping, re-ack, join, claim,
spawn-fresh — were decided by five booleans read under one lock in an order that was only ever a
comment, and the comment is load-bearing three separate ways: an unserved class that reaches the PTY
path forks a login shell nobody asked for, a live id that falls past the JOIN rotates the
incumbent's journal writer out mid-session, and a resume verdict above what a session can number
tells a returning client to drop every frame it is about to be sent. None of the three fails a
build. The precedence is `open_route::route` now, over an `OpenFacts` hostd fills under the same
critical section it always had.

Two booleans became one value on the way: `already_live` and `live_elsewhere` could never both be
true — the second was computed only when the first was false — so the pair had a fourth state that
meant nothing and a route that would have been undefined for it. `Incumbent` has the three states
the question has.

The claim stays Swift (it mutates a store and cancels a TTL task); what crosses is whether to
ATTEMPT it, and `settle` turns its three outcomes into the next action. The other four decisions in
the cluster came with it: the resume clamp (`resume_from`, and it is `i64` because a seq is signed
on the wire), the redraw choice (`redraw` — jiggle only for a cold client on a raw replay), the
fresh-spawn restore gate (`restores_transcript`) and the adoption pair (`survivor_resume`,
`ownership_allows_adoption`). Every door is stateless: there is nothing to allocate, nothing to
free, and no handle whose lifetime could be got wrong.

`slopdesk-muxsession` took its first `slopdesk-wire` edge here, for the class byte alone —
`MuxChannelClass::from_byte` owns which bytes this build routes, and a copy of that list is exactly
the one that decides whether a peer's unknown class gets declined or gets a shell.

**Step 7 — `HostSessionRegistry`.** *(~700 Swift lines)* `controlSessions` `:125` · `muxSessions`
`:152` · `muxSubscriberIDs` `:163` · `muxConnections` `:172` · `hookPaneIDsBySession` `:192` ·
`workspaceChannels` `:317` · `projectObjectIDs` `:338` become one relation table answering ACTIONS.
Absorbs `handleLinkDown` `:2371` · `leavePaneChannel` `:2410` · `reapPanesRemovedFromTopology` `:2438`
· `wireSubscriberEviction` `:2473` · `detachMuxSession` `:2496` · `removeMuxSession` `:2542` ·
`paneSessionsForWorkspace()` `:1469` · `paneRosterRecords()` `:1490`. Swift keeps only
`[MuxSessionKey: MuxChannelSession]` — objects cannot cross.

**Step 8 — metadata admission.** *(~200 Swift lines)* `serveMetadata(requestID:verb:payload:to:)`
`HostServer.swift:3464-3566`: the bounded-admission counter (`maxMetadataInFlight = 32`) and the
performer-chain routing become a verdict; the performers stay (§6).

**Step 9 — collapse the test seams.** *(~400 Swift lines)* `MuxChannelSession.swift:3839-4076` (~240
lines of `_…ForTesting`) and `HostServer.swift:3060-3218` (~160). After steps 2–7 that state is
reachable directly in Rust unit tests, so they are deleted rather than kept as a second surface.

**Totals.** ~4,750 Swift lines deleted against ~800 lines of new face, from 7,886.
`MuxChannelSession.swift` ≈ 4,665 → ~1,400; `HostServer.swift` ≈ 3,221 → ~1,100.

**Constraints.** The wire is unchanged — every step moves a DECISION about bytes whose encoding is
already `slopdesk-wire`'s, and `golden/golden_vectors.json` is not regenerated by any step. No PTY
reader is added: step 1's resume is a re-`subscribe` at an offset through `PaneOutputStream`. No fourth
unsafe crate. Every step deletes the Swift it replaces and adds a ratchet (§8).

## 6. The honest floor — what must NOT move

- **`TIOCSWINSZ` on hostd's duplicate.** docs/51 §6.9: one writer of a pane's window size and it is
  hostd; superd's `resize` verb only records. `posix::pty::set_window_size` is behind the
  `winsize-set` feature, enabled only in superd's `[dev-dependencies]`. A second writer is a lost
  update. `PaneResizeFold` already draws this line — copy it, do not renegotiate it.
- **`tcgetpgrp` (`PTYForegroundProbe`) and `tcgetattr` (`PTYEchoProbe`).** Named in
  `PaneOutputStream.swift`'s header as one of the two reasons the full-relay design was rejected: no
  polled IPC for the foreground process group.
- **The Apple-framework performers** — `HostClipboardPerformer` (NSPasteboard),
  `HostPathActionPerformer` (NSWorkspace), `RepoStatusWatcher` (FSEvents). `PreventSleepDriver` shows
  the pattern when they DO move: behind `slopdesk-apple-power`, `objc2` only.
- **`Sources/SlopDeskTransport/Mux/MuxNWConnection.swift`** (837 lines of Network.framework), for as long as
  hostd is a Swift process. The single largest thing between step 7 and the horizon — and the thing
  inspectord/dropd/androidd prove is replaceable.
- **The `Task`s and the timeouts.** Every ladder step answers WHAT to do and WHEN to arm a timer under
  which generation; Swift arms it.
- **`golden/golden_vectors.json`.**

## 7. Latency risk and the measurement

`ingestPTYChunk` (`:2624-2766`) runs on superd's read-loop delivery thread, once per 32 KiB chunk
(`PaneOutputStream.readChunkSize`, half the 64 KiB queue capacity, deliberately). `sequenceAndFanOut`
`:4167` and `takeMergedFrame` `:623-666` run once per outbound frame. Steps 2, 3 and 4 put doors on
these paths.

**The governing rule is not crossing count.** docs/55 §4c: a crossing is ~1.0 ns; a door plus two
`Array(String.utf8)` is 100.8 ns; a door plus a `Data` allocation is **227.5 ns**. *A crossing COUNT is
not, by itself, a reason to build a door… rank by allocations.* A `PaneOutbox` call per chunk costs
nothing measurable; one that materializes a `Data` per chunk costs 227× that, per chunk, forever.

**So the design constraint is zero allocations added per chunk** — which is why steps 2 and 3 are
verdict-only, and why no step introduces a Swift callback from Rust. docs/55 §4c records the one that
exists: the `sanitize` callback's memcpys cost **+30 ms per cold reattach** (193 → 784 ms over ×20).

**Before committing:**

1. **A/B harness, the ring-buffer port's shape.** That port measured append+ack over 20k chunks
   (531 ms Swift → 446 ms Rust) and `retained_bytes` over 1M probes (28.9 → 27.7 ms). Per step: drive
   N=20,000 32 KiB chunks through `ingestPTYChunk` on both sides of the diff, on a branch build with
   the Swift original still present — deleted before the commit lands.
2. **Allocation count, not wall time, as the gate.** `latency_ratchets.rs`'s own header: *a timing
   assertion in CI is a flake generator.* Instrument with `malloc_zone` statistics or Instruments'
   allocations template and assert delta ≈ 0 per chunk.
3. **Reattach separately, because it has a recorded number.** ×2000 warm reconnect (2.9 → 19.4 ms
   baseline, +8 µs each) and ×20 cold reattach. Step 1 changes the cold path materially; measure
   against the current 193/784 ms figures and record the delta either way.
4. **Compose throughput as the sanity denominator.** 17.9 MiB/s is the recorded compose rate — that is
   what made 30 ms "0.85% of the reattach" acceptable rather than a veto. Quote any new cost the same
   way.

Expect steps 1 and 2 to get FASTER, not slower: step 2 puts merge/split next to `BoundedQueuePolicy`
accounting that is already Rust, removing a crossing per frame; step 1 removes a 64 MiB copy path.

## 8. Invariants

**Rules this plan interacts with.** `deleted_host_swift.rs` (the home for every new ratchet; its
header: *every ban here is a port that DELETED its original*) · `pane_wiring.rs` (supplies the
`Claim::Exists` / `Claim::NoneUnder` shape) · `superd_bodies.rs` and `supervisor_envelope.rs` (step 1
changes what hostd asks superd for) · `hot_paths.rs` (*the Swift face must stay a marshaller* — the
doctrine steps 2/3/4 must satisfy) · `latency_ratchets.rs` (the projection-behind-a-computed-`var`
class, and the BREAK-TESTED convention every new rule follows) · `crate_policy.rs` /
`crate_defaults.rs` (assert `slopdesk-muxsession` stays `forbid(unsafe_code)` as it grows) ·
`shared_constants.rs` (steps 1 and 2 touch numbers spelled on both sides) · `rust_boundaries.rs` ·
`package_graph.rs` · `transport_lanes.rs` / `wire_codecs.rs` (no step changes the wire) ·
`host_probes.rs` / `apple_floors.rs` (§6's floor) · `gate_health.rs`.

**New rules, one per step.**

1. **the detached backlog has one buffer** — `Claim::NoneOf` over `MuxChannelSession.swift` for
   `compactDetachedBacklogForColdClient|peekDetachedBacklog|consumeDetachedBacklog|spliceFoldedRing|DetachedBacklogPeek|detachedHostQueueCapacityBytes`,
   plus `Claim::Mentions` that `PaneOutputStream(initialOffset:)` is how a rebind resumes. *Message:
   the pane's detached bytes are superd's ring and superd's journal; a third copy in hostd is the
   four-copies defect.*
2. **the outbound frame is merged once, in Rust** — LANDED, as two rules rather than one, because
   `deleted_host_swift.rs` is bans and half this claim is about a face.
   `deleted_host_swift::pane_outbound_queue` bans `takeMergedFrame|advanceFIFOHead|fifoHead|outFIFO`
   anywhere under `Sources`; `hot_paths::the_outbound_frame_merges_once` (rule
   `outbound-frame-merge`) requires `PaneOutbox.swift` to exist, to call every one of the six
   `slopdesk_pane_outbox_*` doors, and to hold NO ordering of its own — no array of queued items, no
   head cursor, no `removeFirst`. `hot_paths` is the right home for the second half: its header is
   *the Swift face must stay a marshaller*, and this path runs once per 32 KiB chunk forever.
3. **the subscriber roster is one table** — LANDED, as two rules for the same reason rule 2 split.
   `deleted_host_swift::pane_subscriber_set` bans
   `mintSubscriberIDLocked|nextSubscriberID|lastAckedSeq|lastSentSeq|exitDelivered|subscriberLagBytes|SLOPDESK_SUB_LAG_BYTES`
   anywhere under `Sources` — the CURSORS, not the functions that walked them, because those
   functions survive as marshallers and a member scalar declared anywhere in Swift is a parallel
   table by definition. `hot_paths::the_subscriber_set_is_one_table` (rule
   `subscriber-set-one-table`) requires `PaneFanout.swift` to exist, to call every one of the
   eighteen `slopdesk_pane_fanout_*` doors, to hold no roster/mint/threshold of its own (no `NSLock`,
   no `ProcessInfo`, no `[MuxSubscriberID:` map), and requires `MuxChannelSession.swift` to declare
   no `evicting` and to fold over `subscribers.values`/`.keys`/`.count`/`.isEmpty` never again — the
   population, the order and every cursor come from the door.
4. **what the shell said is translated once** — LANDED, as two rules, for the reason rules 2 and 3
   split. `deleted_host_swift::pane_truths` bans a pane truth coming back as a STORED property
   anywhere under `Sources` (`_currentTitle`, `_currentTitleAt`, `pendingTitleCoalescingReset`,
   `titleAnchorRetirements`, `lastProgress`, `lastProgressPair`, `lastExitTruth`,
   `lastDurationTruth`, `commandRunningSince`, `_runningCommand`, `_completionEpoch`,
   `_lastCompletionStatus`, `echoWarmedUp`) plus the two deleted machines by name
   (`EchoModeDetector`, `latchProgress`) — a declaration, never an accessor, because the face's whole
   job is to spell those names as pass-throughs. `hot_paths::one_batch_one_pass_one_lock` (rule
   `one-batch-one-pass-one-lock`) requires `PaneTruths.swift` to exist, to call all eighteen
   `slopdesk_pane_truths_*` doors, and to hold no lock, no clock and no trim of its own; and requires
   `MuxChannelSession.swift` to name none of the seven retired locks. The `Claim::AtMost` on
   `NSLock()` this plan proposed is subsumed: banning the seven by NAME is the same ratchet without a
   number to maintain.
5. **the reattach re-assert has one order** — LANDED, folded into the two step-4 rules rather than
   added beside them, because it is the same face and the same file.
   `deleted_host_swift::pane_truths` gained `lastCwdTruth`, `lastProjectKey` and
   `projectKeyWarmedUp`; `hot_paths::one_batch_one_pass_one_lock` gained the nine project/ladder
   doors, `projectKeyLock` in the retired-lock ban, and a new `Claim::NoneOf` on
   `MuxChannelSession.swift` for `messages.append(.title|.cwd|.projectKey|.commandStatus` — the
   re-assert may not be hand-built, because a re-ordering that puts the title before the command
   stamp still compiles and still passes every content assertion.
6. **the channel-open route is decided once** — LANDED as `hot_paths::one_open_one_route` (rule
   `one-open-one-route`). Requires `MuxOpenRouter.swift` to exist, to call every one of the seven
   `slopdesk_mux_open_*` doors, and to reach for none of the host's own state (no `NSLock`, no
   `muxSessions`, no `store.claim`) — a router that could read a map would be a second copy of the
   map. Bans four hand-derived answers in `HostServer.swift`: `min(open.lastReceivedSeq` (the clamp,
   docs/55 §8's `PortValidation.port` row exactly), `open.channelClass == MuxChannelClass` (the class
   routing), `owner == supervisorOwnerIdentity` (the adoption test) and `PaneOutputStream.fromNowOn`
   (the live-edge sentinel). The sentinel itself is pinned on BOTH sides — `FROM_NOW_ON == u64::MAX`
   in `open_route.rs`, `fromNowOn = UInt64.max` in `PaneOutputStream.swift` — because a survivor
   resume whose two halves disagree replays a whole transcript twice.
7. **the host's session maps are one relation** — ban the seven dictionary declarations at
   `HostServer.swift:125-338` except `muxSessions`; require `slopdesk_host_registry_*`.

Each rule carries a `/// BREAK-TESTED <date>:` line stating the edit that failed it and the restore
that passed, matching `latency_ratchets.rs`'s convention.
