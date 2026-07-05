# 41 — Coding-Workspace Redesign: Research Dossier

> Status: research + recommended architecture. Binding decisions land in `DECISIONS.md` after ratification.
> Scope: (1) IDE-focused chrome, (2) retire the infinite canvas for a tmux/Muxy-style Session→Tab→Pane hierarchy, (3) Claude Code via auto-detection + hooks (kill the dedicated pane kind), (4) a complete GUI settings interface, (5) terminal parity with Ghostty/Muxy/Warp.

---

## 0. Executive Summary

**What changes.** Replace the free-floating infinite `Canvas` with a tiled **Session → Tab → Pane** tree; swap the generic `NavigationSplitView` chrome for an IDE shell (sessions sidebar + tab bar + split-pane detail + hidden/minimal title bar); make Claude Code a **runtime-detected status on an ordinary terminal pane** instead of a stored `PaneKind`; surface the ~80 `SLOPDESK_*` env flags through real GUI settings.

**Why.** The infinite canvas (drag/snap/non-overlap/camera) is the wrong primitive — every competitor (tmux, Zellij, WezTerm, Muxy, Herdr, Warp) converged on a recursive split tree under named sessions/tabs because it is keyboard-drivable, deterministic, and trivially serializable. A dedicated "Claude Code pane kind" forces the user to pre-declare intent; Muxy/Herdr/Warp instead detect a running `claude` and surface status. Env-only config blocks non-developers and makes the product undemoable.

**Preserved (do not touch).** The transport/liveness layer is layout-agnostic and stays verbatim: `PaneID`/`PaneSpec` identity types, `PaneSessionHandle`/`LivePaneSession` registry, `PaneLeafView` kind switch, all `Connection/Terminal/Video/Input/Inspector/iOS` subdirectories, the mux/wire protocol, the golden corpus. `WorkspaceStore`'s **intent-tree → reconcile() → registry** pattern is kept; only the intent tree's *shape* changes from a flat `[CanvasItem]` to a `Session→Tab→SplitNode` tree.

**Order (detail in §3.8).** Domain model + persistence/migration → store mutations + reconcile over the new tree → split-pane render + IDE chrome → tab/split keybindings + command palette → Claude Code auto-detection → GUI settings → terminal parity backlog. Each layer ships green and atomic.

---

## 1. Current State (condensed; file:line pointers retained)

### 1.1 Shell / scene
- Entry: `Apps/Shared/AppMain.swift:26` (`ClientAppMain`, `@main`) → `SlopDeskClientApp.main()`.
- App: `Sources/SlopDeskClientUI/SlopDeskClientApp.swift:31`; `body` = one `WindowGroup { WorkspaceRootView }` + `.commands { WorkspaceCommands() }` + `.windowResizability(.contentSize)` + `Settings { SettingsView() }` (`SlopDeskClientApp.swift:197`).
- **No window styling today**: zero `windowStyle(.hiddenTitleBar)`, no transparent titlebar, no `NSWindowDelegate`. Stock title bar + traffic lights. Min size `720×480` on the root view (`WorkspaceRootView.swift:85`).
- Root: `WorkspaceRootView.swift:24` = `NavigationSplitView` (sidebar `min:200 ideal:240 max:360`, `WorkspaceRootView.swift:74`); detail branches on `WorkspaceLayout.isCompact(...)` (`WorkspaceLayout.swift:70`) → `PaneCarouselView` (phone) else `CanvasView`. The ONLY responsive branch.
- `detailToolbar` (`WorkspaceRootView.swift:255`): connection-status menu (`.navigation`) + "New Pane" split button (`.primaryAction`). Overlays: `ConnectionGateView`, `CommandPaletteView` (⌘K), `KeyboardCheatSheetView` (⌘/).
- iOS: same `App` struct, `#if os(iOS)` blocks; compact → `PaneCarouselView` (paged `TabView`, `PaneCarouselView.swift:24`); scene-phase drives `pauseAll()`/`resumeAll()`. iOS rots silently — run `bash scripts/check-ios.sh` after UIKit edits.

### 1.2 Domain model (the intent tree)
- `Workspace` (`Workspace.swift:21`) — single persisted `Codable` value: `schemaVersion` (9), `canvas: Canvas`, `focusedPane`, `maximizedPane`, `groups: [PaneGroup]`, `connection: ConnectionTarget?`, `bookmarks`, `layoutPresets`, `snippets`.
- `Canvas` (`Canvas.swift:83`) — infinite plane: `items: [CanvasItem]` (array order ≠ z-order) + `camera: CanvasCamera` (`Canvas.swift:15`, pan-only, **no zoom field by design** — a scale transform breaks libghostty 1:1 mouse mapping).
- `CanvasItem` (`Canvas.swift:40`): `id: PaneID`, `spec: PaneSpec`, `frame: CGRect` (on-screen pane size), `z: Int`, `groupID: PaneGroupID?`.
- `PaneSpec` (`PaneSpec.swift:99`): `kind: PaneKind`, `title`, `video: VideoEndpoint?`. `PaneKind` (`PaneSpec.swift:42`): `.terminal` / `.claudeCode` / `.remoteGUI` / `.systemDialog` (raw-String Codable).
- `PaneID`/`PaneGroupID` (`PaneSpec.swift:15,29`): `struct { let raw: UUID }`. `PaneID` is the registry join key — **reuse verbatim**.
- Layout solvers (all become dead code in a tiled model): `CanvasSnap.swift`, `CanvasNonOverlap.swift:31`, `CanvasGeometry.swift`, `Canvas+Ops.swift`, `SolvedLayout.swift`, `FocusResolver.swift` (geometric neighbor detection — **keep**, still relevant for split focus).

