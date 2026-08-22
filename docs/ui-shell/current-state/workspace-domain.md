# Workspace Domain — Current State

Originally surveyed 2026-06-25 against `Sources/SlopDeskWorkspaceCore/`. Re-verified against the tree
2026-08-22: every row re-checked at a named `file:line`, and every row whose verdict changed says what
changed it. Paths are repo-relative.

Source truth is now THREE places, not one:

- `Sources/SlopDeskWorkspaceModel/` — the pure value model (`TreeWorkspace` / `Session` / `Tab` /
  `SplitNode` / `PaneSpec` / `WorkspaceTopology` / `WorkspaceIntent`). It moved out of
  `SlopDeskWorkspaceCore` so `SlopDeskHost` can import it: the host runs the same applier.
- `rust/slopdesk-tree/`, `rust/slopdesk-ids/`, `rust/slopdesk-workspace/`, `rust/slopdesk-settings/` —
  the ops, the identity, the persistence codec and the settings catalogue. One crate until 2026-08-22
  (`docs/DECISIONS.md` "The domain crate was four crates wearing one name").
- `Sources/SlopDeskWorkspaceCore/Workspace/` — the STORE: the registry, the reconcile loop, the
  intent staging, the device-local preferences.

---

## Overview

**The dual-model transition is over, twice.**

