# 45 — Multi-client state sync: the host-owned workspace document

> **STATUS: PROPOSED.** Design for `WorkspaceDocument` — one host-owned workspace state object,
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

Nothing about that is a persistence bug. `PaneSpec.lastKnownTitle` is persisted
(`Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSpec.swift:255`), the quit-time flush is
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

## 2. Where we are today

### 2.1 The transport fact that gates everything

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

### 2.2 Who owns what today

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

`lastKnownCwd` / `projectKey` are the working counter-example: host-derived, persisted client-side as
a warm cache, **and** re-asserted on every reattach. That is the pattern this document generalizes to
everything.

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
| `RecentlyClosedTab` ring (`WorkspaceStore.swift:599`) | `root/closedTabRing` | ⇧⌘T reopens a tab whose panes live host-side. A per-client undo stack over shared state is incoherent. |
| `Session.name` / `.tabs` order / `.detached` | `session/*` | Topology. |
| `Session.activeTabIndex` → **`session/activeTabID`** | `session/activeTabID` | Indices are exactly what broke in `ed76f137`. Identity, not position. |
| `tabFocusHistory` (`WorkspaceStore.swift:611`) | `session/focusMRU` | If close is an intent and the tree is host-owned, two clients computing successors from different local MRU rings diverge and the host's index clamp reintroduces the `ed76f137` bug. The ring must be shared. |
| `Tab.title` / `.activePane` / `.zoomedPane` / `.root` structure | `tab/*` | Topology. |
| `broadcastActive` / `syncInputTabs` (`WorkspaceStore.swift:1313`) | `tab/syncInputArmed` | tmux `synchronize-panes` is a server-side **window option**. Hosting only the armed bit while fanning client-side is incoherent — client B's keystrokes would not fan. Host both. |
| `WeightedChild.weight` | `splitNode/weight` (**its own object**) | Two clients dragging two different dividers write two different keys and cannot clobber each other. |
| `PaneSpec.kind` | `pane/kind` | Topology. |
| `PaneSpec.title` + `.userRenamed` | `pane/title`, `pane/userRenamed` | A rename is authorship — but authorship *of shared state*. A tab renamed on the Mac is renamed on the phone. |
| `PaneSpec.lastKnownTitle` → **`pane/liveTitle`** | `pane/liveTitle` | Was a client cache of `MuxChannelSession._currentTitle` (`:152`) with **no invalidation signal**. That cache is the reported bug. |
| **NEW** `pane/titleFresh` (u8) | `pane/titleFresh` | Replaces `programTitle(for:)`'s two-stamp guess. The host owns both inputs (OSC-title stamp; segmenter open-block start), so the host ships the **verdict**. §4.4 states the rule. |
| `PaneSpec.lastKnownCwd` | `pane/cwd` | Already host truth (`lastCwdTruth`, type 33). |
| `PaneSpec.projectKey` | `pane/projectKey` | Already host truth (`lastProjectKey`, type 34). |
| `paneForegroundProcess` (`:2956`) | `pane/foregroundProcess` | Type 26. |
| **NEW** `pane/runningCommand` | `pane/runningCommand` | Today `RailRowsBuilder.liveRowTitle(runningCommand:)` reads the *client's* per-materialization `TerminalBlockModel`. A client that has rendered zero bytes cannot reproduce the sidebar title chain at all. Source: the host's own `CommandBlockSegmenter` open block. This is the missing link for "the host alone can render the sidebar". |
| `paneAgentStatus` / `Label` / `Intent` (`:2934`) | `pane/agentState`, `/agentLabel`, `/agentIntent` | Types 27 / 36. |
| `paneProgress` | `pane/progress` | Type 32. |
| type-23 running latch, `lastExitTruth`, duration | `pane/commandRunning`, `/lastExitCode`, `/lastDurationMS` | Already host truth. |
| PTY grid | `pane/grid` (cols, rows) | Published so a non-contributing client letterboxes correctly instead of guessing. |
| **NEW** `pane/liveness` (u8) | 0 live-attached · 1 live-detached · 2 journal-only/dead | Lets a client render a post-restart pane as **stale**, not fake-live. |
| **NEW** `pane/completionEpoch` (u32) | `pane/completionEpoch` | A monotone counter the host bumps on every working→done edge. The host holds **zero** per-client acknowledgement state (§8.4). |
| `PaneSpec.video` **target identity only** | `pane/videoTarget` | Both clients must agree "tab 3 slot 2 is a video pane on Display 1" — that is topology. The **modes** stay device-local (§4.3). |
| **NEW** git summary (type 35) | `project/gitSummary` | `projectGitSummary` (`:3006`) is host truth keyed by **project**, not pane — so it needs its own object kind, or a never-seen-this-host client renders no git line until the first FSEvents edge. |

