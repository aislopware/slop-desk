# 45 — Multi-client state sync: the host-owned workspace document

> **STATUS: SHIPPED — the design record.** Built and unconditional on both ends: the gating flags
> `SLOPDESK_WORKSPACE_DOC` / `SLOPDESK_PANE_FANOUT` were **deleted**, not defaulted-on
> ([46](46-gates-env-paths.md) "Deleted deliberately — do not reintroduce"). Sections below that
> still describe a flag or a fallback are the bake-in-era plan, kept for the reasoning; each carries
> its own *Terminal state* note. Design for `WorkspaceDocument` — one host-owned workspace state object,
> synced to N simultaneously-attached clients, host as the only source of truth. Supersedes the
> client-owned tree of [22](22-workspace-architecture.md) §1.1 for *ownership*; the tree-of-intent ⟂
> table-of-liveness split, the pure ops, and the `makeSession` test seam survive verbatim. Wire
> additions extend [20](20-wire-protocol.md) §4 (PATH 1 CONTROL, types **17** and **37**).
> Ownership rulings land in [DECISIONS.md](DECISIONS.md) **before** any code (§12).

Floor: macOS 26 / iOS 26. Scope: PATH 1 (terminal, TCP mux) + the workspace shell. PATH 2 (video),
PATH 3 (inspector) and PATH 4 (file transfer) are untouched — see §11.

All file:line citations below are verified against the working tree at `fc306605`.

---

## 1. Problem statement

Run `nvim` in a pane. The sidebar row updates to `main.go - NVIM`. Quit the client, reopen it — the
row reads `vi .` again.

Nothing about that is a persistence bug. The title is persisted (as `PaneSpec.lastKnownTitle`, the
client-side cache this document replaces with `pane/liveTitle`), the quit-time flush is
synchronous (`SlopDeskClientApp.swift:786`), and the client very often reattaches to the *same live
nvim process* — `DetachedSessionStore` parks it with an indefinite TTL by default
(`HostServer.swift:279`, [DECISIONS.md](DECISIONS.md):679). The pane the user comes back to is
literally the pane they left.

The row degrades because the **decision to trust the persisted title** is made from state that only
ever existed in the departed client's memory:

| Link in the chain | Where it lives | Survives a relaunch |
|---|---|---|
| `RailRowsBuilder.liveRowTitle` prefers a *fresh* program title over the running command (`RailRowsBuilder.swift:435-462`) | client | — |
| `WorkspaceStore.programTitle(for:)` gates freshness on `paneTitleAt[id] >= paneCommandStartedAt[id]` (`WorkspaceStore+Completion.swift:229`) | client | — |
| `paneTitleAt` (`WorkspaceStore.swift:3112`), `paneCommandStartedAt` (`:3077`) | client, runtime-only, pruned every reconcile | **no** |
| `MuxChannelSession.reestablishActivityOnReattach()` re-asserts 23 / 32 / 26 / 27 / 33 / 34 (`MuxChannelSession.swift:1120`) | host | yes |
| …but **not** type 21 `title` | host | **never sent** |