The original survey described a store holding both a canvas `Workspace` and a `TreeWorkspace` behind a
`liveModel` switch. The canvas was **deleted on 2026-08-17** (`docs/DECISIONS.md` "The canvas is
deleted, two years after it stopped being live"): `Canvas`, `Canvas+Ops`, `Canvas+Codable`,
`CanvasGeometry`, `CanvasNonOverlap`, `CanvasSnap`, `PaneGroup`, `Workspace`, `CompactLayoutResolver`,
`CommandInterpreter`, ~40 canvas-only `WorkspaceStore` members, 22 test suites, five Rust modules and
27 FFI doors went in one commit. The `liveModel` switch went with them — "a two-case enum whose second
case has no model behind it is not a choice." Docs 30, 32 and 35 stay, marked historical.

**A second, larger shift the survey predates: the document is HOST-owned.** `WorkspaceStore.tree` is
no longer a stored value the store mutates. It is a memoized PROJECTION of the host's document
(`Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift:40-70`): nothing assigns to it,
every mutation stages an INTENT (`WorkspaceStore+Intents.swift:33`), the channel folds the host's own
applier into an optimistic layer, and the store reads the result back. With no channel the tree is
EMPTY and every mutation is a silent no-op — deliberately not a fallback to a locally-owned tree, "that
dual path is exactly what this phase removes" (docs/45). Two clients converge because there is one
owner.

So the shape below is: a pure value model in Swift and Rust, a frozen intent vocabulary on the wire, an
applier that runs identically host-side and client-side (optimistically), and a store whose job is the
live registry rather than the layout.

---

## Capability matrix

| Feature | Status | Evidence |
|---|---|---|
| Session/Tab/Pane tree data model | **done** — package moved | `Sources/SlopDeskWorkspaceModel/Domain/Tree/{TreeWorkspace,Session,Tab,SplitNode}.swift` (was `SlopDeskWorkspaceCore/Workspace/Domain/Tree/`). Pure `Equatable`/`Sendable`; **deliberately NOT `Codable`** any more — the file is read and written by `rust/slopdesk-workspace/src/persist.rs` through `WorkspaceFile` (`TreeWorkspace.swift:10-12`). Specs invariant widened: `Set(specs.keys) == leafIDSet() ∪ detachedIDSet()` (`Session.swift:47`). Schema version is ASKED for, not spelled: `slopdesk_ws_schema_version()` (`TreeWorkspace.swift:56`) = `rust/slopdesk-tree/src/workspace.rs:50` = **12**. |
| Pure ops (`WorkspaceTreeOps`) | **moved to Rust** | The Swift file is down to **405 lines** of pure GEOMETRY and FOCUS: divider resize/even/weight, swap, directional move, balance, the five `LayoutPreset` tilings + cycle, focus/cycle/locate. `Sources/SlopDeskWorkspaceModel/Domain/Tree/WorkspaceTreeOps.swift:28-399`. Every STRUCTURAL mutation — split, close (with cascade), new/insert/close/rename tab, session open/close/select/rename, spec update, detach/reattach, mint/close detached, break-pane-to-tab, cross-tab move, dock-at-edge, rebuild — is `rust/slopdesk-tree/src/tree_ops.rs:159-1226`, reached through the intent applier. |
| **Ownership: the host owns the document** | **done — the biggest change since the survey** | `WorkspaceStore.tree` is a projection over `HostWorkspaceMirror`, memoized against `workspaceMirrorRevision`, with this device's own focus and the live divider-drag preview layered on top (`WorkspaceStore.swift:40-70`). The mirror reads in precedence `pending` → `entries` → `fastPath`; `entries` is provably `apply(diffs, base)` and a fast-path write is ERASED the moment a snapshot supplies the same key (`Sources/SlopDeskWorkspaceCore/Workspace/Sync/HostWorkspaceMirror.swift:5-28`). Optimistic patches run the SAME `WorkspaceIntentApplier` the host will run. |
| Intent vocabulary | **done** — frozen | 27 ops, `adoptWorkspace = 0` … `setPaneVideoTarget = 26`, raw values frozen once a golden vector carries one. `Sources/SlopDeskWorkspaceModel/State/WorkspaceIntent.swift:13-55`; applied at `rust/slopdesk-wire/src/document/apply.rs:97-135`. The DECODE half was deleted with the applier's move rather than kept as a second decoder nothing calls (`WorkspaceIntent.swift:9-12`). |
| Reconcile / registry | **done** | `WorkspaceStore.reconcileTree()` (`:2356`, `:2366`) diffs `tree.allPaneIDs()` against the `[PaneID: any PaneSessionHandle]` registry; `reconcileRegistry` (`:2686`) carries orphan-remove-then-async-teardown, the video-cap ceiling and per-pane cache pruning; live wiring (rebind, OSC-9, agent signal, command completion, title/cwd/progress/read-only callbacks) is factored into `wireMaterializedLeaf` (`:2423`). Detached panes count as desired, so detach ↔ reattach never tears a session down. |
| Layout save-restore (⌘S / named presets) | **REMOVED** with the canvas (2026-08-17) | `saveLayoutPreset(name:triggerAppName:)`, `LayoutPresetId`, app-launch-triggered preset switching and `CommandInterpreter` (which routed ⌘S) were all canvas-only and were deleted in the canvas commit. `docs/DECISIONS.md` "The canvas is deleted…". What covers the ground now is `SessionTemplate` (spawn a named layout) and `LaunchPreset` (open one tab) — both spawn, neither restores the current session by name. Not a gap that was left open: a gap that was closed by deciding it was the wrong feature. |
| Reopen-last-closed (⇧⌘T) | **done** — was "partial (canvas only)" | It is now a HOST-side ring in the document, not a client single slot: `WorkspaceTopology`'s closed-tab ring holds the RECORDS (split tree + every pane's spec), because "a per-client undo stack over shared state is incoherent — the tab it reopens has panes that live host-side" (`Sources/SlopDeskWorkspaceModel/State/WorkspaceTopology.swift:33-40`). Reached by `reopenClosedTab` intent op 20 (`WorkspaceIntent.swift:36`), staged at `WorkspaceStore+PaneCycle.swift:30-55` with LIFO index 0 for ⇧⌘T, and by INDEX from Open Quickly (`Sources/SlopDeskClientCore/Overlays/OpenQuicklyPresentation.swift:248,328`). The reopened tab lands at the configured `NewTabPosition`. |
| Session recovery / persistence (relaunch) | **done** — codec moved to Rust | `WorkspacePersistence` is now **IO-thin**: it owns the URL, the two sidecars and the atomic write, and nothing about the FORMAT (`Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift:6-14,65,85`). Both directions go through `Sources/SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift` → `rust/slopdesk-workspace/src/persist.rs`, which owns the version check, the `MAX_PANES` cap, the repair pass and every tolerance rule. **This was a real bug, not a tidy-up**: the deleted Swift decoder named an unnamed split `?? SplitNodeID()` — a fresh uuid per load — so every divider drag a person had made was orphaned on the next launch, silently (`WorkspaceFile.swift:7-17`). Corrupt / foreign-version file → `.corrupt` sidecar + default (`:200-205`); `On Launch = New Window` snapshots the real session to `workspace.previous.json` first (`:158-171`). |
| Resume identity across relaunch | **done — fields DELETED, rule simplified** | `PaneSpec.resumeSessionID` / `resumeLastReceivedSeq` no longer exist. "The pane's resume identity is its own `PaneID`: the client proposes object ids, so the id the host keys its liveness records by IS the id the layout uses" (`Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift:246-253`). |
| Working-directory inheritance for new pane/tab | **done** — was "missing" | Two halves, both real. (1) The POLICY: `WorkingDirectoryPolicy` = `inherit` / `home` / `path`, a face over `slopdesk_workspace::workdir` (`Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkingDirectoryPolicy.swift:21-72`); `home` resolves to a **`nil`** cwd, not "leave the child wherever it lands", because a `fork`/`execve`d child would otherwise inherit hostd's cwd. (2) The CALL SITE: `newTab` reads the active pane's cwd, resolves it through `SettingsKey.workingDirectoryNewTab`, and stamps it on the intent (`WorkspaceStore.swift:1509-1525`); `seedNewPaneFacts` (`:1538`) is the ONE funnel every new-pane gesture passes through, so cwd and project key cannot be seeded by three transcriptions that drift. No visible `cd` is typed — the cwd rides `channelOpen` into the host-side spawn. |
| OSC 7 → live cwd | **done** — was "no wire-level parser" | `rust/slopdesk-superd/src/sniffer.rs:12` sniffs OSC 7; the host derives the truth (warm-up gate, dedupe latch, `proc_pidinfo` probe at the OSC-133 prompt edge for OSC-7-less shells) and pushes wire type 33 `cwd` + type 34 `projectKey`, both re-asserted on reattach. `docs/DECISIONS.md` ~lines 726, 747. The fact lives in the document as `pane/cwd` / `pane/projectKey`, NOT on `PaneSpec` (`PaneSpec.swift:246-253`). |
| New-tab position | **done** — was "missing" | `NewTabPosition` = `auto` / `end` / `after-current` (`Sources/SlopDeskWorkspaceModel/Domain/Tree/NewTabPosition.swift:23-28`). The PLACEMENT arithmetic is `slopdesk_workspace::session`, asked for through `slopdesk_ws_new_tab_index` (`:47-58`) — the Swift copy "answered its own tests and nothing else, which is the one arrangement in which a divergence cannot show up as a red anything". Every ⌘T and ⇧⌘T sends the policy as a byte inside the intent and `tree_ops` places the tab. |
| Spec side table (rename without tree churn) | **done** | Specs live in `Session.specs`, not in the split tree (`Session.swift:46-48`); `rust/slopdesk-tree/src/tree_ops.rs:890` (`updating_spec`) mutates the side table without touching the tree. Rename / title / video edits go through this seam. |
| Multi-session | **domain alive; the SWITCHER UI is removed** | `TreeWorkspace.sessions` + `activeSessionID` are intact, and `newSession` (op 18), `closeSession` (op 19), `renameSession` (op 3) are live intents applied at `rust/slopdesk-tree/src/tree_ops.rs:826-870`. What went on 2026-07-02 (`d1d4398b`) is the multi-session SWITCHER: `SessionSwitcherView`, both its navigator mounts, `SessionRowModel`, the `newSession` ⌃⌘N action + binding row + the whole `Category.sessions`, and `newSessionDefault()`. The domain stayed on purpose — "tabs live inside a Session; the internals remain for the agent control backend, session templates, close-window semantics, and persistence restore". |
| Floating panes | **REMOVED** 2026-07-03 (`231f1398`) | Deleted end-to-end: `Tab.floatingPanes`, `PaneSpec.floatingFrame`, `toggleFloating` / `spawnFloating` / `raiseFloating` / `moveFloating` / `resizeFloating`, the renderer, the chords, the palette/menu rows and every test. **No schema bump** — a stale `floatingPanes` key in an old file is a key `persist::decode_tab` does not read, and the ids it named are dropped as orphan specs by `normalizingSpecs()`; the tiled tree restores intact and floats are NOT re-tiled. The only surviving trace is that decode-ignore note at `Sources/SlopDeskWorkspaceModel/Domain/Tree/Tab.swift:18-20`. |
| Detached panes (own OS windows) | **done — NEW since the survey** | `Session.detached: [DetachedPane]`, in detach order, each keeping its spec in `specs` and its live registry handle (`Session.swift:10,49-54`). Additive field, written only when non-empty so a detach-free file stays byte-identical. Intents `detachPane` (15), `reattachPane` (16), `spawnDetachedPane` (25 — "the only intent that can write `pane/kind`", `WorkspaceIntent.swift:47-49`). Windows at `Sources/SlopDeskMacUI/App/SatellitePaneWindows.swift`. |
| Sync input (fan a keystroke across a tab) | **done — NEW since the survey** | `WorkspaceTopology.syncInputTabs: Set<TabID>` + intent `setSyncInput` (11). Hosted rather than client-local for a reason: "hosting only the armed bit while fanning client-side would mean client B's keystrokes silently do not fan" (`WorkspaceTopology.swift:20-24`). |
| Divider weights | **done** — single-writer | `setDividerWeight` (op 17) is "the ONLY writer of `splitNode/weight`" (`WorkspaceIntent.swift:32-33`). A drag FRAME is a local overlay layered onto the projection, never an intent (`WorkspaceStore.swift:61-67`) — so a 60 fps drag does not become 60 wire messages, and the committed value is one. |
| Session templates (spawn named layout) | **done** — built-ins moved to Rust | `SessionTemplate` + `SessionTemplateEngine` + `WorkspaceStore+Templates.swift`. The three built-ins are no longer a Swift literal list checked against a Rust one by a differential test — they come from the crate via `SessionTemplateCrossing.builtInTemplatesFromTheCrate()` (`Sources/SlopDeskWorkspaceModel/Domain/SessionTemplate.swift:199-221`). Capture still captures geometry only. They persist in `DevicePreferences.sessionTemplates`, not in the tree. |
| Launch presets (open one tab) | **done** — moved to device-local | `LaunchPreset` now lives on `DevicePreferences.launchPresets` (`Sources/SlopDeskWorkspaceCore/Workspace/Store/DevicePreferences.swift:44`), not on `TreeWorkspace` — the tree describes THE LAYOUT, which every attached client shares, and a preset library describes one machine (docs/45 §7.3, `TreeWorkspace.swift:6-9`). CRUD at `WorkspaceStore.swift:1801-1821`; `applyLaunchPreset` opens a tab with optional split + deferred command. |
| Zoom (out-of-tree) | **done** | `Tab.zoomedPane` (render-only; siblings stay mounted at `opacity 0`, `Tab.swift:11-13`), `setZoom` intent 14, `WorkspaceStore.toggleZoomTree()` (`:1462`). |
| Break-pane-to-tab | **done** | `breakPaneToTab` intent 21 (⌃⌘T), `rust/slopdesk-tree/src/tree_ops.rs:1057`, staged at `WorkspaceStore.swift:1746`. |
| Balance / select-layout | **done** — one intent for all three | `applyLayout` (`:1977`), `cycleLayout` (`:1989`) and balance (`:1984`) all compute the new shape with the pure Swift `WorkspaceTreeOps` statics and then send ONE `setTabLayout` intent (24): "one op for every re-tile — apply a preset, cycle to the next one, and balance the splits are all *this tab now has this shape*" (`WorkspaceIntent.swift:43-45`). Five presets at `WorkspaceTreeOps.swift:205`. |
| Swap / dock-at-edge | **done — NEW since the survey** | `swapPanes` (22) backs both drag-onto-pane and the directional move; the client resolves the geometric neighbour against the layout IT is looking at and sends the resolved pair, "so the host never needs a viewport". `dockPaneAtTabEdge` (23) wraps the whole tab root — no `(source, target, axis, before)` triple can express it. `WorkspaceIntent.swift:37-42`. |
| Busy-shell close guard | **done** | `requestClosePaneTree(_:)` (`WorkspaceStore.swift:691`) → `CloseConfirmationPolicy` over `PaneSessionHandle.isShellBusy`; parked state + confirm/cancel at `WorkspaceStore+CloseConfirmation.swift:16-110`, with a policy line and a project name for the sheet. |
| Autotype target marking | **done** | `reconcileTree` marks `isAutotypeTarget` on the first DFS leaf. `WorkspaceStore.swift:2386` |
| Focus coordinator sync | **done** | `reconcileTree` calls `focusCoordinator.focus(focused)` to sync the first-responder arbiter. `WorkspaceStore.swift:2388-2389`, coordinator at `:477` |
| Debounced save | **done** | `saveDebounce: Duration` (default 600 ms, `WorkspaceStore.swift:382,519`); `scheduleSave()` (`:2874`) cancels + rearms behind a monotonic save-generation guard (`:407`); the facts sidecar has its OWN debounce rather than riding this one (`:2925-2932`). |
| Sidebar grouping + sort | **REMOVED by re-scope** 2026-07-10 | The sidebar has exactly ONE layout: panes bucket by their By-Project key, sections sort A→Z on their header, rows within a section follow first-appearance in `session.tabs`. No hamburger, no `.byDate` buckets, no `.updated` recency sort. The absence is asserted in code, twice: `Sources/SlopDeskWorkspaceModel/Domain/Tree/TabOrdering.swift:6-9` and `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+TabOrdering.swift:7-13`. The key is HOST-pushed (wire type 34) so every reconnect converges on the same sections. |
| Manual tab drag-reorder | **REMOVED by re-scope** 2026-07-10 | Same ruling, same two assertions. The `reorderTabs` intent (op 8) and its `[16B session][u16 n][16B tab]*` payload remain on the wire (`WorkspaceIntent.swift:23,156`), and `Sources/slopdesk-corevectors/main.swift:1809` still pins its golden vector — but **no Swift caller stages it**. A reserved wire capability with no client gesture, not a live feature. |
| `PaneKind` | **narrowed by ruling** | Exactly two cases: `.terminal` and `.desktop` (`Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift:38-45`). `remoteGUI` went 2026-07-22 (`docs/DECISIONS.md` ~line 1512); `claudeCode`, `web`, `chooser` and `systemDialog` went with their features. All five are named as RETIRED raw values that fold to `.terminal` through the decode bridge (`PaneSpec.swift:50`, `rust/slopdesk-tree/src/session.rs:56`, `rust/slopdesk-ffi/src/pane_kind.rs:8`). |
| Device-local vs. shared state | **done — NEW split since the survey** | `DevicePreferences` holds what describes ONE machine: `launchPresets`, `sessionTemplates`, `videoModesByTarget`, `connectionByHostKey`, `followSessionFocus` (`DevicePreferences.swift:44-59`), bounded by a `maxItems` cap on decode (`:133-134`). The tree holds only what every attached client shares. That split is what schema 12 exists for, and it is why a file from an older shape resets aside rather than loading "successfully" and losing the user's presets on the next autosave (`TreeWorkspace.swift:43-55`). |