### 1.3 Store (source of truth)
- `WorkspaceStore` (`WorkspaceStore.swift:31`) — `@MainActor @Observable final class`. Owns `workspace: Workspace` (intent) + `registry: [PaneID: any PaneSessionHandle]` (liveness). Every mutation = (1) pure op → new `Workspace`, (2) `reconcile()`.
- `reconcile()` (`WorkspaceStore.swift:2127`) diffs `canvas.allIDs()` vs `registry.keys`; new IDs → `makeSession(spec)` → `LivePaneSession.make(...)`; orphans torn down async. **Pattern preserved; only `allIDs()`'s source changes.**
- Transient (NOT persisted): `liveCameraOffset`, `videoPromotionGeneration`, `pendingRename`, `pendingClose`, `focusHistory` (MRU, `WorkspaceStore.swift:580`), `selectedPanes`, `broadcastActive`, `overviewActive`, `lastSolvedLayout`, `lastViewport`, `recentlyClosed`.

### 1.4 Persistence
- File: `<AppSupport>/SlopDesk/workspace.json` (`WorkspacePersistence.swift:41`); pretty-printed sorted-keys JSON, atomic, debounced 600ms.
- Schema: `currentSchemaVersion = 9` (`Workspace.swift:141`). Migration `WorkspaceSchemaMigration.migrate` (`WorkspaceSchemaMigration.swift:21`) is **forward-only, no field upgrades** — a version mismatch returns `nil` → `defaultWorkspace()` (file moved aside as `workspace.json.corrupt`). Single-user, no backward-compat.
- Hosts: `Workspace.connection` (last host, in workspace.json) + `AppConnection.recentTargets` (5-entry MRU in `UserDefaults` key `connection.recentTargets`, `AppConnection.swift:70`). Only ONE host connected at a time (`AppConnection`, `AppConnection.swift:18`).
- Portable export: `WorkspaceTransfer.swift:17` (`Document` envelope, `format: "slopdesk.workspace"`, `formatVersion: 1`).

### 1.5 Terminal stack (transport — layout-agnostic, preserved)
- Renderer behind `TerminalSurface` seam (`TerminalSurface.swift:21`); prod conformer `GhosttySurface` (`GhosttySurface.swift:138`, Xcode-only, not in SwiftPM graph). Injected via `TerminalRendererFactory.shared` (`TerminalRenderingView.swift:83`); `nil` → `BuildStatusPlaceholderView`.
- Keystroke path: `GhosttyLayerBackedView.keyDown` (`GhosttyTerminalView.swift:674`) → `ghostty_surface_key` → `onWrite` → `TerminalViewModel.sendInput` (`TerminalViewModel.swift:214`) → `SlopDeskClient.sendInput` → `MuxClientTransport.sendInput` (`MuxClientTransport.swift:82`, `WireMessage.input` type 3 on DATA sub-channel).
- Output path: `PTYReadLoop.runLoop` (`PTYReadLoop.swift:94`, 32 KiB blocking read) → `HostOutputSniffer.observe` (`HostOutputSniffer.swift:47`, OSC 0/2/9/133/777 + BEL) → `WireMessage.output` (type 1) + `ReplayBuffer` → client `outputInbox` → `TerminalViewModel.ingestBatch` (`TerminalViewModel.swift:407`) → `GhosttySurface.feedBatch` (`GhosttySurface.swift:387`, off-main `SerialFeedGate`).
- Mux: two physical `NWConnection`s (DATA + CONTROL) per host, SSH-style channels (`MuxRoutingCore.swift:21`); flow control credit-at-consumption (`MuxFlowControl`); `ReplayBuffer` 64 MiB / 4 MiB offline gate (`ReplayBuffer.swift:58`).
- Wire: `[UInt32 BE len][UInt8 type][body]`, big-endian, manual binary, never JSON on hot path. DATA types 1/2/3; CONTROL 10–14 (c→h) / 20–25 (h→c); next free h→c type byte = **26**. New types are golden-additive (surgical-merge `golden/golden_vectors.json`).

