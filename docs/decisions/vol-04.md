# DECISIONS vol-04 — 2026-07-26 … 2026-07-29

> Volume 4 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## Multi-client: hostd owns the workspace document (2026-07-26)

> The architecture record for [45 — Multi-client state sync](../45-multi-client-state-sync.md).
> Supersedes [22](../22-workspace-architecture.md) §1.1 for **ownership**; the tree-of-intent ⟂
> table-of-liveness split, the pure `WorkspaceTreeOps`, and the `makeSession` test seam survive
> verbatim. These rulings land BEFORE the code that implements them (Phases 2–6).

### 1. The three-bucket ownership split

- ✅ **The classification test, stated once:** *would two people looking at the same session disagree about a **fact**, or about a **view**?* Facts are HOST-TRUTH. Views are DEVICE-LOCAL. "Who is here and what are they looking at" is PER-CLIENT-PRESENCE — fanned out, TTL-expired, never persisted, never versioned.
- ✅ **HOST-TRUTH:** topology (sessions/tabs/splits), `activeTabID` by IDENTITY not index, `focusMRU`, the closed-tab ring, presets and templates (they name HOST cwds and spawn HOST commands), per-pane title/`liveTitle`/`titleFresh`/cwd/projectKey/foregroundProcess/`runningCommand`/agent state/progress/`liveness`/`completionEpoch`/grid, the video pane's TARGET identity, and the per-project git summary.
- ✅ **DEVICE-LOCAL:** everything in `PreferencesStore` (a 27″ Studio and an iPhone must not share a font size), window chrome, scroll/copy-mode/selection *inside* a pane (tmux: "the visible position is a property of the client not of the window"), `videoModesByTarget`, `seenCompletionEpoch`, and the notification DELIVERY gate.
- ✅ **Pane identity becomes HOST-MINTED.** The host's mux `sessionID` **is** the pane objectID. A client spawning a pane sends an intent and learns the id back. Today's client-minted UUID gives two devices no shared vocabulary for "the nvim pane". `PaneSpec.resumeSessionID` is deleted — the host-minted id is the rendezvous identity.
- ✅ **ctl-spawned panes ARE in the document**, parented to `root/unattachedSessionID`. Otherwise the host holds two disagreeing pane inventories and the premise of the design is false.
- ✅ **A delete removes an OBJECT, never a single field.** A field is retired by setting it to a ZERO-LENGTH value, and zero-length is a first-class value the projection honours — because `""` is already meaningful on this wire (the type-21 title retirement).
- ❌ **REJECTED: CRDT / OT.** Zed is the decisive precedent: a real CRDT for **text buffers**, plain host-authoritative RPC broadcast for the **Project/Worktree tree** — the structurally identical case to ours. With one serialization point there is nothing to merge.
- ❌ **REJECTED: an operation log with delta compaction.** Snapshot-at-current-`stateNum` instead. Cost is then O(tree), never O(elapsed): no retention window, no compaction, no `OffsetOutOfRange` equivalent, and reconnect-after-four-hours is the same code path as steady state.
- ✅ **`epoch: UUID` is the no-migration directive expressed on the wire.** Minted at every hostd start. Without it a restarted daemon counts `stateNum` back up and a returning client accepts a delta computed against a *different document* — divergence that is permanent, silent, and has no detector. A foreign epoch means reset-then-snapshot: the same path as a missed frame.
- ✅ **The Inspector (PATH 3) stays a derived, lossy read model.** The document is authoritative; the inspector is not reconciled into it.
- ✅ **Blast radius, stated out loud.** A compromised mesh peer goes from "can attach one pane" to "can restructure the workspace and close tabs". Security remains the WireGuard mesh; **no app-layer auth is introduced** — the client label on the wire is a LABEL, not a credential, checked nowhere and granting nothing.

### 2. Focus is host-truth; `videoModesByTarget` is not

- ✅ **`Session.activeTabID` / `Tab.activePaneID` are HOST-TRUTH.** They are not a render preference: they determine `successorAfterClose`, notification targeting, and what a fresh client opens into. tmux puts `session->curw` server-side.
- ✅ **The escape hatch ships in the SAME phase**, not later: a device-local `followSessionFocus` (default **ON macOS / OFF iOS**). Unfollowed clients carry their view in presence, so picking up a phone can never yank a Mac's screen.
- ✅ **The 2026-07-22 `videoModesByTarget` ruling stands, on two of its three legs.** Quoting it: (a) *"Immersive is a client-LOCAL CGEventTap — the host cannot own another machine's keyboard routing"* — **stands**. (b) *"host-side durability would need a persistent per-pane identity the host doesn't have (PaneID/workspace is a client concept)"* — **OBSOLETE**, pane identity is now host-minted. (c) *"a second client (iPad/macbook) viewing the same host must NOT inherit the first client's per-pane view prefs"* — **stands**. (a) + (c) alone carry the ruling, which is a stronger argument than the original.
- ✅ The video **target identity** becomes topology (both clients must agree "tab 3 slot 2 is a video pane on Display 1"); the **modes** stay device-local.

### 3. PTY size under N clients: monotone min-fold over ATTACHMENT

- ✅ **A subscriber contributes iff it holds an open `channelClass == 0` channel for that pane.** That set IS the refcount. Grid is `min(cols)`/`min(rows)` over contributors behind a **750 ms settle timer**; a pane with **zero** contributors keeps its last size rather than snapping to 80×24. **iOS is size-passive by default** (tmux `ignore-size`). Wire type 11 `resize` stops being a command and becomes a **contribution** — no wire change.
- ✅ **BOTH `pty.setWindowSize` sites route through one `applyResolvedGrid()`** — the client path AND the ctl-socket `resizeForControl` path. Leaving the second outside the fold silently breaks the monotone-min invariant.
- ❌ **REJECTED: WezTerm's / `screen -x`'s unconditional last-writer-wins.** Two clients at different sizes fight and the loser is simply told the new dimensions.
- ❌ **REJECTED: an input-keyed driver latch.** It has NO hysteresis: two clients typing alternately flap `TIOCSWINSZ` + `SIGWINCH` + a full TUI repaint on every exchange, and one stray byte from a pocket reflows a 200-column Mac. A min-fold is monotone and settles; a latch always flaps.
- ❌ **REJECTED: a presence-keyed predicate.** A 30 s heartbeat TTL is not a resize request — network jitter on a cellular iPhone would SIGWINCH a Studio's nvim.
- ⚠️ **Acknowledged cost:** zellij Discussion #5066 (smallest-client-wins is a documented pain point). The iOS-passive default removes the worst case; the resolved grid + contributor list are published so a non-contributing client renders a LABELLED letterbox rather than guessing.

### 4. The badge fact is shared; the acknowledgement is not

- ✅ **Objective host `pane/completionEpoch` (monotone counter) + device-local `seenCompletionEpoch`.** Clients agree on the FACT and disagree on the ACKNOWLEDGEMENT. The host holds **zero** per-client acknowledgement state.
- ❌ **REJECTED: tmux's server-side shared activity flags** (one client reading clears everyone's badge) **and a host-held `unseenBy: Set<ClientInstanceID>`** — unbounded, no GC, undefined for a client that was offline when the event fired, undefined across a restart.
- ✅ **Types 22/25 fan to every client and each client gates locally** (`NotificationPolicy.shouldDeliver`). Duplicate banners across a user's own devices are **the point** — you want the banner on the machine you are at. Host-global `hookAuthority` suppression is unchanged.

### 5. Workspace channel transport rules

- ✅ **`channelClass`: 0 PTY · 1 workspace · 2 read-only observer.** The field is already encoded, decoded and golden-pinned, and read nowhere in the host — the seam is free. Workspace routing goes in `spawnMuxChannel` **before** the pane-routing critical section, so the one-shell-per-sessionID invariant is untouched.
- ✅ **The workspace channel must NEVER use `enqueueControl`.** It sheds NEW messages past `maxControlOutQueued = 1024`, so a shed snapshot leaves a client pinned at `stateNum 0` **with no retry trigger** — a silent, permanently blank workspace. The channel owns its own send task with **depth-1 coalescing**: a pending diff is discarded and recomputed, never queued. Host memory is O(clients × state) regardless of how slow a client is; a sleeping iPhone is free.
- ✅ **Diff from the ACKED base, not the last-sent base** (mosh SSP). A diff is then a set of independent property assignments, so duplicates and reorders are no-ops *by construction* and a lost frame self-heals on the next tick. **There is no retransmit path on either side.**
- ✅ **Only kinds 0 (snapshot) and 1 (diff) advance `stateNum` or trigger an ack.** A presence or intent-result frame that advanced it would make the host retire, via `assumedAcked`, a diff it never sent — permanent silent divergence on the very first `renameTab`.
- ✅ **The client fast-path overlay may NEVER write `entries`.** The retained type-21/26/27/32/33/34/36 pushes keep painting sub-frame, but into a separate `fastPath` layer that any diff erases. `entries` stays provably `apply(diffs, base)` — writing pushes into it would freeze a producer disagreement forever, which is the exact bug class this work exists to eliminate, reintroduced as an optimisation.
- ✅ **Conflict rule, one sentence:** *the last write to a given `(kindTag, objectID, field)` key wins, ordered by arrival at the single `HostWorkspaceDocument` actor* — no merge, no timestamps, no vector clocks. Figma's model. Anti-flicker: while a local change is unacknowledged, conflicting server values are held back rather than applied-then-corrected.
- ✅ **State plane vs byte plane:** data arriving on a pane channel the state plane has already retired is **DROPPED** — not applied, not an error. A pane surface is torn down only after its own `channelClose`, never on a state-plane edge alone. The untrusted-input idiom applied to our own host.
- ✅ **Hard sequencing gate before fan-out:** `closePane`/`closeTab` reap **unconditionally** and `channelClose` **every** subscriber; only `detach` is refcounted. A refcount-aware close would leave a shell running with no UI anywhere and no document entry.
- ✅ **`SLOPDESK_SUB_LAG_BYTES` (default 32 MiB) evicts a laggard rather than letting it stall the pane**, deliberately below the real 64 MiB offline gate; `ReplayBuffer` retention releases at `min(lastAckedSeq)`; **the PTY drain pauses only when the LAST subscriber is gone**, preserving today's detached-budget behaviour exactly. Eviction is affordable precisely because the 2026-07-25 snapshot-replay work made a cold reattach cost one screen, not a history. **Amended 2026-07-28** ("The fan-out laggard soak", below): the drain also pauses when the FASTEST member stops consuming — "the last subscriber is gone" is not the same statement as "nobody is consuming", and a pane that shrank back to one member had no producer bound at all.

### 6. Doc corrections made in this pass

- ✅ [20](../20-wire-protocol.md) next-free type bytes read 17 / **36** while 36 was `agentSessionIntent`; corrected to 17 / **37**, with a note that these numbers are prose and `WireMessage.swift` is the source of truth.
- ✅ [20](../20-wire-protocol.md) "Replay-buffer caps" read 64 MiB ceiling / 4 MiB offline gate; the code is **256 MiB / 64 MiB**.
- ✅ [22](../22-workspace-architecture.md) claimed sessionIDs are NOT persisted; `PaneSpec.resumeSessionID` persists them and Stage-2 resume is default-ON. Its `SlopDeskClientUI/…` paths are also stale (the code lives under `Sources/SlopDeskWorkspaceCore/Workspace/`).
- ✅ `WorkspaceStore.blockBookmarks`'s doc claimed stable-`PaneID` keying while the code uses the per-materialization `bookmarkScopeKey`. **Comment fixed, code kept** — the scope key is deliberate (a relaunch must not re-apply a prior run's raw block indices onto unrelated commands).

---

## Multi-client Phase 4: what the code decided that the design did not (2026-07-27)

> Amends [45 — Multi-client state sync](../45-multi-client-state-sync.md) §5–6 with the rulings that
> only surfaced once the channel existed. Each of these was found by a test, not by review.

### 1. `stateNum` starts at 1, never 0