**Pane identity becomes host-minted.** The host's `sessionID` UUID **is** the pane objectID, published
in every snapshot. A client spawning a pane sends an intent and **learns the id back**. `PaneID`
survives client-side as the local rendering key, seeded from the host id. `PaneSpec.resumeSessionID`
is deleted — the host-minted pane id *is* the rendezvous identity.

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

### 4.4 Deleted outright, not relocated

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
2 = .paneObserver  read-only PTY subscriber            (Phase 6)
```

`HostServer.spawnMuxChannel` (`:616`) gains a **first line**, placed **before** the `attachedElsewhere`
critical section at `:634-643`, so the PTY exclusivity invariant is untouched through Phase 5:

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
   - §8.3.1 gains a `channelClass` paragraph (0 PTY / 1 workspace / 2 observer);
   - new **§10 "Workspace document channel"** — entry grammar, epoch/stateNum, diff-from-acked-base,
     the depth-12 cap, the coalescing-not-shedding rule, the PTY size policy, and the
     state-plane/byte-plane ordering rule (§8.7).

**The golden blind spot, named.** Two of the 13 frozen keys — **`hostOutputSniffer`** (the OSC
title/bell state machine behind type 21) and **`terminalModeTracker`** — are PATH-1-adjacent. A
title-sniffer behaviour change in exactly the phases that touch the title path produces **no
`golden-check.sh` signal at all**. Mitigation, added in Phase 1:
`Tests/SlopDeskProtocolTests/HostOutputSnifferGoldenGuardTests.swift` asserts the frozen vector still
round-trips against the live sniffer, so the XCTest suite is a real gate rather than an implicit one.

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

`ScrollbackJournalStore` writes to `<Application Support>/SlopDesk/scrollback/`
(`ScrollbackJournal.swift:115-119`); the document is a **sibling of that directory**, not a file inside
it. `sweep(maxAge:keepNewest:)` (`:298-308`) walks only `*.scrollback` in that directory and never sees
the new file — correct, and worth saying so nobody "fixes" it.

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
3. **Live processes do not survive** — `DetachedSessionStore` is in-process. Restored panes come back
   with `pane/liveness = 2` and their last-known metadata, `titleFresh = 0`, `commandRunning = 0`,
   `attachedBy` empty. The client renders them **stale** (dimmed, no busy dot), not fake-live. This is
   zellij's resurrection boundary and the design does not pretend to move it.
4. A restored pane's `<uuid>.scrollback` journal still drives PATH-B `composeTranscript` on respawn —
   unchanged.

### 6.6 Lifecycle reconciliation

Two host subsystems change the world behind the document's back and must be wired to it, or the
document goes semantically stale with no signal:

- **`DetachedSessionStore.onEvicted`** fires *after* it kills a stored session, on both TTL eviction
  and `SLOPDESK_DETACH_MAX_SESSIONS` overflow (`DetachedSessionStore.swift:37-60,84-115`). Subscribe
  the document: set `pane/liveness = 2`, bump `stateNum`.
- **`ScrollbackJournal.sweep(maxAge: 14d, keepNewest: 256)`** deletes journals. A pane whose journal is
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

- `tree` becomes `mirror.project()`.
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
`renamePane` is idempotent; `splitPane` / `spawnPane` are **not**. Staging a patch removes the
double-apply window between the delta carrying an intent's effect and the `intentResult` retiring it —
and removes the need to define that ordering at all.

**Anti-flicker (Figma's rule):** while `pending` touches key K, an incoming host value for K is written
into `entries` but **not surfaced**; the overlay wins until the intent resolves. Resolution is
`stateNum >= intentResult.new` (not `intentResult` *arrival* — retiring on arrival flashes the
pre-intent value for one RTT), a non-zero `status` (the UI **snaps** to host truth, which is the
correct visible outcome of a rejected rename), or a **3 s timeout**.

**Offline intents are dropped at disconnect, never queued or replayed.** Replaying "close tab 3" after
a four-hour disconnect is wrong. The UI disables mutation while the workspace channel is down.

### 7.3 What the client persists

**`workspace-cache.json`**

```json
{ "hostKey": "<host identity>", "epoch": "<uuid>", "stateNum": 4471,
  "snapshot": "<base64 of the raw kind-0 payload bytes>" }