---

## Key files

**The value model** (`Sources/SlopDeskWorkspaceModel/` — moved out of `SlopDeskWorkspaceCore` so
`SlopDeskHost` can import it):

- `Domain/Tree/TreeWorkspace.swift` — top-level value; invariant; `defaultWorkspace()`; the asked-for schema version
- `Domain/Tree/Session.swift` — `Session` (tabs + specs side table + `detached`) and `DetachedPane`
- `Domain/Tree/Tab.swift` — split tree + out-of-tree zoom (and the `floatingPanes` decode-ignore note)
- `Domain/Tree/{SplitNode,SplitNode+Ops,SplitLayoutSolver}.swift` — the n-ary tree and its geometry solve
- `Domain/Tree/WorkspaceTreeOps.swift` — the pure GEOMETRY + FOCUS statics that are left in Swift
- `Domain/Tree/{NewTabPosition,TabOrdering,TreeIdentity}.swift` — placement, By-Project bucketing, id minting
- `Domain/{PaneSpec,SessionTemplate,LaunchPreset,ConnectionTarget,FocusResolver}.swift`
- `State/{WorkspaceIntent,WorkspaceIntentApplier,WorkspaceTopology,PaneLiveness,WorkspaceFields,HostWorkspaceState}.swift`
- `Codec/{WorkspaceFile,WorkspaceStateCodec,WorkspaceStateFile}.swift` — boundaries over the Rust codec, not implementations