Zero is the "I know nothing" sentinel a client sends in `subscribe`, and the base every snapshot
declares. If the host could also legitimately BE at zero, a client that had genuinely received and
acked the opening document would be indistinguishable from one that had never connected — and would
be re-snapshotted forever. Found by `testAChangeAfterTheAckArrivesAsADiffFromTheAckedBase`, which got
a second snapshot where a diff belonged.

### 2. One send outstanding at a time — which is what depth-1 coalescing MEANS

§5.5 gives the client the rule "`baseStateNum != stateNum` → DROP and resubscribe". The host must
therefore never declare a base the client does not hold. Recomputing from the acked base is necessary
but not sufficient: while a frame is unacked, the acked base is STALE, so a second frame sent
against it names a state the client has already moved past, and the client's own drop rule turns a
burst into a resubscribe loop.

**The host holds further updates until the previous frame is acked.** They coalesce into the pending
slot and ship as one diff. 500 versions with no ack in between produce exactly ONE diff, and the
500th value lands when the ack arrives. This costs one RTT of update latency and buys a natural rate
limit; for titles and cwd that is a feature. It is safe without a retransmit path because this rides
the mux CONTROL sub-channel, which is TCP: a frame is only ever "lost" with the link, and the link
taking the channel down is itself the resubscribe trigger.

### 3. `PaneLiveness` lives in the MODEL target, not the host

§6.2 filed it under `Sources/SlopDeskHost/`. Both ends need it — the host writes `entries()`, the
client reads `init(paneID:entries:)` — and one round-trippable value beats an encoder and a decoder
maintained apart. It also buys a headless round-trip test with no PTY in sight, which is where the
four `titleFresh` rules are pinned. The host keeps only `PaneLiveness.capture(from:)`.

The spec's `assertions() -> [WireMessage]` is NOT implemented: the reattach re-assert's messages come
partly from `agentDetector.reestablishOnReattach()`, which MUTATES the detector (it re-anchors so an
unchanged state still re-emits). A pure snapshot cannot produce them. The two consumers stay separate
until Phase 4c retires the message half.

### 4. A liveness merge CLEARS before it writes

Writing only the fields a record carries would latch `runningCommand` after the command finished and
`agentLabel` after the agent exited — the same "edge published, current value retained nowhere"
failure this document exists to end, moved one layer up. `merge(paneLiveness:)` replaces exactly the
liveness field set and leaves topology alone.

### 5. Facts are SWEPT, not pushed

The per-pane truths come from at least five independent producers — the sniffer's read-loop thread,
the foreground poll task, the hook socket, the blocks segmenter, the project-key resolver. Wiring
each one to the document separately is precisely how a fact goes missing. `reconcileWorkspaceDocument`
re-captures every pane and merges the lot: correct by construction, and free when nothing changed
because `stateNum` only moves when the value did. Event sites KICK a pass rather than carry one, so
steady-state latency is a hop; the periodic tick is only a backstop for facts with no edge to hang a
kick on.

### 6. Project object ids are MINTED, not `UUIDv5(projectKey)`

§5.3 proposed a v5 UUID, which needs a SHA-1 the host target does not otherwise link. A minted id is
exact where a hash is merely unlikely to collide, and its only cost — a different id after a restart
— is invisible: a restart mints a new `epoch`, every client resets and re-snapshots, and
`project/key` carries the path the client actually joins on.

### 7. The client awaits `channelOpenAck` before its first request

`channelOpen` is announced on the DATA link while `subscribe` rides CONTROL, so a subscribe sent
immediately can beat the host's registration of the control sub-channel. The frame is dropped and the
client waits forever for a snapshot that never comes. Same discipline as PATH A's reattach. This
presented as a FLAKE under the full suite and passed in isolation — which is how open-order races
always present, and why [CLAUDE.md](../../CLAUDE.md) says in-memory loopback misses them.

### 8. Loopback tests POLL a collector; they never await `inbound.next()`

Awaiting the iterator strands xctest the moment an expected frame does not arrive, and a hung suite
tells you nothing while blocking the gate. With the `channelClass` route reverted, the tests now fail
in six seconds with "timed out waiting for 1× snapshot".

## Multi-client Phase 4d: two silent defects, and where the rest of it actually lives (2026-07-27)

Phase 4c shipped the client half. Two of its rules were wrong in ways nothing could report.

### 1. The document is keyed by the HOST's pane id

4c wrote and read the mirror under `PaneID.raw`. That id is minted on the CLIENT when a pane is
created; the document keys panes by the id the host mints on channel open. Two different UUIDs, and
no decoder can tell them apart.

So host truth landed under keys the UI never queried — the document was inert on a live client — and
worse, the two mirror layers were keyed APART, which makes the erasure rule that keeps them disjoint
unreachable. A client guess the host contradicts would have won forever: the exact bug the document
exists to end, reintroduced one layer down. The 4c suite missed it by building its fixtures from
`paneID.raw`, asserting the mapping it also assumed.

`PaneSpec.resumeSessionID` already held the host's id — `onResumeIdentitySnapshot` fires on every
connect, not only under the detach flag, and the store persists it — so the mapping was on disk the
whole time and survives a relaunch exactly as the document does. `documentPaneID(_:)` reads it.

The local-id FALLBACK is right for the mirror, whose overlay is this client's own namespace, and
wrong for anything shared. `documentPaneIDIfKnown(_:)` is the shared-surface form: a tree-local id in
the presence roster names nothing on any other client.

### 2. A mirror change repainted nothing

The mirror is a plain value in a plain box, so that its convergence is provable with no SwiftUI near
it — which also means folding a frame in is not `@Observable`. A read funnel consulting only the
mirror registered no dependency, so the row held its old value until an unrelated mutation happened
to repaint it. That is precisely the multi-client case: a client whose only source of news is the
document changes nothing of its own, so the unrelated mutation never comes.

`workspaceMirrorRevision` is the box's observable shadow, bumped from `onChange`. It carries no data
— the `completionFlashTick` idiom.

### 3. Only `runningCommand` was worth routing through the document in Phase 4

The obvious reading of §7.2 is "move every per-pane fact to the mirror". Most of them do not need it:
`ClaudePaneDetector.reestablishOnReattach` already re-asserts types 26/27/36, so foreground process,
agent status, label and intent all recover on a returning client by themselves. Routing them would
have been churn with no observable effect until Phase 5 brings the ROWS a second client would render
them in.

The open command's TEXT is the exception, and it is not re-asserted by anything: it lives in the
client's `CommandBlock` model, which is per-materialization. A pane whose bytes were never rendered
here has no blocks at all, so a busy row could say no more than "zsh".

`cwd` and `projectKey` stay on `PaneSpec` for the same reason — persisted, restored cold, and about
to be re-homed wholesale when Phase 5 makes topology host-owned.

### 4. The unread finish is a comparison; "seen" is scoped to the document epoch

`paneUnseenDone` was the fact itself, so it disagreed between clients, died on relaunch, and could
not be learned by a client disconnected across the finish — the host's done→idle decay had already
taken the edge. The counter is askable; the Set survives only as its projection.

Two rules the mechanism needs:

- The comparison is INEQUALITY, not `>`. A restarted daemon counts from zero again, and a `seen`
  stranded above the live counter silences that pane forever. For the same reason the persisted map
  carries the document epoch it was recorded under and is dropped when that changes: one re-announced
  finish beats permanent silence.
- A zero counter must never be RECORDED as seen. Every pane reads zero until the document arrives,
  so writing it erases a restored map before the channel has said which document this is.

"A finish you are LOOKING at is a finish you have seen" moves from the EDGE to the COMPARISON. Stated
at the edge it loses to ordering the moment the document is live, because the host's counter and this
client's own `.done` arrive on different paths in no guaranteed order.

### 5. "Held by `<label>`" is blocked on Phase 6, not deferred

§7.2 filed it under Phase 4. It cannot be: attachment needs the pane channel to declare whose it is,
and only the workspace channel's `subscribe` carries a `clientInstanceID` — which is why the host
fills the roster's `panes` list with nothing. The declaration arrives with the pane-observer class.

The roster does know who is VIEWING each pane, which is honest on its own and now reads in the row
tooltip. Rendering ownership on a viewing record would have been a guess dressed as a fact, and
suppressing `channelOpen` on the strength of it would make panes unopenable for a reason the user
could not undo.

### 6. `pane/lastActivityMS` stays unstamped

The session keeps no last-activity latch and the only place to make one is the PTY read path — a
wall-clock read per chunk, on the hot path, for a field nothing reads. `0` is already the record's
own "never observed", so the absence is expressible rather than a lie.

## Multi-client Phase 5: the layout becomes host truth (2026-07-27)

[docs/45](../45-multi-client-state-sync.md) Phase 5. Phase 4 shipped the per-pane FACTS, which repair a
degraded row; two clients still held two separate trees, so a tab opened on the Mac simply did not
exist on the phone. Six decisions the plan did not settle, or settled differently.

### 1. New object ids are proposed by the CLIENT, not minted by the host

§4.1 has the host mint pane ids and the client "learn the id back". It does not, for one reason:
latency. An optimistic overlay cannot insert a leaf it has no id for, so a host-minted id makes every
split wait a round trip before anything appears on screen — worst exactly where the round trip is
longest. `splitPane`, `spawnPane`, `spawnTab` and `newSession` therefore carry the id, and the host
validates rather than mints: a proposed id already in use — **including one parked in the closed-tab
ring**, which is still a real pane a reopen will bring back — is `rejectedInvalid`. Aliasing two
panes onto one PTY is the same hazard the mux's own exclusivity check exists for.

The side benefit is that a retried intent is idempotent, which the plan's version could not be.

### 2. Zoom and sync-input are ASSIGNED, never toggled

Both were toggles client-side, where a toggle is unambiguous. Over shared state it is not: the result
depends on how many clients sent it, and two clients zooming the same pane cancel out. An idempotent
assignment cannot have that bug, and it is what makes a duplicated intent free.

### 3. The closed-tab ring holds whole TABS, not ids

§5.3 gives `root/closedTabRing` as a `TabID` list. A `TabID` alone cannot rebuild a tab, and ⇧⌘T has
to put back the split tree and every pane's spec — so the ring names tabs whose `tab/*`,
`splitNode/*` and `pane/*` entries are still in the document. **A closed tab is exactly a tab whose
`tab/sessionID` back-pointer names a session that does not list it in `tabOrder`.** No new grammar;
one new rule, which is that the reaper leaves them alone.

### 4. The reaper had to narrow, and "not captured" is now three cases

Phase 4's rule — reap what the capture pass did not report — was correct while the document held
liveness only, because "not captured" and "not a pane" then coincided. With topology here they do
not: a pane the host restored from disk has no process (that is what a restart IS) but is a real pane
in a real tab, and the old rule would have erased the user's layout on every daemon restart. One pass
now decides all three: captured → its liveness; in the topology but not captured → `liveness = 2`,
keeping `cwd` and `projectKey`, which describe a PLACE rather than a process; neither → reaped.

### 5. `pristine` is answered by the FILE, and any accepted intent ends it

`adoptWorkspace` asks "has this host ever had a workspace of its own?". The answer is whether a file
exists — and it has to be asked BEFORE `load()`, which mints a default when there is nothing to
restore and so can no longer tell the two apart. Any accepted intent then ends pristine, including
one that changed nothing: a client that renamed a tab to its own name has still taken ownership.

### 6. The optimistic patch retires on a FRAME COUNT, not a `stateNum`

`intentResult` carries no state number, and does not need one. The host bumps `stateNum` and queues
the new document BEFORE it queues the result, and the result is not gated on the outstanding frame —
so the first document frame to arrive after an `applied` result provably already contains that
intent's effect. Retiring on the answer itself would blink the old layout back for one frame;
retiring on a frame that arrived BEFORE the answer would show the old layout until the next unrelated
change. A refusal is the exception and snaps back at once, because waiting keeps showing the user
something the host has already said is not true.

Two findings from wiring it up that are not decisions but bite the same way:

**Exactly ONE document frame is outstanding at a time.** A test client that acks once sees one more
frame and then silence, which reads as the host having stopped publishing. It is the flow control
working: while an ack is pending, updates coalesce into the pending slot, which is what keeps every
diff's `baseStateNum` equal to what the client actually holds.

