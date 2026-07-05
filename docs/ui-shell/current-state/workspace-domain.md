# Workspace Domain — Current State

Assessed: 2026-06-25  
Source truth: `Sources/SlopDeskWorkspaceCore/`

---

## Overview

The workspace domain has a **dual-model** in transition:

- **Canvas model** (`Workspace` / `Canvas`) — the original infinite-canvas value, still the live path in the shipped app (`WorkspaceStore.liveModel == .canvas`).
- **Tree model** (`TreeWorkspace` / `Session` / `Tab` / `SplitNode`) — the `Session → Tab → Pane` redesign (docs/42), promoted to live in the W5 cutover. `WorkspaceStore.liveModel == .tree` drives the IDE shell and all tree-path unit tests; it is the **current live model in the UI-shell build**.

All assessments below focus on the **tree path** (the shipping UI-shell target) unless noted.

---

## Capability matrix

| Feature | Status | Evidence |
|---|---|---|
| Session/Tab/Pane tree data model | **done** | `Session.swift`, `Tab.swift`, `TreeWorkspace.swift` — full `Session → Tab → SplitNode → PaneID` value hierarchy; pure `Codable`/`Equatable`/`Sendable`; specs == leafIDs invariant; floating-pane layer reserved |
| Pure ops (`WorkspaceTreeOps`) | **done** | `WorkspaceTreeOps.swift` — split, close (with cascade), zoom toggle, resize, swap, move, dock, focus (directional + cycle), tab open/close/rename/select, session open/close/rename/select, break-pane-to-tab, floating spawn/move/resize/embed/raise, tmux select-layout (5 presets + cycle), balance-splits |
| Reconcile / registry | **done** | `WorkspaceStore.reconcileTree()` (`:2974`) diffs `tree.allPaneIDs()` against the `[PaneID: any PaneSessionHandle]` registry; shared `reconcileRegistry` helper carries orphan-remove-then-async-teardown, video-cap ceiling, per-pane cache pruning; live wiring (pane rebind, OSC-9, agent signal, command-completion, title/cwd/resume-identity callbacks) factored into `wireMaterializedLeaf` (`:2998`) |
| Layout save-restore (⌘S / named presets) | **partial** | `saveLayoutPreset(name:triggerAppName:)` (`:1910`) saves canvas snapshots into `WorkspacePersistence`; `CommandInterpreter.saveLayout` (`:36`) routes ⌘S. **Canvas path only** — no equivalent tree path method (`SessionTemplate` captures session geometry for template spawning, but not mid-session named saves from the tree shell). App-launch-triggered preset switching exists on canvas only. |
| Reopen-last-closed (⇧⌘T) | **partial** | `recentlyClosed: RecentlyClosedPane?` single-slot (`:563`) + `reopenClosedPane()` (`:635`) — **canvas path only**: the store records the canvas item + frame on `closePane(_:)`, restores it via `Canvas.restoring`. On the tree path `closePaneTree` does NOT populate `recentlyClosed`, so ⇧⌘T is a no-op after a tree-path close. `CommandInterpreter.reopenClosedPane` chord `⇧⌘T` (`:18`, `:254`) routes to `store.reopenClosedPane()` which internally calls `workspace.canvas.restoring(...)` — dead on tree. |
| Session recovery / persistence (relaunch) | **done** | `WorkspacePersistence.loadTree()` (`:159`) peeks schema version, decodes `TreeWorkspace`, runs `normalized()`, promotes `lastKnownTitle`; `save(_ tree:)` writes atomically sorted-key JSON to `Application Support/SlopDesk/workspace.json`. Corrupt file → `.corrupt` sidecar + default. Resume-identity fields `resumeSessionID` / `resumeLastReceivedSeq` (in `PaneSpec`) allow reattach to a running host PTY session across relaunch when `SLOPDESK_DETACH_ENABLED` (wired in `LivePaneSession` at `:269`; `onResumeIdentitySnapshot` snapshotted ~3 s cadence and on reconnect). Schema migrations: v10→v11 identity re-decode; v5–v9 canvas migration DELETED (no-backcompat directive). |
| Working-directory inheritance for new pane/tab | **partial** | `PaneSpec.lastKnownCwd` field (`PaneSpec.swift:156`) is stored + persisted + displayed (palette subtitle, titlebar menu, inspector column, sidebar row). It is **written by the file explorer / agent footer** (`AgentInputFooterCoordinator.updateCwd` at `Footer/AgentInputFooterCoordinator.swift:68`) but **not by OSC 7** (no wire-level OSC-7 parser pipes into `lastKnownCwd`; the spec doc notes OSC 7 as the host-side mechanism). Critically, `newTab(kind:)` and `splitActivePane` never read `lastKnownCwd` of the active pane to pre-populate the new pane's cwd — the new pane always starts with `nil` cwd and the shell default. No `inheritCwd` logic exists anywhere. `SessionTemplate` per-pane `cwd` field (`SessionTemplate.swift:52`) allows templates to specify a working directory, sent as a literal `cd` after PTY comes up. |
| New-tab position | **missing** | `WorkspaceTreeOps.newTab` always `tabs.append(tab)` (`WorkspaceTreeOps.swift:587`). There is no "insert after active tab" or configurable `newTabPosition` option. Same for `breakPaneToTab` (`WorkspaceTreeOps.swift:721`). |
| Spec side table (rename without tree churn) | **done** | Specs live in `Session.specs: [PaneID: PaneSpec]`, not in the split tree. `WorkspaceTreeOps.updatingSpec` mutates the side table without touching the tree. Rename/title/video edits all go through this seam. |
| Multi-session | **done** | `TreeWorkspace.sessions: [Session]` + `activeSessionID`; `newSession`, `closeSession`, `selectSession`, `renameSession` all implemented in `WorkspaceTreeOps` + wired in `WorkspaceStore`. |
| Floating panes | **done** | `Tab.floatingPanes: [PaneID]` (schema-reserved, MVP = `[]` for saved files); full ops: `toggleFloating`, `spawnFloating`, `raiseFloating`, `moveFloating`, `resizeFloating` in `WorkspaceTreeOps`. Floating frame persisted in `PaneSpec.floatingFrame`. |
| Session templates (spawn named layout) | **done** | `SessionTemplate` + `SessionTemplateEngine` + `WorkspaceStore+Templates.swift` — expand template → `Session`, insert, reconcile, defer `cd`/command bytes 1.4 s after PTY up. Capture (`saveCurrentSessionAsTemplate`) captures geometry only (no runtime cwd/command). Three built-in templates (Editor+Terminal, Editor·Server·Git, Claude+Terminal). |
| Launch presets (open one tab) | **done** | `LaunchPreset` persisted on `TreeWorkspace`; `applyLaunchPreset` opens a new tab with optional split + deferred command. CRUD + palette/settings fully wired. |
| Zoom (out-of-tree) | **done** | `Tab.zoomedPane`; `WorkspaceTreeOps.toggleZoom`; `WorkspaceStore.toggleZoomTree`. |
| Break-pane-to-tab | **done** | `WorkspaceTreeOps.breakPaneToTab` (`WorkspaceTreeOps.swift:705`); `WorkspaceStore.breakPaneToTab`. |
| Balance / select-layout | **done** | `WorkspaceTreeOps.balanceSplits`, `applyLayout` (5 presets), `cycleLayout`. |
| Busy-shell close guard | **done** | `requestClosePaneTree` checks `isShellBusy`; `pendingClose` + `confirmPendingClose`/`cancelPendingClose`. |
| Autotype target marking | **done** | `reconcileTree` marks `isAutotypeTarget` on the first DFS leaf (`:2985–2987`). |
| Focus coordinator sync | **done** | `reconcileTree` calls `focusCoordinator.focus(focused)` to keep the iPad first-responder arbiter in sync (`:2989–2991`). |
| Debounced save | **done** | `saveDebounce: Duration` (default 600 ms); `scheduleSave()` cancels + rearms a task; `persistence.save(tree)` writes atomically. |