### 1.6 Claude Code today (explicit kind — being removed)
- `SlopDeskClaudeCode` module = client-side output analysis only: `TerminalModeTracker` (`TerminalModeTracker.swift:39`, DECSET 1049/47/1047 + OSC 133 → `.shellPrompt`/`.altScreen`), `InputBoxModel` (`InputBoxModel.swift:23`, A/B1 affordance + echo dedup), `InputDedupRing`. **No process detection, no IPC, no MCP, no OSC 777.**
- Host: `ClaudeCodeProfile` (`ClaudeCodeProfile.swift:30`) curated PTY launch (`["-lc","claude"]`, forced env `CLAUDE_CODE_ENTRYPOINT=remote_mobile`). `HostServer.LaunchMode` (`HostServer.swift:32`) is a **construction-time constant** (`--claude` flag, `HostdArguments.swift:76`) — whole daemon is shell OR claude, no per-pane switch.
- `.claudeCode` is created explicitly (⇧⌘N `CommandInterpreter.swift:208`, palette, pill picker) → `addPane(kind:.claudeCode)` → `ClaudeCodePaneView` (`PaneLeafView.swift:401`) = terminal + `InspectorPanel` on `port+1` (inspector wired but **no host daemon exists yet**).

### 1.7 Settings today
- Real UI: `SettingsScene.swift:75`, 3 `@AppStorage` tabs (Canvas / Notifications / Advanced), 9 keys in `SettingsKey` enum (`SettingsScene.swift:9`), fire-time readers allow live toggle.
- NOT in UI: all ~80 `SLOPDESK_*` flags (video/FEC/QP/pacer/capture/mux/terminal), read once at static-`let` init from `ProcessInfo.environment`. No live reload. Terminal font/theme/keys: deliberately not loaded (`GhosttyTerminalView.swift:139`); bridge = `ghostty_config_load_string` (`ghostty.h:1133`), blocked on grid-reflow → host PTY resize.

---

## 2. External Prior Art (concrete, stealable specifics)

### 2.1 Muxy (open-source SwiftUI + libghostty; the closest sibling)
- Hierarchy: `Project → Worktree → SplitNode tree → TabArea → Tab → Terminal`. Sidebar rows ARE projects (folder = identity); named **workspaces** are *filters* over the project list (`⌘⌥S` inline switcher). Each git **worktree** owns its own split/tab tree.
- Splits: arbitrarily nested binary tree. `⌘D` split right, `⌘⇧D` split down, `⌘⇧W` close pane, `⌘⌥←/→/↑/↓` focus, `⌘⌥↩` maximize (transient focus lens, layout preserved). Tabs drag between panes / drop on edge to split.
- **Tab/split state is in-memory only** between restarts; reproducible layouts = checked-in `.muxy/layouts/*.yaml`.
- **Claude Code = hook → Unix socket.** Bundled `muxy-claude-hook.sh` fires on `notification` ("Needs attention") and `stop` (extracts `last_assistant_message`, 200-char cap). Transport: `printf '%s|%s|%s|%s\n' type paneID title body | nc -U "$MUXY_SOCKET_PATH"`. Muxy exports `MUXY_SOCKET_PATH` + `MUXY_PANE_ID` into every pane env. **No passive process detection** — hook-only.
- CLI: `muxy split-right [cmd]` returns the new pane ID; `muxy send --pane $ID`, `muxy read-screen --pane $ID --lines 50`, `muxy send-keys`. A `muxy-cli` skill teaches agents the pattern.
- Settings: `⌘,`, top search bar, JSON tab for bulk edit, per-provider hook toggles, key-capture recorder, custom "Commands" (named shell cmd → new tab).

### 2.2 Herdr (Rust/Ratatui TUI; "tmux for agents")
- `Workspace → Tab → Pane` (real PTYs). Sidebar workspaces **roll up to most-urgent child agent state** (blocked > working > done > idle). Stable short IDs `w1`, `w1:t1`, `w1:p1`.
- Agent states: 🔴 blocked / 🟡 working / 🔵 done / 🟢 idle / unknown. Pane borders can show agent label.
- **Claude Code = hook reports session *identity* only** (`SessionStart` → `pane.report_agent_session` over Unix socket `~/.config/herdr/herdr.sock`). **State comes from "screen manifest detection"**: identify foreground process (`claude`), read the *bottom-buffer* snapshot (not scrolled viewport), evaluate TOML manifests (`src/detect/manifests/claude.toml`, AND/OR gates) against known approval/permission/spinner UI. Blocked is conservative (only on known approval UI; unknown → idle). `herdr agent explain <pane>` shows which rule matched. Session restore via `claude --resume <id>`.
- Navigator `prefix+g`: searchable workspace→tab→pane tree with state filters (`b`/`w`/`i`/`d`). `wait agent-status <pane> --status done` for agent-to-agent coordination.