**The store** (`Sources/SlopDeskWorkspaceCore/Workspace/`):

- `Store/WorkspaceStore.swift` — the projection, the registry, reconcile, the tree-mutation stagers (~3,780 lines)
- `Store/WorkspaceStore+Intents.swift` — `stage(_:_:)`, the one funnel every mutation crosses
- `Store/WorkspaceStore+{PaneCycle,CloseConfirmation,Templates,TabOrdering,ReadOnly,Progress,Attention,Completion,Drop,Desktop,Lifecycle,Bootstrap}.swift`
- `Store/WorkspacePersistence.swift` — IO only: the URL, the atomic write, the `.corrupt` and `.previous` sidecars
- `Store/DevicePreferences.swift` — the device-local half (presets, templates, video modes, connection targets)
- `Store/LivePaneSession.swift`, `Store/PaneSessionHandle.swift` — the production handle and its protocol
- `Sync/{HostWorkspaceMirror,WorkspaceChannelClient,WorkspaceMirrorBox,LoopbackWorkspaceDocument}.swift` — the replica and its transport
- `Domain/{WorkingDirectoryPolicy,CloseConfirmationPolicy,SessionTemplateEngine}.swift`

**The Rust half:**

- `rust/slopdesk-tree/src/tree_ops.rs` — **every structural mutation**
- `rust/slopdesk-tree/src/{workspace,session,split_tree,tab_ordering,focus,geometry,split_layout}.rs`
- `rust/slopdesk-wire/src/document/apply.rs` — the intent applier both ends run
- `rust/slopdesk-workspace/src/persist.rs` — the `workspace.json` codec, version check, pane cap, repair pass
- `rust/slopdesk-workspace/src/{workdir,templates,rail_list,rail_title,state_codec,frecency}.rs`
- `rust/slopdesk-ids/` — identity, JSON, shell quoting (leaf, no deps)