**A test that constructs a `HostServer` with the document enabled must inject a store.** `load()`
mints and the persist sink writes, both against `<Application Support>/SlopDesk/workspace-state.json`
— so one test against the default path silently replaces a workspace somebody is using.

## Multi-client Phase 5b: the pane's facts get somewhere to live (2026-07-27)

[docs/45](../45-multi-client-state-sync.md) §7.3. Phase 5b moved every per-pane fact off `PaneSpec` and
into the document, read through `HostWorkspaceMirror`. Three rulings the move forced.

### 1. `SLOPDESK_WORKSPACE_DOC` stays default-OFF, and the client is not allowed to need it

The open question in docs/45 §10 was whether the flag flips ON with this phase. It does not. The
reason is a rule, not a schedule: **the flag gates a TRANSPORT, so nothing on the render path may
depend on it.** A client with the flag off must draw the same sidebar as one with it on, one RTT
staler — otherwise "off" is not a bake-in switch, it is a second product with its own bug list, and
the no-backcompat directive forbids exactly that dual path.

That is why the store still owns `tree`, and why the facts that left `PaneSpec` land in the MIRROR
rather than in the channel: the mirror has two producers, and the per-pane control pushes are the one
that works with the flag off. The flag flips when the store's mutations become intents (the remaining
Phase 5b step) — at which point a flag-off client would have no layout at all, and the answer is to
flip it, not to keep a tree-owning path beside the projection.

### 2. The client's cache is a PICTURE, and the two layers say which

`workspace-cache.json` holds what this device last knew about ONE host's panes, gated on
`host:port` — the only host identity available before connecting. What it seeds is split by what the
fact IS, and the split is the whole reason it can never go stale:

- `pane/spawnCwd` is TOPOLOGY — where this pane's shell is asked to start. It joins the seeded
  topology, because a respawn after a host restart has no live shell to ask and no other source.
- `pane/cwd` and `pane/projectKey` are LIVENESS — where a shell IS. They go to the mirror's FAST
  PATH, which the erasure rule deletes for any key a host frame supplies.

No promotion step, no fallback title, no freshness heuristic: those three are how a cache outlives
the fact it cached, which is the `vi .` bug in its original form. The epoch is deliberately not a
gate — a hostd restart mints a new one while restoring the document byte-identically, and gating the
paint on it would blank the window on exactly the reboot case the cache exists for.

**The reopen ring counts as live.** A closed pane's facts are not reaped on the close edge, because
⇧⌘T restores the original `PaneID`s and would otherwise bring the pane back with no directory. The
host's applier already unions `closedTabs` into its live set; one document with two answers is the
failure mode.

### 3. Shape can no longer tell a real session from the throwaway default

`On Launch = New Window` skips its `.previous` snapshot when `workspace.json` is "the default the
store autosaved last time". With the pane's facts gone from the tree, a real single un-renamed
terminal is structurally IDENTICAL to that default — and skipping on shape destroys it, taking with
it the `PaneID` the host has a PTY filed under, which can then never be reattached.

So the skip takes two facts: default-shaped AND a sidecar already exists. With no sidecar there is
nothing to lose by writing one. `WorkspaceFile.isDefaultShape` — `persist::is_default_file_shape`, asked of the FILE so the two
seed names are never spelled client-side — is a shape test and says so; the ambiguity is resolved
where the consequence is.

Two things that follow, and are not decisions:

**`TreeWorkspace.currentSchemaVersion` goes to 12.** The retired keys are outside `CodingKeys`, so a
file from the previous shape decodes "successfully" and the next autosave rewrites it without the
user's presets and templates — silently, with no `.corrupt` copy. Stale data has to decode-FAIL.

**An optimistic patch needs a driver.** `expirePending` had none: a send that threw left a patch
standing over host truth forever. The failed send now drops its own patch at once (the host was never
asked — there is no answer to wait for), every inbound frame sweeps before it is folded in, and a
one-shot backstop covers a host that accepted and died on a channel too quiet to sweep itself.

## Multi-client Phase 5b: the store's mutations become intents (2026-07-27)

[docs/45](../45-multi-client-state-sync.md) §7.2. The step the entry above defers: `WorkspaceStore.tree`
stops being a stored `TreeWorkspace` and becomes a projection of `workspaceMirror.topology`, and every
mutator becomes an intent. Two rulings, and the seam that makes the cutover reviewable.

### 1. `SLOPDESK_WORKSPACE_DOC` flips default-ON on BOTH ends in the SAME commit

Not a schedule — a coupling. A host with the flag off answers `sendOpenAck(accepted: false)`, which
the client publishes as `.refused` and never retries, because a refusal is a definite answer rather
than a transient failure. So a default-ON client against a default-OFF host holds `topology == nil`:
zero sessions, a blank window, and no error anywhere, since a nil topology makes `stageIntent` return
`nil` and every mutation a silent no-op. The two defaults move together or not at all.

The flag keeps its `!= "0"` shape on both ends, which is this repo's default-ON idiom.

Two things this ruling costs, named rather than discovered:

**`syncInputTabs` becomes persisted host truth.** It rides `tab/syncInputArmed`, which the host
persists with the rest of the topology — overturning its "never persisted, dies with the app" doc
comment. Sync-input surviving a relaunch is a behaviour change and is the price of the tab being one
object that every client and the host agree about.

**The close successor is the host's, so the project-section rule moves with it.** `plannedTabSuccessor`
picks MRU, else the neighbour inside the same PROJECT SECTION, else display order — that middle clause
is the `ed76f137` fix for the close-jumps-to-another-project bug, and it is not fixable client-side
once the host owns the close. So it is re-landed rather than surrendered: `TabOrderingEngine` (with the
pane → project-key precedence that feeds it) lives in `SlopDeskWorkspaceModel`, below both ends,
because `SlopDeskHost` cannot see `SlopDeskWorkspaceCore` and a second transcription host-side is
exactly how the bug comes back. `WorkspaceIntentApplier.apply` takes the pane → key lookup as a
parameter; the host document, the loopback and the client's optimistic overlay all feed it the same two
document cells (`pane/projectKey`, else `pane/cwd`) so all three pick the same tab.

So the successor RULE is unchanged. What the move actually changes is the ring it reads: the MRU is
host-owned and SHARED, so two clients closing the same tab land on the same tab, where two per-client
rings would have sent them to two different ones. That is the point of the phase, stated in the one
place a user would notice it.

### 2. The seam is opt-in, and the client never installs a document of its own

`WorkspaceChannelClient.send(intent:)` refuses anything that is not `.live`, and `.live` is published
only from inside the async `start()` run loop. Every store mutator is synchronous. So the cutover
turns ~430 synchronous call sites across ~100 test files into no-ops that compile, log nothing, and
fail the suite as "nothing happened" with no pointer to the cause.

`LoopbackWorkspaceDocument` answers that by BEING the host in-process: the same
`WorkspaceIntentApplier`, the same `encodeDiff` → `decodeDiff` round trip through the mirror's own
apply entry point, on the caller's turn. A differential test pins it against `HostWorkspaceDocument`
byte for byte, because the decision function is shared but the versioning around it is not.

**Nothing installs one by default, and that is the ruling.** A client that can rewrite its own
workspace with no host in the loop IS the locally-owned tree this phase exists to delete, and shipping
one as the default would make "the host applied my intent" and "I applied my own intent" the same
code path — a green suite with the workspace channel entirely broken. So it is reached by name
(`WorkspaceStore.attachLoopbackWorkspaceDocument()`), production builds its channel through
`liveWorkspaceChannel`, which has no document, and a client with no host keeps exactly one honest
outcome: it cannot change the layout.

**Frame order is result-then-document.** `WorkspaceChannelSession.drain` writes every queued
`intentResult` before the state frame, so an `applied` result arms its patch at `framesApplied + 1`
and the diff immediately behind retires it in the same turn. The loopback reproduces that order; the
opposite order leaves one inert patch shadowing host truth until some later intent sweeps it.

### 3. Two facts the cutover has to carry, found by measuring

**`spawnTab` and `splitPane` are not determined by their arguments.** `WorkspaceTreeOps.newTab` mints
the `TabID` itself, so the client's optimistic patch and the host's diff name different tabs for the
same intent. Ruling 1 of the Phase 5 entry — new object ids are PROPOSED by the client — covers the
pane and not the tab.

**Presence is drained by one task, not one per update.** A detached task per `updatePresence`
publishes in scheduling order, not issue order, and the host keeps the newest `presenceClock` and
ignores the rest — so a reordered burst leaves the roster showing a view the user has already left,
permanently, with nothing later to correct it.

### 4. The cross-tab gutter drop is a wider op 23, not a lost gesture

`dockPaneAtTabEdge` already carries `(sourcePaneID, targetTabID, edgeByte)`, and it already refuses
anything that does not land in the tab the client named. What it did not have was an applier that could
GET there: it ran the same-tab `WorkspaceTreeOps.moveLeafToRootEdge`, so the rail-drag MOVE of a pane
out of one tab into another tab's container gutter was refused on arrival. The fix is
`moveLeafToTabRootEdge`, which resolves the destination by tab id instead of by `activeTabIndex`;
`moveLeafToActiveTabRootEdge` delegates to it, and is the local gesture pointed at the active tab.
**No wire change and no golden change** — the args always said which tab. Accepting the loss would
have deleted a shipped gesture for more work than delivering it.

A destination in another SESSION stays refused. The prune and the insert are one session's business —
the pane's spec lives in `session.specs`, so a cross-session dock is a different op with a different
invariant to keep, and no gesture asks for one.

### 5. The GUI gates launch a real host and a throwaway workspace dir

`check-video.sh` ran only `slopdesk-videohostd`. Once the layout is the host's, the detached `.desktop`
pane the video seam mints is an object in a document that daemon does not have — the client would send
its intent nowhere and the gate would pass on a screenshot of an empty window. So the video proof
starts `slopdesk-hostd` too and points `SLOPDESK_AUTOCONNECT_PORT` at it, which is the TCP leg
`WorkspaceStore.videoTarget(from:)` already reads. The alternative — installing a
`LoopbackWorkspaceDocument` under automation — would make the GUI proof stop proving the shipping
path's layout, and installing one by default is rejected in §2 above.

Both gates give their daemon a throwaway `HOME` **and** a fresh `SLOPDESK_WORKSPACE_STATE_DIR`. The
client's `persistence: nil` under automation protected the developer's `workspace.json`; it protects
nothing once the client reshapes the HOST. Fresh, not merely private: `adoptWorkspace` answers
`rejectedStale` to a host that already has a workspace, so a reused dir would keep a stale layout and
the screenshot would prove the wrong thing.

### 6. What the cutover found once every mutator went through the applier

Six client rules turned out to live in the client. Each is now the applier's, because a client cannot
correct the host afterwards:

**A cascaded-away tab is as reopenable as a closed one.** `closeTab` filed the whole tab onto the ring;
`closePane` did not — so closing a tab's SOLE leaf silently cost the user their ⇧⌘T. It captures now,
through the same helper, when the pane it is asked to close is its tab's only leaf.

**Closing a BACKGROUND tab returns the session's own active tab.** Ahead of the MRU ring, because the
ring's head is where the user was BEFORE, which is not where they are now. Without it, dismissing a tab
you are not looking at moves your selection — the bug the index clamp used to cause.

**A closed tab outlives its session.** A session emptied by closing its last tab takes its id with it,
while the tabs it lost still hold the only copy of their panes' specs. So ingestion requires the
`tab/sessionID` back-pointer to be PRESENT but no longer to resolve, and `reopenClosedTab` lands an
orphan in whichever session is active rather than refusing it.

**`adoptWorkspace` is staged optimistically.** `pristine` is a fact about the HOST's own file and no
cell carries it, so a client asking `WorkspaceIntentApplier` "would this be accepted" can only answer
by assuming yes. `WorkspaceMirrorBox.stageIntent` therefore passes `documentIsPristine: true` and lets
a `rejectedStale` snap the patch away — which is what the pending layer is for. Refusing locally
instead would make op 0 unsendable by construction, and the automation bootstrap is its only caller.