### 2.3 Warp (the agentic-IDE bar)
- **Blocks** = command+output as a first-class addressable unit (jump, copy-output-only, filter-in-place, bookmark, share with context). **Sticky command header** pins the producing command when output overflows (cheap, high value).
- Hierarchy: `Window → Tab → Pane`. **Vertical Tabs** sidebar shows per-tab git branch / cwd / agent status / PR badge / diff stats. Session restore incl. agent run state (SQLite).
- **Agent toolbelt on auto-detection**: detecting Claude Code/Codex/etc. in a pane auto-activates rich multi-line input, diff-context attach, notification routing, "last seen by agent at" indicator, interactive code-review panel. **Notification Mailbox** + **Agent Management** panel = cross-tab view of all running agents.
- **Tab Configs** (TOML, `warp://tab_config/<name>`): reusable multi-pane layouts that auto-run commands on open; "Save as new config" from a live tab.
- Settings: `⌘,`, bidirectional TOML sync, in-settings search, keybinding conflict highlighting, agent profiles (per-dir permission scopes) + MCP management.

### 2.4 Ghostty / libghostty (our renderer; what the C API exposes)
- `ghostty_surface_binding_action(surface, "action_name", len)` = **universal lever** — fire any action by name string: `new_split:right`, `goto_split:left`, `toggle_split_zoom`, `new_tab`, `goto_tab:N`, `jump_to_prompt:-1`, `copy_to_clipboard`, `paste_from_clipboard`, `start_search`/`navigate_search`, `clear_screen`, `scroll_page_up`, etc.
- `ghostty_config_get(config, &out, "key", len)` reads any config value by string key at runtime; `ghostty_config_load_string` (`ghostty.h:1133`) injects font/theme/palette/keybind config. `ghostty_app_update_config` / `ghostty_surface_update_config` hot-reload; `ghostty_app_set_color_scheme` pushes light/dark.
- Config-only (not enumerable via C): the keybind table, most `macos-*`. **Splits/tabs at the Ghostty level are NOT used** — SlopDesk drives one surface per pane and does its own tiling at the SwiftUI layer; libghostty splits/tabs flow through `action_cb` which we don't host. We keep our own split tree.
- Terminal features libghostty owns (already working): VT/Unicode, scrollback, selection/copy, bracketed paste, mouse modes, cursor styles, OSC 8 (internal), OSC 52, Kitty graphics (build-gated). Gaps in OUR embedding: font/theme/keybind config (no load-string call), scrollback search (no exposed API), OSC 8 click-to-open (sniffer skips it).

### 2.5 tmux / Zellij / WezTerm (split-tree + persistence canon)
- Vocabulary → canonical: tmux `Session/Window/Pane` = Zellij `Session/Tab/Pane` = WezTerm `Workspace+Window/Tab/Pane` → **`Session / Tab / Pane`**.
- Tree shape: tmux = binary (compact layout string, do NOT parse), WezTerm = strict binary (`PaneNode` enum, `mux/src/tab.rs:2103`), **Zellij = n-ary** (`TiledPaneLayout { children_split_direction, children: Vec<...>, split_size: Percent|Fixed }`, `layout.rs:847`) + parallel `Vec<FloatingPaneLayout>` (absolute x/y/w/h) + stacked panes. **N-ary wins** — closing child N redistributes weights equally instead of the WezTerm "sibling eats all freed space".
- Zoom is **out-of-tree state** everywhere (WezTerm `TabInner.zoomed`, tmux `resize-pane -Z`) — store a `zoomedPaneID` on the Tab, render-only, tree untouched.
- Persistence: tmux-resurrect = TSV (session/window/pane/cwd/last-command + layout string; no scrollback). Zellij = native KDL layout serialization, attach-by-name. WezTerm = none built-in (Lua startup scripts). **Declarative layout presets** (Zellij KDL `tab_template`/`pane_template`/`swap_tiled_layouts`, Warp TOML) are the model for our workspace presets.
- Keyboard: tmux = prefix-chord (`Ctrl+b` then key); Zellij = modal modes (Pane/Tab/Resize/...); WezTerm = direct modifier chords. macOS convention → **direct chords** (`⌘D`/`⌘⇧D` splits, `⌘⌥arrows` focus, `⌘⌥↩` zoom, `⌘T` tab).

### 2.6 Claude Code hooks (the detection substrate)
- Events: once/session `SessionStart` (matcher `startup`/`resume`/`clear`/`compact`), `SessionEnd`; once/turn `UserPromptSubmit`, `Stop`, `StopFailure`; per-tool `PreToolUse`/`PostToolUse`; async `Notification` (matcher `permission_prompt`/`auth_success`/`elicitation_complete`).
- Handler types: `command` (JSON on stdin, exit 2 = block), `http` (POST JSON), `mcp_tool`, `prompt`. Config in `~/.claude/settings.json` or `.claude/settings.json`.
- Stdin shape: `{ session_id, hook_event_name, cwd, permission_mode, transcript_path }` (+ `tool_name`/`tool_input` for tool events).
- Detection without hooks: OSC 2 title `Claude: <name>`; process name `claude` (`pgrep -af '^claude'`, cwd via `lsof`); transcript JSONL at `~/.claude/projects/<slug>/<session-id>.jsonl` (last line type → state); `CLAUDE_CONFIG_DIR` override.