---

## Key files

- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/TreeWorkspace.swift` — top-level tree value; invariant; normalizing repairs; `defaultWorkspace()`
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/Session.swift` — `Session` value (tabs + specs side table); deterministic `Codable`
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/Tab.swift` — `Tab` (split tree + zoom + floating layer)
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/WorkspaceTreeOps.swift` — all pure tree operations (split, close, zoom, resize, layout, focus, sessions, tabs, floating)
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift` — store: `reconcile()` / `reconcileTree()`, tree-mutation methods, `recentlyClosed`, `saveLayoutPreset`, `sidebarCollapsed`, `newTab`, `newSession`, etc.
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift` — `load()` / `loadTree()` / `save()` / `save(_ tree:)` / schema-version peek
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceSchemaMigration.swift` — version gate; `migrateToTree`
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/LivePaneSession.swift` — production handle; lazy connect; resume-identity wiring
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSpec.swift` — per-pane spec: `lastKnownCwd`, `lastKnownTitle`, `resumeSessionID`, `resumeLastReceivedSeq`, `floatingFrame`
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Templates.swift` — session-template spawn + capture
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplate.swift` — `SessionTemplate` / `TemplatePane` / `TemplateNode`; three built-in templates
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/CommandInterpreter.swift` — command enum; chord-to-command mapping including `reopenClosedPane` / `saveLayout`