**`canMutate` requires `.live`, not merely a channel.** The mirror is SEEDED with the restored tree at
`init`, so `topology != nil` the moment the store exists — a bootstrap armed on "there is a topology"
would fire before the subscription and be dropped by `send(intent:)`'s own guard, consuming itself.

**A tab with no active pane is unrepresentable.** The document's tab decoder repairs a missing focus to
the tab's first leaf. So the client's "looking at no pane" report is reached by having no workspace at
all — refused, or not yet subscribed — which is the state a client is actually ever in.

### 7. `followSessionFocus` is an OVERLAY on the projection, not a second tree

docs/45 §8.2 shipped the flag — persisted, ON macOS, OFF iOS — and nothing read it. Reading it is the
last thing the cutover owed, and it is the one place where "the layout is one value" has to bend: an
iPhone glancing at a build log must not drag a Studio's screen with it, and OFF is the shipped iOS
default, so the unfollowing path is not an edge case.

It is expressed the same way the divider drag already is — a device-local value the `tree` getter lays
over `workspaceMirror.topology`, keyed off the same `workspaceMirrorRevision` that both caches the
projection and invalidates every reader. `WorkspaceStore.DeviceFocus` holds one tab and, when the
navigation named one, one pane; `stageFocus(tab:)` / `stageFocus(pane:)` are the fork, and every focus
gesture — `selectTab`, `selectSession`, `focusPaneTree`, and the directional `moveFocusTree` — goes
through them, so nothing can grow a fifth path that ignores the flag.

Three things this shape decides:

**The overlay re-applies the applier's own op.** It runs `WorkspaceTreeOps.focusPane`, which is
literally what op 10 runs host-side, so an unfollowing device sees precisely what it would have seen
had it been following — including the zoom-exit rule, without which a local focus could land on a pane
the tab's shared zoom hides.

**It resolves at read time and is never reconciled.** A tab or pane another client closed simply stops
applying and host truth shows through, so there is no sweep to get wrong and no way for this device to
be stranded on a view of a thing that is gone.

**Turning following back ON clears it.** A surviving overlay would pin the device to a tab no other
client can see it on. That also means the only state in which one can be held is "not following", so
the overlay needs no second guard on the flag — one rule, checked in one place.

Presence is untouched by all of this and deliberately so: `currentWorkspaceView()` reports the
projection, which already carries the overlay, so an unfollowing client still publishes where it is
looking and the roster still names it. That is the whole difference between looking away and hiding.

Two consequences that fall out of putting the overlay under `tree` rather than beside it, both wanted:

**A LAYOUT gesture still lands where the user is pointing.** `splitActivePane`, `toggleZoomTree` and
the rest resolve their target off `tree`, so they name the pane THIS device sees — an unfollowing
phone splits its own pane, not the Studio's. The intent carries that pane's id, so the host applies it
to the right leaf and every client sees the split. Only FOCUS is device-local; the layout stays one
value, which is the line the whole phase draws.

**An unfollowing device does not feed `session/focusMRU`.** The ring is advanced by the `focusTab`
intent, so a phone that sends none contributes no history and the close successor is chosen from where
the FOLLOWING clients have been. That is the correct reading of §8.2 — a client that declines to move
shared focus has also declined to vote on it — and closing a tab remains a shared layout change either
way, so the phone's own view falls back to host truth when the tab it was on goes.

## Multi-client Phase 5b: what the projection owed the rest of the app (2026-07-27)

[docs/45](../45-multi-client-state-sync.md) §7.2. A review round over the cutover above. Every finding
here has the same shape: `WorkspaceStore.tree` became a value nothing local has to touch for it to
change, and six things around it still assumed the opposite.

### 1. A document change reconciles the registry — the tree of intent moved without its table of liveness

`reconcileTree()` had 51 call sites and every one of them was a store MUTATOR. That was correct while
the store owned the tree: nothing else could change the leaf set. With `tree` a projection it is the
whole multi-client case that is missed — client A splits, client B's rail grows a row for a pane B has
no `LivePaneSession` for (blank, no PTY, no error), and a pane A closes leaves B's handle and its mux
channel up forever. It fires on the SINGLE-client path too, at every connect: the launch seed is
replaced wholesale by the host's own snapshot, whose pane ids this client has never seen.

So the mirror's change hook reconciles. Two rules make that safe:

**A reconcile already running suppresses it.** The diff clears the overlay of every pane it orphaned,
and each clear announces itself — without the guard the hook re-enters the pass that triggered it,
once per cleared pane.

**A document-driven pass does NOT acknowledge focus.** `clearActiveLeafCompletionBadge()` and
`refreshFocusedDoneSettle()` mean "this user has arrived at the focused pane", and a change another
client published is not this device visiting anything. Unread-completion is a per-DEVICE fact; running
those on a remote change is how a ✓ disappears before anyone here saw it.

### 2. With no document there is no layout, so nothing is written

`stop()` resets the mirror, and it runs on the way to EVERY re-subscribe — so `topology == nil` and
`tree` is a workspace of zero sessions for as long as the resubscribe takes, and forever against a
host that refuses the channel. Both writers read `tree`: the layout save and the document-fact cache.
A quit in that window replaced `workspace.json` with an empty workspace and `workspace-cache.json`
with an empty state — the layout and the cold-paint folder names gone permanently, for a condition
that is not an error at all.

The absence of a document is not an empty document. Both writers skip.

### 3. Op 26 `setPaneVideoTarget` — the mint is not the last word on a binding

**This is a wire addition, and `golden/golden_vectors.json` moved for it** (one appended op entry,
plus two new `workspaceIntentArgs` vectors; hand-merged, generated with no `SLOPDESK_*` set).

`spawnDetachedPane` was documented as the only op that can write `pane/videoTarget`, and the cutover
made `updateSpecLive` drop anything that was not an authored rename. Between them, the pane-rebind sink
— whose entire job is "persist every committed video endpoint so a relaunch re-streams the bound
window" — became a debug log line. The display switcher and the window re-pick both move a stream that
is ALREADY RUNNING: the document kept naming display 0 while the window showed display 1, so a relaunch
re-streamed 0 and ⌥⌘N on display 0 revealed the window showing 1 while ⌥⌘N on display 1 minted a
duplicate.

There is no client-side repair — a fact with no op behind it is one the next host frame erases. The op
carries the DERIVED title with it (the applier renames the pane to the new target's title unless the
user authored one) so the binding and the label can never disagree, and a zero-length target UNBINDS,
which stays distinct from bytes that fail to decode.

### 4. The device-focus overlay follows the object the device itself just made

§7 above ruled that the overlay is never reconciled — a tab another client closed simply stops
applying. That is right for a change this device did not ask for and wrong for one it did: the appliers
land a new tab, a split's new leaf and a reopened tab FOCUSED, and an overlay still naming the old one
undoes exactly that. On iOS, where not-following is the default, ⌘T grew a rail row the device never
switched to and a split left the keystrokes in the pane it was split off.

So a staged intent adopts the focus it moved, and the probe has two halves because the appliers move
two different things: `spawnTab` / `newSession` / `reopenClosedTab` change the ACTIVE TAB, while
`splitPane` / `closePane` / `reattachPane` leave it alone and focus a leaf inside whichever tab they
touched — which, on an unfollowing device, is the device's tab and not the host's. A gesture that moves
no focus at all (a divider drag, a rename) leaves the device exactly where it was looking, which is
what keeps §7's guarantee intact.

A device whose own tab went away with the change drops the overlay rather than keeping a dead `TabID`:
⇧⌘T restores a tab under its ORIGINAL id, so a stale overlay would silently come back to life with it.

### 5. The launch adopt is sent WITHOUT an optimistic patch

§6 above ruled `adoptWorkspace` optimistic, because `pristine` is a fact about the host's own file and
no cell carries it. That ruling stands for the automation bootstrap. It does not survive giving op 0 a
NORMAL-launch caller, which it needed: `stageAdopt` had no non-automation caller at all, so a user
upgrading with a six-tab workspace met a first-run host, got its single-pane default, and lost the
layout — uploaded nowhere, even though `documentIsPristine` means the host would have taken it.

Offered optimistically, the far more common REFUSAL (any host that already has a workspace, i.e. every
launch after the first) would flash the client's stale layout for a round trip — and, with ruling 1
above, spawn a shell for every pane in it and kill them all when the refusal lands. So the launch offer
goes out unstaged: nothing to roll back, a refusal costs one frame and changes nothing on screen, an
acceptance arrives as an ordinary document frame. Once per launch — a reconnect must not re-offer a
tree that describes the workspace as it was before every change made since.

### 6. Three rules that were counting the wrong thing

**The ⇧⌘T cue asks WHICH tab is on the ring, not how many.** `WorkspaceIntentApplier.capturing` trims
to `closedTabRingCap` right after appending, and the ring is host-persisted and shared — so the count
reaches 25 and never grows again, and every close from that moment on loses its undo affordance while
⇧⌘T keeps working.