```

The **exact snapshot payload bytes**, not a re-encoded model. Painted immediately at launch so there is
no blank window, and **never authoritative**: no promotion, no fallback title, no freshness heuristic.

**The paint gate is `hostKey` + a successful length-checked decode — not the epoch.** The epoch's job
is to prevent accepting a stale *delta*, not to prevent painting a stale *picture*. A hostd restart
mints a new epoch while `workspace-state.json` restores the document byte-identically; gating the paint
on the epoch would blank the window on exactly the reboot case the cache exists for. The recorded epoch
is used for one thing: `subscribe` sends `knownStateNum = 0` when it differs. The incoming kind-0
snapshot replaces the cache wholesale regardless.

`hostKey` mismatch or a failed decode → discard to empty; the client shows a connecting state for one
RTT. Strictly better than "show `vi .` forever".

**`device-prefs.json` / UserDefaults** — window frame, sidebar width, rail collapsed,
`videoModesByTarget`, `seenCompletionEpoch`, `followSessionFocus`, `focusHistory` seed,
`blockBookmarks`, `Session.connection` per `hostKey`. Everything in §4.3.

**Gone from disk:** `TreeWorkspace` (sessions/tabs/splits/specs/presets), `lastKnownTitle`,
`lastKnownCwd`, `projectKey`, `resumeSessionID`, `resumeLastReceivedSeq`. Per the no-migration
directive the existing v11 file simply **decode-fails to default** on first run of the new build.

### 7.4 Cold-start sequence

```
CLIENT                                                     HOST (hostd)
  |                                                              |
  |-- read workspace-cache.json ------------------------------→  |   (local, ~2 ms)
  |   PAINT the full sidebar from cached snapshot bytes          |
  |   every row marked "unconfirmed" (subtle, not a spinner)     |
  |                                                              |
  |-- TCP mux connect, hello(v1) ------------------------------→ |
  |←------------------------------------------------ helloAck --|
  |                                                              |
  |-- channelOpen(channelClass: 1, sessionID: zero) -----------→ |  routed BEFORE the
  |←------------------------------------------- channelOpenAck --|  attachedElsewhere gate
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
  |   LAZY, and ONLY for a pane whose attachedBy is empty or     |
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
   timer** so a burst of joins resolves once.
3. A subscriber may declare itself **size-passive** (tmux `ignore-size`) and contributes nothing.
   **iOS is size-passive by default.** A phone must never crush a Mac.
4. **A pane with zero contributing subscribers keeps its last size** — it does not snap to 80×24.
5. Wire type 11 `resize` stops being a command and becomes a **contribution**.
   `scheduleResize` / `flushPendingResize` (`MuxChannelSession.swift:1812-1850`) folds the min before
   the single client-path `pty.setWindowSize` at **`:1850`**. **No wire change.**
6. There is a **second, independent** `pty.setWindowSize` at **`:2138`**, inside
   `resizeForControl(rows:cols:)` — the ctl socket's `resize` verb, used by `slopdesk-ctl` and
   orchestrators. Both paths route through one `applyResolvedGrid()` that reads the folded contributor
   set; the ctl verb is an explicit override that also updates `pane/grid`. Leaving `:2138` outside the
   fold silently breaks the monotone-min invariant.
7. The resolved grid and the contributor list are published in the presence frame, so a
   non-contributing client renders a **labelled** letterbox — `120×40 · sized by MacBook Pro` —
   instead of guessing. That readout is what makes the policy debuggable on hardware.

Known, accepted cost: zellij's smallest-client-wins is a documented pain point (Discussion #5066). The
iOS-passive default removes the worst case. **iOS needs a scale-to-fit path in `TerminalSurface` that
does not exist yet** — Phase 6 work, not free.

### 8.4 Input, and the badge

**Last-writer-wins into the one PTY. No arbitration, no locking, no exclusivity.** tmux, `screen -x`
and WezTerm all do this, and it is correct here because the writers are **one human on two machines**,
not adversaries. `MuxChannelSession.inputTask` (`:774-798`) merges N subscriber `.inbound` streams into
the existing single writer; bytes interleave atomically at frame granularity. Observer-class
(`channelClass == 2`) subscribers' `input` frames are **dropped host-side**.

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
    detached-budget behaviour exactly.
  - An evicted client reconnects cold and gets `composeSnapshotReplay`'s render-once state transfer.
    **This is precisely why the 2026-07-25 PATH-B work makes multi-attach affordable: eviction costs
    one screen, not a history.**

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
- `Tests/SlopDeskWorkspaceCoreTests/WorkspaceStoreProgramTitleTests.swift`
  - `testTitleWithNoCommandStartIsTrusted`
  - `testTitlePredatingCommandStartIsStillRejected`