---

## 3. Target Architecture

### 3.1 Domain model — Session → Tab → Pane with n-ary split tree

Replace `Workspace.canvas: Canvas` with a session list. New types (in `Workspace/Domain/`):

```swift
enum SplitAxis: String, Codable { case horizontal, vertical }   // horizontal = side-by-side

enum SplitWeight: Codable {                                     // child share within parent's axis
    case flex(Double)   // proportional; normalized at layout time (default .flex(1))
    case fixed(Int)     // fixed cols/rows
}

indirect enum SplitNode: Codable, Equatable {
    case leaf(PaneID)                                           // reuse existing PaneID verbatim
    case split(id: SplitNodeID, axis: SplitAxis, children: [WeightedChild])
}
struct WeightedChild: Codable, Equatable { var weight: SplitWeight; var node: SplitNode }

struct Tab: Identifiable, Codable, Equatable {
    let id: TabID
    var title: String
    var root: SplitNode                                         // the tiled tree of PaneIDs
    var zoomedPane: PaneID?                                     // out-of-tree zoom state
    var floatingPanes: [PaneID]                                 // optional overlay layer (Phase 2+)
    var activePane: PaneID?
}

struct Session: Identifiable, Codable, Equatable {
    let id: SessionID
    var name: String
    var tabs: [Tab]
    var activeTabIndex: Int
    var connection: ConnectionTarget?                           // per-session host (multi-host capable)
}

struct Workspace: Codable, Sendable, Equatable {               // schemaVersion -> 10
    var schemaVersion: Int
    var sessions: [Session]
    var activeSessionID: SessionID?
    var snippets: [Snippet]                                    // keep
    var layoutPresets: [LayoutPreset]                          // repurpose: now Session/Tab templates
    // RETIRED from v9: canvas, focusedPane, maximizedPane (now per-Tab), groups, bookmarks
}
```

`PaneSpec` is reused unchanged (carries `kind`/`title`/`video`); the canvas-specific `frame`/`z`/`groupID` are dropped. The split tree stores only `PaneID`s; specs resolve via a `[PaneID: PaneSpec]` map per session so the tree stays a pure geometry/identity structure.

**Why n-ary, not binary:** matches the close/rebalance UX (redistribute flex equally among N siblings); avoids redundant intermediary nodes for 3-way splits. Mirrors Zellij `TiledPaneLayout`.

**Zoom:** `Tab.zoomedPane` — render-only (same as WezTerm `TabInner.zoomed`). All other panes stay mounted (`opacity 0`, `allowsHitTesting(false)`) exactly like the current maximize trick (`CanvasView.swift:64`) to avoid libghostty surface rebuild / replay corruption.

### 3.2 New domain operations (pure, return new tree)
- `splitPane(_ id: PaneID, axis:, newSpec:) -> (Workspace, PaneID)` — find leaf, replace with a `.split` of the original + new leaf (or append to parent if axis matches).
- `closePane(_ id:)` — remove leaf; if parent drops to 1 child, collapse the split; redistribute flex weights of remaining siblings to sum-preserve.
- `resizeDivider(in splitID:, between:and:, delta:)` — adjust two adjacent flex weights, keep their sum constant.
- `moveFocus(.left/.right/.up/.down)` — **reuse `FocusResolver`** against a freshly solved `[PaneID: CGRect]` (the split solver replaces `Canvas.solvedLayout()`).
- `newTab`, `closeTab`, `selectTab(_:)`, `moveTab(_:)`, `newSession`, `closeSession`, `renameSession`.
- `breakPaneToTab(_ id:)` (Zellij/Herdr "break pane") — eject a pane into a new tab.

### 3.3 Split-tree geometry solver (replaces `SolvedLayout` / `CanvasGeometry`)
New `SplitLayoutSolver.solve(_ root: SplitNode, in rect: CGRect) -> [PaneID: CGRect]`: recursive descent, partitioning `rect` along each node's axis by normalized flex weights (fixed children subtracted first). Feeds both render and `FocusResolver`. Keep `FocusResolver.swift` (geometric neighbor detection is layout-model-independent).

### 3.4 App shell / chrome
- `SlopDeskClientApp.swift:197`: change `.windowResizability(.contentSize)` → `.automatic`; add `.windowStyle(.hiddenTitleBar)` (macOS 13+) so traffic lights float; or `NSWindow` `.fullSizeContentView` + `titlebarAppearsTransparent`.
- `WorkspaceRootView.swift:71`: keep `NavigationSplitView` spine but re-purpose columns:
  - **Sidebar** = Sessions list (grouped by host), each row = session name + rollup agent-status dot (Herdr-style) + unread badge. Footer: "New Session". (`PaneSidebarView.swift:22` repurposed.)
  - **Detail top** = a **tab bar** (custom `HStack` of tab pills + `+`, or macOS 26 `Tab`/`TabSection` with `.tabViewStyle(.sidebarAdaptable)`); injected via `ToolbarItem(.principal)` or a view above the split area.
  - **Detail center** = recursive split-pane view (`SplitTreeView` — new, replaces `CanvasView`), using `GeometryReader` + the solver's rects; dividers are draggable `Divider`-backed handles.