**Deleted, and named here so nothing looks merely misplaced:**
`Canvas*.swift`, `PaneGroup.swift`, `Workspace.swift`, `CompactLayoutResolver.swift`,
`CommandInterpreter.swift`, `WorkspaceSchemaMigration.swift`, `SessionSwitcherView.swift`,
`SessionRowModel.swift`, `SplitNode+Codable.swift`, `InPaneChooserView.swift`.

---

## Notes — wiring gaps, dead seams, traps

### 1. The four gaps the original survey found are all CLOSED

Each was a real gap on 2026-06-25 and each has since been implemented, not re-scoped away:

| Survey gap | Closed by |
| --- | --- |
| Reopen-last-closed is canvas-only | A host-side ring in the document + intent op 20 (`WorkspaceStore+PaneCycle.swift:30-55`) |
| No cwd inheritance for interactive new-tab / split | `WorkingDirectoryPolicy` + `seedNewPaneFacts` (`WorkspaceStore.swift:1509-1538`) |
| OSC 7 not wired into cwd at all | Sniffed in superd, pushed as wire types 33/34, held in the document |
| New-tab position always appends | `NewTabPosition` + `slopdesk_ws_new_tab_index` (`NewTabPosition.swift:23-58`) |

The fifth — "dual-model coexistence is a trap" — is closed by deletion rather than by fixing.