- `Tests/SlopDeskHostTests/HostServerListPanesTests.swift` — `testDetachedPaneIsListed`
- `Tests/SlopDeskProtocolTests/HostOutputSnifferGoldenGuardTests.swift` — closes the frozen-key blind
  spot (§5.7)

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

**Host**
- `HostWorkspaceDocument` actor (pane + project records only — topology still client-owned), `epoch`,
  `stateNum`.
- `WorkspaceChannelSession` with the **depth-1 coalescing** send task. **Never `enqueueControl`.**
- `PaneLiveness.paneEntries()` fed from the truths `MuxChannelSession` already latches.
- **`pane/titleFresh`** computed host-side, all four rules of §4.4.
- **`pane/runningCommand`** from the host's own `CommandBlockSegmenter`.
- **`pane/completionEpoch`** bumped on each working→done edge.
- **`project/gitSummary`** fed from `RepoStatusWatcher` (type 35 keeps pushing as the fast path).
- ctl panes get entries under `root/unattachedSessionID`.
- `channelClass == 1` routing in `spawnMuxChannel`, **before** the `attachedElsewhere` gate.

**Client** — SHIPPED; four bullets below were revised in the doing, see
[DECISIONS](DECISIONS.md) § *Multi-client Phase 4d*.

- `HostWorkspaceMirror` with **two** layers, not three: `entries` and `fastPath`. The optimistic
  `pending` layer has no writer until Phase 5's intents, and `value(for:)` is its insertion point.
- Every mirror key is the **host-minted** pane id (`documentPaneID(_:)`), never the tree-local
  `PaneID`. Getting this wrong is silent — it was, for one commit.
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
- `Tests/SlopDeskWorkspaceCoreTests/WorkspaceMirrorFastPathTests.swift` — fast-path-write a key, then
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
- `WorkspaceIntentApplier` — all 21 ops, pure, with validate-then-drop and a re-check of the RESULT
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

**Still to do — the store cutover**
The client `WorkspaceStore` still owns and persists its own `TreeWorkspace`; the document is read for
per-pane facts and the optimistic layer, not yet for the LAYOUT. Until that flips, two clients see
two trees and the phase's headline value is not delivered on hardware. It is deliberately separate
because it is the single riskiest change in the plan — every UI surface reads `store.workspace` —
and everything under it is now proven headlessly. It carries with it:
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

### Phase 6 — PTY fan-out · `SLOPDESK_PANE_FANOUT` (`== "1"`, default-OFF), LAST

**Value: two clients watch one live nvim.**

- `MuxChannelSession.data` / `.control` (`:56-58`) → `subscribers: [MuxSubscriberID: Subscriber]`;
  `rebindRelay` (`:1243-1466`) splits into `addSubscriber` / `removeSubscriber` (the existing swap
  becomes the 1-subscriber special case).
- `reestablishActivityOnReattach()` runs **on JOIN**, per new subscriber.
- **`min(lastAckedSeq)` retention + `SLOPDESK_SUB_LAG_BYTES` eviction, in this same commit** (§8.6).
- min-fold over `attachedBy` with the 750 ms settle timer; both `pty.setWindowSize` sites (`:1850`,
  `:2138`) route through `applyResolvedGrid()`; iOS size-passive; contributors published.
- `channelClass == 2` observer subscribers (input dropped host-side).
- **Delete** the `attachedElsewhere` refusal (`HostServer.swift:634-643`). The hazard it names — two
  sessions aliased to one id — dissolves: with **one** session object and N sub-channels there is one
  journal writer and one close path.
- Park in `DetachedSessionStore` only when the subscriber set empties.
- iOS `TerminalSurface` letterbox / scale-to-fit (does not exist today).

**Gate:** `SubprocessE2ETests` gains a **two-subscriber** case with a **real PTY**. Per
[CLAUDE.md](../CLAUDE.md) the in-memory loopback provably misses open-order races, so a loopback test
is not acceptable evidence here. Plus a laggard-eviction soak on a real cellular iOS client — a unit
test cannot tune `SLOPDESK_SUB_LAG_BYTES`. Plus `bash scripts/check-ios.sh`.