- Per-pane chrome: repurpose `PaneChromeView.swift:14` (already tmux-shaped) as the slim split-leaf header (kind glyph + live OSC title + RTT badge + Claude status chip + close/split). **Remove** `FloatingPaneHandle.swift` (the pill has no place in a tiled layout). `PaneLeafView.swift:32` reused **verbatim** (kind switch is layout-agnostic).
- Compact (iPhone): `PaneCarouselView.swift:24` becomes the per-tab pane carousel; tab switching is the page indicator at session level.

### 3.5 How panes bind to transports (unchanged)
`reconcile()` (`WorkspaceStore.swift:2127`) keeps its exact contract; only `canvas.allIDs()` becomes `workspace.allPaneIDs()` (DFS over every session's every tab's split tree + floating layer). `LivePaneSession`/`PaneSessionHandle`/`AppConnection` untouched. **One change worth making:** lift the single app-global host to **per-session** `connection` (Session.connection) so different sessions can target different hosts — `AppConnection` becomes keyed by host, with a small connection pool. (Open decision §7.)

### 3.6 Persistence & migration
- File path unchanged (`workspace.json`). Bump `currentSchemaVersion` → **10**.
- Current migration is hard-reset-on-mismatch (`WorkspaceSchemaMigration.swift:21`), so a v9→v10 jump would blank existing workspaces. **Write a real v9→v10 migration** (first non-trivial one): wrap the old flat `canvas.items` into a single default Session with a single Tab whose `root` is an N-way `.split` (or a single leaf if 1 item) preserving `PaneID`s and `PaneSpec`s; drop `frame`/`z`/`groupID`/`camera`. Map old `groups` → tabs (one tab per group) to preserve organization. Requires a raw-JSON version peek before typed decode (decode `{schemaVersion}` first, branch).
- `WorkspaceTransfer` envelope `formatVersion` → 2.

### 3.7 Wire/transport impact
- None required for layout. Claude-status and (optional) hook-notify ride the existing CONTROL channel as **new h→c message types starting at byte 26** (golden-additive; surgical-merge corpus; update `docs/20-wire-protocol.md`).

### 3.8 Implementation phase order (each ships green + atomic)
1. **Domain + migration** — new `Session/Tab/SplitNode` types, pure ops, `SplitLayoutSolver`, v9→v10 migration, unit tests (split/close/resize/focus + migration round-trip). No UI yet; keep canvas rendering compiling against a shim.
2. **Store** — swap `WorkspaceStore` canvas mutations for split ops; `reconcile()` over `allPaneIDs()`; per-session connection (or defer per §7). Tests: reconcile materializes/orphans across tabs.
3. **Render + chrome** — `SplitTreeView`, IDE shell (hidden titlebar, sessions sidebar, tab bar), `PaneChromeView` slim header, delete `FloatingPaneHandle`/`CanvasView`/canvas solvers. `check-macos.sh` screenshot proof.
4. **Keybindings + palette** — `WorkspaceCommands` split/tab/session actions; `CommandPaletteView` offers them; cheat sheet updated.
5. **Claude Code auto-detection** (§4).
6. **GUI settings** (§5).
7. **Terminal parity backlog** (§6), ranked.

---

## 4. Claude Code Auto-Detection Design

**Goal:** remove `PaneKind.claudeCode`; any `.terminal` pane running `claude` is auto-detected and surfaces status in the sidebar + pane chrome.

### 4.1 Remove the stored kind
- Drop `.claudeCode` from `PaneKind` (`PaneSpec.swift:42`). Update every `case .claudeCode` switch: `PaneLeafView.swift`, `LivePaneSession`, `WorkspaceStore`, `CommandInterpreter.swift:208`, `FloatingPaneHandle` (deleted anyway), `CommandPaletteView.swift:664`, `KeyboardCheatSheet.swift:34`.
- Replace with a **runtime flag** on the live session: `LivePaneSession.claudeStatus: ClaudeStatus` (`@Observable`), derived from detection signals. The inspector second-channel (`subscribeInspector()`) opens/closes **dynamically** when the flag flips, instead of at pane creation. The B1 compose-box already flips on alt-screen and is not Claude-specific — no change.