### 2. `reorderTabs` is a wire op with no client gesture

Op 8 is defined, has an argument encoding, has a golden vector, and is applied by
`rust/slopdesk-wire/src/document/apply.rs:118`. Nothing in `Sources/` stages it, because manual tab
drag-reorder was removed by the 2026-07-10 re-scope. This is the shape a doc audit should flag rather
than assume: an op that decodes cleanly and is reachable by no user action. It is reserved, not dead —
the agent control backend can send one — but no UI produces it.

### 3. The document is the single writer; the store's local overlays are the exception, and they are named

Two things are read on top of host truth without being intents, and both are deliberate:

- **This device's focus** (`WorkspaceStore.swift:56-60`) — docs/45 §8.2, so a phone can look at one tab
  while the Studio works in another.
- **The live divider-drag weight** (`:61-67`) — a drag frame is a preview; only the committed value is
  an intent.

Anything else layered onto the projection would be the divergence the document exists to end. Both
overlays bump `workspaceMirrorRevision` themselves, because the memo key must over-invalidate rather
than under-invalidate — "one that under-invalidates would freeze the layout" (`:88-93`).

### 4. The `fastPath` layer is a hazard with a written-down discipline

The pane channel and the workspace channel are two independent producers of the same fact, and the
per-pane control queue is newest-shed at 1024 — lossy AND unordered relative to the document. So a
fast-path write is read only where `entries` has nothing, and is ERASED the moment a snapshot or diff
supplies the same key (`HostWorkspaceMirror.swift:14-23`). Letting a fast-path value survive a document
value "would freeze that disagreement forever, which is precisely the bug class this document exists to
end, reintroduced as an optimisation."