**A re-tile exits zoom.** `WorkspaceTreeOps.applyLayout` cleared `zoomedPane` ("`select-layout` exits
zoom"); op 24 carries only ids and axes, so the applier preserved it. A zoomed tab renders one pane, so
the re-tile lands invisibly while the caller's cycle cursor keeps advancing underneath. The applier
clears it, which is where the rule belongs now.

**`tabFocusHistory` is deleted, not kept.** The close successor reads `topology.focusMRU`; the client's
ring had no reader left, and a test still pinned its exact contents. A pinned value that cannot affect
behaviour is worse than no test: the next editor reasons about the wrong MRU. The tests now assert the
document's ring, which is the one the close path actually reads.

### 7. A refused layout change is REPORTED, not silently swallowed

docs/45 §7.2 said "the UI disables mutation while the workspace channel is down", and nothing read
`canMutate`. Because `init` seeds the mirror, a store with a dead channel renders a complete,
normal-looking workspace in which every gesture is a no-op logged only behind
`SLOPDESK_WORKSPACE_DEBUG` — indistinguishable from a UI that ignored the gesture.

Disabling was rejected: the controls are the whole workspace (every divider, every tab, every pane),
graying them is a large surface for a transient state, and the honest problem is that the failure is
INVISIBLE rather than that it is possible. So `stage(_:_:)` fires `onLayoutChangeUnavailable` and the
app raises a transient chip beside the ⇧⌘T and jump cues it already has. A refusal ON THE MERITS — a
re-tile of a lone leaf, a reopen with an empty ring — stays silent: that is the document doing its job
and says nothing about reachability.

---

## Multi-client Phase 6: the read-only subscriber, and the phone that fits (2026-07-27)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §8.3, §8.4, §9 Phase 6. Shipped
behind `SLOPDESK_PANE_FANOUT` (`== "1"`, **default-OFF**). No wire change, no golden change: the whole
phase leaves `golden/golden_vectors.json` byte-identical and moves no unknown-type probe.

### 1. Read-only is a property of the SUBSCRIBER, never of the session

An observer (`channelClass == 2`) is one member of a `MuxChannelSession` that has other members. Two
things share the PTY with it and must keep writing: every ordinary member's own input relay, and
`writeRawForControl` — the `slopdesk-ctl` / orchestrator injection path, which is not a subscriber at
all. A session-level `isReadOnly` flag would gag the cockpit the moment somebody opened a read-only
view, breaking every scripted answer with no error. So the drop lives in `startInputRelay(for:)` and
nowhere else.

### 2. A dropped frame is STILL credited — this is the whole trap

Credit is granted at CONSUMPTION. A frame that is dropped without `noteConsumed` never returns the
window: the observer's sender parks after exactly one window and the channel dies silently, with no
error and nothing to grep for. It would present as "the read-only client froze after a while", on
hardware, weeks later. `testAnObserversInputIsDroppedButStillCredited` delivers more than a full
window so a build that drops-without-crediting cannot pass by accident.

The echo probe and `foldUserInput` ARE skipped with the write. `foldUserInput` is the Esc-cancel
unblock edge, so an observer's stray keystroke would clear another client's `.needsPermission` latch —
the supervision alert vanishes and nobody answers the prompt.

### 3. An observer never votes in the size fold, and the rule is structural

Passivity is applied inside `addResizeContributor`, not at the join call site, so every path that
re-resolves passivity (notably `reresolveSizePassivity` on a late workspace `subscribe`) keeps it. The
observer is still REGISTERED as an attachment with `contributes: false` — it genuinely holds the pane,
and publishing it is what lets a client name who IS clamping.

The same audit found `reresolveSizePassivity` addressing `primarySubscriberID` unconditionally: under
a fan-out, one session is named by N keys, so a phone's late subscribe would have marked the MAC's
contribution passive and handed the phone the vote it was denied. It now resolves the subscriber the
connection actually rides.

### 4. `MuxClientTransport`'s acquire hop was the missing half

`channelClass` has ridden `MuxChannelOpen` since the mux landed, and `ConnectionRegistry.acquire` and
`MuxNWConnection.openChannel` both took it with a default of 0 — but `MuxClientTransport`'s injected
closure was 5-arg and could not express it, so every pane opened as class 0 because that was the only
value the hop had. The widening is a Swift signature change inside `SlopDeskTransport`, not a wire
change. Anyone estimating this as "the field is already on the wire" measured the host half only.

### 5. VIEWERS and HOLDERS are different facts and the UI says both

`paneViewers` reads the roster's `clients` (`viewingPaneID`); `paneHolders` reads its `panes`
(`attachments`), joined to `clients` for a label. A client can look at a pane it does not hold and
hold one it is not showing. The join to a label is OPTIONAL and legitimately misses —
`slopdesk-client` opens no workspace channel — so an unlabelled attachment is NAMED (`another
client`), never force-unwrapped and never dropped: dropping it would make a CLI-held pane read as
unheld and make the resolved grid's arithmetic unexplainable.

### 6. The iOS letterbox SHRINKS, and never magnifies

A phone is size-passive host-side, so the grid belongs to whichever Mac clamped the fold. The surface
is framed at its NATURAL size for that grid and then transformed — sizing the frame to the scaled rect
would make the renderer derive a different grid from it, which is the phone reflowing to its own
window, the exact thing size-passivity exists to stop. Scale is capped at 1: magnifying a glyph grid
is blur, and a coding tool's text has to be exact.

Every input can legitimately be absent (no roster, no cell metrics, pre-layout), and each of those
renders FULL-BLEED — the honest ceiling the pane's other overlays already keep: an absent decoration,
never a wrong one. The geometry and the `120×40 · sized by MacBook Pro` readout are pure values in
`SlopDeskTerminal` so they carry the tests the iOS-only SwiftUI path cannot; `check-ios.sh` proves the
view type-checks.

### 7. The `attachedElsewhere` refusal is flag-conditional, not deleted

> **SUPERSEDED 2026-07-29** by "Multi-client fan-out is unconditional" at the end of this log. The
> flag is deleted, and the refusal with it — ungating PATH D makes the branch unreachable, not merely
> flag-off. What follows is the 2026-07-27 reasoning, kept as written.

docs/45 §9 said "delete it". It survives as the flag-OFF branch instead, and that is what keeps the
shipping path byte-identical: with the flag unset the JOIN route is unreachable, `subscribers.count`
never exceeds 1, the drain never leaves its inline single-send, and no outbox is ever built. It gets
deleted the day the flag flips default-ON — which needs hardware, and hardware has said nothing yet.

## Multi-client: two clients, watched (2026-07-28)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §9 Phase 5b. `docs/45` carried
one open item through six phases — "nobody has yet watched two real clients converge on one layout".
`scripts/check-multiclient.sh` is that observation, standing. No production code moved: the gate is a
script plus the contract tests that keep it honest.

### 1. The gate observes the CLIENT, not the host

The claim is "client B's view followed". Reading the host's `workspace-state.json` proves the host
applied the intent, which is the PREMISE — a gate built on it stays green through any client-side
regression that stops B rendering what it was sent. So each instance is asked what IT is showing,
over its own `SLOPDESK_CLIENT_SOCKET`: `slopdesk --socket … windows|tabs|panes` is served by
`WorkspaceControlBackend` off `WorkspaceStore.tree`, which IS the projection. `GuiGateLaunchContract-
Tests` asserts the host document file never reappears in the gate's code.

### 2. No test seam was needed, and none was added

The obvious move — an env var that makes a client dump its topology — buys production code for an
automation-only reader. The client-control socket already answers the same question through a
SHIPPING path, so a regression in the thing the gate reads is a regression a user would also feel.

### 3. The gesture is a real menu click

`Panes ▸ Split Right` through System Events, addressed by unix id (two same-named processes). That
exercises command → intent → host → fan-out → projection, which an env seam calling the store
directly would skip. The price is an Accessibility TCC grant for whatever terminal runs the gate; it
is named in the failure message, and the gate is already Aqua-only.

### 4. What converges is TOPOLOGY

Pane ids, owning tab, pane kind, tab order, per-tab pane counts. Titles and cwd are LIVENESS (§4.1) —
pushed on a pane's own control channel, which with `SLOPDESK_PANE_FANOUT` off only ONE client holds —
and focus is device-overridable on purpose (§8.2). Comparing them would pin flakiness as if it were
the contract.

### 5. The second client starts from a DIFFERENT layout, deliberately

Both instances launch with the same automation bootstrap, so B mints its own session/tab/pane, mounts
them, and has its `adoptWorkspace` refused by a host that already has one. Convergence from two
different starting layouts is a stronger claim than convergence from an empty one, and it is the only
shape that exercises the refusal path end to end.

### 6. Shells are counted LIVE, not cumulative

`N panes ⇒ N shells` is a statement about what is still running. The cumulative `shell … attached`
count legitimately includes B's refused launch pane and the pane a closed tab took with it — both
reaped. Counting log lines would pin a number that has no invariant behind it; counting the daemon's
children names the actual failure, which is a PTY nobody's layout claims.

It is REACHED then HELD, not read once. A single read the instant `converge` returns goes red on a
correct system under `SLOPDESK_PANE_FANOUT=1`: the transient PTY in §8 below is still alive at that
moment, because `converge` returns when the DOCUMENT DIFF lands and the reap waits on B's leaf
unmounting behind it. Waiting cannot hide the failure the census exists to catch — a leak is
permanent, so the deadline expires and the same message prints — and the hold that follows is what
stops a late re-dial slipping in behind the assertion.

### 7. Fan-out is asserted POSITIVELY, per pane

With `SLOPDESK_PANE_FANOUT=1`, "no `attachedElsewhere` refusals" is satisfied by a second client that
never tried to attach. Every pane in the final layout must appear in a hostd `joined live session …
as subscriber` line; only then does the absence of refusals mean anything.

### 8. One thing hardware said that no test had

Flag ON, closing a tab on client A makes client B spawn a fresh PTY for the pane that just died: B's
leaf re-dials in the window between the host's `channelClose` and the document diff that removes the
pane, and a pane channel naming a session the host no longer has is a SPAWN. Transient — the diff
lands, the leaf unmounts, the shell is reaped, and the live count is exact afterwards — and absent
with the flag off, where B holds no channel to re-dial. Recorded in [45 §9 Phase 6], not fixed here:
it belongs to the flag that is still default-OFF. **Fixed since** — and it was the reconnect campaign,
not the leaf: see "A pane the host retired is not re-dialled" below.

## The launch dial hold: a pane does not open a PTY under an unconfirmed id (2026-07-28)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §7.4 point 5. Hardware found
a client whose restored pane ids diverged from a non-pristine host's dialling its own ids anyway:
the host spawned a shell for each unknown session id, the `adoptWorkspace` came back
`rejectedStale`, and the client then projected host truth and abandoned what it had dialled.
Measured, one hostd and two launches: `client ['5C95FF8D','71673628','6573D268']` vs
`host ['11111111','22222222','33333333']` → **three panes on screen, SIX shells**. After the hold,
same script, **three**.

### 1. It is a bug, not a tradeoff — because SHOWING and DIALLING are separable

The framing that nearly made this a design decision was that any fix "regresses the case
`runArmedLaunchAdoptIfPossible` exists for: the first connect to a genuinely new host". That is only
true of fixes that touch the OFFER — host-scoping `workspace.json`, or refusing to propose. The
offer is not the problem. What the optimistic patch buys is the layout on screen in the first frame,
and that is untouched here: the panes render, in their tabs, with their titles and cached folder
names. What it cannot buy is a PTY, because opening one is the single act on this path that a
`rejectedStale` cannot take back. So the hold is on the DIAL alone, and the pristine-host case keeps
everything it had.

### 2. The hold waits on the ADOPT'S OWN intent id, not on "some patch is pending"

`adoptWorkspace` is the one op whose verdict a client genuinely cannot predict — `documentIsPristine`
is a fact about the host's file that no cell carries, which is why `WorkspaceMirrorBox.stageIntent`
hardcodes `documentIsPristine: true` for the optimistic run. Every other pane-minting op (split, new
tab, reopen) is pre-checked against the same applier the host runs, so its ids are as good as
accepted and its panes dial on the frame the user asked for — Phase 5 ruling 1 survives intact. So
`send(intent:args:intentID:)` takes the id, `runArmedLaunchAdoptIfPossible` mints and keeps it, and
`isPending(_:)` answers the gate. Waiting on `pendingIntentCount == 0` instead would have let any
gesture in that window extend the hold for reasons unrelated to it.

### 3. The id is claimed BEFORE the stage, and that ordering is the whole fix working

Staging announces itself on the mirror, and the mirror's change hook re-runs the gate. An id recorded
after `stageAdopt` returns leaves the gate reading "no offer outstanding" for exactly the turn in
which the offer became a prediction — and the fan-out inside that turn dials every restored pane.
`beginPending` runs before the announcement, so an id claimed first is already answerable when the
re-entrant refresh fires. This was caught by the headless test, not by reading the code.

### 4. Bounded, and every terminal state opens it

A hold with no release is worse than the churn: a window of panes that never connect. So it opens on
`rejectedStale`, on `applied` + the frame behind it, on the `pendingTimeout` backstop (a host that
accepted and died), on `box.reset()`, on a channel that answers `refused` or `closed`, on a store
with no channel at all, and on the in-process loopback (whose document adopted this very seed). The
gate is a STORED, observed property because its inputs are `@ObservationIgnored` launch state and a
plain-class channel state — a computed one would never invalidate the SwiftUI body that keys on it.

### 5. Released by a store fan-out, not only by the leaf that re-renders

`TerminalLeafView`'s connect task is keyed on `dialTaskKey`, which moves `nil → pane` on release, so
a mounted leaf re-fires. That alone would leave anything SwiftUI has not got to — a satellite window,
a leaf mid-mount — waiting for an unrelated nudge. So the release also calls
`redialDisconnectedPanes()`, which no-ops on a healthy channel. It also makes the property provable
with no view in the process, which is how it is tested.

### 6. The AUTOMATION bootstrap is deliberately NOT held

`bootstrapTree` also ends in `stageAdopt`, and its refusal has the same shape — `check-multiclient.sh`
engineers exactly that for its second client, and its §6 note already accounts for the throwaway
shell. It is left alone: the bootstrap runs only under `SLOPDESK_AUTOCONNECT_*`, which no user sets,
so holding it would buy a round trip of latency and regression risk in two load-bearing GUI gates for
zero user-facing benefit. The boundary is `pendingLaunchAdopt`, which the bootstrap clears when it
takes over the launch.

### 7. The gate got a phase, and the fixture that feeds it is DERIVED

`check-launch-restore.sh` phase C relaunches with a layout whose pane ids the host has never seen and
asserts that not one of them reaches the host — plus, in `hold_steady`, that the whole log's
`attached for pane` count never leaves the pane count, which is the number that went to six. The
divergent layout is derived from the committed fixture by rewriting every UUID (`uuid5`, so runs are
reproducible) rather than committed beside it: a second file is a second thing to keep in step, and
the day it drifted the gate would pass while testing a different shape. Disjointness and pane count
are asserted, so a derivation that quietly produced the same ids fails loudly.

### 8. The gate's own hostd HOME is now wiped between runs

Found while running phase C: the scrollback JOURNAL lives under `<Application Support>` off HOME, and
the gate reset only `SLOPDESK_WORKSPACE_STATE_DIR`. With the fixture pinning the pane ids, run N+1
inherited run N's transcripts and phase A's "cold launch against a pristine host" replayed bytes from
a session it never had. That is the one input that differed between two otherwise identical runs, and
one of them went red. Wiping it is the gate keeping the promise its own comment already made.

## The fan-out laggard soak: the producer bound does not survive a shrink (2026-07-28)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §8.6, §10 open question 2.
`SLOPDESK_SUB_LAG_BYTES` and `min(lastAckedSeq)` retention shipped with the fan-out but had never
been watched under a real slow subscriber. `scripts/soak-fanout-laggard.sh` is that soak: a real
`slopdesk-hostd`, real `slopdesk-client`s, a real PTY, and a laggard frozen with `SIGSTOP` — which
stops it reading its socket and acking in the same instant, the way a backgrounded phone stops.

### 1. What the soak confirmed, with numbers

At the shipped `SLOPDESK_SUB_LAG_BYTES = 32 MiB`: retention held **8.4 MB / 113,359 lines** for the
frozen laggard and it received every one of them, in order, exactly once, on resume. The fast member
took **134.2 MB / 1,813,753 lines** — contiguous, no duplicates — *while* the laggard was frozen, so
neither the drain nor the read loop is serialised behind a parked member. Eviction fired on the
laggard and only the laggard (`pane subscriber 1: evicted`), the shell survived it, and the evicted
client reconnected to a rendered screen. Every property docs/45 §8.6 claims, on the shipped binaries.

**What it cannot settle is the CONSTANT.** On loopback the entire 134 MB moves in ~20 s, so 32 MiB of
lag accumulates far faster than any human-scale "my phone was asleep" interval. 32 MiB remains an
unvalidated first guess pending a cellular link; the soak validates the machinery around it.

### 2. What it broke: "the last subscriber is gone" ≠ "nobody is consuming"

The producer bound is `PausableQueueGate`, and it counts **enqueued-not-yet-sent** bytes. On the
inline path that is exact: the drain parks *inside* `MuxSubChannel.send`, the out-FIFO fills to
`hostQueueCapacityBytes` (64 KiB), the read loop stops, and the kernel PTY buffer backpressures the
shell. Under fan-out the drain must hand each frame to per-member outboxes and dequeue immediately —
a serial `for sub in subscribers { await sub.data.send(…) }` would give every member head-of-line
over every other — so `outstanding` returns to zero on every frame and **that source can never assert
again, for the rest of the pane's life**. `fanoutActive` is cleared only by `rebindRelay`, which runs
off a set that has EMPTIED; a pane that shrinks from two members to one while LIVE keeps the fan-out
shape forever. And eviction cannot cover the gap, because it never takes a pane to zero members.

Measured as an A/B inside one hostd — a control pane that never fanned out, a test pane that fanned
out and then lost its second client, both frozen at the same instant, both asked for 44.4 MB: the
control's shell blocked after 64 KiB and was **still blocked minutes later**, while the test pane
delivered **44,400,067 bytes** into host RAM with nobody reading. Same process, same shell, same
generator. Two clients ago is enough to lose the bound permanently, and the laggard eviction this
work exists for is one of the ways a pane gets there.

### 3. The bound is re-derived from the FASTEST member, not restored by un-latching the flag

Flipping `fanoutActive` back on a live shrink is the obvious fix and it is wrong: the surviving
member's outbox sender may be mid-batch, so the drain resuming inline sends would interleave with it
and deliver frames out of order. Quiescing the sender first is worse — it is parked on a credit
window, and cancelling it drops the batch, which is byte loss.

So the gate gains a THIRD pause source, OR-composed with the other two under its one lock: bytes
sequenced that not even the fastest member has put on the wire, `retainedBytes(above:
max(lastSentSeq))`, against the same `BoundedQueuePolicy.capacity` so the attached ↔ detached re-size
still comes from one constant. The frontier is a **MAX**, which is the whole difference between this
and "the slowest member": one parked phone can never assert the pause while a Studio is still
draining — that member's cost stays `SLOPDESK_SUB_LAG_BYTES`'s problem. A pane nobody is draining
pauses exactly where the inline path always did.

`lastSentSeq` is advanced per MESSAGE, not per batch, and that is load-bearing: once this source has
paused the read loop there is no producer left to recompute anything, so a sender's own progress is
the only thing that can resume it. Batch granularity would leave the pane waiting for the very PTY
byte the pause is preventing.

### 4. Inert wherever it must be

The source keys on a member having an outbox SENDER, not on a flag or a member count. Nothing calls
`startDataSender` outside the two fan-out paths, so with `SLOPDESK_PANE_FANOUT` unset the frontier is
empty, the backlog is 0, and the shipping default is byte-identical. `rebindRelay` builds its
returning member without a sender, so the whole detach/reattach sequence — including a cold reattach
still pushing a 64 MiB detached backlog — is untouched. `detach()` empties the set and already
recomputes, so the detached "output while away" budget is not clipped by a stale frontier.

The transition from inline delivery to an outbox seeds the member's frontier at the HEAD: everything
through it has already reached that member, and a zero would read as "has shipped nothing" and pause
the read loop on every join. A joiner's seed also claims what the drain fanned into its outbox while
its snapshot was on the wire; that optimism is bounded by one gate capacity and self-corrects on the
next frames, which is cheaper than threading an exact watermark through the join.

## A pane the host retired is not re-dialled (2026-07-28)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §9 Phase 6. The transient
recorded there — "closing a tab on client A makes client B spawn a fresh PTY for the pane that just
died" — is closed. `SLOPDESK_PANE_FANOUT=1 scripts/check-multiclient.sh` had it in its own log every
run: four panes, **five** `attached for pane …` lines, one uuid appearing twice.

    mux channel  7 (conn …ADCA27): joined live session 5AD35312… as subscriber 1
    mux channel 11 (conn …ADCA27): shell /bin/sh (pid 75883) attached for pane 5AD35312…

### 1. The window is real, and it belongs to the HOST's own ordering

`HostServer+Workspace` answers an applied `closeTab` in a fixed order: `reapPanesRemovedFromTopology`
(a `channelClose` to every subscriber) and only then `reconcileWorkspaceDocument()` (the frame that
removes the pane). Client B therefore learns the channel is dead one round trip BEFORE it learns the
pane is gone. Client A never sees the window because its optimistic patch removed the pane on the
frame the user clicked, so its session was already torn down `deliberatelyClosed` when the host's
close arrived. Reordering the host would not fix it either: the two facts ride different channels and
land on different client tasks, so their arrival order is not the host's to promise.

### 2. It was never the leaf, and that is why a leaf-level gate would have been theatre

The obvious reading — "B's leaf re-dials" — does not survive reading the code. The leaf's connect
task is keyed on `dialTaskKey`, which moves only on the pane id or `panesMayDial`, and neither moves
here; and its body routes through `ConnectionViewModel.connectIfNeeded()`, which returns on
`.reconnecting`. The dial came from the pane's own `ReconnectManager`: the peer `channelClose` ends
the inbound stream exactly as a link failure does, `handleStreamEnded` yielded `.disconnected`, and
the campaign's first attempt fires with no backoff at all.

### 3. The discriminator has to come from the MUX, because it is gone by the time anyone can ask

Above the transport a retirement and a drop are the same event: a stream that ended. Only
`MuxNWConnection` still holds the difference, so the `channelClose` arm marks the sub-channel
(`MuxSubChannel.peerCloseReason`), `MuxClientTransport` reports it as `hostCloseReason`, and
`SlopDeskClient` records it BEFORE it yields the event — the `childExited` ordering, so every
subscriber reading the mark on that `.disconnected` sees it already set. (The mark starts life as a
bool and becomes a `MuxCloseReason` on 2026-07-28, below — the same seam, one level finer.)

Keyed on the FRAME, never on the resulting state. A REFUSED `channelOpenAck` also resolves to
`.closed` and also finishes the sub-channel, and it is not a retirement — it is a verdict on an open
this side is still making (`attachedElsewhere` is the shipped one), whose campaign must keep running.
`MuxPeerCloseMarkTests` pins both, and the refusal case goes red the moment the check is relaxed to
the state.

### 4. Terminal for the SESSION, not just for the campaign

There are three dial paths and gating one only moves the spawn. `ReconnectManager` gates on
`isHostClosed` beside `isPaused`/`isClosed`/`isExited`; `SlopDeskClient.connect` refuses outright,
which is the enforcement point at the one call that opens a channel; and `ConnectionViewModel`
carries its own mirror so `connectIfNeeded()` — the leaf's remount task AND
`redialDisconnectedPanes()` — returns. The mirror is needed because `connect()` builds a NEW client:
a client-level guard alone is invisible to the path that replaces the client.

An EXPLICIT re-dial clears it. The user asking for a shell on this pane is a decision this client is
entitled to make; what it must not do is make it automatically, a round trip before it learns the
pane is gone.

**Scope (2026-07-28, below).** The `connectIfNeeded()` mirror is `retiredByHost` and answers only the
REAPED pane. The eviction close latches `evictedByHost` instead, which gates the campaign and the
status but NOT `connectIfNeeded()` — see §6.

### 5. The status is `.disconnected`, because the campaign it would be waiting for is gated off

Leaving the fold at `.reconnecting(attempt: 0)` would have produced exactly the frozen dot this repo
keeps closing elsewhere: a spinner for a retry nobody is making. A host close reads as deliberate in
the fold — it IS deliberate, decided at the other end. `observeEvents` asks the client once, on
the `.disconnected` edge, so the fold stays synchronous and every other event skips the hop. Both
closes answer this the same way; there is no campaign behind either.

### 6. It covers the EVICTION close too, and that is the right answer, not a side effect

`wireSubscriberEviction` is the other place the host closes a pane channel: a laggard removed to
protect the session. An instant re-dial there re-joins to be evicted again — a churn loop that costs
the host a state transfer each time. Both closes mean "your attachment is over, by host decision",
and in both the recovery is an explicit re-dial or the app-connection fan-out, not a reflex.

**That last sentence names a recovery §4's guard disables — corrected 2026-07-28, below.** The
fan-out runs through `connectIfNeeded()`, which §4 gates, so an evicted client had neither recovery.
The eviction close now says so on the wire and only the reap latches the `connectIfNeeded()` guard;
the campaign stays gated for both, which is the churn this section is actually about.

### 7. The gate stops tolerating it, and gets an assertion a churn cannot outlive

`check-multiclient.sh` had been taught a 20 s settle because the spawn was transient and a live
census could only be told to wait it out. A live count is the wrong instrument for something that
dies: 7a now asserts that no pane uuid appears twice in `attached for pane …`, which is written down
permanently and passes no settle. Proven red by neutralising the three gates and re-running the flag
on: the shell census still said "2 pane(s), 2 live shell(s) ✅" and 7a failed by name. The settle
drops 20 s → 4 s, which is now sized for the only thing left in it — the kernel collecting a PTY
child the host killed before it broadcast the diff.

## An evicted subscriber can come back; a reaped pane cannot (2026-07-28)

Amends the ruling above: its §6 says an evicted client recovers by "an explicit re-dial or the
app-connection fan-out", and its §4 gates `connectIfNeeded()` — which IS the fan-out
(`WorkspaceStore.handleConnectionEstablished()` → `redialDisconnectedPanes()` →
`ConnectionViewModel.connectIfNeeded()`). So under `SLOPDESK_PANE_FANOUT=1` a client that lagged past
`SLOPDESK_SUB_LAG_BYTES` was evicted, kept the pane on screen — `leavePaneChannel` drops only that
client's registration, so the topology never loses it — and had exactly one way back: the user.
For the process lifetime, nothing else could dial it.

### 1. Retirement and eviction are opposite facts, and only the host knows which

A reap means the PANE is gone: its session id stops existing, so re-opening the channel is a fresh
login shell for a row that is one round trip from leaving the layout. An eviction means only the
ATTACHMENT is gone: the shell is still running, the other members still hold it, and this client's
topology still names it. The first must never be dialled again; the second is the only thing that
CAN dial itself back.

Above the transport both are one stream ending, and after an eviction nothing further is ever said —
no document frame follows, because nothing about the layout changed. So the fact has to ride the
close: `channelClose` gains an optional `[UInt8 reason]` (`MuxCloseReason`, docs/20 §8.3.2), and
`MuxSubChannel.peerCloseReason` carries it up through `MuxClientTransport.hostCloseReason` to
`SlopDeskClient.hostChannelCloseReason`.

`.retired` is the ABSENT body — the empty-bodied close every peer already sends — so the default path
stays byte-identical and only the eviction costs a byte. And a close always CLOSES: the reason is
advice about recovery, never permission to skip the teardown, so an absent body and an unrecognised
byte read the same conservative way (`.retired`, which withholds the automatic re-dial) instead of
throwing and stranding the channel open with its PTY.

### 2. The campaign is gated for BOTH; only `connectIfNeeded()` discriminates

This is the split the previous ruling collapsed. `ReconnectManager` asks `isHostClosed` and never the
reason — an immediate retry is wrong for a reap (a spawn) and wrong for an eviction (it re-joins to
be evicted again, billing the host a state transfer every lap). `SlopDeskClient.connect` refuses for
both, because THIS client instance is spent either way.

`ConnectionViewModel` is where they part. `retiredByHost` gates `connectIfNeeded()`; `evictedByHost`
does not. What that admits is precisely two events: the app-connection fan-out, and the leaf's
connect-on-remount when the user returns to the tab. Neither is a reflex — each is a one-shot,
client-level transition, and the fan-out in particular fires exactly when this client has just proven
it can hold a connection again. Recovery is an EVENT, not a retry.

### 3. The status stays `.disconnected`, and that is not a lie

The alternative ruling — eviction is terminal until the user acts — would have obliged the UI to
render the pane unreachable, because a pane drawn as live that can never reattach is a lie. It is not
the answer taken: the recovery above is real. But the pane still reads `.disconnected` between the
eviction and that recovery, because no campaign is running and `.reconnecting` would be the frozen
dot this repo keeps closing. `.disconnected` is what a drop with no retry behind it actually is, and
it is the state both the fan-out and an explicit Reconnect act on.

### 4. Proven where it can go red

`EvictedSubscriberRedialTests` drives the real `LivePaneSession` → `SlopDeskClient` path: the fan-out
recovers an evicted pane (red before the split — one channel, timed out waiting for two), the
campaign still does not (the control that keeps it from becoming churn), and the reap is still left
alone in the same rig. `HostServerCloseReasonTests` pins the reason at its origin over a real mux
loopback, so the one line in `wireSubscriberEviction` cannot be dropped silently; `MuxPeerCloseMarkTests`
and `MuxEnvelopeCodecTests` pin the wire, including that the default close is still an empty body.
`scripts/soak-fanout-laggard.sh` remains the proof against a real PTY and a real SIGSTOPped laggard.

## Multi-client fan-out is unconditional (2026-07-29)

Supersedes "Multi-client Phase 6 §7 — the `attachedElsewhere` refusal is flag-conditional, not
deleted" (2026-07-27) and discharges docs/45 §9 Phase 6 correction #1, which held the deletion until
"the day the flag flips default-ON". The ruling: multi-client sync is a first-class, always-on
feature — tmux and zellij do not ask permission to share a session either — so it ships with **no
toggle at all**. `SLOPDESK_PANE_FANOUT` is deleted: the environment variable, the
`HostServer.paneFanoutEnabled` property, the init parameter, and both guards it fed.

### 1. The `attachedElsewhere` refusal is not conditional, it is unreachable

Ungating PATH D does not merely make the refusal rare, it makes it dead, and the difference is worth
writing down because a "flag-off branch" that survives as dead code is how a deleted feature comes
back. `attachedElsewhere` was `joining == nil && liveElsewhere != nil`. With the flag gone, `joining`
is assigned from exactly the condition `let live = liveElsewhere`, so `liveElsewhere != nil` implies
`joining != nil` and the conjunction is unsatisfiable.

The step that had to be read rather than assumed is `registerJoiningKeyLocked`, because a registration
that could FAIL would resurrect the refusal under a new name. It cannot: it returns a non-optional
`MuxSubscriberID`, its body is `reserveSubscriberID()` plus two dictionary writes, and that resolves
to a post-incremented counter with no bound, no throw and no early return. There is no
registration-failed path for the refusal to survive as, so the local, the branch, and the comment
block explaining why the branch was not deletable all go.

One refusal on a live sessionID remains, and it is a different fact at a different time:
`performJoin`'s `joinSubscriber` returning nil — the pane emptied or the joining link died while the
host was composing its state transfer. It fires AFTER the accept ack, unregisters the key, and drops
the resize contributor. Deleting the exclusivity refusal does not touch it.

### 2. The detached-store claim needed a real guard, not a substitution

The one edit in this change that is not mechanical. The claim gate read `!attachedElsewhere`;
substituting the now-constant `false` would let a JOINING open also enter `store.claim`, and a hit
would have `muxSessions[key] = session` overwrite the registration `registerJoiningKeyLocked` wrote
one statement earlier — the joiner's key naming the CLAIMED session while `muxSubscriberIDs[key]`
names a member of the JOINED one. That is unreachable today only because a live session is never
also in the detached store, which is an inference about the store, not a stated invariant of this
critical section. It is written as `joining == nil`, so the mutual exclusion is in the code.

### 3. What the deleted refusal actually protected, and what now proves it

"One attachment per sessionID" was never the point; one SHELL per sessionID was. A second
`channelOpen` falling through to `spawnFreshShell` meant a second `openpty()` + `fork()` under one id
and `claimJournal` rotating the incumbent's journal writer out mid-session. The JOIN route is what
makes that impossible, so the test that pinned the refusal is inverted into the narrower claim that
survives it: `SubprocessE2ETests.testASecondClientJoinsTheLiveSessionAndForksNoSecondShell` counts
`/bin/sh` children of the real hostd pid **out of the process table** before and after the second
client attaches, and requires the same single pid.

Counted rather than inferred, because a host that answered the second open by forking again would
satisfy every byte-level assertion in `testTwoClientsShareOneRealPTY` — both clients would see a
working shell, their own — and still be broken. `comm` is matched as `-sh` as well as `sh`: a pane's
shell is a LOGIN shell, so `argv[0]` carries the conventional leading hyphen.

### 4. The gate stops being able to run blind

`scripts/check-multiclient.sh`'s step 7b was conditional on the flag, which made the fan-out
assertion optional in exactly the runs that did not set it — a gate that can pass without observing
the feature it exists to check. It is unconditional now. Its refusal grep goes with it rather than
staying: the log string it searched for is deleted, so the check could only ever pass vacuously, and
a tautological assertion in a gate is worse than no assertion because it reads like coverage. The
`SLOPDESK_PANE_FANOUT` the script passed to each CLIENT process was already dead — no client-side
code ever read the variable.

### 5. What is tuning and stays

`SLOPDESK_SUB_LAG_BYTES` (default 32 MiB, deliberately below the 64 MiB offline gate) and the
`min(lastAckedSeq)` retention fold are NOT feature toggles and are untouched. Neither was ever gated
on the flag: `evictLaggards` skips a one-member subscriber set on its own, so a lone subscriber is
never evicted because eviction requires two or more members — not because the fan-out was off.

### 6. No wire change, no golden change

`paneFanoutEnabled` appears in no encoder or decoder. `MuxChannelClass`'s raw values are untouched
and the `channelClass` byte has been on the wire and golden-pinned since the mux landed; only its
ROUTING moves. `golden/golden_vectors.json` is byte-identical.

## The workspace document is unconditional (2026-07-29)

Supersedes both "`SLOPDESK_WORKSPACE_DOC` stays default-OFF, and the client is not allowed to need
it" (Multi-client Phase 5b, 2026-07-27) and "`SLOPDESK_WORKSPACE_DOC` flips default-ON on BOTH ends
in the SAME commit" (Multi-client Phase 5b, 2026-07-27), and closes docs/45 §10 open question 1. The
companion to "Multi-client fan-out is unconditional": multi-client sync is a first-class, always-on
feature and ships with **no toggle at all**. `SLOPDESK_WORKSPACE_DOC` is deleted — the environment
variable, `HostServer.workspaceDocEnabled` (property, init parameter, both guards),
`WorkspaceChannelClient.isEnabledByDefault`, and its two conjuncts.

### 1. A switch whose off position is a broken product is not a switch

The 2026-07-27 coupling ruling described the off position exactly, and describing it is what settles
it. A host with the flag off answers `sendOpenAck(accepted: false)`; the client publishes
``WorkspaceChannelClient/State/refused`` and never retries, because a refusal is a definite answer
rather than a transient failure; `topology` stays `nil`; `stageIntent` returns `nil`, so every
mutation is a silent no-op that compiles. What the user gets is a blank window with no error
anywhere. There is no configuration in which somebody wants that, and a flag with one usable position
is a coupling hazard with a settings-shaped disguise — the two ends had to move in one commit
precisely because the mismatch is undiagnosable from the UI.

The "flag gates a TRANSPORT, so nothing on the render path may depend on it" rule from the earlier
entry is not repudiated; it was overtaken. Once `WorkspaceStore.tree` became a projection of
`workspaceMirror.topology`, the render path DOES depend on the channel, and the answer stated there
was to flip the flag rather than keep a tree-owning path beside the projection. Removing it is that
answer taken to its end.

### 2. Only the flag's share of the optionality goes

`HostServer.workspaceDocument` was Optional for exactly one reason — a single ternary on the flag —
so it becomes non-Optional and `openWorkspaceChannel`'s flag-off refusal arm goes with it as
unreachable code.

`HostServer.workspaceStore` stays Optional, and this is the distinction the change turns on:
`HostWorkspaceStore.make(...)` returns `nil` when Application Support cannot be resolved, and
`installWorkspaceDocument` has a live degraded arm for it that mints a fresh default each start and
keeps `pristine` true. A host that cannot persist still serves a workspace. Only the `: nil` arm of
the flag's ternary is deleted; the `?` on the type, `workspaceStore?.flush()` in `stop()`, and the
injected `workspaceStore:` init parameter are all untouched.

Also explicitly not dead: `State.refused` and `sendOpenAck(accepted: false)` for `channelClass == 1`,
which a second workspace channel on one mux connection still produces (two subscribers behind one
link would each keep their own acked base for the same viewer, and the roster would show one device
twice). `testASecondWorkspaceChannelOnOneConnectionIsRefused` is what keeps that path pinned.

### 3. "No workspace channel means CONTRIBUTES" survives, minus one clause

`sizePassiveForConnection` returning `false` for a connection with no workspace channel is unchanged.
Its populations are: the shipped `slopdesk-client` CLI, which can only ever open `channelClass` 0 or
2; the transient window in which a GUI client has opened pane channels but its subscribe has not
landed, which is what `reresolveSizePassivity(connectionID:)` exists to close; and any peer that does
not know the class. The flag-off client is struck from that list and nothing else about the rule
moves.

### 4. What the removal costs, named rather than discovered

Every host unit test that passed `workspaceDocEnabled: false` did so to stop `HostServer.init` from
constructing a `HostWorkspaceStore` at the developer's real Application Support path. With the
argument gone they all construct one. That is inert as the suite stands — no XCTest calls
`HostServer.start()`, so `installWorkspaceDocument()` and therefore `store.load()` never run, and
`stop()`'s `flush()` returns early with nothing pending — but it is a live trap for the next test
that adds a `start()`.

So the standing rule from the Phase-5 entry is restated wider: **any test that calls
`HostServer.start()` must inject a `workspaceStore:` or point `SLOPDESK_WORKSPACE_STATE_DIR` at a
scratch directory.** The construction is free; reaching disk is not.

### 5. Proven by inversion, and by an env read that must stay inert

`testTheFlagOffRefusesTheChannel` is inverted, not deleted:
`testTheWorkspaceChannelIsServedWithTheEnvironmentSetToZero` sets `SLOPDESK_WORKSPACE_DOC=0` in the
process environment, builds the rig under it, and requires an accepted open AND a real snapshot. It
is red before the change and green after, and it stays red if anyone re-introduces an env read —
which a constructor-argument test could not do, because after the change there is no argument to
pass. Deleting the test instead would have left the suite identically green on both sides of the
change, which proves nothing.

### 6. No wire change, no golden change

`workspaceDocEnabled` appears in no encoder or decoder, and the golden generator reads no
`SLOPDESK_*` variable. `MuxChannelClass.workspace`'s raw value `1` and the type-17/37 envelopes are
untouched — only whether the host is willing to route the class, which it now always is.
`golden/golden_vectors.json` is byte-identical.

### 7. What `make check` still cannot see

Green here proves the removal compiles and the unit contracts hold. It does not prove two clients
converge — `scripts/check-multiclient.sh` (Accessibility TCC, unlocked Aqua) and
`scripts/check-launch-restore.sh` are the only gates that reach the shipping workspace-document path,
and neither runs under `make check`.

## The dial hold is about PROVENANCE, not about the launch (2026-07-29)

Design: [45 — Multi-client state sync](../45-multi-client-state-sync.md) §7.4 point 5. Extends "The
launch dial hold" above, which shipped keyed on one launch's `adoptWorkspace`. Multi-client sync is
now unconditional, which makes the divergent-id churn the difference between a feature and a
liability: it fires precisely when a client meets a host whose document it has not seen.

### 1. The launch was one instance of the rule, and keying on it left the rest reachable

The hold released the moment the launch offer was answered — `pendingLaunchAdopt`/`launchAdoptIntentID`
are per-launch facts — so a user who connects to a SECOND host inside one app run landed in the
identical state with none of the launch's markers: the tree on screen is host A's document, host B
has published nothing, and every pane id in it is unknown there. `HostServer` spawns a fresh PTY for
any unknown non-zero session id (PATH B, and it must — the client mints split/new-tab/reopen ids and
dials them ahead of the host applying the intent, Phase 5 ruling 1), so the establish fan-out spent
one shell per stale id and B's own document then replaced the layout and abandoned them.

Measured headlessly on the `LaunchDialHoldTests` rig — a real `WorkspaceChannelClient`, real
`LivePaneSession`s, three panes settled at host A and the app pointed at host B:
**six channels for three panes**, the same number hardware produced at launch. After the fix, three.

So the rule is stated once, about provenance: *a pane may dial an id at the host that named it, and
nowhere else.* `dialConfirmedHostKey` is the `host:port` whose own document frame last folded;
`panesMayDial` holds while it differs from the committed target. The launch arm is unchanged and
byte-identical — before any host frame there is no confirmed key, so a cold launch holds for the same
reason it always did, and the nine pre-existing pins in that file are the regression proof.

### 2. Stamped on the FOLD, never on the mirror merely announcing itself

`WorkspaceMirrorBox.onChange` fires for optimistic patches, fast-path pushes and presence rosters as
well as for document frames. Between `commitConnectionTarget(B)` and the re-subscribe that answers
it, the mirror still holds host A's document — so a stamp driven by the hook would file A's layout
under B's name and open the gate on the spot. `noteFoldedDocumentProvenance()` therefore gates on
`documentFramesApplied` MOVING, and skips `seedEpoch` (the store's own seed is the question, not an
answer). A `reset()` takes the count to zero, which is exactly right: the subscription that vouched
for those entries is gone.

### 3. `commitConnectionTarget` is the one place that can see it, and it already runs first

`AppConnection` commits the target before `establish()`, so the hold is in place before the
connection reports up and before `handleConnectionEstablished()` fans out. That function's two calls
are also reordered to open the subscription BEFORE the redial. The order settles nothing on its own
(both are asynchronous) — what settles it is the hold — but asking which panes exist before asking
for them is the rule this whole class of bug lives in, and the previous order stated the opposite.

### 4. Every arm is bounded, including the one that was not

A subscription the host ACCEPTS and never publishes on stays `.opening` forever: `.live` is published
only when a frame folds. Nothing bounded that arm, so a host that routed `channelClass 1` and then
went quiet left `panesMayDial` false for the life of the process — a window of panes that never
connect, which §4 of the entry above already ruled is worse than the churn. `paneDialHoldBackstop`
(one `pendingTimeout`, 3 s) is that release: armed while a hold stands, cancelled by any answer, and
re-armed in full at a second host rather than inheriting the first one's remainder. On expiry the
behaviour degrades to what it was before the hold existed — bounded churn beats an unbounded hold.

### 5. A reconnect to the SAME host is still not held

`testAReconnectIsNotHeld` pinned exactly the claim that left the hole open, and it was right about
its own case: after a wifi flap the panes on screen came from that host's own last frame, so their
ids are confirmed and a second round trip would be latency for nothing. It is SPLIT, not deleted —
`testAReconnectToTheSameHostIsNotHeld` keeps it (now committing a target, so it is no longer vacuous)
and `testNoPaneDialsThePreviousHostsIdsAtANewHost` asserts the opposite for a different host key.

### 6. What the gates can and cannot see

`scripts/check-launch-restore.sh` reaches the shipping launch path and its phase C still pins the
launch arm on hardware. It cannot reach a host switch — one hostd, one port — and neither can any
other gate, so the host-switch arm is pinned headlessly and this entry says so rather than claiming
coverage that does not exist. The honest residual: the second host's 2N shells are measured on the
in-process rig, not on two real hostds.

## The establish fan-out runs before the subscription, and the document is its second chance (2026-07-29)

An adversarial review of the three commits above found a regression the ten hardware gates are blind
to. `handleConnectionEstablished()` had been reordered to open the workspace subscription first, so
that the provenance stamp would be armed before any pane could dial. But `startWorkspaceChannel()`
stops the old subscription, `stop()` resets the mirror, and `WorkspaceStore.tree` is a pure
PROJECTION of that mirror — so `redialDisconnectedPanes()` iterated an EMPTY pane set on every
reconnect. A pane that gave up to `.failed`/`.unreachable` during an outage was never revived: a dead
terminal behind a green "Connected" pill, until the user hits per-pane Reconnect once per pane.

### 1. The order is forced by the projection, not chosen

The fan-out has to read the pane set before anything resets it, so it goes first. What keeps that
safe at a NEW host is not the order — it is `panesMayDial`, which is already holding by then because
`commitConnectionTarget(_:)` stamps the new host before the connection reports up, and the provenance
rule refuses ids the attached host has not named.

### 2. `.closed` is not "nothing is coming"

`resolvedPaneDialGate()` read `.closed` as a host that will never publish, and answered `true`. That
is the state the app is ACTUALLY in when the next target is committed, since the shared connection is
torn down before the new endpoint is stamped — so the arm handed a host switch exactly the dial it
exists to prevent. `.refused` keeps that answer, because a host that declines `channelClass 1` really
will never publish one; `.closed` falls through to provenance, bounded by `paneDialHoldBackstop`.

### 3. The flap that beats the snapshot needs an edge nothing else provides

An establish arriving while the mirror is already empty — the previous establish re-opened the
subscription and the link died again before the snapshot answered — has no pane set to iterate at any
point in the method, and the gate never moves, because the host that confirmed those ids is still the
host being dialled. `armPaneRedialOnDocument()` books the fan-out a second run; the first document
frame the ATTACHED host folds spends it, which is the one instant at which the panes are back on
screen and their provenance is settled.

### 4. What made the previous test unfalsifiable, and the rule that follows

`testNoPaneDialsThePreviousHostsIdsAtANewHost` claimed "RED at six channels for three panes" while
its dial-count assertion could not fail: the same reset emptied the tree before any redial could see
it, so the count stayed at 3 with the provenance rule fully disabled. It now asserts a precondition
that host A's layout is still on screen when the fan-out runs. Verified by neutering
`resolvedPaneDialGate()` to `return true` and confirming the count line fires at 6 vs 3 — the number
hardware produced. **A test over a projection must pin that the projection is populated, or it is
asserting about an empty tree and the code it claims to cover can be deleted outright.**

## A cold launch keeps the layout it restored, because the reset has nothing to forget (2026-07-29)

The window the user restored from disk left the screen the instant the connection came up.
`handleConnectionEstablished()` re-opens the subscription, `WorkspaceChannelClient.stop()` resets the
mirror on the way, and `WorkspaceStore.tree` is a pure projection of that mirror — so every establish
blanked the layout and the window stayed blank until a snapshot answered.

The reset is right when there is host truth to forget: keeping `entries` across a reconnect would let
a diff apply against a document the host may have replaced. A COLD launch has none. Everything in the
mirror is the store's own seed, carried under `WorkspaceStore.seedEpoch`, and throwing it away buys
nothing — the next subscribe declares `stateNum 0` and gets a full snapshot either way. So the reset
is now conditional on `WorkspaceMirrorBox.holdsHostDocument`, which is the same test
`noteFoldedDocumentProvenance()` already used to decide whether a host had spoken. `framesApplied`
cannot answer it: the seed is folded like any other frame.

What this closes is the blank window with no error on it — a host that accepts the connection and
then never publishes (a class it does not know, a wedged daemon, a link that dies mid-subscribe) used
to leave the user with nothing to look at. That is the same failure the deleted `SLOPDESK_WORKSPACE_DOC`
produced in its OFF position, arrived at by a different road.

Showing is not dialling. The restored ids are still unconfirmed, so `panesMayDial` keeps them from
opening a PTY until the attached host names them — the division of labour the hold was built for, and
the reason a possibly-stale layout on screen is inert rather than dangerous.

**Deliberately not changed.** A WARM reconnect — one where the host has already published — still
resets, so the window is empty for one round trip and, if that link also dies, until a subscribe
succeeds. Suppressing that would mean holding one host's entries across a reconnect, which is exactly
the hazard the reset exists for. `armPaneRedialOnDocument()` already covers the redial half of that
window.

**Latent, recorded rather than fixed.** `attachWorkspaceChannel(_:)` stops the outgoing channel — and
so may reset the box — after `attachLoopbackWorkspaceDocument()` has published its adopt. Replacing a
live host channel with a loopback would therefore erase the document the loopback is authoritative
over. Unreachable today: the shell installs one channel at startup and never replaces it.

## The workspace handshake is bounded, because silence is not a verdict (2026-07-29)

`WorkspaceChannelClient.run()` awaited the host's `channelOpenAck` with no clock on it. The pane path
bounds the identical wait — `MuxClientTransport.race` against one `handshakeTimeout`, and its comment
names the case: a dead host mid-open. The document path did not, and it is the path whose silence
costs the most.

A host that registers the channel and then never acks leaves the loop suspended for the life of the
process. `state` never leaves `.opening`, and nothing anywhere reaches that: `workspaceChannelState`
has four readers and not one of them is a watchdog. No reopen is attempted, no subscribe goes out, no
snapshot arrives. The window keeps drawing per-pane facts off the control-push sinks while its LAYOUT
sits frozen at the last fold, with nothing on screen to say why — the same blank-window class as the
deleted `SLOPDESK_WORKSPACE_DOC` and the establish reset, reached by a third road.

`paneDialHoldBackstop` still frees the panes to dial, so the state is survivable. That is exactly what
made it invisible: the panes work, the layout is simply never the host's again.

**`.closed`, never `.refused`.** A refusal is a host stating it does not serve `channelClass 1`, and
it stops this client for good — `resolvedPaneDialGate` reads it as "no document is ever coming" and
releases the hold on that basis. Silence states nothing about the host, so it has to stay retryable;
the connection layer's next establish re-opens.

**The test double had to learn cancellation.** The race cancels the loser, and `withTaskGroup` awaits
every child at scope exit. A poll loop that swallows cancellation with `try?` spins instead of
returning, which keeps the group open and turns the bound back into the hang it was added to remove.
The production awaiter (`MuxNWConnection.awaitOpenAck`) already resumes a cancelled waiter; the rig's
`VerdictBox` now does too.

**How it was found.** A mutation that made the host drop the workspace route silently did not turn
`WorkspaceChannelLoopbackTests` red — it hung xctest for 77 minutes. The unbounded wait in the rig's
`awaitOpenAck` is what stranded it, in a file whose own comment states the rule every wait in it must
be bounded.