### 4.2 Detection signals (defense in depth, ordered by reliability)
1. **Host process detection (primary, most robust).** After PTY fork, the host watches the PTY master's foreground process group (`tcgetpgrp` + `proc_pidpath`/`kinfo_proc`) on a low-rate kqueue/poll; when the leaf process becomes `claude`, emit a new CONTROL message `WireMessage.foregroundProcess(name:)` (type **26**). `MuxChannelSession` already knows what it spawned; add a foreground watcher. Definitive "this PTY is running claude".
2. **Claude Code hooks (richest state, opt-in).** Ship an installer (`slopdesk integration install claude`, Muxy/Herdr-style) that writes `~/.claude/hooks/slopdesk-agent.sh` + patches `settings.json`. The hook posts JSON to a host-local Unix socket (`MUXY`-style: export `SLOPDESK_SOCKET_PATH` + `SLOPDESK_PANE_ID` into every pane env from the host). Events used: `SessionStart` (identity + active), `Notification`/`permission_prompt` (blocked), `Stop` (done/waiting), `SessionEnd` (gone). Host folds socket events → `WireMessage.claudeStatus(paneSeq:, state:, label:)` (type **27**) on CONTROL.
3. **Screen-manifest fallback (no hooks, Herdr-style).** Client-side: when foregroundProcess == `claude`, run the existing `TerminalModeTracker` for alt-screen, plus a small bottom-buffer matcher (from `TerminalViewModel.ring`) against known Claude approval/spinner/idle UI. Conservative blocked (only known approval UI; unknown → idle). Debuggable.
4. **OSC 2 title** (`Claude: …`) — already arrives as `WireMessage.title`; weak corroboration only.

### 4.3 Sidebar status state machine
```
states: idle 🟢 | working 🟡 | blocked 🔴 | done 🔵 | none ⚪
none --foregroundProcess=claude--> idle
idle --UserPromptSubmit | PostToolUse | spinner-detected--> working
working --Notification(permission_prompt) | approval-UI--> blocked
blocked --user-input-sent--> working
working --Stop | idle-prompt-detected--> done
done --(seen by user)--> idle
any --SessionEnd | foregroundProcess!=claude--> none
any --no signal >60s & no transcript update--> stale (dim)
```
Session rows **roll up to most-urgent child** (blocked > working > done > idle), like Herdr. Pane chrome shows the dot + a short label (`label` capped 32 chars from hook `last_assistant_message` / manifest).

### 4.4 Host launch mode
`HostServer.LaunchMode` stays plain-shell by default (no `--claude`); `claude` is just a command the user runs. Drop the curated `ClaudeCodeProfile` auto-launch from the default path (keep it available as a snippet/launch-preset). The forced env (`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_NO_FLICKER`) can be applied per-session via settings/launch-preset env injection instead of a daemon mode.

---

## 5. GUI Settings Design

### 5.1 Two bridge mechanisms
1. **`@AppStorage` (live, client-side)** — already proven for the 9 canvas/notification keys (`SettingsScene.swift:9`). Used for client UI + terminal-render prefs.
2. **Prefs sidecar → daemon-at-launch (video/host/mux)** — the ~80 video flags are read at static-`let` init from `ProcessInfo.environment` and cannot live-reload. The `envInt/envDouble` resolver helpers already accept an injected dict in tests (`LiveCongestionController.swift:566`, `QPController.swift:25`). Refactor the static resolvers to read from an injectable `[String:String]` populated at process start from a `video-prefs.json` sidecar. UI marks these **"applies on reconnect/restart."** Flag host+client-symmetric keys (`SLOPDESK_FEC_M/_K`, `SLOPDESK_MUX_WINDOW`) with an explicit "set on both ends" warning.

### 5.2 Panels (extend `SettingsScene.swift`, widen its `frame` at :87)
- **General** — default shell, working dir, startup, scrollback, confirm-close.
- **Appearance** — interface density, sidebar style, show-grid (legacy → retire), theme (light/dark pair).
- **Terminal** *(new)* — font family/size/weight, ligatures (`font-feature`), theme/palette, cursor style, scrollback lines, keybindings. Persist `TerminalPreferences: Codable` → `terminal-prefs.json`; apply via `ghostty_config_load_string` at `GhosttyTerminalView.swift:153` **before** `ghostty_config_finalize`, then read the libghostty cell size and send a PTY resize before first keystroke (solves the documented grid-mismatch blocker).
- **Video & Network** *(new)* — QP floor/ceiling (`CONST_QP`/`MAX_QP`/`QP_DECOUPLE`), FEC m/k (symmetric warning), capture mode (`DISPLAY_CAPTURE`), pacer (`PACER`/`PLAYOUT_*`), scroll resample Hz, VD toggle. Grouped host-only vs symmetric. "Applies on reconnect."
- **Agents** *(new)* — Claude Code hook install/uninstall button, notification routing, per-dir permission note, MCP server list (future).
- **Notifications** — OSC 9/777, long-command (existing).
- **Keyboard Shortcuts** *(new)* — remappable split/tab/session/focus bindings with conflict highlighting (Warp/Muxy-style key-capture recorder).
- **Connections** — saved hosts (promote `AppConnection.recentTargets` MRU to a managed profile list), per-profile ports + env overrides.
- **Advanced / JSON** — raw `settings.json`/prefs editor (Muxy/Warp-style escape hatch).

### 5.3 Settings persistence
- Client/terminal/keybind prefs: `@AppStorage` + `terminal-prefs.json` under `<AppSupport>/SlopDesk/`.
- Video/host prefs: `video-prefs.json` (daemon reads at launch).
- New `SettingsKey` cases under `terminal.*`, `video.*`, `agents.*`, `keys.*`.