---

## 10. Risks and open questions

| Risk | Phase | Mitigation |
|---|---|---|
| The `MuxChannelSession` subscriber-set rewrite touches the out-FIFO, the 1024-shed control queue, the credit window, journal ownership, the input task and `rebindRelay`'s reattach ordering **simultaneously** | 6 | Last phase; `SLOPDESK_PANE_FANOUT` default-OFF; **two-subscriber `SubprocessE2ETests` with a real PTY** is the gate, not loopback |
| A corrupt `workspace-state.json` bricks every client at once | 5 | Decode-fail → the **default** document + `.corrupt-<ts>` preserve-aside; `SLOPDESK_WORKSPACE_DOC=0` falls back to the retained fast-path sinks |
| `WorkspaceTreeOps` was written for trusted local `@MainActor` callers and now takes network input | 5 | Depth cap 12, `u8` child counts, all counts bounded before allocate, every referenced ID must pre-exist; `WorkspaceIntentHostileTests` |
| Laggard-eviction threshold is a policy invention with no prior art in this repo | 6 | Calibrated below the real 64 MiB offline gate; real cellular-iOS soak, not a unit test; same commit as fan-out |
| Golden hand-merge performed **three** times (Phase 3 codec keys, Phase 4 wire keys, `muxEnvelopes` class-1 record) against a 48-key corpus with 13 non-emitted frozen keys | 3, 4 | Never `>`-redirect; regenerate with no `SLOPDESK_*` env; the frozen-key list goes in the Phase-3 commit message |
| `hostOutputSniffer` / `terminalModeTracker` are frozen keys the generator never emits → a title-path change has **no** golden signal | 1 | `HostOutputSnifferGoldenGuardTests` |
| Phase 1's `.title`-after-`.commandStatus` ordering is one careless reorder from silently regressing | 1 | Explicit comment + `testTitleIsEnqueuedAfterCommandStatus`; **deleted** in Phase 4 when `pane/titleFresh` ships |
| `tab/syncInputArmed` host-side means an iPhone can fan thumb-typing into four panes | 5 | The armed state is **visible on every client** (that is the point of hosting it) and arming is an explicit user action; accepted |
| Shared focus feels like a screen-grab in real use | 5 | `followSessionFocus` ships in the same phase, default OFF on iOS; unfollowed clients carry their view in presence |
| A second client's **video** pane: the document advertises `pane/videoTarget`, but nothing establishes that `SCStream` / `VTCompressionSession` support two concurrent sessions on one target — and the hang-safety rule forbids proving it in a unit test | 4 | **HW-PENDING.** Until `scripts/check-video.sh` says otherwise, a second client's video pane renders **unavailable** with the refusal in the client's video-pane materializer, not the host |
| The blast radius of a compromised mesh peer grows from "can attach one pane" to "can restructure your whole workspace and close your tabs" | 5 | Stated out loud in DECISIONS Entry 1. Security remains the WireGuard mesh; no app-layer auth is introduced |

**Open questions**

1. Should `SLOPDESK_WORKSPACE_DOC` ever flip default-ON before Phase 6 lands, given that Phases 4–5
   ship a synchronized document over a still-single-attach PTY? The `attachedBy` gate makes it
   coherent, but "see it, can't open it" is a UX call, not an architecture one.
2. `SLOPDESK_SUB_LAG_BYTES = 32 MiB` is a first guess. Only a cellular-iOS soak settles it.
3. Does the document itself ever need sweeping, or is the capped `closedTabRing` + explicit
   `closePane` sufficient across months of churn? Measure before adding a GC.

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
8. **Live-process survival across a hostd restart.** The document persists topology and metadata so the
   workspace re-renders correctly; the panes come back **dead** (`liveness = 2`), exactly zellij's
   resurrection caveat. Only `DetachedSessionStore`-parked sessions survive, and only while the daemon
   lives.
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
  NOT persisted" — `PaneSpec.resumeSessionID` persists them and Stage-2 resume is default-ON), and its
  `SlopDeskClientUI/…` paths are stale (the code lives under
  `Sources/SlopDeskWorkspaceCore/Workspace/`).
- `WorkspaceStore.swift:1132-1140`'s `blockBookmarks` field doc claims stable-`PaneID` keying while
  `WorkspaceStore+Blocks.swift:21-25` uses the per-materialization `bookmarkScopeKey` — **fix the
  comment, keep the code**.