### 5. `TreeWorkspace` still carries its transitional name, and one stale doc line

The type comment at `TreeWorkspace.swift:14-19` still explains the name as a W2 additive-coexistence
measure whose cutover would promote it to `Workspace` — but the canvas `Workspace` was deleted on
2026-08-17, so the name has been free for the taking since. The same comment block says "10 = this
shape" at `:27` while `:43-55` correctly describes 12. Cosmetic, in code, and reported rather than
fixed here (this audit does not edit `Sources/`).

`rust/slopdesk-workspace` has the mirror-image problem, and it is already booked: "the residual crate
no longer contains `workspace.rs` — `slopdesk-workspace` is now the client's remaining *surfaces*, not
the document, and the name says otherwise. Renaming it touches 34 `slopdesk-ffi` files — mechanical,
and deferred rather than declined" (`docs/DECISIONS.md`, 2026-08-22).

### 6. `apply.rs` is a domain applier living in the wire crate

The residual `wire → tree` edge is deliberate and documented: `apply.rs` is 2,076 lines and *is* a
domain applier, but moving it into the domain crate changes public paths that `slopdesk-ffi` and
`slopdesk-superd` name. "A protocol depending on the model it serialises is not an inversion. A
protocol depending on the settings catalogue is" (`docs/DECISIONS.md`, 2026-08-22). Read it as a known
residual with a stated line, not as an accident.

### 7. Persistence restores SHAPE and INTENT only

Unchanged since the survey and worth restating because the surrounding architecture moved: the file
never carries live connections, byte buffers or session ids. On launch the store decodes the tree and
starts the registry EMPTY; reconcile materializes **idle** sessions; the view connects lazily on
appear. A relaunch is a fresh session (`WorkspacePersistence.swift:16-19`). What changed is that the
pane's resume identity is now just its `PaneID`, so there are no resume fields to restore.