---

## 6. Terminal Feature Parity Backlog (ranked by value)

| # | Feature | Value | Where it plugs in |
|---|---------|-------|-------------------|
| 1 | **Font/theme/keybind config** | High (biggest gap; unblocks settings) | `ghostty_config_load_string` at `GhosttyTerminalView.swift:153`; + host PTY resize after cell-size read. New `TerminalPreferences` model. |
| 2 | **In-surface splits via our tree** | High (core redesign) | `SplitTreeView` + `SplitNode` (§3). Each pane stays one libghostty surface; we tile. |
| 3 | **Tabs** | High | `Tab` model + tab bar (§3.4). |
| 4 | **Claude/agent status chips** | High | §4; `PaneChromeView` + sidebar rollup. |
| 5 | **Scrollback search (⌘F)** | High | (a) drive `ghostty_surface_binding_action(s,"start_search"/"navigate_search")` if the pinned 1.3.1 ABI exposes the search actions — verify; else (b) client-side search over `TerminalViewModel.ring` (256 KiB raw, no parsed grid → line-level only). |
| 6 | **Sticky command header** | Medium-High (cheap) | Already have OSC 133 C/D via `HostOutputSniffer`; pin last `commandStatus` command text at top of `TerminalScreenView` when output overflows. |
| 7 | **OSC 8 hyperlink click-to-open** | Medium | `HostOutputSniffer.finishOSC` (`HostOutputSniffer.swift`) — add `case "8":`; new wire type (≥26); client opens URL. libghostty may render link internally; wire the click. |
| 8 | **Command palette: tab/split/session + workflows** | Medium | `CommandPaletteView.swift:31` extend; add Warp-style typed filter chips + snippet/launch-preset entries. |
| 9 | **Launch presets / declarative layouts** | Medium | Repurpose `LayoutPreset` → Session/Tab template (Zellij KDL / Warp Tab Config analog); auto-run commands on open. |
| 10 | **Right-click context menu** | Medium | New embedder-level menu on `GhosttyLayerBackedView.rightMouseDown` (copy/paste/split/search). |
| 11 | **Vim mode in input / rich multi-line compose** | Low-Medium | iOS `TerminalInputHost` / macOS; Warp-style. Lower priority for a remote tool. |
| 12 | **Sixel / iTerm2 images** | Low | Depends on libghostty (Kitty only, build-gated); not wired. Defer. |

---

## 7. Open Decisions (with recommended default)

1. **Tree arity — binary vs n-ary.** → **n-ary** (Zellij model). Cleaner close/rebalance, no redundant nodes. *Default: n-ary.*
2. **One host vs per-session host.** Current app is single-host (`AppConnection`); tmux/Muxy attach one server per session. → **per-session `connection`** with a small host-keyed `AppConnection` pool, but **defer the multi-host pool** — ship Phase 1–4 single-host (Session.connection optional, all sessions share the one host) to limit blast radius. *Default: model per-session now, implement multi-host pool post-MVP.*
3. **Floating panes.** Zellij/Muxy have them; adds complexity. → **defer to Phase 2+**; reserve `Tab.floatingPanes: [PaneID]` in the schema now so no later migration. *Default: schema-reserved, not implemented in MVP.*
4. **Migration vs hard-reset on v9→v10.** → **write a real v9→v10 migration** (wrap canvas into one Session/Tab, preserve PaneIDs/specs). The single-user no-compat policy technically allows a blank reset, but the first real migration is cheap and preserves user layouts. *Default: real migration.*
5. **Claude detection primary signal.** → **host foreground-process watch (type 26) as primary**, hooks (type 27) as the richer opt-in, screen-manifest as no-hooks fallback. Process watch is zero-config and robust; hooks add state quality. *Default: ship process-watch + manifest first, hooks installer second.*
6. **Keep the read-only Inspector (`port+1`)?** Wired but has no host daemon. → **keep the seam, gate it behind the Claude flag, build the host daemon as part of the agents work** (or drop it if hook-notify + status chips cover the need). *Default: keep seam, build daemon only if hook status proves insufficient.*
7. **Sessions sidebar grouping.** → group sessions **by host**, per-host collapse; within a host, sessions ordered MRU. *Default: group-by-host.*
8. **Compact (iPhone) projection.** → tab bar collapses to a page indicator; `PaneCarouselView` shows the active tab's panes as pages; sessions reachable via the sidebar sheet. *Default: carousel-per-tab.*
9. **`ClaudeCodeProfile` curated launch.** → **retire as a daemon mode**; offer the curated env + `claude` command as a built-in launch preset/snippet instead. *Default: preset, not LaunchMode.*
10. **Settings live-reload for video flags.** → **no live reload** (static-`let` reality); sidecar read at daemon launch, UI says "applies on reconnect." Refactoring all resolvers to live-reactive is out of scope. *Default: launch-time sidecar.*