---

## Notes — wiring gaps, dead seams, traps

### 1. Reopen-last-closed is canvas-only (dead on tree path)
`recentlyClosed` is set only in `closePane(_:)` (canvas `Canvas.removing`). `closePaneTree(_:)` never touches it. The ⇧⌘T command routes to `reopenClosedPane()` which internally calls `workspace.canvas.restoring(...)`. On a tree-model store this silently no-ops. **Gap: a tree-path reopen-last-closed stack needs its own implementation.**

### 2. Named layout presets (⌘S) are canvas-only
`saveLayoutPreset(name:triggerAppName:)` snapshots `workspace.canvas`. On the tree path the concept is covered by `SessionTemplate` (capture) but that is a different abstraction: a template spawns a new session, it does not restore the current session's geometry by name. **Gap: the spec'd ⌘S "save layout" for the tree shell is not implemented.**

### 3. Working-directory inheritance for new pane/tab is missing
`newTab(kind:)` and `splitActivePane(axis:kind:)` both create a `PaneSpec` with `lastKnownCwd: nil` and `command: nil`. They never read the focused pane's `lastKnownCwd`. The `SessionTemplate` per-pane `cwd` field provides cwd-at-spawn for template-launched panes only. OSC 7 from the host is not wired into `lastKnownCwd` updates at all (only the file-explorer footer `AgentInputFooterCoordinator.updateCwd` updates the in-memory coordinator cwd, but this does not flow back into `PaneSpec.lastKnownCwd`). **Gap: no cwd inheritance for interactive new-tab / split.**

### 4. New-tab position always appends
`WorkspaceTreeOps.newTab` calls `tabs.append(tab)` unconditionally. There is no `insertAfterActive` or configurable `newTabPosition` setting. **Missing: tab insertion position policy.**

### 5. Dual-model coexistence (canvas + tree live simultaneously)
`WorkspaceStore` holds both `workspace: Workspace` (canvas) and `tree: TreeWorkspace`. Both are persisted from the same `workspace.json` file (schema version determines which decoder wins). The `liveModel` flag (`LiveModel.canvas` vs `.tree`) gates which reconcile loop runs. Store extensions that touch only one side silently no-op on the other (the `recentlyClosed` / `saveLayoutPreset` canvas-only gap above are symptoms of this). The canvas side will be retired at the W5 cutover, but until then cross-path interactions are a trap.

### 6. Session recovery detail
`lastKnownCwd` is **not** persisted back to `PaneSpec` from live OSC 7 events (the field exists in the schema but has no write path from the terminal VM / wire). `lastKnownTitle` IS wired (`onTitleChanged` → `updateSpecLive` at `:3038`) and promoted on load. Resume-identity fields are wired and tested.