`commandStatus` (23) *is* re-asserted, so `paneCommandStartedAt` gets a fresh stamp. `title` (21) is
not, so `paneTitleAt` stays empty. The gate `stamped >= started` therefore fails forever, and the row
falls through to the raw running command — `vi .`. The gap is known and admitted in two places in the
tree: `MuxChannelSession.swift:1300-1304` ("`.title` is not re-asserted by any reestablish call, so a
quiet reconnect would never flush it") and [DECISIONS.md](DECISIONS.md):733.

That is the *instance*. The **class** is the real subject of this document:

> A host-derived fact, extracted from a byte stream by a stateful host parser, is exposed to clients
> only as an **edge-triggered event**. The host's memory of "what is true right now" is wired to an
> unrelated consumer. Any client that starts listening after the edge fired has permanently missed it
> and **has no way to ask**.

At N = 1 client this manifests as a stale sidebar. At N > 1 it is fatal: two clients that each missed
a different set of edges disagree about the workspace, forever, with no detector. And SlopDesk cannot
even reach N > 1 today — `HostServer.spawnMuxChannel` refuses a second attach to a live `sessionID`
outright (`HostServer.swift:634-643`, *"One attachment per sessionID, ever"*).

**Goal.** hostd owns a single workspace document — topology *and* per-pane facts. Every client is a
replica. A client that has never seen this host renders the full workspace, with correct titles, from
the host alone. Two clients attached at once see the same thing and cannot diverge. Same model as
tmux's server, zellij's session process, WezTerm's mux.

---

## 2. The starting point this plan was written against

> Historical. Every phase below has shipped; §2 records the single-subscriber transport as it stood
> before Phase 1, which is what the plan had to move. The exclusivity refusal it describes is gone —
> see Phase 6 and `docs/DECISIONS.md`, "Multi-client fan-out is unconditional".

### 2.1 The transport fact that gated everything

`spawnMuxChannel` computes `attachedElsewhere` inside one critical section and answers
`channelOpenAck(accepted: false)` when a live `sessionID` is presented from a second connection
(`HostServer.swift:634-643`, refusal at `:687-694`). The stated reason is sound: aliasing one session
under two composite keys would let the loser's close path kill the winner's PTY and interleave two
writers into one scrollback journal.

Below that, `MuxChannelSession` is single-subscriber **by construction**: exactly one
`data: MuxSubChannel` and one `control: MuxSubChannel` (`MuxChannelSession.swift:56-58`), which
`rebindRelay` **swaps** on reattach (`:1243-1466`) rather than appending to. One `inputTask` reads one
`data.inbound` (`:774-798`). One `TIOCSWINSZ` per pane, latest-wins (`:1850`).

So "multiple clients" is not a feature to enable — it is plumbing that does not exist.

Two pieces of it, however, already do:

- **`ReplayBuffer` is genuinely multi-reader-shaped.** `messages(after:)` (`:334`) and
  `replay(after:)` (`:522`) are parameterized per caller. Only `ack(upTo:)` (`:217`) /
  `acknowledge(upTo:)` (`:496`) are a single mutating watermark — that needs a min-fold, not a
  rewrite.
- **PATH 3 already runs N observers correctly.** `InspectorServer.serve` (`InspectorServer.swift:233-306`)
  gives each accepted connection its own `replayLog.subscribe(fromSeq:)` cursor, replay-then-live,
  with a drain-and-cancel disconnect. It is the template.
- **The host already fans out to a set.** `registerAgentStatusObserver` / `fanAgentStatusChanged`
  (`HostServer.swift:1263-1340`) is a `[UUID: closure]` observer set feeding the ctl socket. The
  pattern exists; it is simply not wired to the GUI wire.

### 2.2 Who owns what — the split this design starts from

The inventory §5.7 maps and §7 moves. Every `PaneSpec.*` row is a client-side cache of a fact the host
already holds; the document cell each one lands in is in the §5.7 table, and the caches themselves are
gone from `PaneSpec` (`b89aeebb`).

| State | Lives | Persisted | Host knows |
|---|---|---|---|
| `TreeWorkspace` (sessions → tabs → splits → `PaneSpec`) | client only | `workspace.json`, per device | **nothing** |
| `PaneSpec.title` / `.userRenamed` | client | yes | no |
| `PaneSpec.lastKnownTitle` | client (cache of host truth) | yes | yes (`_currentTitle`, `:152`) |
| `PaneSpec.lastKnownCwd` / `.projectKey` | client (cache) | yes | yes, **and re-asserted** (33/34) |
| `paneAgentStatus` / `Label` / `Intent` / `ForegroundProcess` / `Progress` | client mirrors | no | yes, re-asserted (26/27/32/36) |
| `paneTitleAt` / `paneCommandStartedAt` | client, runtime-only | no | inputs exist host-side; verdict does not |
| `paneUnseenDone` / `paneDoneDwellSince` | client | no | no concept |
| `broadcastActive` / `syncInputTabs` | client | no | no concept |
| `tabFocusHistory` (`:611`), `recentlyClosedTabs` (`:599`) | client, in-memory | no | no concept |
| `projectGitSummary` (`:3006`) | client mirror | no | yes (type 35, FSEvents) |
| `PreferencesStore`, `FolderFrecencyStore`, window chrome | client, per device | yes | correctly not |
| PTY + `_currentTitle` / `lastCwdTruth` / `lastProjectKey` / `lastExitTruth` | host, in memory | **no** | — |
| `<uuid>.scrollback` + `<uuid>.scrollback.size` | host disk (`<App Support>/SlopDesk/scrollback/`) | yes | — |

A pane's cwd and project key are the working counter-example: host-derived, cached client-side as a
warm picture, **and** re-asserted on every reattach. They live in the mirror as `pane/cwd` and
`pane/projectKey`, and that is the pattern this document generalizes to everything.

### 2.3 What the wire can express

[20](20-wire-protocol.md) §4 types 1–36 contain **no verb for topology**. There is no "list sessions",
no "describe workspace", no way for a client with zero local state to discover a pane. `channelOpen`
names a `sessionID` the client must already know, and that UUID is **client-minted** ([20](20-wire-protocol.md)
§8.2) — two devices have no shared vocabulary for "the nvim pane".

The one enumeration verb that exists, `list-panes`, lives on the AF_UNIX NDJSON ctl socket
(`AgentControlListener.swift`) for `slopdesk-ctl` — and `listPanesForControl()` reads only
`muxSessions + controlSessions` (`HostServer.swift:1237-1241`), never `detachedStore`. A pane that
survived a client quit — the reported scenario exactly — is invisible to the one "describe all panes"
API in the product.

---

## 3. Prior art

| System | The lesson we take | The mistake we avoid |
|---|---|---|
| **tmux** | Every semantic fact is server state: sessions, windows, panes, four option scopes, paste buffers, hooks. Clients hold *view* state only — tty size, scroll offset, current key table. The man page is explicit: *"the visible position is a property of the client not of the window."* | Pane titles have **no** control-mode push notification. `pane-title-changed` is hook-only (`notify.c:180-216` whitelist), so a title reaches a client only as a side effect of a border redraw. iTerm2's sync loop doesn't even poll `#{pane_title}`. **This is our bug, upstream.** The retrofit (`refresh-client -B` format subscriptions, `%subscription-changed`) is what tmux needed once it noticed. |
| **zellij** | Multiplayer is one authoritative tab/pane tree plus a `HashMap<ClientId, PaneId>` for per-client focus, and a config flag (`mirror_session`, default off) for shared focus. Other clients' cursors are painted as styled glyphs in the existing render diff — no new wire message. Session layout is dumped to KDL every 1 s, gated on a content-changed check. | Smallest-viewing-client-wins canvas sizing is a documented pain point (Discussion #5066): a phone letterboxes a Studio. Resurrection is layout + static text replay, not live-state transfer — a server death is unrecoverable. |
| **WezTerm** | Per-line `SequenceNo` with `changed_since(seq) = seqno == 0 \|\| seqno > seq`, and a **per-(connection, pane)** `PerPane` cursor over one shared `Screen` — N independent readers, one writer. A newly attached client bootstraps with `ListPanes` then a `GetPaneRenderChanges` from `seqno = 0`, which trivially returns everything: **no special-cased bootstrap path**. | `Resize` is unconditional and last-sender-wins. Two clients at different sizes fight, and the loser just gets told the new dimensions. Same weakness as `screen -x`. |
| **mosh (SSP)** | The whole convergence argument. A sender keeps the state the receiver last **acked**, and every datagram carries `diff(current, assumedAckedState)` — *not* a diff from the last thing sent. Loss, duplication and reorder are all handled by the receiver: *"do I already have `new_num`? drop. do I still hold `old_num`? if not, drop."* (`networktransport-impl.h`, commented as security-sensitive idempotency). **No retransmit path exists on either side.** | Nothing. This is the engine. |
| **Figma** | Property-level last-writer-wins by **server arrival order** — no timestamps, no vector clocks, no CRDT, because there is exactly one serialization point. Anti-flicker rule: while a local change is unacknowledged, *discard* conflicting server values rather than apply-then-correct. Fractional indexing for ordered sequences. | — |
| **Zed** | The decisive precedent for "do we need a CRDT". Zed uses a real CRDT for **text buffers**, and plain host-authoritative RPC broadcast (`UpdateWorktree`, `scan_id`, `is_last_update`) for its **Project/Worktree tree** — the structurally identical case to ours. On rejoin it re-streams the entire current worktree. Cost is O(tree), not O(elapsed). | — |
| **Yjs / Liveblocks** | Presence is a wholly separate channel: keyed by `clientID`, versioned by a **per-client** clock (newest wins, no merge), never persisted into the document, 30 s missed-heartbeat TTL, null-broadcast on clean disconnect. | Mixing presence into the versioned document. |

**Synthesis.** Ownership model from tmux. Convergence engine from mosh. Conflict rule from Figma. The
explicit *rejection* of CRDT for tree-shaped state from Zed. Presence shape from Yjs. Per-client
delivery cursors over one shared log from WezTerm — which we already have in `ReplayBuffer` and
`InspectorReplayLog`.

---

## 4. The ownership model

The classification test, stated once:

> Would two people looking at the same session disagree about a **fact**, or about a **view**?

Facts are HOST-TRUTH. Views are DEVICE-LOCAL. "Who is here and what are they looking at" is
PER-CLIENT-PRESENCE — fanned out, TTL-expired, never persisted, never versioned.

### 4.1 HOST-TRUTH — in `HostWorkspaceState`, synced to every client

| Field (today's home) | Entry key | Why it is a fact |
|---|---|---|
| `TreeWorkspace.sessions` order | `root/sessionOrder` | Topology. |
| `TreeWorkspace.activeSessionID` | `root/activeSessionID` | What a fresh client opens into. |
| `layoutPresets` / `launchPresets` / `sessionTemplates` | `root/*` | They name **host** cwds and spawn **host** commands. Host config, not device config. |
| `WorkspaceTopology.closedTabs` ring (read LIFO by `WorkspaceStore+PaneCycle.swift`) | `root/closedTabRing` | ⇧⌘T reopens a tab whose panes live host-side. A per-client undo stack over shared state is incoherent. |
| `Session.name` / `.tabs` order / `.detached` | `session/*` | Topology. |
| `Session.activeTabIndex` → **`session/activeTabID`** | `session/activeTabID` | Indices are exactly what broke in `ed76f137`. Identity, not position. |
| `tabFocusHistory` (`WorkspaceStore.swift:611`) | `session/focusMRU` | If close is an intent and the tree is host-owned, two clients computing successors from different local MRU rings diverge and the host's index clamp reintroduces the `ed76f137` bug. The ring must be shared. |
| `Tab.title` / `.activePane` / `.zoomedPane` / `.root` structure | `tab/*` | Topology. |
| `broadcastActive` / `syncInputTabs` (`WorkspaceStore.swift:1313`) | `tab/syncInputArmed` | tmux `synchronize-panes` is a server-side **window option**. Hosting only the armed bit while fanning client-side is incoherent — client B's keystrokes would not fan. Host both. |
| `WeightedChild.weight` | `splitNode/weight` (**its own object**) | Two clients dragging two different dividers write two different keys and cannot clobber each other. |
| `PaneSpec.kind` | `pane/kind` | Topology. |
| `PaneSpec.title` + `.userRenamed` | `pane/title`, `pane/userRenamed` | A rename is authorship — but authorship *of shared state*. A tab renamed on the Mac is renamed on the phone. |
| `PaneSpec.lastKnownTitle` → **`pane/liveTitle`** | `pane/liveTitle` | The client-side cache it replaces holds `MuxChannelSession._currentTitle` (`:152`) with **no invalidation signal**, which is the reported bug. |
| **NEW** `pane/titleFresh` (u8) | `pane/titleFresh` | Replaces `programTitle(for:)`'s two-stamp guess. The host owns both inputs (OSC-title stamp; segmenter open-block start), so the host ships the **verdict**. §4.4 states the rule. |
| `PaneSpec.lastKnownCwd` | `pane/cwd` | Already host truth (`lastCwdTruth`, type 33). |
| `PaneSpec.projectKey` | `pane/projectKey` | Already host truth (`lastProjectKey`, type 34). |
| `paneForegroundProcess` (`:2956`) | `pane/foregroundProcess` | Type 26. |
| **NEW** `pane/runningCommand` | `pane/runningCommand` | Today `RailRowsBuilder.liveRowTitle(runningCommand:)` reads the *client's* per-materialization `TerminalBlockModel`. A client that has rendered zero bytes cannot reproduce the sidebar title chain at all. Source: the open block superd's tap reports, latched host-side (`docs/51` §6.14). This is the missing link for "the host alone can render the sidebar". |
| `paneAgentStatus` / `Label` / `Intent` (`:2934`) | `pane/agentState`, `/agentLabel`, `/agentIntent` | Types 27 / 36. |
| `paneProgress` | `pane/progress` | Type 32. |
| type-23 running latch, `lastExitTruth`, duration | `pane/commandRunning`, `/lastExitCode`, `/lastDurationMS` | Already host truth. |
| PTY grid | `pane/grid` (cols, rows) | Published so a non-contributing client letterboxes correctly instead of guessing. |
| **NEW** `pane/liveness` (u8) | 0 live-attached · 1 live-detached · 2 journal-only/dead | Lets a client render a post-restart pane as **stale**, not fake-live. |
| **NEW** `pane/completionEpoch` (u32) | `pane/completionEpoch` | A monotone counter the host bumps on every working→done edge. The host holds **zero** per-client acknowledgement state (§8.4). |
| `PaneSpec.video` **target identity only** | `pane/videoTarget` | Both clients must agree "tab 3 slot 2 is a video pane on Display 1" — that is topology. The **modes** stay device-local (§4.3). |
| **NEW** git summary (type 35) | `project/gitSummary` | `projectGitSummary` (`:3006`) is host truth keyed by **project**, not pane — so it needs its own object kind, or a never-seen-this-host client renders no git line until the first FSEvents edge. |

**Pane identity is ONE namespace.** A pane's `PaneID` **is** its document objectID and its mux
`sessionID`, verbatim — `WorkspaceStore.documentPaneID(_:)` is the identity function, kept as a named
funnel because it is the sentence "the document calls this pane what we call it". The client PROPOSES
the id (DECISIONS, Multi-client Phase 5 ruling 1: a host-minted id would make every split wait a round
trip) and presents it on `channelOpen`, so the host files that pane's liveness under the very key the
topology names it by. `PaneSpec.resumeSessionID` is deleted: that id *is* the rendezvous identity, so
a second field for it could only disagree.

Two namespaces with a translation table between them is what put an optimistic overlay and host truth
on different keys, where the erasure rule that keeps the mirror's two layers disjoint could never fire.

**ctl-spawned panes are in the document.** `spawnControlPane` (`HostServer.swift:1388`, registered at
`:1537`) creates a real PTY pane with no client connection. It gets `pane/*` entries parented to a
host-owned session addressed by `root/unattachedSessionID`, so an orchestrator's pane is visible and
attachable from every client; the ctl `kill` verb (`:1373`) routes through the same close path so the
entries are deleted. Without this the host has two disagreeing pane inventories and the premise of
this document is false.

### 4.2 PER-CLIENT-PRESENCE — fanned out, TTL-expired, never persisted, never in `stateNum`

| Field | Note |
|---|---|
| `clientInstanceID` | Minted per **connection**, not per install — two windows of one app are two identities. |
| device label (`Host.current().localizedName`), `clientKind` (0 macOS / 1 iOS) | A **label, not a credential**. Checked nowhere, grants nothing. The no-app-layer-auth directive holds. |
| `viewingTabID` / `viewingPaneID` | The unfollowed client's own view (§8.2). |
| viewport `cols`×`rows`, size-passive flag | The client's *offer*; the fold reads attachment, not this (§8.3). |
| `presenceClock` | Per-client monotone; newest wins, no merge. |
| **derived** per-pane `attachedBy` + `sizeContributors` + resolved grid | Presence-derived by construction. Keeping them in the versioned document would persist dead connection UUIDs across a restart and churn `stateNum` on every WireGuard flap. |

### 4.3 DEVICE-LOCAL — never crosses the wire

| Field | Why |
|---|---|
| All of `PreferencesStore` (`PreferencesStore.swift:37-138`) — font, theme, cursor, scrollback depth, keybindings, appearance/density | A 27″ Studio and an iPhone must not share a font size. The one-way `video-prefs.json` sidecar hostd reads at *its* next launch is config drop, not sync; unchanged. |
| `FolderFrecencyStore` | Per-device Open-Quickly MRU, shell-history-shaped. |
| `recentCommands` (`:1465`), `clipboardRing` (`:1483`) | Per-device rings. Clipboard **sync** (verbs 15/16) is a separate shipped feature and stays as-is — the *ring* is local. |
| `WindowSizeMode`, `SidebarAutoHidePolicy`, `NewTabPosition`, `AutoHideTabsPanelMode` | How **this window** behaves. |
| NSWindow frame, sidebar width, rail collapsed | Ditto. |
| `Session.connection: ConnectionTarget?` (`Tree/Session.swift:49`) | "Which host am I talking to" is definitionally a client concept. `project()` joins host topology with a client-side connection identity keyed by `hostKey` — the same key that validates `workspace-cache.json` (§7.3). |
| `TreeWorkspace.videoModesByTarget` | Binding precedent, [DECISIONS.md](DECISIONS.md):1312-1321 — see §12 Entry 2 for the full three-leg quote and which leg this design obsoletes. |
| `selectedPanes`, `groupDragLive`, `groupHandleDragLive`, `overviewActive`, `isInteractiveResizeActive`, `nativeFrameSize`, `liveCameraOffset`, `retainedSessionIDs` | Gesture and render state. |
| `focusHistory` (canvas quick-switch MRU) | Each client's own "last window" (tmux `client->last_session`). Distinct from `session/focusMRU`, the shared successor ring. |
| Scroll offset, copy mode, hint mode, selection **inside** a pane | tmux is explicit: the visible position belongs to the client. |
| `lastNotifiedStatus`; the type-22 bell and type-25 notification **delivery gate** | You want the banner on the machine you are at. Both fan to every client and each client gates locally via `NotificationPolicy.shouldDeliver(event:appActive:sourcePaneVisible:)` (`NotificationPolicy.swift:115-122`). Duplicate banners across a user's own devices are **the point**. Host-global `hookAuthority` suppression (`ClaudePaneDetector.swift:163`) is unchanged. |
| **NEW** `seenCompletionEpoch[paneID]` | The per-viewer half of the badge. Clients agree on the **fact**, disagree on the **acknowledgement**. |
| **NEW** `followSessionFocus` (Bool, default **ON** macOS / **OFF** iOS) | §8.2. |
| `blockBookmarks` | Client-local and per-materialization. Note the pre-existing doc/impl mismatch: `WorkspaceStore.swift:1132-1140` claims stable-`PaneID` keying, `WorkspaceStore+Blocks.swift:21-25` uses `bookmarkScopeKey`. **Fix the comment, not the code.** |

### 4.4 Deleted outright, not relocated — **SHIPPED**

- `WorkspacePersistence.promotingLastKnownTitles()` (`:200-219`)
- `WorkspaceStore.programTitle(for:)` (`WorkspaceStore+Completion.swift:228-234`)
- `paneTitleAt` (`:3112`) / `paneCommandStartedAt` (`:3077`) **as titling inputs** — `paneCommandStartedAt` survives only for the elapsed-time readout
- `paneUnseenDone` / `paneDoneDwellSince` — replaced by `completionEpoch` vs `seenCompletionEpoch`
- `PaneSpec.resumeSessionID`
- `WorkspaceSchemaMigration` for the tree — the tree stops being a client schema

These heuristics exist **only to decide whether to trust a client cache**. With a host document there
is nothing to decide.

**The `titleFresh` rule, stated completely** (it is the field that kills the reported bug, so it gets
its own rule rather than a table cell):

1. A title stamped with **no open command block** → `1` (trust). Hookless shells (Starship, no
   OSC-133) must not lose titles.
2. A title stamped **before** the current block's start → `0`.
3. A title stamped **at or after** the current block's start → `1`.
4. **Respawn, and any `liveness` 2 → 0 transition, clears `pane/liveTitle` and sets `titleFresh = 0`.**
   Without this the host restores a dead process's title from disk, sees no open block, applies rule 1
   and renders it forever — the reported bug, inverted, and unrecoverable because
   `enqueueRestoredScrollback` appends restored bytes with `control: []` and bypasses
   `HostOutputSniffer` entirely (`MuxChannelSession.swift:2020-2041`), so replayed OSC escapes can
   never regenerate a type-21 push.

---

## 5. Protocol design

### 5.1 Transport: `channelClass == 1`, zero envelope churn

`MuxChannelOpen.channelClass: UInt8` is already encoded, decoded, and golden-pinned at values 0 and
255 (`Sources/slopdesk-corevectors/main.swift:1281,1291`) — and read **nowhere** in
`Sources/SlopDeskHost`. The seam is entirely free.

```
0 = .pane          today's PTY channel                 (unchanged)
1 = .workspace     the workspace-document channel      (NEW)
2                  spoken for, served by nobody        (see §8.4)
```

`HostServer.spawnMuxChannel` (`:616`) gains a **first line**, placed **before** the critical section
that routes a pane open, so the one-shell-per-sessionID invariant is untouched:

```swift
if open.channelClass == MuxChannelClass.workspace {
    return openWorkspaceChannel(open, on: connection, connectionID: connectionID)
}
```

Exactly **one** workspace channel per mux connection; a second is `accepted: false`. Only the CONTROL
sub-channel is used (unwindowed); the DATA sub-channel `openChannel` also creates stays idle.

### 5.2 Two new wire types — and only ever two

Both are verb/kind-multiplexed envelopes shaped exactly like `metadataRequest` (16) /
`metadataResponse` (30) (`WireMessage.swift:190,206`), so **every future workspace verb costs zero
type numbers and never shifts the unknown-type probe again**.

#### Type 17 — `workspaceRequest` (client → host, CONTROL)

```
[u32 BE requestSeq][u8 verb][u32 BE payloadLen][payload…]
```

| verb | name | payload |
|---|---|---|
| 0 | `subscribe` | `[16B clientInstanceID][u8 clientKind][16B knownEpoch][i64 BE knownStateNum][u8 flags][u16 BE labelLen][label UTF-8]`<br>flags: b0 size-contributing, b1 focus-following. All-zero epoch + `knownStateNum` 0 = "I know nothing". Re-sending `subscribe` **is** resync. |
| 1 | `ack` | `[i64 BE stateNum]` |
| 2 | `presence` | `[i64 BE presenceClock][16B viewingTabID][16B viewingPaneID][u16 cols][u16 rows][u8 flags]` |
| 3 | `intent` | `[16B intentID][u8 op][u32 BE argLen][args…]` |

`labelLen > 64` → `malformedBody`. Unknown verb → `malformedBody`, never a trap. Unknown flag bits →
**ignored**, not an error.

#### Type 37 — `workspaceEvent` (host → client, CONTROL)

Epoch and both state numbers are **hoisted into the envelope** so a client drops a mis-based frame
after a 33-byte read, without parsing the payload:

```
[u8 kind][16B epoch][i64 BE baseStateNum][i64 BE newStateNum][u32 BE payloadLen][payload…]
```

| kind | name | base / new | payload |
|---|---|---|---|
| 0 | `snapshot` | `0` / current | `[u32 BE entryCount][entry…]` |
| 1 | `diff` | subscriber's **acked** / current | `[u32 BE setCount][entry…][u32 BE delCount][key…]` |
| 2 | `presence` | `0` / `0` | roster, below — **full replace, never diffed** |
| 3 | `intentResult` | `0` / stateNum at which the effect becomes visible | `[16B intentID][u8 status]` — 0 applied · 1 rejectedStale · 2 rejectedInvalid · 3 unknownOp · 4 rejectedNotFound |
| 4 | `reset` | `0` / `0`, `epoch` = the NEW epoch | empty — drop everything, resubscribe from 0 |

kind-2 presence payload:

```
[u16 BE clientCount][clientRecord…][u16 BE paneCount][paneAttachRecord…]
clientRecord     := [16B clientInstanceID][u8 clientKind][u8 flags]
                    [16B viewingTabID][16B viewingPaneID][u16 cols][u16 rows]
                    [u16 labelLen][label UTF-8]
paneAttachRecord := [16B paneID][u16 resolvedCols][u16 resolvedRows][u16 n]
                    ([16B clientInstanceID][u8 contributes][u16 cols][u16 rows])*
```

`stateNum` is **`Int64`**, matching `output.seq` / `ack.seq` / `resumeFromSeq`. One seq idiom in the
codebase.

### 5.3 The state object: a flat, deterministically-ordered entry map

```
key   := [u8 kindTag][16B objectID][u8 field]                  — 18 bytes, fixed
entry := key ++ [u32 BE valueLen][value…]
```

Entries are emitted in **ascending `(kindTag, objectID bytes, field)`** order. Deterministic bytes →
golden vectors are stable and a diff never churns on dictionary iteration order. This is the
discipline `Session`'s hand-written `Codable` already uses.

| kindTag | objectID | fields |
|---|---|---|
| **0** root | all-zero | 0 `sessionOrder` `[u16 n][16B SessionID]*` · 1 `activeSessionID` · 2 `hostDisplayName` · 3 `layoutPresets` · 4 `launchPresets` · 5 `sessionTemplates` · 6 `closedTabRing` `[u16 n][16B TabID]*` · 7 `unattachedSessionID` (ctl panes, §4.1) |
| **1** session | `SessionID` | 0 `name` · 1 `tabOrder` `[u16 n][16B TabID]*` · 2 `activeTabID` · 3 `detachedPanes` `[u16 n]([16B PaneID][16B originTabID])*` · 4 `focusMRU` `[u16 n][16B TabID]*` |
| **2** tab | `TabID` | 0 `title` · 1 `sessionID` (owner back-pointer) · 2 `layoutStructure` · 3 `activePaneID` · 4 `zoomedPaneID` · 5 `syncInputArmed` u8 · 6 `userRenamed` u8 |
| **3** pane | **host-minted PaneID (== the mux `sessionID`)** | 0 `kind` u8 · 1 `title` · 2 `userRenamed` u8 · 3 `liveTitle` · 4 `titleFresh` u8 · 5 `cwd` · 6 `projectKey` · 7 `foregroundProcess` · 8 `runningCommand` · 9 `agentState` `[u8 state][u8 kind]` · 10 `agentLabel` · 11 `agentIntent` · 12 `progress` `[u8 state][u8 pct]` · 13 `commandRunning` u8 · 14 `lastExitCode` i32 · 15 `lastDurationMS` u32 · 16 `grid` `[u16 cols][u16 rows]` · 17 `liveness` u8 · 18 `completionEpoch` u32 · 19 `lastActivityMS` i64 · 20 `videoTarget` (opaque `VideoEndpoint` blob) · 21 `spawnCwd` |
| **4** splitNode | `SplitNodeID` | 0 `weight` `[u8 weightKind (0 flex / 1 fixed)][u64 BE Double.bitPattern]` |
| **5** project | `UUIDv5(projectKey)` | 0 `key` (the absolute toplevel path) · 1 `gitSummary` (the type-35 body verbatim) |

**`layoutStructure`** (tab field 2) — pre-order, self-describing, **weights excluded**:

```
node := [u8 tag]
        tag 0 (leaf)  → [16B PaneID]
        tag 1 (split) → [16B SplitNodeID][u8 axis (0 h / 1 v)][u8 childCount][node…]
```

- Weights are **not** here — they are `splitNode/weight` entries. That is the divider-conflict fix.
- `Double` weights ride as raw **`bitPattern`**, never a re-parsed decimal — the bit-exact-float rule,
  and the `bytesEwmaBits` precedent in the golden generator.
- **Depth cap = `SplitNode.maxDepth` (12, `SplitNode.swift:132`), checked BEFORE recursion.**
  `SplitNode+Codable.swift:59` documents that today's stack safety comes from `JSONDecoder`, not the
  cap. In a hand-rolled binary decoder over network input, **the cap *is* the stack-safety mechanism.**
- `childCount` is `u8` → fan-out ≤ 255, bounded before allocate.

**Missing key vs empty value.** `""` is a *meaningful* title in this codebase: `publishAgentEmission`
sets `_currentTitle = ""` and ships an EMPTY type-21 as the ownership-retirement signal
(`MuxChannelSession.swift:1023-1029`, pinned by `MuxChannelSessionTitleRetirementTests`). Therefore:

> A **delete** removes an OBJECT (every field for one objectID), never a single field. A field is
> retired by **setting it to a zero-length value**, and zero-length is a first-class value the
> projection honours.

**Decode contract, everywhere:** every count is checked against remaining bytes **before any
`reserveCapacity`**; no force-unwrap on any field; C-style bools as `byte != 0`; strings are strict
UTF-8, never lossy, clamped ≤ 65535 at a scalar boundary (the type-35 idiom); `entryCount > 65536` →
`malformedBody`; an **unknown `kindTag` / `field`** whose length prefix is well-formed is **SKIPPED,
not fatal** — length-prefixing makes forward tolerance free, and that is how a newer host talks to an
older client with no version negotiation (which we are not allowed to have).

### 5.4 Intent ops (verb 3)

Each maps 1:1 onto an existing pure `WorkspaceTreeOps` static func — that reuse is the whole
implementation lever.

```
 0 adoptWorkspace (legacy one-shot, §6.4)   11 setSyncInput
 1 renamePane                                12 spawnPane
 2 renameTab                                 13 spawnTab
 3 renameSession                             14 setZoom
 4 closePane                                 15 detachPane
 5 closeTab                                  16 reattachPane
 6 splitPane                                 17 setDividerWeight  ← ONLY writer of splitNode/weight
 7 movePane                                  18 newSession
 8 reorderTabs                               19 closeSession
 9 focusTab                                  20 reopenClosedTab
10 focusPane
```

`WorkspaceTreeOps` is today exercised only from the client's `@MainActor` store with trusted local
input. Running it inside a host actor exposes it to a network peer. **Every intent payload gets the
validate-then-drop treatment**: depth cap 12, `u8` child counts, all counts bounded before allocate,
and **every referenced `PaneID` / `TabID` / `SessionID` must already exist in the document** or the
intent is rejected `rejectedNotFound`. None of that discipline exists in the tree ops today.

### 5.5 Snapshot vs delta: the mosh rule

> The host keeps, per subscriber, the `HostWorkspaceState` **value** that subscriber last acked
> (`assumedAcked`). Every send computes `diff(from: assumedAcked, to: current)` — **from the acked
> base, not the last-sent base.**

Consequences, and they are the entire correctness argument:

- A diff is a set of **independent property assignments**, so `apply(d, apply(d, s)) == apply(d, s)`
  **by construction**. Duplicates and reorders are no-ops with zero extra machinery.
- A **lost frame self-heals on the next tick**, because the next diff is recomputed from the acked
  base. There is **no retransmit path on either side**.
- A client four hours offline acks the same old `stateNum` and gets **exactly one diff** — or a
  snapshot. Reconnect and steady state are literally the same code.
- Cost is bounded by the **size of the tree**, never the **duration of the absence**. No retention
  window, no compaction, no `OffsetOutOfRange` equivalent. (Zed's worktree rejoin does exactly this.)

**Client apply rules.** Only kinds **0** and **1** may write `stateNum` or trigger an ack. A kind-2 or
kind-3 frame that advanced `stateNum` would make the host retire, via `assumedAcked`, a diff it never
sent — permanent, silent divergence on the very first `renameTab`.

```
kind 0 snapshot     → adopt epoch, replace entries wholesale, clear fastPath,
                      stateNum = new, ACK
kind 4 reset        → clear entries + fastPath + pending, adopt epoch,
                      subscribe(known: 0). No stateNum write, no ack.
kind 1 diff:
   epoch != self.epoch      → DROP, subscribe(known: 0)
   newStateNum <= stateNum  → DROP (already have it)
   baseStateNum != stateNum → DROP, subscribe(epoch, known: stateNum)
   otherwise                → apply sets, then deletes; erase fastPath for every key
                              touched; stateNum = new; ACK
kind 2 presence     → replace roster.  No stateNum write, no ack.
kind 3 intentResult → record the watermark for intentID. No stateNum write, no ack.
```

A snapshot is self-contained and therefore **epoch-independent**: the epoch check precedes kind-1 only,
so a post-restart client converges in one frame, not two.

**The `epoch: UUID`**, minted at every hostd start and on any non-recoverable model rebuild, is
load-bearing and non-optional. Without it, a restarted hostd counts `stateNum` back up and a returning
client sitting one behind **accepts a delta computed against a completely different document** —
divergence that is permanent, silent, and has no detector. The epoch is also the no-migration
directive expressed on the wire: a foreign epoch means reset-then-snapshot, which is the same code
path as a missed frame and as a four-hour reconnect.

### 5.6 Send queue: depth-1, COALESCING, never `enqueueControl`

`MuxChannelSession.enqueueControl` sheds **NEW** messages past `maxControlOutQueued = 1024`
(`:2058-2072`, verified). A shed snapshot leaves a client pinned at `stateNum 0` **with no retry
trigger** — a silent, permanent blank workspace.

The workspace channel therefore owns its **own** send task with **depth-1 coalescing**: a pending diff
is **discarded and recomputed**, never queued. Two rules, not implementation notes:

- The workspace channel **must never** use `enqueueControl`.
- Host memory is **O(clients × state)** regardless of how slow a client is. A sleeping iPhone is free.

Retention: at most **4** sent-but-unacked snapshots per subscriber (the state is tens of KB). A
subscriber whose acked `stateNum` falls outside that window gets a snapshot.

### 5.7 Golden vectors, tests and docs — the exact work

1. **`Sources/slopdesk-corevectors/main.swift`** — two new top-level keys:
   - `root["workspaceWireMessages"]` — type 17/37 envelope round-trips: empty payload, `UInt32.max`
     requestSeq, `Int64.min` / `Int64.max` state numbers, all five kinds, unknown verb/kind bytes.
   - `root["workspaceStateCodec"]` — key/entry/snapshot/diff payloads, a nested `layoutStructure` blob
     at depth 1 / 11 / 13 (the cap boundary), a `Double.bitPattern` weight, a zero-length
     `pane/liveTitle`.

   Emitted keys **35 → 37**.
2. **`Package.swift`** — add `"SlopDeskWorkspaceModel"` to `slopdesk-corevectors`'s deps (currently
   `SlopDeskProtocol, SlopDeskVideoProtocol, SlopDeskVideoHost, SlopDeskVideoClient`).
3. **`golden/golden_vectors.json`** — regenerate with **no `SLOPDESK_*` env**, then **hand-merge the
   new keys**. Corpus **48 → 50**. **Never `>`-redirect** — that wipes the 13 frozen XCTest-only keys
   (`captureRetarget, captureUnion, hostOutputSniffer, inputMotionCoalesce, naluJoin, naluSplit,
   terminalModeTracker, vdChipPixelLimit, vdOriginToRight, vdRefreshRates, virtualDisplayGeometry,
   windowFits, windowPlacement`).
4. **`muxEnvelopes`** (`main.swift:1267`) — add a `channelClass: 1` record beside the existing 0 and
   255. **Coverage only; the codec is unchanged.** Third hand-merged key.
5. **`Tests/SlopDeskProtocolTests/MetadataWireMessageTests.swift:223`** — `[17, 37, 99]` →
   **`[18, 38, 99]`**, and update the explanatory comment. **This is the only value-specific pin.**
   `FrameDecoderTests.swift:88-97,175-188` and `MuxEnvelopeCodecTests.swift:134-145` use the
   type-agnostic `0xFF` sentinel and are unaffected.
6. **`docs/20-wire-protocol.md`** —
   - two rows in the §4 message table;
   - `:352-353` is **stale today** (claims next-free host→client is **36**; 36 is `agentSessionIntent`).
     Correct it to 37 **and then** to the post-change values: client→host **18** (10–17 used),
     host→client **38** (20–37 used);
   - `:105-108` — add type **21** to the reattach re-assert enumeration (its absence *is* the bug);
   - **§5 "Replay-buffer caps" (`:373-381`) is stale**: it says 64 MiB ceiling / 4 MiB offline gate.
     Code is `ReplayBuffer.maxBackupBytes = 256 MiB` (`ReplayBuffer.swift:54-55`) and
     `offlineGateBytes = 64 MiB` (`:57-58`). Correct it in the same pass — the multi-subscriber
     eviction policy (§8.6) is calibrated against those numbers;
   - §8.3.1 gains a `channelClass` paragraph (0 PTY / 1 workspace);
   - new **§10 "Workspace document channel"** — entry grammar, epoch/stateNum, diff-from-acked-base,
     the depth-12 cap, the coalescing-not-shedding rule, the PTY size policy, and the
     state-plane/byte-plane ordering rule (§8.7).

**The golden blind spot, named.** Two of the 13 frozen keys — **`hostOutputSniffer`** (the OSC
title/bell state machine behind type 21) and **`terminalModeTracker`** — are PATH-1-adjacent. A
title-sniffer behaviour change in exactly the phases that touch the title path produces **no
`golden-check.sh` signal at all**. Mitigation, added in Phase 1:
`rust/slopdesk-superd/tests/golden_sniffer.rs` asserts the frozen vector still round-trips against
the live sniffer, so the suite is a real gate rather than an implicit one. (It was a Swift test named
HostOutputSnifferGoldenGuardTests until the sniffer moved into
superd's pump — the guarantee crossed languages with the code, and `scripts/golden-check.sh` is what
holds the two ends together: `hostOutputSniffer` is a SUITE-PINNED key, and that script fails if no
suite replays it.)

---

## 6. Host-side model

### 6.1 The SwiftPM leaf target (the constraint every design must clear)

`SlopDeskWorkspaceCore` depends on `SlopDeskClient, SlopDeskTransport, SlopDeskInspector,
SlopDeskClaudeCode, SlopDeskAgentDetect, SlopDeskTerminal, SlopDeskVideoProtocol, Defaults`
(`Package.swift:160-180`). hostd (`SlopDeskTransport, SlopDeskProtocol, SlopDeskInspector,
SlopDeskAgentDetect, SlopDeskVideoProtocol`, `:104-109`) **cannot** import it.

```swift
// Package.swift — leaf target. Foundation + CoreGraphics, ZERO package dependencies.
.target(name: "SlopDeskWorkspaceModel"),
```

Moves in — from the **real** layout, not the shape the type names suggest:

```
Sources/SlopDeskWorkspaceModel/
  Domain/PaneSpec.swift          ← also declares PaneID(:15), PaneGroupID, PaneKind,
                                    VideoEndpoint(:129), VideoPaneModes(:171)
  Domain/Tree/TreeIdentity.swift ← SessionID(:11), TabID(:22), SplitNodeID(:33)
  Domain/ConnectionTarget.swift  ← Session.connection references it (Tree/Session.swift:49)
  Domain/SolvedLayout.swift      ← WorkspaceTreeOps:446,725,1177
  Domain/FocusResolver.swift     ← ditto
  Domain/LaunchPreset.swift
  Domain/SessionTemplate.swift
  Domain/Tree/{TreeWorkspace,Session,Tab,SplitNode,SplitNode+Codable,SplitNode+Ops,
               WorkspaceTreeOps}.swift
  State/HostWorkspaceState.swift   ← NEW
  State/WorkspaceStateDiff.swift   ← NEW
  Codec/WorkspaceStateCodec.swift  ← NEW (caseless-enum namespace, MetadataCodec-shaped)
```

**`LayoutPreset` requires a file split, not a file move.** It is declared in
`Domain/Workspace.swift:79` alongside the canvas-era `Workspace` (`:21`) and `CanvasBookmark`
(`:113`), yet `TreeWorkspace.layoutPresets` (`Tree/TreeWorkspace.swift:29`) needs it. Split it into its
own `Domain/LayoutPreset.swift` first.

`SplitNode+Ops.swift` is not optional — it holds
`settingDividerWeight(splitID:leadingIndex:leadingWeight:)` (`:367`), the exact op intent 17 maps onto.

`WorkspaceTreeOps.swift`, `SolvedLayout.swift` and `FocusResolver.swift` all `import CoreGraphics`;
the target is therefore **Foundation + CoreGraphics**, both system frameworks, zero package deps.

Then `SlopDeskWorkspaceCore` **+=** `"SlopDeskWorkspaceModel"`, `SlopDeskHost` **+=**, and
`slopdesk-corevectors` **+=**.

The **wire envelope** (types 17/37) lives in `Sources/SlopDeskProtocol/WireMessage.swift` carrying an
**opaque `Data` payload** — `SlopDeskProtocol` never parses workspace state, exactly as it never parses
a `metadataRequest` payload. The **payload codec** lives in `SlopDeskWorkspaceModel` because it needs
the model types. Precedent parity with `MetadataCodec`.

### 6.2 New host types

```
Sources/SlopDeskHost/
  Workspace/HostWorkspaceDocument.swift    actor. Owns `state`, `epoch`, `stateNum` and the
                                           subscriber registry. The SINGLE serialization point.
  Workspace/WorkspaceChannelSession.swift  one per subscribed connection: assumedAcked, the
                                           depth-1 coalescing send task, the presence record.
  Workspace/WorkspaceIntentApplier.swift   validate-then-drop → WorkspaceTreeOps → new stateNum.
  Workspace/HostWorkspaceStore.swift       disk persistence (debounce + SIGTERM flush) and the
                                           DEFAULT document for a first-run host.
  PaneLiveness.swift                       value type holding the truths MuxChannelSession
                                           already latches, with `assertions() -> [WireMessage]`
                                           and `paneEntries() -> [WorkspaceEntry]`. ONE source,
                                           two consumers: the reattach re-assert (Phase 1) and
                                           the document (Phase 4).
```

The fan-out **shape** already runs in production: `registerAgentStatusObserver` /
`fanAgentStatusChanged` (`HostServer.swift:1263-1340`) is a `[UUID: closure]` observer set feeding the
ctl socket. `HostWorkspaceDocument`'s subscriber registry is the same pattern, wired to the GUI wire.

### 6.3 Persistence

```
<Application Support>/SlopDesk/workspace-state.json     — sibling of scrollback/
```

Scrollback transcripts go in `<Application Support>/SlopDesk/scrollback/` — hostd picks the directory
(`ScrollbackTranscripts.makeFromEnvironment`) and superd writes the files (`docs/51` §6.8); the
document is a **sibling of that directory**, not a file inside it. The sweep walks only `*.scrollback`
in that directory and never sees the new file — correct, and worth saying so nobody "fixes" it.

JSON on disk is fine — **the manual-binary rule is about the WIRE.** Sorted keys, atomic
write-and-rename, 600 ms debounce, synchronous flush on SIGTERM/SIGINT (the
`WorkspaceStore.saveImmediately()` idiom).

**Per-field persistence is explicit, not incidental.** The entry map is flat; serializing it wholesale
would restore `commandRunning = 1`, `agentState = working` and a dead client's attachment on a pane
whose process no longer exists — the "fake-live" render §6.5 exists to prevent.

| Persisted | Not persisted (reset to default on load, **before** `liveness = 2` is stamped) |
|---|---|
| every `root/*`, `session/*`, `tab/*`, `splitNode/*` field | — |
| `pane/`: `kind`, `title`, `userRenamed`, `cwd`, `projectKey`, `videoTarget`, `spawnCwd` | `liveTitle`, `titleFresh`, `foregroundProcess`, `runningCommand`, `agentState`, `agentLabel`, `agentIntent`, `progress`, `commandRunning`, `lastExitCode`, `lastDurationMS`, `grid`, `liveness`, `completionEpoch`, `lastActivityMS` |
| `project/key` | `project/gitSummary` (FSEvents re-derives it) |

`pane/grid` is restored from the existing `<uuid>.scrollback.size` sidecar at respawn, not from the
document.

**Decode-fail → the default document** (one session, one tab, one pane), previous file preserved aside
as `workspace-state.corrupt-<ts>.json`. This is the no-backcompat directive; but it is a **new class of
host-side corruption** — a corrupt file must degrade to a usable workspace, never brick the daemon for
every client at once.

### 6.4 Bootstrap

A host whose store is empty (first run, or a decode-fail) **mints a default document** — one session,
one tab, one pane — on first `subscribe`. The default-tree constructor moves out of
`WorkspacePersistence.launchTree()` into `HostWorkspaceStore`. Without this, deleting client-side tree
persistence in Phase 5 leaves nobody able to create the first pane and the cold start dead-ends in a
blank window.

`adoptWorkspace` (op 0) is a **legacy one-shot only**: the first client to attach to a host whose
document is still at its untouched default may upload its local tree once. The actor serializes it, so
exactly one wins.

- Winner: host takes ownership, mints a new `stateNum`, broadcasts.
- **Loser: gets `rejectedStale`, and its local tree is written aside to `workspace-cache.orphan.json`
  with a one-time, visible "this host already has a workspace — import my old layout?" affordance.**
  Silent data loss is not acceptable even once.

Refused forever after the document is touched. It is a **bootstrap, not a migration**.

### 6.5 hostd restart

1. A new **`epoch`** is minted → every attached client gets `reset` then `snapshot`. No stale delta can
   ever be accepted.
2. `workspace-state.json` restores **topology, titles, cwd, project keys, presets, closed-tab ring**
   (§6.3's persisted column).
3. **Live processes survive iff the pane is superd-supervised** (2026-08-11 → [51]). A supervised pane is
   re-adopted from `slopdesk-superd` with its shell still running and comes back **live**, carrying the
   pane id superd recorded so the agent's hook feed keeps routing. An UNSUPERVISED pane (superd absent)
   still follows the old rule below, which is why it is kept rather than deleted:
   `DetachedSessionStore` is in-process, so those panes come back with `pane/liveness = 2` and their
   last-known metadata, `titleFresh = 0`, `commandRunning = 0`, `attachedBy` empty — rendered **stale**
   (dimmed, no busy dot), not fake-live.
4. A restored pane's `<uuid>.scrollback` journal still drives PATH-B `composeTranscript` on respawn —
   unchanged.

### 6.6 Lifecycle reconciliation

Two host subsystems change the world behind the document's back and must be wired to it, or the
document goes semantically stale with no signal:

- **`DetachedSessionStore.onEvicted`** fires *after* it kills a stored session, on both TTL eviction
  and `SLOPDESK_DETACH_MAX_SESSIONS` overflow (`DetachedSessionStore.swift:37-60,84-115`). Subscribe
  the document: set `pane/liveness = 2`, bump `stateNum`.
- **The journal sweep (`maxAge: 14d, keepNewest: 256`)** deletes journals. A pane whose journal is
  gone is no longer restorable; the document keeps its entries (topology is still real) but its
  `liveness` stays 2 and it can only respawn empty. State it; do not silently pretend.

Document GC: the `closedTabRing` is capped, and a `closePane` deletes the object outright, so the
document does not grow unbounded across months of churn.

### 6.7 Phase-1 host changes, concretely

```swift
// MuxChannelSession.swift — reestablishActivityOnReattach() (:1120), append AFTER the
// cwd/projectKey block.
// ORDERING IS LOAD-BEARING until Phase 4 ships pane/titleFresh: commandStatusForReattach() is
// enqueued FIRST at the top of this function, so a `.title` appended here lands after it and the
// client's stamp comparison passes. `_currentTitle` is "" after an agent-title retirement (:1027);
// skipping empty keeps MuxChannelSessionTitleRetirementTests honest and never resurrects a
// retired title.
titleLock.lock(); let title = _currentTitle; titleLock.unlock()
if !title.isEmpty { messages.append(.title(title)) }
```

```swift
// HostServer.swift:1237 — listPanesForControl() also reads detachedStore.
// Today a pane that survived a client quit — precisely the reported scenario — is invisible to
// the one "describe all panes" API that exists.
let detached = detachedStore.allSessions()   // new production enumeration API
return (mux + ctrl + detached).map { … }
```

`DetachedSessionStore` gains `func allSessions() -> [MuxChannelSession]`. It exposes `insert` (`:84`),
`claim` (`:170`), `contains` (`:192`), `remove` (`:210`), `evict` (`:223`), `drainAll` (`:236`) — every
production API except enumeration.

Also delete the two now-false comments: `MuxChannelSession.swift:1300-1304` and the
[DECISIONS.md](DECISIONS.md):733 aside.

---

## 7. Client-side model

### 7.1 `HostWorkspaceMirror` — pure, headless, `SlopDeskWorkspaceCore/Workspace/Sync/`

```swift
struct HostWorkspaceMirror: Sendable {
    private(set) var epoch: UUID?
    private(set) var stateNum: Int64
    private(set) var entries:  [WorkspaceKey: Data]              // applied host truth — kinds 0/1 ONLY
    private(set) var fastPath: [WorkspaceKey: Data]              // control-push overlay (§7.2)
    private(set) var pending:  [IntentID: WorkspaceStatePatch]   // optimistic overlay

    mutating func apply(_ e: WorkspaceEvent) -> ApplyOutcome     // .applied(Int64)/.needsResubscribe/.dropped
    func project() -> TreeWorkspace                              // derived, never stored
}
```

Precedence on read: `pending` → `entries` → `fastPath`. No SwiftUI, no transport import beyond
`SlopDeskProtocol` + `SlopDeskWorkspaceModel`. This is the headless-testable core.

### 7.2 `WorkspaceStore` changes

Its **published surface does not change** — views keep reading `tree`, `paneAgentStatus`, and friends.
What changes is who writes it.

- `tree` becomes `mirror.project()` — **SHIPPED**: a computed `workspaceMirror.topology?.tree`,
  memoized against `workspaceMirrorRevision` (a projection walks every cell and a view body reads
  `tree` dozens of times a frame), with an empty `TreeWorkspace` when there is no topology. Nothing
  assigns to it, and exactly two local overlays ride on top — the in-flight divider PREVIEW and an
  unfollowing device's own focus (both below). Both are keyed off `workspaceMirrorRevision`, which is
  simultaneously the projection cache's key and the Observation shadow every reader binds to, so an
  overlay change repaints without a document frame.
- The per-pane mirrors (`WorkspaceStore.swift:2934-2966`) become **computed reads through the mirror**.
- The existing type-21/26/27/32/33/34/36 control sinks are kept as a **low-latency fast path** — but
  they write `mirror.fastPath`, **never `entries`**. `entries` remains provably
  `apply(diffs, base)`, which is the whole convergence argument. A fast-path value is:
  - read only when the key is absent from `pending` and `entries`;
  - **erased** for any key a diff or snapshot supplies, in the same apply step.

  So the pushes still paint sub-frame on the focused pane, and any disagreement between the push
  producer and the document producer resolves to the document within one tick. Writing `entries`
  directly would freeze such a disagreement forever — the exact bug class this document exists to
  eliminate, reintroduced as an optimisation. (`enqueueControl` is newest-shed at 1024, so that path is
  lossy *and* unordered relative to the workspace channel.)
- Every mutating method becomes **intent + optimistic patch**:

```swift
func renamePane(_ id: PaneID, to title: String) {
    let intentID = IntentID()
    mirror.stage(intentID, patch: [.pane(id, .title): title.wireBytes,
                                   .pane(id, .userRenamed): [1]])   // a PATCH, never an op replay
    send(.workspaceRequest(seq: nextSeq(), verb: .intent,
                           payload: encodeIntent(intentID, .renamePane, id, title)))
}
```

The overlay is a **set of key→value writes**, never a replay of `WorkspaceTreeOps` operations.

**The one thing that is NOT an intent: a live divider drag.** `setDividerWeightLive` runs per drag
FRAME. One intent per frame would flood the channel and make every other client watch the drag, so it
records an ephemeral `(split, index, weight)` the `tree` getter overlays onto the projection, and
`commitDividerResize()` sends the single op-17 with the CLAMPED weight the user actually saw. The
preview is discarded the instant the intent is staged.

**The second thing that is NOT an intent: focus on a device that does not follow.** With
`followSessionFocus` off (§8.2 — the iOS default) `selectTab` / `selectSession` / `focusPaneTree` /
`moveFocusTree` send nothing at all and record a `WorkspaceStore.DeviceFocus` (one tab, plus a pane
when the gesture named one) that the `tree` getter overlays. The overlay applies the very ops the
applier would have — `WorkspaceTreeOps.focusPane` included, so the shared zoom's collapse rule still
holds locally — and resolves against the projection on every read, so a tab another client closed
stops applying instead of stranding this device. Turning the flag back on drops it. Presence is
unaffected: `currentWorkspaceView()` reports the projection, overlay and all.

**Geometry is resolved client-side, and the WINNER travels.** The host has no viewport, so it cannot
answer "which pane is to the left". `moveFocusTree` resolves the neighbour against the layout this
client is looking at and sends `focusPane` naming it; `swapActivePaneInDirection` sends the resolved
`swapPanes` PAIR; `resizeActivePane` sends the resolved `setDividerWeight`.

**Every gesture that mints a pane titles it "Terminal".** A launch preset or a session template that
names its panes (`htop`, `Editor`) follows the mint with `renamePane`, which is also what the name is:
an authored identity the next OSC title must not overwrite.
`renamePane` is idempotent; `splitPane` / `spawnPane` are **not**. Staging a patch removes the
double-apply window between the delta carrying an intent's effect and the `intentResult` retiring it —
and removes the need to define that ordering at all.

**Anti-flicker (Figma's rule):** while `pending` touches key K, an incoming host value for K is written
into `entries` but **not surfaced**; the overlay wins until the intent resolves. Resolution is
`stateNum >= intentResult.new` (not `intentResult` *arrival* — retiring on arrival flashes the
pre-intent value for one RTT), a non-zero `status` (the UI **snaps** to host truth, which is the
correct visible outcome of a rejected rename), or a **3 s timeout**.

**Offline intents are dropped at disconnect, never queued or replayed.** Replaying "close tab 3" after
a four-hour disconnect is wrong. What the UI does instead is SAY SO: `WorkspaceStore.stage(_:_:)` fires
`onLayoutChangeUnavailable` for the states where nothing can land — no channel, a channel that is not
`.live`, a host that has published no topology — and the app raises a `WORKSPACE OFFLINE · LAYOUT IS
HOST-OWNED` chip. Deliberately a report rather than a disabled control: the store keeps rendering the
last layout it knows, so the window looks entirely normal, and the failure being invisible is the whole
problem. A refusal ON THE MERITS (a re-tile of a lone leaf, a reopen with an empty ring) stays silent —
that is the document doing its job and says nothing about reachability.

**Testing this needs a seam, and the seam is opt-in.** `send(intent:)` refuses anything that is not
`.live`, and `.live` is published only from inside the async run loop — so every synchronous store
mutation against a projected `tree` is a no-op in a test that cannot suspend.
`LoopbackWorkspaceDocument` (`Sources/SlopDeskWorkspaceCore/Workspace/Sync/`) is that far end
in-process: the same `WorkspaceIntentApplier`, the same `encodeDiff` → `decodeDiff` round trip through
`WorkspaceMirrorBox.apply`, answering on the caller's turn, and pinned against `HostWorkspaceDocument`
byte for byte. Reached by name via `WorkspaceStore.attachLoopbackWorkspaceDocument()` and never
installed by default — a client that can rewrite its own workspace with no host IS the locally-owned
tree this document replaces (DECISIONS, Multi-client Phase 5b — "the store's mutations become
intents" ruling 2).

### 7.3 What the client persists

**`workspace-cache.json`**

```json
{ "hostKey": "<host identity>", "snapshot": "<base64 of the raw kind-0 payload bytes>" }
```

The **exact snapshot payload bytes**, not a re-encoded model — the wire codec is the one decoder both
ends already agree on, and a second JSON shape for the same facts is a second place for them to drift.
Painted immediately at launch so there is no blank window, and **never authoritative**: no promotion,
no fallback title, no freshness heuristic.

**Which layer a cached fact seeds is decided by what the fact IS** (DECISIONS, Multi-client Phase 5b
ruling 2). `pane/spawnCwd` is TOPOLOGY — where the pane's shell is asked to start — and a respawn
after a host restart has no live shell to ask, so it joins the seeded topology. `pane/cwd` and
`pane/projectKey` are LIVENESS — where a shell IS — and seed the mirror's FAST PATH, which the
erasure rule deletes for any key a host frame supplies. That is what makes "never authoritative"
mechanical rather than a promise.

**The paint gate is `hostKey` + a successful bounded decode — not the epoch.** The epoch's job
is to prevent accepting a stale *delta*, not to prevent painting a stale *picture*. A hostd restart
mints a new epoch while `workspace-state.json` restores the document byte-identically; gating the paint
on the epoch would blank the window on exactly the reboot case the cache exists for. No epoch or
`stateNum` is recorded at all: the mirror resets on every channel stop, so nothing resumes from this
file and a recorded resume position would be a claim the client cannot honour.

**The rows are filtered by `WorkspaceStateFile.persisting` on the way out AND back in**, which is the
same policy the host's own `workspace-state.json` uses. It is what keeps `commandRunning = 1` and
`liveness = attached` off the disk: a restored fake-live row is the render §6.5 exists to prevent, and
this file is the one input a user can edit by hand.

`hostKey` mismatch or a failed decode → discard to empty; the client shows a connecting state for one
RTT. Strictly better than "show `vi .` forever".

**`device-prefs.json` / UserDefaults** — window frame, sidebar width, rail collapsed,
`videoModesByTarget`, `launchPresets`, `sessionTemplates`, `seenCompletionEpoch`, `followSessionFocus`,
`focusHistory` seed, `blockBookmarks`, the connection target per `hostKey`. Everything in §4.3.

**`hostKey` is `"<host>:<port>"`** (`DevicePreferences.hostKey(for:)`). It is the only host identity
known *before* connecting — `root/hostDisplayName` arrives WITH the snapshot, so it cannot gate a
pre-connect read — and it is already what `AppConnection.recentTargets` dedupes on, so the cache gate
and the gate's recent-hosts menu agree on what "the same host" means.

`followSessionFocus` defaults **ON for macOS, OFF for iOS** (§8.2), resolved at compile time.

**Not on disk, on any client:** the `TreeWorkspace` itself (sessions/tabs/splits/specs/presets), and
the five per-pane caches `PaneSpec` does not carry — a pane's live title, its cwd, its project key, its
resume session id and its resume sequence. The layout is the host's file; those facts are the mirror's
cells (`pane/liveTitle`, `pane/cwd`, `pane/projectKey`) and the pane's own id is the rendezvous
identity. Per the no-migration directive a file from a different shape **decode-fails to default**.

### 7.4 Cold-start sequence

Four ordered facts hold this together, and each exists because the one before it does:

1. **The mirror is SEEDED before a packet moves.** `init` publishes the restored tree as a kind-0
   snapshot at `stateNum 1` under `seedEpoch` (the zero UUID, the wire's "none"), with the cache's
   `pane/spawnCwd` folded into the topology and its `pane/cwd` / `pane/projectKey` into the fast path.
   So `topology != nil` the instant the store exists and the window paints a real layout rather than
   the empty one a projection with no document renders. The first HOST frame carries the host's own
   epoch, which differs, so it RESETS the mirror and replaces the seed wholesale — a seed is never
   diffed onto.
2. **`canMutate` is `.live` AND a topology, not either one.** Step 1 makes `topology != nil` true
   immediately, so a gate that asked only that would open before the subscription — and
   `send(intent:)`'s own `.live` guard would then drop the intent silently.
3. **The automation bootstrap SHAPES at launch; only its UPLOAD waits for the channel.** The app
   shell calls `bootstrapFromEnvironment` synchronously at launch, before the channel is even
   installed — but the layout is already decided by then, so it is resolved once into a
   `BootstrapShape` and seeded into the mirror right there. The window therefore mounts the
   autoconnect pane and dials THAT, and nothing else. What waits is the `adoptWorkspace` /
   `spawnDetachedPane` upload, re-fired from `attachWorkspaceChannel` and the channel's own state
   changes; it adopts the very tree already on screen, pane ids included, so the document publishes
   the pane that already holds the PTY.

   While a bootstrap is armed, `reconcileTreeFromDocument` HOLDS. The host's first-run default is a
   layout this client is about to replace, and the projection drives the registry — materializing it
   would give the pane the window is showing, and the shell behind it, exactly one turn to live, then
   spawn a second shell for the pane that replaces it. The hold is that one turn: the channel folds a
   frame and publishes `.live` with no suspension between, and that `.live` edge is what runs the
   bootstrap.

4. **The LAUNCH ADOPT holds the same turn, and is staged optimistically.** The ordinary user's path
   has the identical race: the layout restored from `workspace.json` is about to be offered to a
   pristine host (`runArmedLaunchAdoptIfPossible`), and the frame that arrives first is that host's
   own first-run default. So `reconcileTreeFromDocument` holds while an offer is outstanding AND a
   real host epoch has landed — before one lands the mirror holds this client's own seed, which IS
   the tree on offer, and a host that never opens a workspace channel must not stop the reconcile
   for good. The offer then stages OPTIMISTICALLY, which puts that tree straight back over host
   truth, so the reconcile releasing the hold is a no-op and every restored terminal keeps the shell
   it dialled at launch. Silently proposing it instead cost three panes their sessions and left the
   host's default pane running a PTY nobody was attached to. A refusal is unchanged: `rejectedStale`
   snaps the patch away and host truth stands.

5. **No pane DIALS an id the attached host has not confirmed** (`WorkspaceStore.panesMayDial`). Point 4 keeps
   the restored layout on screen across the round trip, which is right — and that layout is also a
   PREDICTION, because `documentIsPristine` is a fact about the host's own file that no cell carries.
   Showing a pane and opening a PTY for it are different acts, and only the first is reversible:
   `HostServer` spawns a fresh shell for ANY unknown non-zero session id (PATH B), so a client whose
   `workspace.json` names panes this host has never seen — a schema bump that decode-failed to the
   default, a layout restored from a backup, the same client meeting a second host — gets a shell per
   stale id, and the refusal then replaces every one of those panes with host truth. Measured on
   hardware before the hold: three panes on screen, SIX shells.

   So the dial waits for the verdict, either verdict. The offer's own arm is keyed on the adopt's
   `intentID` (`WorkspaceMirrorBox.isPending`), so it is bounded by the same `pendingTimeout`
   backstop every optimistic patch has, and it is released by the mirror's own change hook — an
   `intentResult` that snaps the patch away, or the document frame behind an accepted one.

   **The rule is PROVENANCE, not the launch.** Keying only on the launch left the identical state
   reachable with none of the launch's markers: connect to a SECOND host inside one app run and the
   tree on screen is host A's document, host B has published nothing, and every id in it is unknown
   there. So the store remembers `dialConfirmedHostKey` — the `host:port` whose OWN document frame
   folded into the mirror — and holds whenever it differs from the target now committed. Stamped on
   the FOLD (the frame count moving), never merely on the mirror announcing itself: between
   `commitConnectionTarget` and the re-subscribe that answers it, the mirror still holds the previous
   host's document, and stamping there would file one machine's layout under the other's name.
   `commitConnectionTarget` runs before the connection reports up, so the hold is in place by the
   time the establish fan-out asks every pane to dial — and `handleConnectionEstablished` opens the
   subscription BEFORE that fan-out, so the answer is the nearest thing in flight. Measured
   headlessly at the second host before the rule: three panes, SIX channels.

   Every arm is bounded. A subscription the host ACCEPTS and never publishes on stays `.opening`
   forever (`.live` is published only when a frame folds), so `paneDialHoldBackstop` — one
   `pendingTimeout` — opens the gate anyway: a hold with no release is a window of panes that never
   connect, which is strictly worse than the churn. A refused or closed channel releases immediately;
   an in-process loopback document, whose mirror this store seeded, is never held at all.

   It covers NOTHING else: a split, a new tab and a reopened one all dial on the frame the user asked
   for, because the client proposes those ids and its own applier has already agreed the host will
   take them (Phase 5 ruling 1); a wifi flap back to the SAME host confirms nothing that host has not
   already said, so the re-subscribe holds nobody. Cost, measured on loopback: ~0.13 s on a launch
   that reaches its shells in ~1.1 s. The launch arm is gated by `scripts/check-launch-restore.sh`
   phase C; the host-switch arm is pinned headlessly in `LaunchDialHoldTests` (no GUI gate reaches a
   second hostd).

```
CLIENT                                                     HOST (hostd)
  |                                                              |
  |-- read workspace-cache.json ------------------------------→  |   (local, ~2 ms)
  |   SEED the mirror from it + the restored tree (epoch = zero) |
  |   PAINT the full sidebar from cached snapshot bytes          |
  |   every row marked "unconfirmed" (subtle, not a spinner)     |
  |   mutation is REFUSED here: canMutate needs `.live` too      |
  |                                                              |
  |-- TCP mux connect, hello(v1) ------------------------------→ |
  |←------------------------------------------------ helloAck --|
  |                                                              |
  |-- channelOpen(channelClass: 1, sessionID: zero) -----------→ |  routed BEFORE the
  |←------------------------------------------- channelOpenAck --|  pane-routing section
  |                                                              |
  |-- 17 workspaceRequest(subscribe: clientInstanceID, kind,     |
  |        knownEpoch, knownStateNum, flags, label) -----------→ |
  |                                                              |
  |            epoch matches AND stateNum retained?              |
  |                     yes ↓                    no ↓            |
  |←-- 37 kind 1 diff                        37 kind 0 snapshot  |
  |        base = knownStateNum, new = N       base = 0, new = N |
  |                                                              |
  |   mirror.apply → project() → tree                            |
  |   rows CONFIRMED.  pane/liveTitle = "main.go - NVIM",         |
  |   pane/titleFresh = 1, pane/runningCommand = "vi .",         |
  |   pane/foregroundProcess = "nvim"   ← the bug is dead here   |
  |                                                              |
  |-- 17 ack(N) ----------------------------------------------→  |
  |-- 17 presence(clock, viewingTab, viewingPane, WxH) -------→   |
  |←-- 37 kind 2 presence (client roster + per-pane attachment) -|
  |                                                              |
  |   LAZY, and ONLY once the launch adopt has been ANSWERED     |
  |   (point 5) and for a pane whose attachedBy is empty or      |
  |   contains me:                                               |
  |-- channelOpen(channelClass: 0, sessionID: <host PaneID>) --→  |  the ordinary PTY path,
  |←-- channelOpenAck(resumeFromSeq) + snapshot replay ----------|  completely unchanged
  |                                                              |
  |   steady state: host pushes 37 kind 1 diffs on every change  |
  |   edge; client acks; types 21/26/27/32/33/34/36 continue as  |
  |   the fastPath overlay for attached panes                    |
```

**Where `vi .` dies:** there is no `paneTitleAt` / `paneCommandStartedAt` comparison (both deleted), no
`promotingLastKnownTitles()` (deleted), and no `programTitle(for:)` (deleted).
`RailRowsBuilder.liveRowTitle` keeps its exact precedence chain — it is good and already unit-pinned —
but reads `pane/liveTitle` gated on the **host's** `pane/titleFresh` byte, with `pane/runningCommand`,
`pane/foregroundProcess` and `pane/agentIntent` as its other inputs. The bug cannot recur without
deleting a field from the snapshot.

---

## 8. Multi-client semantics

### 8.1 The conflict rule

> **The last write to a given `(kindTag, objectID, field)` key wins, ordered by arrival at the single
> `HostWorkspaceDocument` actor — no merge, no timestamps, no vector clocks, no CRDT.**

There is exactly one serialization point, so "concurrent" means "arrived in some order". This is
Figma's and Linear's answer, and Zed's precedent is decisive: a real CRDT for **text buffers**, plain
host-authoritative RPC broadcast for the **Project/Worktree tree** — the structurally identical case.

Two clients renaming one tab: both echo optimistically, the host applies both in arrival order, the
loser's overlay resolves and snaps. Two clients splitting one pane: both intents apply, you get two
splits — correct, and identical everywhere. Two clients dragging **different** dividers: different
`splitNode/weight` keys, both survive. The **same** divider: last one wins, the only sane answer.

Ordering fields (`sessionOrder`, `tabOrder`) are short lists rewritten wholesale by the host.
Fractional indexing is explicitly **not** needed at this scale (§11).

**Arbitrary BETWEEN clients, fixed WITHIN one.** "Arrived in some order" is the rule for two devices
racing; a single client's own intents arrive in the order it staged them, and that is a guarantee the
transport owes rather than an accident of scheduling. The optimistic overlay each intent stages is
this same applier run locally, in stage order — so a request that overtakes its predecessor makes the
projection a prediction of a sequence the host never runs. Every multi-intent gesture depends on it: a
mint followed by `renamePane`, the `swapPanes` pair, and the automation bootstrap's `adoptWorkspace`
followed by `spawnDetachedPane` — where the cost is total, because only a PRISTINE document accepts an
adopt and any intent that passes it spends that one chance. `WorkspaceChannelClient` therefore drains
its intents through a single task (`intentQueue`), exactly as it already does its presence updates: a
detached task per call publishes in SCHEDULING order, not issue order.

### 8.2 Focus — host-truth, with a shipped per-device follow flag

`Session.activeTabID` and `Tab.activePaneID` **are HOST-TRUTH.** They are not a render preference —
they determine `successorAfterClose`, notification targeting, and what a fresh client opens into. tmux
puts `session->curw` server-side.

The escape hatch ships in the **same phase**, not later. A **device-local** `followSessionFocus` flag,
default **ON for macOS, OFF for iOS**:

| following | client renders | local navigation writes |
|---|---|---|
| **ON** | `session/activeTabID` + `tab/activePaneID` | `focusTab` / `focusPane` intent → host truth → every following client moves |
| **OFF** | its own `viewingTabID` / `viewingPaneID` | **presence only** — others see "iPhone is looking at pane X", shared focus is untouched |

This is zellij's per-client `ActivePanes` + Yjs awareness, with tmux's shared `curw` as the default for
machines that want it. It is unambiguous, it never diverges shared state, and picking up a phone can
never yank a Mac's screen.

**SHIPPED**, as an OVERLAY rather than a second tree. The OFF row is a `WorkspaceStore.DeviceFocus` —
one tab, plus a pane when the gesture named one — that the `tree` getter lays over the projection,
exactly the way the divider preview does (§7.2). It applies the same `WorkspaceTreeOps` op the applier
would have, so the device sees what it would have seen had it been following; it resolves against the
projection on every read, so a tab another client closed stops applying instead of stranding the
device on a view of nothing; and it is dropped the moment following resumes, because a surviving one
would pin the device to a tab no other client can see it on. **Turning the flag OFF is the same instant
in reverse**: the overlay takes hold of what the device is looking at *right then*
(`currentViewAsDeviceFocus()`), because with none recorded the projection is host truth verbatim — and
the moment somebody reaches for that switch is the moment another client is dragging them, so
"detaches at your next tap" is the one timing that fails the gesture. `selectTab`, `selectSession`,
`focusPaneTree` and the directional `moveFocusTree` all fork through `stageFocus(tab:)` /
`stageFocus(pane:)`, so no gesture can grow a path around the flag. Presence is published from the
projection either way — looking away is not hiding.

The flag is reachable: **Settings → General → Shared Focus**, one toggle on both platforms
(`SharedFocusSetting` + `GeneralSettingsLayout.sharedFocus`), advertised in the searchable All-Settings
list as `follow-session-focus`. Cross-platform on purpose — the default differs BY platform, so a device
with no row keeps its default forever and the escape hatch is unreachable in whichever direction that
device did not start in. It is device-local, so it is not a `Defaults.Key`: the row writes through
`setFollowSessionFocus(_:)` into `device-prefs.json`, which is also what makes the overlay-drop rule apply
to the control for free. Being outside `UserDefaults` is also why **"Reset All Settings" reaches it
through a second object**: `PreferencesStore.resetAll()` clears `Defaults.Keys` and the typed models and
can touch neither `device-prefs.json` nor a row it does not know about, so the panel calls
`resetEverySetting(deviceLocal:)` — `resetAll()` plus `WorkspaceStore.resetDeviceLocalSettings()`, which
restores exactly `AllSettingsCatalog.deviceLocalKeys` and leaves the preset library, the video-mode
latches and the connection MRU alone (device *state*, not settings — the same line `resetAll()` draws at
window geometry). `AllSettingsCatalogTests` binds all three reset surfaces to the advertised list, so a
future row belonging to none of them fails there instead of quietly outliving the reset.

### 8.3 PTY size — monotone min-fold over ATTACHMENT, never presence, never a latch

An input-keyed driver latch has **no hysteresis**: two clients typing alternately flap `TIOCSWINSZ` +
`SIGWINCH` + a full TUI repaint on every exchange, and one stray byte from a pocket reflows a
200-column Mac. **A min-fold is monotone and settles; an input-keyed latch always flaps.**

But the fold's *predicate* matters as much as its arithmetic. Keying it on presence
(`viewingPaneID`, 30 s TTL, 100 ms throttle) means a lapsed heartbeat on a cellular iPhone SIGWINCHes
a Studio's nvim — network jitter driving a terminal reflow. So:

1. A subscriber **contributes** iff it holds an **open `channelClass == 0` channel** for that pane —
   a state-plane fact that changes only on explicit `channelOpen` / `channelClose`, never on a
   heartbeat. That set *is* the refcount, and it is what the presence frame publishes as
   `attachedBy`. This is tmux's `aggressive-resize on` intent expressed structurally: a client that
   unmounts a pane closes its channel and stops contributing, which the retained-session LRU already
   governs.
2. The grid is `min(cols)` / `min(rows)` over contributing subscribers, behind a **750 ms settle
   timer** so a burst of joins resolves once. The settle arms on a **CONTRIBUTOR-SET change**, never
   on an ordinary resize frame — arming it per frame would put 750 ms between a divider drag and the
   shell noticing. It arms only when the set moves BETWEEN two non-empty states: a set going 0→1 or
   1→0 has exactly one possible fold, so a fresh pane's first client waits for nothing. An offer that
   arrives while a settle is outstanding joins the fold rather than arming the 16 ms debounce; the
   `.ack` / `.bye` / channel-close flushes bypass both timers, as they always have.
3. A subscriber may declare itself **size-passive** (tmux `ignore-size`) and contributes nothing.
   **iOS is size-passive by default.** A phone must never crush a Mac. Enforced HOST-side, from the
   workspace channel's `clientKind`: `MuxChannelOpen` carries no client kind, so a client-side gate
   alone would be defeated by any build that predates it. A pane channel with **no** workspace channel
   behind it **CONTRIBUTES** — that is `slopdesk-client`, which only ever opens class 0, and
   defaulting it to passive would leave a CLI unable to size its own pane. Panes opened before
   the workspace `subscribe` lands are re-resolved by the subscribe itself. **A pane no VOTER holds
   is sized by its size-passive members instead** — "never crush a Mac" is about a Mac that is
   THERE, and folding every contributor away on an iOS-only setup left the shell at the `openpty`
   default for its whole life. The fallback keys on the contributing set being EMPTY, not on it
   having made no offer, so a Mac that has opened its channel but not yet offered still shuts the
   phone out.
4. **A pane with zero ATTACHED subscribers keeps its last size** — it does not snap to 80×24.
5. Wire type 11 `resize` stops being a command and becomes a **contribution**. `scheduleResize`
   records the offering subscriber's LATEST offer; `applyResolvedGrid()` folds the min and performs
   the one `pty.setWindowSize`. **No wire change.** Idempotence is a comparison against the live
   `TIOCGWINSZ`, **never** against a remembered resolved grid: `endRedrawJiggle` deliberately leaves
   the PTY one row short while an app re-layouts, and a "resolved size unchanged, skip" memo would
   leave the pane short for the rest of the session.
6. The ctl socket's `resize` verb (`resizeForControl(rows:cols:)`, used by `slopdesk-ctl` and
   orchestrators) routes through the same `applyResolvedGrid()` as an explicit override that stands
   until the next CONTRIBUTING client offer — so the next client offer still wins, and the ctl path
   gets the journal size sidecar and the settled redraw nudge it never had. Retiring it on the next
   APPLY instead makes the verb inert: `.ack` flushes the fold, and the override's own `SIGWINCH`
   provokes a repaint the client acks tens of milliseconds later. A second, independent `TIOCSWINSZ` there silently breaks the
   monotone-min invariant AND leaves the sidecar describing a geometry the PTY no longer holds.
   `PTYProcess.beginRedrawJiggle` / `endRedrawJiggle` stay outside the fold on purpose: they are a
   transient repaint dance that restores what it borrowed.
7. The resolved grid and the contributor list are published in the presence frame, so a
   non-contributing client renders a **labelled** letterbox — `120×40 · sized by MacBook Pro` —
   instead of guessing. That readout is what makes the policy debuggable on hardware.
   `TerminalLetterbox` (shrink-to-fit, never magnify; centred; degrades to full-bleed for every
   unknown) and `TerminalGridReadout` are pure values in `SlopDeskTerminal`, so the arithmetic and
   the sentence carry unit tests the iOS-only SwiftUI path cannot.

Known, accepted cost: zellij's smallest-client-wins is a documented pain point (Discussion #5066). The
iOS-passive default removes the worst case.

**Rule 6 undercounts the writers.** There are FOUR `TIOCSWINSZ` sites, not two: `setWindowSize`
(`PTYProcess.swift:301` — the one the fold routes through), `beginRedrawJiggle` (`:367`),
`endRedrawJiggle` (`:388`) and the spawn-time `openpty` winsize (`:99`). The jiggle pair is outside
the fold on purpose, and it is precisely why rule 5's idempotence compares against the live
`TIOCGWINSZ`. Every file:line in this section predates Phases 5–6 and is stale by roughly +67 to
+250 lines; the symbol names are current, the numbers are not.

### 8.4 Input, and the badge

**Last-writer-wins into the one PTY. No arbitration, no locking, no exclusivity.** tmux, `screen -x`
and WezTerm all do this, and it is correct here because the writers are **one human on two machines**,
not adversaries. Each subscriber's own input relay feeds the session's ONE serial PTY writer; bytes
interleave atomically at frame granularity.

**There is no read-only attachment.** Class 2 was built as one — a subscriber whose `input` the host
dropped — and it is REMOVED: every member of a pane types into it. tmux's `attach -r` and `screen`'s
multiuser ACLs serve pairing and demos, which is not what this product is for, and the machinery cost
a fork in the input relay plus a permanent exception in the size fold. The class byte stays reserved
so a stale peer that still sends it is refused rather than handed somebody else's shell.

`tab/syncInputArmed` fans a sync-armed tab's input from **any** subscriber to every pane in the tab,
and the SYNC INPUT pill shows on every client — true `synchronize-panes` parity.

The completion badge splits: the **fact** is shared (`pane/completionEpoch`, a monotone host counter),
the **acknowledgement** is not (`seenCompletionEpoch`, device-local). The host holds **zero** per-client
acknowledgement state — no `unseenBy` set to GC, nothing undefined for a client that was offline when
the event fired, nothing undefined across a restart.

### 8.5 Presence

Yjs awareness verbatim: `clientInstanceID` (per **connection**), device label, `clientKind`,
`viewingTabID` / `viewingPaneID`, viewport, `presenceClock` (per-client, newest wins, no merge). Fanned
as kind-2 **full replace**, throttled to 100 ms. **30 s missed-heartbeat TTL**; null-broadcast on clean
channel close. **Never persisted, never in `stateNum`.**

Cheap later, no wire cost: zellij's fake-cursor trick — paint another client's cursor as a styled glyph
inside the existing render diff.

### 8.6 Join, leave, offline, and the laggard

- **Join:** the Nth client opens its own workspace channel, subscribes, gets a snapshot. Nothing about
  existing clients changes. For a PTY pane (Phase 6), joining appends to
  `MuxChannelSession.subscribers` with its **own** `ReplayBuffer` cursor and receives the
  already-shipped `SnapshotReplayPolicy` / `composeSnapshotReplay` state transfer exactly as a cold
  reattach does today, plus a full `reestablishActivityOnReattach()` that now runs **on JOIN**, not
  only on REPLACE.
- **Leave → detach:** the subscriber is removed. **Refcounted:** a session parks in
  `DetachedSessionStore` only when the subscriber set **empties**.
- **Close ≠ detach.** `closePane` / `closeTab` is a topology delete and is **not** refcounted. Applying
  it must (1) delete the entries, (2) have the host send `channelClose` on **every** subscriber channel
  for that PaneID, (3) reap the PTY unconditionally. A refcount-aware close would leave the shell
  running with no UI anywhere and no document entry — the exact orphan Phase 6 must not create, and it
  is what makes §8.7's "tear down only on `channelClose`" satisfiable, because the host always sends
  one.
- **Offline:** the client keeps rendering its last `entries` greyed, drops all pending intents, and on
  return sends `subscribe(epoch, acked: staleStateNum)`. Same epoch → one diff. New epoch → snapshot.
  **Minutes or hours makes no difference** — cost is O(tree), never O(elapsed).
- **Laggard.** Today's offline gate **pauses the PTY drain** at **64 MiB**
  (`ReplayBuffer.offlineGateBytes`, `:57-58`), with a 256 MiB hard ceiling (`:54-55`). The naive
  multi-subscriber generalization lets **one sleeping iPhone freeze a build for two Macs**. So:
  - `ReplayBuffer` retention releases at **`min(lastAckedSeq)`** across subscribers. (`ack(upTo:)`
    `:217` / `acknowledge(upTo:)` `:496` are a single mutating watermark today — the min-fold is real
    work, not a parameterization.)
  - A subscriber more than **`SLOPDESK_SUB_LAG_BYTES`** (default **32 MiB**, deliberately *below* the
    64 MiB gate) behind the head is **EVICTED** (`channelClose`) rather than allowed to stall the pane.
    With N subscribers, eviction **replaces** buffering for the laggard; the gate's pause-the-PTY
    semantics are reserved for the case where they still mean what they always meant.
  - **The PTY drain pauses only when the LAST subscriber is gone** — preserving today's
    detached-budget behaviour exactly. **Amended by the soak** (`scripts/soak-fanout-laggard.sh`):
    "the last subscriber is gone" is not the same statement as "nobody is consuming". A pane that
    fanned out keeps delivering from per-member outboxes for the rest of its life — including after
    it shrinks back to ONE member — so `PausableQueueGate`'s enqueued-not-yet-sent accounting, which
    the fan-out drain releases at hand-off, can never assert again, and eviction cannot fire either
    (it never takes a pane to zero members). The producer bound is therefore re-derived from the
    **FASTEST member's delivery frontier**: `retainedBytes(above: max(lastSentSeq))` at the same
    `hostQueueCapacityBytes`. One laggard still never pauses the loop; a pane nobody is draining
    does, exactly as the inline path always did.
  - An evicted client reconnects cold and gets `composeSnapshotReplay`'s render-once state transfer.
    **This is precisely why the 2026-07-25 PATH-B work makes multi-attach affordable: eviction costs
    one screen, not a history.** What triggers that reconnect is the app-connection fan-out, the
    leaf's connect-on-remount, or the user — never the reconnect campaign, whose immediate retry
    would re-join to be evicted again and bill that state transfer every lap. The close says which
    kind it is (`MuxCloseReason.subscriberEvicted`, docs/20 §8.3.2); nothing else ever tells the
    client, because an eviction changes nothing about the layout.

  This lands **in the same commit** as the fan-out. Without it, Phase 6 makes the product worse.

### 8.7 State plane vs byte plane

A client can receive `pane/liveness = dead` or a pane delete on the workspace channel while `output` /
`exit` frames for that pane are still in flight on an **independent** mux channel.

> **Rule: data arriving on a pane channel the state plane has already retired is DROPPED — not
> applied, not an error. A pane surface is torn down only after its own `channelClose`, never on a
> state-plane edge alone; the state-plane edge marks it dead in the UI and stops new input.**

This is the untrusted-input idiom applied to our own host. It goes in
[20](20-wire-protocol.md) §10.

---

## 9. Phasing

Six phases. Each independently shippable, testable and revertable. **Phase 1 fixes the reported bug on
its own, with zero wire and zero golden churn.**

### Phase 1 — "the title comes back" · no wire, no golden, ~40 lines

**Value: quit the client, reopen, and nvim's title is correct — including for shells with no OSC-133
integration.**

`.title` re-assert alone is **not** sufficient. `commandStatusForReattach()` returns `nil` when
`runningSince == nil` (`HostOutputSniffer.swift:264-268`), so `paneCommandStartedAt` never gets stamped,
so `programTitle(for:)`'s `guard let started` fails and the row still falls through to `vi .`. Both ends
are needed, and both deploy together (already the convention).

| File | Change |
|---|---|
| `Sources/SlopDeskHost/MuxChannelSession.swift` | `reestablishActivityOnReattach()` (`:1120`) appends `.title(_currentTitle)` when non-empty, **after** the `commandStatusForReattach()` append. Comment says the ordering is load-bearing **and dies in Phase 4**. |
| `Sources/SlopDeskHost/MuxChannelSession.swift` | Delete the now-false comment at `:1300-1304`. |
| `Sources/SlopDeskHost/DetachedSessionStore.swift` | New production `allSessions() -> [MuxChannelSession]`. |
| `Sources/SlopDeskHost/HostServer.swift` | `listPanesForControl()` (`:1237`) includes `detachedStore.allSessions()`. |
| `.../WorkspaceStore+Completion.swift` | **Relax `programTitle(for:)`**: a title with a `paneTitleAt` stamp but **no** `paneCommandStartedAt` is TRUSTED — the hookless-shell case, expressed client-side until the host byte ships. Safe because the host only re-asserts a title it **currently holds**; `_currentTitle` is cleared to `""` on retirement (`:1027`). |
| `docs/20-wire-protocol.md` | Add type **21** to the reattach re-assert enumeration at `:105-108`. |
| `docs/DECISIONS.md` | Delete the `:733` aside; write the Phase-1 entry. |

**Known scope limit, to state in the commit message.** The client's `.title` sink is gated:
`ConnectionViewModel.swift:750` — `if SettingsKey.titleShellControlledEnabled, !text.isEmpty { … }`.
The default is ON (`SettingsKey.swift:994`, `Key<Bool>(… default: true)`), so the fix holds for every
default install; with the shell-controlled-title toggle off it is a no-op on that device by design.

**Tests (fail-first, all headless)**

- `Tests/SlopDeskHostTests/MuxChannelSessionActivityReattachTests.swift`
  - `testReattachReassertsCurrentTitle` — **prove it fails first**
  - `testReattachDoesNotResurrectRetiredTitle` — pins the `_currentTitle = ""` clear at `:1027`
  - `testTitleIsEnqueuedAfterCommandStatus` — pins the load-bearing ordering
- The title-trust cases moved with the sniffer: `rust/slopdesk-superd/tests/golden_sniffer.rs`
  (they were the Swift cases testTitleWithNoCommandStartIsTrusted
  and testTitlePredatingCommandStartIsStillRejected in WorkspaceStoreProgramTitleTests)
- `Tests/SlopDeskHostTests/HostServerListPanesTests.swift` — `testDetachedPaneIsListed`
- `rust/slopdesk-superd/tests/golden_sniffer.rs` — closes the frozen-key blind spot (§5.7)

This repairs the **live detach/reattach** case, which is the common one. `_currentTitle` lives in
memory on `MuxChannelSession` and dies with hostd; after a **daemon** restart the title stays degraded
until Phase 5's persistence. And if nvim genuinely never emits an OSC 0/2 title in this `$TERM`,
`vi .` **is** the last true title — Phase 4's `pane/runningCommand` + `pane/foregroundProcess` fixes
that variant.

### Phase 2 — SwiftPM leaf-target extraction · mechanical, zero behaviour change

**Value: hostd can name a tab.**

- `Package.swift`: `.target(name: "SlopDeskWorkspaceModel")` (Foundation + CoreGraphics, no package
  deps); add it to `SlopDeskWorkspaceCore`, `SlopDeskHost`, `slopdesk-corevectors`.
- Split `LayoutPreset` out of `Domain/Workspace.swift:79` into its own file, then move the §6.1 file
  list. Imports only.
- Move the existing tree tests to `Tests/SlopDeskWorkspaceModelTests/` **unchanged**.

**Gate:** `make check` green, every existing tree test passes unmodified, **and
`bash scripts/golden-check.sh` shows a zero-key diff** (regenerated with no `SLOPDESK_*` env). The
phase moves `Session.swift` and `SplitNode+Codable.swift` — the hand-written deterministic `Codable`
this design cites as its ordering precedent — *and* adds a dependency to the vector generator in the
same commit. "Existing tests pass" does not prove the encoded bytes are unchanged; the corpus does.

### Phase 3 — the state value layer · pure, headless, no wire

**Value: the convergence proof exists before any socket does.**

- `SlopDeskWorkspaceModel/State/HostWorkspaceState.swift` — the entry map, `diff(from:)`,
  `applying(_:)`, deterministic ascending emission.
- `SlopDeskWorkspaceModel/Codec/WorkspaceStateCodec.swift` — key/entry/snapshot/diff/`layoutStructure`
  encode + decode, validate-then-drop throughout, depth cap = `SplitNode.maxDepth` (12).
- Golden: two new emitted keys, `make check`, hand-merge into the 48 → 50 corpus.

**Tests — the gate for the whole architecture**

```
Tests/SlopDeskWorkspaceModelTests/WorkspaceStateAlgebraTests.swift
  testDiffApplyIdentity        apply(diff(a,b), a) == b
  testApplyIsIdempotent        apply(d, apply(d,s)) == apply(d,s)
  testSnapshotRoundTrip        reduce(snapshot(host)) == host
  testTitleRetirementIsASet    diff(a,b) for title → "" emits a SET, not a delete
  testRandomizedConvergence    1000 random intent sequences under random drop / duplicate /
                               reorder / epoch-change, WITH presence + intentResult frames
                               interleaved between every diff → all replicas converge
Tests/SlopDeskWorkspaceModelTests/WorkspaceStateCodecHostileTests.swift
  truncation at every byte offset; entryCount = UInt32.max; layoutStructure at depth 11/12/13;
  childCount = 255; non-UTF-8 strings; unknown kindTag/field skip-not-fatal;
  Double.bitPattern weight exactness; zero-length pane/liveTitle round-trip
```

### Phase 4 — the workspace channel, READ-ONLY · wire 17/37, `channelClass 1`

**Value: two clients agree on every per-pane fact, and a client that has never seen this host can
enumerate its panes with correct titles.**

Ships behind **`SLOPDESK_WORKSPACE_DOC`** (`== "1"`, default-OFF during bake-in; flips to `!= "0"`
default-ON once hardware-proven). When off, the retained type-21/26/27/32/33/34/36 sinks **are** the
fallback — they still write `fastPath` and, with no `entries` to lose to, drive the UI exactly as today.

**Terminal state (2026-07-29):** the flag is DELETED and the channel is unconditional on both ends
(DECISIONS, "The workspace document is unconditional"). The fallback described above stopped being
one the moment Phase 5b projected the tree — the sinks carry per-pane FACTS, never the LAYOUT.

**Host**
- `HostWorkspaceDocument` actor (pane + project records only — topology still client-owned), `epoch`,
  `stateNum`.
- `WorkspaceChannelSession` with the **depth-1 coalescing** send task. **Never `enqueueControl`.**
- `PaneLiveness.paneEntries()` fed from the truths `MuxChannelSession` already latches.
- **`pane/titleFresh`** computed host-side, all four rules of §4.4.
- **`pane/runningCommand`** from the latch superd's `0x05` block events feed (`docs/51` §6.14).
- **`pane/completionEpoch`** bumped on each working→done edge.
- **`project/gitSummary`** fed from `RepoStatusWatcher` (type 35 keeps pushing as the fast path).
- ctl panes get entries under `root/unattachedSessionID`.
- `channelClass == 1` routing in `spawnMuxChannel`, **before** the pane-routing critical section.

**Client** — SHIPPED; four bullets below were revised in the doing, see
[DECISIONS](DECISIONS.md) § *Multi-client Phase 4d*.

- `HostWorkspaceMirror` with **two** layers, not three: `entries` and `fastPath`. The optimistic
  `pending` layer has no writer until Phase 5's intents, and `value(for:)` is its insertion point.
- Every mirror key is the pane's DOCUMENT id (`documentPaneID(_:)`), and both ends must agree which
  UUID that is. Getting it wrong is silent — it was, for one commit.
- Mirror reads open with `observeWorkspaceMirror()`. The box is not `@Observable`; a funnel that
  forgets renders once and then goes deaf.
- **Deleted** `paneTitleAt`, `programTitle(for:)`. `paneCommandStartedAt` stays — it is the
  client's own freshness stamp when the document is off, not a titling input.
  `promotingLastKnownTitles()` moves to Phase 5: it is about PERSISTED spec titles, which is topology.
- `RailRowsBuilder.liveRowTitle` reads `pane/liveTitle` gated on `pane/titleFresh`, plus
  `pane/runningCommand`. `foregroundProcess` / `agentIntent` / `agentLabel` / `agentState` stay on
  their store dicts: `reestablishOnReattach` re-asserts all of them, so routing them changes nothing
  observable until Phase 5 brings the rows a second client would render them in.
- `paneUnseenDone` becomes the PROJECTION of `pane/completionEpoch` vs device-local
  `seenCompletionEpoch` (persisted, scoped to the document epoch). Nothing writes the Set but
  `refreshUnseenDone(for:)`.
- The client publishes presence from the reconcile funnel, dirty-guarded on the view.
- **held by `<label>` moves to Phase 6.** Attachment needs the pane channel to declare whose it is,
  and only the workspace `subscribe` carries a `clientInstanceID` — which is why the host fills the
  roster's `panes` list with nothing. Phase 4 renders VIEWERS in the row tooltip instead, and does
  not suppress `channelOpen`.

**Wire / golden / docs:** all of §5.7 except the topology entries.

**Tests**
- `Tests/SlopDeskHostTests/WorkspaceChannelLoopbackTests.swift` over the existing `LoopbackByteChannel`
  seam (the one `InspectorServer` tests use) — subscribe → snapshot → diff → epoch change → mis-based
  diff → resubscribe; a **new-epoch-converges-in-ONE-frame** case; a **shed-proof** case that floods
  `controlOut` past 1024 and asserts the snapshot still lands.
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/WorkspaceMirrorFastPathTests.swift` — fast-path-write a key, then
  deliver a diff with a **different** value for that key; assert the projection follows the diff and a
  later empty diff does **not** resurrect the fast-path value.
- `Tests/SlopDeskHostTests/WorkspacePresenceTests.swift` — clock ordering (older clock ignored), TTL
  expiry, null-broadcast on clean close, two connections from one device yielding two identities, a
  stale reconnecting clock not resurrecting a dead viewer.
- **Gate includes `bash scripts/check-ios.sh`** (`clientKind` branching).

### Phase 5 — topology flips host-side · intents, overlay, persistence

**Value: the literal ask — the layout is one value the host owns, and every client renders it.**

**Host — SHIPPED**
- `WorkspaceTopology`: root/session/tab/splitNode/pane-topology entries, projected and ingested.
  The active tab crosses as an IDENTITY, never the index it is stored as (the `ed76f137` bug one
  layer up). Divider weights are their own cell, one per SPLIT, riding as raw `bitPattern`s.
- `HostWorkspaceStore` — `workspace-state.json`, the §6.3 per-field filter (applied on the way IN as
  well as out), atomic write, 600 ms debounce, flush on shutdown, corrupt-file-kept-aside, and the
  **default document** for a first-run host.
- `WorkspaceIntentApplier` — every op, pure, with validate-then-drop and a re-check of the RESULT
  against the depth cap and the specs invariant. `intentResult`; `adoptWorkspace` with the
  pristine-is-a-file rule.
- Host-owned `focusMRU` drives `closeTab`'s successor; host-owned closed-tab ring drives ⇧⌘T.
- `DetachedSessionStore.onEvicted` → `liveness = 2`.
- The reaper narrowed to three cases (§DECISIONS Phase 5.4).

**Client — SHIPPED**
- The `pending` optimistic layer, computed by running the host's own applier, with the anti-flicker
  rule: a refusal snaps back at once, an acceptance is held until the next document frame, an
  unanswered patch expires after 3 s, a `reset` drops them all.
- `WorkspaceChannelClient.send(intent:args:)` — stages before it sends, and does not send at all when
  this client can already tell the host will refuse.

**Deferred to Phase 5b — the store cutover**
Phase 5 left the client `WorkspaceStore` owning and persisting its own `TreeWorkspace`: the document
was read for per-pane facts and the optimistic layer, not for the LAYOUT, so two clients still saw two
trees. It was split out because it is the single riskiest change in the plan — every UI surface reads
`store.workspace` — and everything under it was proven headlessly first. It carried with it:
- `workspace.json` → `workspace-cache.json` (raw snapshot bytes) + `device-prefs.json`
- `followSessionFocus` (default ON macOS / OFF iOS)
- deleting `PaneSpec.resumeSessionID`, the tree's `WorkspaceSchemaMigration`,
  `WorkspacePersistence.promotingLastKnownTitles()`, and the topology `scheduleSave()` debounce
- moving `cwd` / `projectKey` off `PaneSpec`

**Not carried, with reasons** (`WorkspaceTopologyOmissions`): `layoutPresets` embeds a whole retired
`Canvas` the tree path never reads; `launchPresets` / `sessionTemplates` are host CONFIG rather than
topology and their root fields stay reserved — a topology write is excluded from reaping them, so a
future build's config survives this one.

**Tests — SHIPPED**
- `WorkspaceTopologyTests` — round trip through the encoded snapshot, byte determinism, identity-not-
  position, what must not cross, hostile structures
- `WorkspaceIntentApplierTests` — every op, every refusal, hostile payloads, idempotence, the depth cap
- `WorkspaceConvergenceTests` — **two mirrors, one document, interleaved intents, byte-identical
  projections** through the real session; plus the late joiner and the refusal-moves-nothing case
- `OptimisticIntentTests` — the anti-flicker rule in every direction
- `WorkspaceStateFileTests` / `HostWorkspaceStoreTests` — no living process survives a restart
- Golden: `workspaceStateCodec` extended, `workspaceIntentOps` + `workspaceIntentArgs` added
  (corpus 50 → 52). **Gate included `bash scripts/check-ios.sh`.**

### Phase 5b — the store's mutations become intents

**Value: the headline one. `WorkspaceStore.tree` is a projection of the document, so two clients see
ONE tree.** The ops it needed shipped in `2ca874f8`; the cutover itself changed no golden vector, and
the review round after it added exactly one op (26 `setPaneVideoTarget`, below).

**SHIPPED**
- **The device-local facts leave the tree.** Presets, templates, `videoModesByTarget` and the
  connection target move to `DevicePreferences` + `device-prefs.json` (§7.3); the client's layout cache
  becomes `workspace-cache.json`, raw snapshot bytes.
- **A pane's id IS its document id**, and the five cached facts come off `PaneSpec` — `lastKnownTitle`,
  `lastKnownCwd`, `projectKey`, `resumeSessionID`, `resumeLastReceivedSeq`. Every reader is retargeted
  at `workspaceMirror`. `spawnCwd` is read through the mirror too, topology before fast path, which is
  what makes a relaunch respawn a restored pane where it started rather than in `$HOME`.
- **`TabOrderingEngine` moves into `SlopDeskWorkspaceModel`**, below both ends, and
  `WorkspaceIntentApplier.successorAfterClosing` re-lands the `ed76f137` project-section rule. The
  RULE is unchanged; the MRU RING is now shared, so two clients closing one tab land on one tab.
- **Op 23 `dockPaneAtTabEdge` honours the tab its args always named** —
  `WorkspaceTreeOps.moveLeafToTabRootEdge`, so the cross-tab rail-drag gutter drop lands. No wire
  change.
- **`LoopbackWorkspaceDocument`** — the opt-in in-process document (§7.2) every tree-driving test now
  holds, pinned byte-for-byte against `HostWorkspaceDocument`.
- **`SLOPDESK_WORKSPACE_DOC` is default-ON (`!= "0"`) on BOTH ends, in one commit.** The 47 assignment
  sites are intents; `recentlyClosedTabs`, `plannedTabSuccessor`, `replaceTree` and `mutateTree` are
  deleted; `syncInputTabs` is host truth via `tab/syncInputArmed`, and therefore persisted.
  *(2026-07-29: the flag is deleted outright. The one-commit coupling it needed is now structural —
  there is no off position for the two ends to disagree about.)*
- **`followSessionFocus` is read** (§8.2) — an unfollowing device overlays its own focus on the
  projection and sends no intent, while still publishing presence.
- **The GUI gates prove the shipping path.** `check-macos.sh` and `check-video.sh` give their daemon a
  fresh `SLOPDESK_WORKSPACE_STATE_DIR`, and `check-video.sh` stands up a real `slopdesk-hostd` for the
  detached `.desktop` pane's intent to land in.

**SHIPPED — the review round after the cutover** (DECISIONS, Multi-client Phase 5b — "what the
projection owed the rest of the app")

- **A DOCUMENT change reconciles the pane registry.** The hook that made a host frame repaint now also
  materializes the leaves it added and tears down the ones it removed — the multi-client case the
  mutator-only reconcile could never see, and the first-connect case on a single client. A pass driven
  by the document does NOT acknowledge focus: unread-completion is per-device.
- **Nothing is persisted while there is no document.** `stop()` resets the mirror on the way to every
  re-subscribe, so `tree` is empty for that window; both writers now skip rather than replacing
  `workspace.json` and `workspace-cache.json` with empty ones.
- **Op 26 `setPaneVideoTarget`** — re-point a LIVE pane's video binding, with the derived title. The
  ONE golden change in the phase. Without it the display switcher's commit reached nothing.
- **The device-focus overlay follows the object THIS device just made** — an unfollowing iPhone's ⌘T
  and split land focused, while a gesture that moves no focus leaves it where it was looking.
- **The launch adopt has a caller**, so an upgrading client offers its restored layout to a first-run
  host instead of discarding it. Staged optimistically and held for one turn (§7 note 4), so the panes
  the window already dialled keep their shells; a refusal snaps the patch away and host truth stands.
  What it offers is the SEEDED TOPOLOGY, not the tree: `pane/spawnCwd` is a topology fact that on a
  cold launch only `workspace-cache.json` still knows (the panes have no live shell to ask), and a
  proposal rebuilt from the tree alone would have a pristine host accept every pane with its project
  directory stripped — the next launch starting all of them in hostd's own cwd, and the first cwd push
  after that writing the loss into the cache.
- **A refused layout change is reported** (`onLayoutChangeUnavailable` → a transient chip) rather than
  swallowed; the ⇧⌘T cue asks which tab is on the ring rather than how many; a re-tile exits zoom
  host-side; the client's dead `tabFocusHistory` is deleted in favour of `topology.focusMRU`.

**SHIPPED — hardware verification, `scripts/check-multiclient.sh`**

Two real macOS instances, one `slopdesk-hostd`, one machine. Each client gets its own
`CFFIXED_USER_HOME` container and its own `SLOPDESK_CLIENT_SOCKET`; the gate drives a REAL menu
gesture on client A (System Events, addressed by unix id) and reads what client B is rendering.

- **It observes the CLIENT, not the host.** The shipping client-control socket already answers the
  question — `slopdesk --socket … windows|tabs|panes` is served by `WorkspaceControlBackend` off
  `WorkspaceStore.tree`, the projection itself — so the gate needs no test seam. Reading the host's
  `workspace-state.json` would only have proven the host applied the intent, which is the premise.
- **What it watched.** Client B mints its own session/tab/pane at launch, mounts them, and has its
  `adoptWorkspace` refused; it then throws its own ids away and projects A's. `Panes ▸ Split Right`,
  `Tabs ▸ New Tab` and `Tabs ▸ Close Tab` on A each land in B's projection — the removing direction
  included. Topology only (§4.1 liveness and §8.2 focus are device-scoped by design).
- **N panes ⇒ N live shells**, counted as the daemon's children rather than as log lines: the
  cumulative attach count legitimately includes B's refused launch pane and the closed tab's pane,
  both reaped. A leak is a shell that is still there.
- Pinned by `GuiGateLaunchContractTests`, which is what keeps the gate from quietly reading the host
  document, sharing one container between the instances, or warning instead of failing.

**NOT shipped**
- **A cross-SESSION dock.** Refused by design — a pane's spec lives in its session's side table, so
  moving one between sessions is a different op with a different invariant, and no gesture asks.

### Phase 6 — PTY fan-out, LAST — **SHIPPED, AND UNCONDITIONAL**

**Value: two clients watch one live nvim.** Four commits, no wire change and no golden change in any
of them: `golden/golden_vectors.json` is byte-identical across the whole phase and no unknown-type
probe moves. Everything the fan-out needed was already on the wire — `channelClass` on
`MuxChannelOpen`, `WorkspaceRosterPane.attachments` in the presence roster — and close-vs-leave is
resolved by the HOST-owned `closePane` intent rather than a `closeReason` byte.

- `MuxChannelSession.data` / `.control` → `subscribers: [MuxSubscriberID: Subscriber]`. A subscriber
  IS its sub-channel pair (`let`), so a returning client REPLACES the member instead of having
  channels swapped under tasks a departed one owned; `rebindRelay` becomes the one-member join.
- `reestablishActivityOnReattach()` runs **on JOIN**, addressed to the new member only.
- **`min(lastAckedSeq)` retention + `SLOPDESK_SUB_LAG_BYTES` eviction, in the same commit** (§8.6).
  `ReplayBuffer.retainedBytes(above:)` is the metric, and the lag check runs on BOTH the append and
  the ack side — a client that has stopped acking never calls `acknowledge`, so a consumer-side-only
  check never fires on the exact member it exists to remove.
- min-fold over the ATTACHED set with the 750 ms settle; every `pty.setWindowSize` caller routes
  through `applyResolvedGrid()`; iOS size-passive; contributors published in the roster.
- Park in `DetachedSessionStore` only when the subscriber set empties.
- iOS letterbox / scale-to-fit, with §8.3 rule 7's readout.

**Eight corrections this phase earned, against the text above and in §8.3:**

1. **The `attachedElsewhere` refusal is DELETED, and it was not merely deleted — it was
   unreachable.** This correction originally said the refusal survives as a flag-OFF branch until
   the flag flips default-ON. The flag is gone entirely (2026-07-29 ruling: multi-client sync is
   first-class and has no toggle), and with PATH D ungated the refusal is not rare, it is dead:
   `joining` is assigned from exactly the condition that makes `liveElsewhere` non-nil, so
   `joining == nil && liveElsewhere != nil` is unsatisfiable. `registerJoiningKeyLocked` returns a
   non-optional id and cannot fail, so there is no registration-failed path for it to survive as
   either. The detached-store claim guard that read `!attachedElsewhere` becomes `joining == nil` —
   see `docs/DECISIONS.md`, "Multi-client fan-out is unconditional" §2.
2. **There are FOUR `TIOCSWINSZ` writers, not two.** §8.3 rule 6 names `setWindowSize` and the ctl
   verb and misses two: `PTYProcess.beginRedrawJiggle` (`:367`) and `endRedrawJiggle` (`:388`), plus
   the spawn-time `openpty` winsize (`:99`). The jiggle pair stays deliberately OUTSIDE the fold — it
   is a transient repaint dance that restores what it borrowed — which is exactly why idempotence
   compares against the live `TIOCGWINSZ` and never against a remembered resolved grid. Every
   file:line in §8.3 and §9 predates Phases 5–6 and is stale by roughly +67 to +250 lines; the
   symbol names are current, the numbers are not.
3. **The 750 ms settle arms on a CONTRIBUTOR-SET change, never on a resize frame** — and only when
   the set moves between two non-empty states. Arming per frame would put 750 ms between a divider
   drag and the shell noticing; arming on 0→1 would make a fresh pane's first client wait for a fold
   it alone decides.
4. **Close-vs-leave needs no wire change.** Phase 5 moved the topology host-side, so
   `WorkspaceIntentApplier.closePane` (verb 4) runs on the HOST: a `channelClose` on a pane channel
   is ALWAYS a refcounted LEAVE, and the unconditional REAP is driven by the document's own
   `closePane` / `closeTab` apply, which `channelClose`s every subscriber and kills the PTY. That
   satisfies §8.6's asymmetry and §8.7's "the host always sends one `channelClose`".
5. **The fan-out shape is cleared by an EMPTIED set, not by a leave.** A pane that fanned out and
   then lost every client reaches `rebindRelay` with the drain still routing into per-member
   outboxes — and `rebindRelay` builds only the returning member's CONTROL sender, so the reattached
   client would receive the state transfer and then nothing at all, `.exit` included, while
   `dequeueOutput` kept the queue gate flowing so the PTY never backpressured. Clearing on a mere
   LEAVE would be wrong for the opposite reason (two writers on one data channel while the survivor's
   sender is mid-outbox); clearing on EMPTY is safe because `detach()` retired every member first.
6. **A joining channel RESERVES its subscriber id in the same critical section that registers its
   key.** `muxSessions[key]` is written synchronously, but the member only exists after an
   O(retained history) render and a whole state transfer through the joiner's credit window. A key
   with no `muxSubscriberIDs` entry falls back to `primarySubscriberID`, so a link drop in that
   window retired the INCUMBENT — and parked a session whose client was still connected.
7. **A joiner's outbox is kicked when its sender is built.** The joiner enters the set before its
   sender exists, so frames the drain fans out during the state transfer land on a nil wake and
   their producer-side yields go nowhere. Without the kick they wait for the next PTY byte, which a
   pane that just went idle never produces.
8. **Two §8.3 rules are amended by what they do on hardware-shaped inputs:**
   - **Rule 6 — the ctl override stands until the next client OFFER, not until the next APPLY.**
     Every `.ack` flushes the fold, and the override's own `SIGWINCH` provokes a repaint whose ack
     lands within tens of milliseconds, so an override retired by the next apply is undone by the
     output it caused: `slopdesk-ctl resize` would be inert on any pane a client holds. A
     CONTRIBUTING subscriber's `resize` retires it; nothing else does. CONTRIBUTING means what
     `fold(_:)` CREDITS, not the passivity flag: on the iOS-only setup rule 3's amendment covers, the
     phone IS that subscriber, and keying the retirement on the flag left a lone phone locked out of
     its own pane for good after one `slopdesk-ctl resize`. An OBSERVER still never retires it.
   - **Rule 3 — a pane no VOTER holds is sized by its size-passive members.** "A phone must never
     crush a Mac" is a statement about a Mac that is THERE; on an iOS-only setup every contributor is
     passive, the fold resolved to nothing, and rule 4 then kept the `openpty` default 80×24 for the
     shell's whole life. The fallback keys on the contributing set being EMPTY — not on it having
     made no offer — so a Mac that has opened its channel but not yet offered still shuts the phone
     out, and OBSERVERS are excluded from it, because a spectator never inherits the vote.

**Gate:** `SubprocessE2ETests`' `testTwoClientsShareOneRealPTY` (both clients see the same PTY bytes)
and `testASecondClientJoinsTheLiveSessionAndForksNoSecondShell` (the join forks nothing — `/bin/sh`
children of the real hostd pid, counted out of the process table before and after). Two shipped
`slopdesk-client` processes on one `--session-id` against one `slopdesk-hostd`, real PTYs. Per
[CLAUDE.md](../CLAUDE.md) the in-memory loopback provably misses open-order races, so a loopback test
is not acceptable evidence here. Plus `bash scripts/check-ios.sh`. There is ONE configuration to run.

**Hardware, as far as it goes:** `bash scripts/check-multiclient.sh` runs the Phase 5b gate and
asserts the fan-out unconditionally in step 7b — every pane in the FINAL layout has to appear in a
hostd `joined live session … as subscriber` line. The assertion is POSITIVE and per-pane on purpose:
counting refusals and expecting none is satisfied both by a second client that never tried and by a
host with no refusal left to log. Green on two real macOS instances against one daemon.

**Observed there, and now CLOSED — a retired pane is not re-dialled.** Closing a
tab on client A made client B spawn a fresh PTY for the pane that just died: the host answers an
applied `closeTab` with `channelClose` to every subscriber FIRST and the removing document frame
SECOND, so B held a dead channel for a pane it still had on screen, and a pane channel naming a
session the host no longer has is a SPAWN. Not the leaf — the pane's own `ReconnectManager`, which
cannot tell a per-channel close from a link drop once the inbound stream has ended. The mux carries
the difference (`MuxSubChannel.peerCloseReason` → `ClientTransporting.hostCloseReason` →
`SlopDeskClient.hostChannelCloseReason`), and every automatic dial path — the campaign,
`SlopDeskClient.connect`, `connectIfNeeded()` and with it `redialDisconnectedPanes()` — refuses a
retired pane; an EXPLICIT re-dial still works.

The eviction close carries a DIFFERENT reason (`MuxCloseReason.subscriberEvicted`), because the two
facts are opposites: an evicted client's pane is still running and stays in its topology forever, so
treating it as retired stranded it undiallable for the process lifetime. The campaign is gated for
both (an instant re-join would only be evicted again), but `connectIfNeeded()` is gated only by the
REAP — so the app-connection fan-out and the leaf's connect-on-remount reattach an evicted pane.
Rulings in [DECISIONS](DECISIONS.md#a-pane-the-host-retired-is-not-re-dialled-2026-07-28) and
[its amendment](DECISIONS.md#an-evicted-subscriber-can-come-back-a-reaped-pane-cannot-2026-07-28);
headless regression in `HostRetiredPaneRedialTests`, `EvictedSubscriberRedialTests`,
`HostServerCloseReasonTests` + `MuxPeerCloseMarkTests`. The gate no longer tolerates it: step 7a
asserts no pane uuid appears twice in `attached for pane …` — permanent evidence, unlike a live
census, which passed even on the buggy build — and the settle it had been given drops 20 s → 4 s.

**The iOS half now RUNS: `bash scripts/check-ios-tests.sh`.** `check-ios.sh` type-checks the
`#if os(iOS)` slice and executes nothing, and `swift test` compiles the macOS slice — so every iOS
default in this document (`WorkspaceClientKind.thisPlatform`, §8.2's
`platformDefaultFollowSessionFocus`, §8.3 rule 7's letterbox geometry) was only ever asserted against
the WRONG branch of its own fork. The new gate builds a host-less XCTest bundle
(`Apps/ClientApp-iOS/Tests/`) for the iOS-Simulator triple and runs it in a booted simulator. It does
NOT use `xcodebuild test`: DVT refuses to enumerate simulator devices whenever /Library's
CoreSimulator package is older than the installed Xcode, and installing that package needs admin
rights an agent run does not have — `simctl` is unaffected, so the script hands the bundle to the
simulator's own `xctest` agent instead.

**Rule 3's amendment is host-side only, and the client can defeat it.** `TerminalLetterboxContainer`
frames the surface at the HOST's resolved grid whenever one is published — deliberately, so a phone
cannot reflow a Mac's pane to its own window. But a pane no VOTER holds is sized by its size-passive
members, so on an iOS-only setup the phone's offer becomes a pure ECHO of the grid it was just given,
and the fold has a fixed point: whatever the roster published first is what that shell keeps, and no
rotation, split or font change can move it. The roster already carries the discriminator —
`WorkspaceRosterPane.Attachment.contributes` is `true` for a lone phone, and `TerminalGridReadout`
already reads it to drop the attribution — so the container needs the same gate: full-bleed when THIS
device is the one sizing the pane, letterbox only when somebody else is. Not yet done: an iOS-only
pane observed on the Simulator does sit at the `openpty` default 80×24, but the Simulator's terminal
surface renders no PTY bytes at all there, so that run cannot separate this loop from the renderer.

**Still owed, and honestly owed:** the laggard-eviction threshold is a policy invention calibrated
below the real 64 MiB offline gate — only a cellular-iOS soak settles it, and a unit test cannot.

---

## 10. Risks and open questions

| Risk | Phase | Mitigation |
|---|---|---|
| The `MuxChannelSession` subscriber-set rewrite touches the out-FIFO, the 1024-shed control queue, the credit window, journal ownership, the input task and `rebindRelay`'s reattach ordering **simultaneously** | 6 | Last phase; **two-subscriber `SubprocessE2ETests` with a real PTY** is the gate, not loopback — plus a process-table shell count, so a join that secretly forked cannot pass |
| A corrupt `workspace-state.json` bricks every client at once | 5 | Decode-fail → the **default** document + `.corrupt-<ts>` preserve-aside. There is no fallback and never was one: the fast-path sinks carry per-pane facts, not the LAYOUT, so a host that serves no document serves no tree |
| `WorkspaceTreeOps` was written for trusted local `@MainActor` callers and now takes network input | 5 | Depth cap 12, `u8` child counts, all counts bounded before allocate, every referenced ID must pre-exist; `WorkspaceIntentHostileTests` |
| Laggard-eviction threshold is a policy invention with no prior art in this repo | 6 | Calibrated below the real 64 MiB offline gate; real cellular-iOS soak, not a unit test; same commit as fan-out |
| Golden hand-merge performed **three** times (Phase 3 codec keys, Phase 4 wire keys, `muxEnvelopes` class-1 record) against a 48-key corpus with 13 non-emitted frozen keys | 3, 4 | Never `>`-redirect; regenerate with no `SLOPDESK_*` env; the frozen-key list goes in the Phase-3 commit message |
| `hostOutputSniffer` / `terminalModeTracker` are frozen keys the generator never emits → a title-path change has **no** golden signal | 1 | `HostOutputSnifferGoldenGuardTests` |
| Phase 1's `.title`-after-`.commandStatus` ordering is one careless reorder from silently regressing | 1 | Explicit comment + `testTitleIsEnqueuedAfterCommandStatus`; **deleted** in Phase 4 when `pane/titleFresh` ships |
| `tab/syncInputArmed` host-side means an iPhone can fan thumb-typing into four panes | 5 | The armed state is **visible on every client** (that is the point of hosting it) and arming is an explicit user action; accepted |
| Shared focus feels like a screen-grab in real use | 5 | `followSessionFocus` ships in the same phase, default OFF on iOS; unfollowed clients carry their view in presence |
| A second client's **video** pane: the document advertises `pane/videoTarget`, and the hang-safety rule forbids constructing an `SCStream` / `VTCompressionSession` in a unit test, so whether two of each can serve ONE capture target was unprovable headlessly | 4 | **MEASURED — it works** (`bash scripts/check-video.sh --second-client`, 2026-07-29). A second instance given ONLY the terminal autoconnect learned the pane from the document, resolved the ports off its `ConnectionTarget` defaults, dialled its own lane and decoded + presented; the first client's decode counter kept CLIMBING across the join (16 → 34), so it is a fan-out and not a takeover; both instances hold their own media lane, asserted per-PID. Pixel-checked: each instance's own screenshot shows the same remote window live, B's frame NEWER than A's. No refusal ships on either side |
| The blast radius of a compromised mesh peer grows from "can attach one pane" to "can restructure your whole workspace and close your tabs" | 5 | Stated out loud in DECISIONS Entry 1. Security remains the WireGuard mesh; no app-layer auth is introduced |

**Open questions**

1. ~~Should `SLOPDESK_WORKSPACE_DOC` ever flip default-ON before Phase 6 lands?~~ **CLOSED — the
   answer is removal, not a default** (DECISIONS, "The workspace document is unconditional",
   2026-07-29). The two earlier rulings are superseded. The flag's off position is a host that
   answers `.refused`, a client that holds `topology == nil` and never retries, and every mutation a
   silent no-op — a blank window with no error. Nobody wants that configuration, and a switch with
   one usable position is a coupling hazard wearing a settings label. Multi-client sync is
   first-class and always-on, like tmux and zellij, and has no toggle at all.
2. `SLOPDESK_SUB_LAG_BYTES = 32 MiB` is a first guess. Only a cellular-iOS soak settles it.
   **The MECHANISM is now soaked** (`scripts/soak-fanout-laggard.sh`, real `slopdesk-hostd` + two
   `slopdesk-client`s, the laggard frozen with `SIGSTOP` so it stops reading AND stops acking in the
   same instant). At the shipped 32 MiB: retention held 8.4 MB for the laggard and it received every
   line exactly once on resume; the fast member took 134.2 MB, contiguous and duplicate-free, while
   the laggard was frozen; eviction fired on the laggard and only the laggard, and the shell
   survived it. What that CANNOT settle is the constant — on loopback the whole 134 MB moves in
   ~20 s, so the threshold is crossed long before any human-scale "my phone was asleep" interval.
   32 MiB stands as an unvalidated guess pending a real cellular link.
3. Does the document itself ever need sweeping, or is the capped `closedTabRing` + explicit
   `closePane` sufficient across months of churn? Measure before adding a GC.
4. ~~Does anything read `followSessionFocus`?~~ **CLOSED.** Every focus gesture forks through
   `stageFocus(tab:)` / `stageFocus(pane:)`: ON sends the intent, OFF records a `DeviceFocus` the
   `tree` getter overlays and sends nothing. Presence goes out either way (DECISIONS, Multi-client
   Phase 5b, ruling 7). The flag is also **reachable**: Settings → General → Shared Focus writes it
   through `WorkspaceStore.setFollowSessionFocus(_:)`, injected at BOTH settings roots
   (`SlopDeskSettingsScene` and the iOS `SettingsSheet`, which does not inherit its presenter's
   environment), so neither platform is stuck on the default it was born with.

---

## 11. Non-goals

1. **Identical terminal CONTENT rendering.** Two clients converge on the same bytes via independent
   `ReplayBuffer` cursors, but they do **not** share scroll position, selection, or copy-mode cursor —
   and that is **correct** (tmux: the visible position belongs to the client). SlopDesk renders in
   libghostty client-side; zellij's server-side-rendered identical pixel stream is a deliberate
   architectural difference, not an oversight.
2. **A "mirror everything" pixel-lockstep mode** (`screen -x` / zellij `mirror_session = true`). Would
   need a separate opt-in mode.
3. **PATH 2 (video) fan-out.** All clients agree a pane streams Xcode (`pane/videoTarget` is topology),
   but each client negotiates its own UDP stream, its own FEC, its own resolution. Two clients watching
   one video pane is **N encodes, not a fan-out** — and whether the host supports even two is
   HW-PENDING (§10). `videoModesByTarget` stays device-local per
   [DECISIONS.md](DECISIONS.md):1312-1321.
4. **PATH 3 (Inspector).** Untouched, still a separate read-only TCP port. It is the **template**, not a
   merge target. Where it and the document carry the same fact (agent lifecycle), the Inspector is a
   **derived, lossy read model** with no ordering guarantee relative to `stateNum`, and
   `HostWorkspaceDocument` is authoritative on disagreement.
5. **PATH 4 (file transfer).** Untouched.
6. **Offline tree editing / intent queueing / rebase-on-reconnect.** A disconnected client cannot open a
   tab; pending intents are **dropped at disconnect, not replayed**. Making this work needs durable
   client-side intent logs and LiveStore-style `upstream-rebase` + `rebaseGeneration` — a materially
   larger sync engine.
7. **Any app-layer auth, pairing, tokens, or per-client permissions.** `clientInstanceID` and the device
   label are **presence decoration, not credentials**. Security remains the WireGuard mesh.
8. ~~**Live-process survival across a hostd restart.**~~ **SUPERSEDED 2026-08-11 → [51].** This was a
   non-goal on the reasoning that a live process cannot outlive the daemon that forked it. True, and
   the fix was to stop forking it from the daemon: `slopdesk-superd` holds the PTY master fd, so a
   supervised pane comes back **live**, not `liveness = 2`. The rest of this section's reasoning about
   what the *document* can and cannot carry is unchanged — see §6.5.
9. **Cross-host workspaces.** A client talking to two hostds gets **two documents** and must compose
   them itself; the rail would need a real multi-document model, which is not designed here.
10. **Fractional indexing for tab order.** Short lists rewritten wholesale by the host are sufficient at
    this scale. Revisit only if concurrent reorder churn is actually observed.
11. **Command blocks (types 28/29) in the document.** The host already segments them authoritatively and
    re-sends held metadata on reattach, so they self-heal; "which block is running" stays a per-client
    derivation. Only `pane/runningCommand` enters the document.
12. **Block bookmarks.** Client-local and per-materialization. The doc comment gets fixed; the behaviour
    does not change.
13. **A generic format-subscription channel** (tmux `refresh-client -B` / `%subscription-changed`).
    Validated prior art, and the right retrofit *if* the document ever needs ad-hoc fields — but a
    fixed, golden-pinned entry schema is the right starting point.
14. **Multi-user collaboration.** Input from two clients interleaves with **no arbitration** and the
    client label is checked nowhere. Correct under the "one human, many devices, WireGuard mesh" threat
    model; must not be mistaken for a collaboration feature.

---

## 12. `docs/DECISIONS.md` entries to write

Per the re-scope convention these land **before** the corresponding code.

**Entry 1 — "Multi-client: hostd owns the workspace document"** (before Phase 2). The three-bucket
ownership split with the fact-vs-view test; host-minted pane identity replacing the client-minted
`sessionID`; `epoch: UUID` as the no-migration directive expressed on the wire; the one-sentence LWW
rule; the explicit rejection of CRDT/OT with the Zed precedent (CRDT for text buffers,
host-authoritative RPC for the worktree tree); the explicit rejection of an operation log / delta
compaction in favour of snapshot-at-current-`stateNum`; **ctl-spawned `controlSessions` panes ARE in
the document** under `root/unattachedSessionID` so `listPanesForControl` and the document cannot
disagree; the delete-removes-an-OBJECT / zero-length-retires-a-FIELD rule; the Inspector as a derived
lossy read model with the document authoritative; the default-document bootstrap and `adoptWorkspace`
as a legacy one-shot **with its orphan-file escape**; and the enlarged blast radius of a compromised
mesh peer, stated out loud.

**Entry 2 — "Focus is host-truth; `videoModesByTarget` is not"** (before Phase 5). Must quote
[DECISIONS.md](DECISIONS.md):1312-1321 in **all three legs** and say which survive:
(a) *"Immersive is a client-LOCAL CGEventTap — the host cannot own another machine's keyboard
routing"* — **stands**;
(b) *"host-side durability would need a persistent per-pane identity the host doesn't have
(PaneID/workspace is a client concept)"* — **obsolete**, pane identity is now host-minted;
(c) *"a second client (iPad/macbook) viewing the same host must NOT inherit the first client's
per-pane view prefs"* — **stands**.
(a) + (c) alone carry the ruling, which is a stronger argument than the original. Then: which pane a
session points at is not a view wish — it determines successor-after-close, notification targeting, and
what a fresh client opens into. Records the device-local `followSessionFocus` flag (ON macOS / OFF iOS)
as the shipped escape, and that `videoModesByTarget` stays device-local while the video **target
identity** becomes topology.

**Entry 3 — "PTY size under N clients: monotone min-fold over ATTACHMENT"**. Records the rejection of
WezTerm's / `screen -x`'s unconditional last-writer-wins **and** of an input-keyed driver latch (it
flaps `TIOCSWINSZ` + `SIGWINCH` + repaint on alternating keystrokes and lets a pocket byte reflow a
200-column Mac) **and** of a presence-keyed predicate (a 30 s heartbeat TTL is not a resize request).
The contributor set is the open-`channelClass 0` set; 750 ms settle; iOS size-passive; zero-contributor
keep-last-size; **both** `pty.setWindowSize` sites (`MuxChannelSession.swift:1850` client path, `:2138`
ctl path) route through one `applyResolvedGrid()`. Names zellij Discussion #5066 as the acknowledged
cost.

**Entry 4 — "The badge fact is shared; the acknowledgement is not"**. Objective host
`pane/completionEpoch` + device-local `seenCompletionEpoch`. Records the rejection of tmux's
server-side shared activity flags **and** of a host-held `unseenBy: Set<ClientInstanceID>` (unbounded,
no GC, undefined for a client offline when the event fired, undefined across a restart). The host holds
**zero** per-client acknowledgement state. Same entry covers types 22/25: fan to all, gate per client,
duplicate banners across a user's own devices are the point; `hookAuthority` suppression stays
host-global.

**Entry 5 — "Workspace channel transport rules"**. `channelClass 1` (0 PTY / 1 workspace / 2
observer); the workspace channel **must never** use `enqueueControl` (verified newest-shed at 1024 →
a shed snapshot is a permanently blank client with no retry trigger); depth-1 coalescing;
diff-from-the-**acked** base; **only kinds 0 and 1 advance `stateNum` or ack**; the client fast-path
overlay may **never** write `entries`; the **state-plane vs byte-plane** validate-then-drop ordering
rule; `SLOPDESK_SUB_LAG_BYTES` eviction against the real 64 MiB gate / 256 MiB ceiling, and "the PTY
pauses only when the LAST subscriber leaves"; and the hard sequencing gate — **`closePane` reaps
unconditionally and `channelClose`s every subscriber; only `detach` is refcounted** — before fan-out.

**Entry 6 — doc corrections (same pass).**
- [20](20-wire-protocol.md):352-353 is **stale today** (claims next-free host→client is 36; 36 is
  `agentSessionIntent`).
- [20](20-wire-protocol.md):373-381 "Replay-buffer caps" is **stale**: it says 64 MiB ceiling / 4 MiB
  offline gate; the code is 256 MiB (`ReplayBuffer.swift:54-55`) and 64 MiB (`:57-58`).
- [22](22-workspace-architecture.md):349 is **stale** ("a relaunch is a fresh session… sessionIDs are
  NOT persisted"): a pane's own id is its mux `sessionID`, so presenting it on `channelOpen` resumes
  the shell, and Stage-2 resume is default-ON. Its `SlopDeskClientUI/…` paths are stale too (the code
  lives under `Sources/SlopDeskWorkspaceCore/Workspace/`).
- `WorkspaceStore.swift:1132-1140`'s `blockBookmarks` field doc claims stable-`PaneID` keying while
  `WorkspaceStore+Blocks.swift:21-25` uses the per-materialization `bookmarkScopeKey` — **fix the
  comment, keep the code**.
