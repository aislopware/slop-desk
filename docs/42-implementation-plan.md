# 42 — Coding-Workspace Redesign: Implementation Plan

> Status: **BINDING**. Supersedes the recommendations in `docs/41-redesign-research.md §3–7` where they conflict. Ratified architecture = the dossier defaults (Open Decisions §7.1–7.10) + the synthesis below.
> Verified against the live tree (file:line are real). The plan is the winner (clean headless-domain-first) grafted with the best ideas from the incremental + UX-led proposals.

---

## Decisions (the ratified architecture, terse + final)

1. **Retire the infinite canvas → `Session → Tab → Pane` (n-ary tiled split tree).** The canvas (`Canvas`/`CanvasItem`/camera/snap/non-overlap) is the wrong primitive for a coding tool; every competitor converged on a recursive split tree. Tree arity = **n-ary** (Zellij model): close/rebalance redistributes flex equally among N siblings, no redundant binary intermediaries. (Dossier §7.1.)
2. **Spec storage = side table.** The split tree stores only `PaneID`s (pure geometry/identity). A pane's `PaneSpec` lives in `Session.specs: [PaneID: PaneSpec]` so a rename/title never churns a tree diff. `reconcile()` reads `spec(for:)` from this map.
3. **`reconcile()` body is preserved verbatim.** The riskiest concurrency/video-cap logic is untouched; only the *source* of the leaf-id set moves — `allLeafIDs()` becomes `workspace.allPaneIDs()`. Invariant `Set(registry.keys) == Set(allPaneIDs())` holds. (`WorkspaceStore.swift:20, :273, :2128`.)
4. **Coding-IDE chrome.** Hidden title bar (traffic lights over the sidebar), a **sessions sidebar grouped by host** with a rollup agent-status dot (Herdr: blocked > working > done > idle), a **tab bar** per session, and a **recursive split-pane detail** replacing `CanvasView`. `PaneLeafView` kind switch is reused verbatim. (Dossier §7.7.)
5. **Claude Code = runtime-detected status, not a stored `PaneKind`.** Drop `PaneKind.claudeCode`; any `.terminal` pane running `claude` is auto-detected. Three signals, defense-in-depth: **(1) host foreground-process watch** (primary, zero-config, wire type 26), **(2) Claude Code hooks** (richest, opt-in, wire type 27), **(3) client screen-manifest fallback** (no wire). State drives a **pure headless state machine** in a new `SlopDeskAgentDetect` SwiftPM target. (Dossier §7.5, §7.9.)
6. **GUI Settings.** Two bridges: **`@AppStorage`** (live, client/terminal-render prefs) + a **prefs sidecar → daemon-at-launch** for the ~80 `SLOPDESK_*` video flags (read at `static let` init from `ProcessInfo.environment`, cannot live-reload → marked "applies on reconnect/restart"). The ~80 sites route through a new `EnvConfig` resolver, **behavior-preserving** (empty overrides ≡ today, pinned by test + `make golden`). (Dossier §7.10.)
7. **Terminal parity.** Font/theme/keybind config via `ghostty_config_load_string` (unblocks the documented grid-mismatch), tabs/splits via our tree, scrollback search, sticky command header, OSC 8 click-to-open, launch presets, right-click menu.
8. **Migration = a real v9→v10 step** (first non-trivial one). Preserve every `PaneID`+`PaneSpec`; map groups → tabs. Requires a pre-decode raw-JSON version peek (a v9 file fails the *typed* v10 decode before migration runs). A **frozen `WorkspaceV9` mirror** immunizes the migration against future live-type edits. (Dossier §7.4.)
9. **Deferred, but schema-reserved now:** per-session multi-host (`Session.connection` modeled; MVP shares the one `AppConnection`); `Tab.floatingPanes` (empty in MVP, no later migration). (Dossier §7.2, §7.3.)
10. **Reuse, do not rebuild:** `Sources/SlopDeskInspector/HookIngest.swift` (`HookParser`/`HookPayload`/`EventBuilder`) already parses `SessionStart`/`PostToolUse`/`SubagentStop` with fixtures — **extend** it (test-first) with `Notification(permission_prompt)`/`Stop`/`SessionEnd`, do not reimplement. `Sources/SlopDeskHost/InspectorServer.swift` is a complete `NWListener` daemon on `terminalPort+1` — **feed it**, do not rebuild; the only net-new host piece is the Claude-hook Unix-socket listener.

---

## Domain model (final Swift type sketches)

New folder `Sources/SlopDeskClientUI/Workspace/Domain/Tree/` — every type is a pure `Codable`/`Equatable`/`Sendable` value with **no SwiftUI/transport import** (headless-unit-testable). `PaneID`/`PaneSpec`/`VideoEndpoint`/`FocusDirection`/`Snippet` reused verbatim. `PaneGroupID`/`PaneGroup`/`CanvasBookmark`/`CanvasCamera` retired.

```swift
// Identity (next to PaneID in PaneSpec.swift or TreeIdentity.swift) — mirror PaneID exactly.
public struct SessionID:   Hashable, Codable, Sendable { public let raw: UUID; public init(raw: UUID = UUID()) { self.raw = raw } }
public struct TabID:       Hashable, Codable, Sendable { public let raw: UUID; public init(raw: UUID = UUID()) { self.raw = raw } }
public struct SplitNodeID: Hashable, Codable, Sendable { public let raw: UUID; public init(raw: UUID = UUID()) { self.raw = raw } }

public enum SplitAxis: String, Codable, Sendable, Equatable { case horizontal, vertical } // horizontal = side-by-side columns

public enum SplitWeight: Codable, Sendable, Equatable {
    case flex(Double)  // proportional, normalized at layout time; default .flex(1); clamp ≥ minWeight
    case fixed(Double) // fixed points along the parent axis, subtracted first
    public static let minWeight = 0.05
}

public struct WeightedChild: Codable, Sendable, Equatable { public var weight: SplitWeight; public var node: SplitNode }

public indirect enum SplitNode: Codable, Sendable, Equatable {
    case leaf(PaneID)
    case split(id: SplitNodeID, axis: SplitAxis, children: [WeightedChild]) // n-ary
    // hand-written init(from:): defensive repair on decode — drop empty splits, collapse single-child
    // into its child, flatten a child split sharing the parent axis (Zellij merge), re-mint duplicate
    // PaneIDs, clamp non-finite/≤0 weights, cap depth (maxDepth = 12). Never trap. (validate-then-repair)
}

public struct Tab: Identifiable, Codable, Sendable, Equatable {
    public let id: TabID
    public var title: String          // "" = derive from active pane's OSC title
    public var root: SplitNode         // never empty for a live tab
    public var activePane: PaneID?     // focused leaf within this tab
    public var zoomedPane: PaneID?     // out-of-tree zoom (render-only; tree untouched). WezTerm TabInner.zoomed.
    public var floatingPanes: [PaneID] // SCHEMA-RESERVED (Dossier §7.3); always [] in MVP
}

public struct Session: Identifiable, Codable, Sendable, Equatable {
    public let id: SessionID
    public var name: String
    public var tabs: [Tab]                     // ≥ 1 for a live session
    public var activeTabIndex: Int             // clamped to tabs.indices on decode
    public var specs: [PaneID: PaneSpec]       // side table; invariant Set(specs.keys) == Set(leafIDs)
    public var connection: ConnectionTarget?   // per-session host; MVP shares the one AppConnection (Dossier §7.2)
}

public struct Workspace: Codable, Sendable, Equatable {  // currentSchemaVersion = 10
    public var schemaVersion: Int
    public var sessions: [Session]             // ≥ 1
    public var activeSessionID: SessionID?
    public var snippets: [Snippet]             // KEEP verbatim
    public var layoutPresets: [LayoutPreset]   // repurposed → Session/Tab launch templates (C5)
    // RETIRED from v9: canvas, focusedPane, maximizedPane (→ Tab), groups, bookmarks, connection (→ Session)
}
```

**Facade the store consumes** (so the store body changes minimally):
```swift
public extension Workspace {
    func allPaneIDs() -> [PaneID]               // DFS over every session → tab → split tree (+ floating)
    func activeTabPaneIDs() -> [PaneID]         // drives active-tab focus/visibility (reconcile keeps the full set)
    func spec(for id: PaneID) -> PaneSpec?      // search the owning session's specs
    func tab(containing id: PaneID) -> (SessionID, TabID)?
    var activeSession: Session? { get }
    func contains(_ id: PaneID) -> Bool
}
```

**Pure ops** (`WorkspaceTreeOps.swift` + `SplitNode+Ops.swift`; each returns a new value, some `(Workspace, PaneID)`): `splitPane(_:axis:newSpec:)` (insert sibling if parent axis matches, else replace leaf with a 2-child split), `closePane(_:)` (remove + collapse single-child + flex-redistribute; empty tab → close tab; empty session → close session unless last), `resizeDivider(splitID:childIndex:delta:)` (sum-preserving), `moveFocus(_:solved:)` (reuse `FocusResolver` over solved rects), `togglingZoom(_:)`, `breakPaneToTab(_:)`, `newTab/closeTab/selectTab/moveTab/renameTab`, `newSession/closeSession/renameSession/selectSession`, `updatingSpec(_:_:)` (mutates `specs`, not the tree), `normalizingActive()`/`normalizingSpecs()` (repairs run in `load()`).

**Solver** (`SplitLayoutSolver.swift`, replaces `Canvas.solvedLayout()`/`CanvasGeometry`/`SolvedLayout`-canvas-bits, keep the `SolvedLayout` type): `static func solve(_ root: SplitNode, in rect: CGRect, minLeaf: CGSize = .init(width: 160, height: 120)) -> [PaneID: CGRect]` — recursive descent, fixed children subtracted first, flex normalized, clamp to `minLeaf`. Zoom is applied at **render** (zoomed leaf → full rect; siblings stay mounted at `opacity 0` + `allowsHitTesting(false)` — the proven `CanvasView.swift:64` no-teardown trick, avoids libghostty surface rebuild). `FocusResolver.swift` kept verbatim (layout-model-independent).

---

## Migration (from current persistence schema)

Current state: `currentSchemaVersion = 9`; `WorkspaceSchemaMigration.migrate` is hard-reset (`from != to → nil`) and runs on the **already-decoded typed value** (`WorkspacePersistence.swift:100`). A v10 `Workspace` has no `canvas`/`groups`, so a v9 file **fails the typed v10 decode** at `:95` *before* migration runs. The fix is a **pre-decode raw-JSON version peek**.

`WorkspacePersistence.load()` edit:
1. Decode `struct VersionPeek: Decodable { let schemaVersion: Int }` off the raw bytes.
2. `== 10` → typed-decode `Workspace` directly.
3. `9` (forward-tolerant `5...9`) → decode a **frozen `WorkspaceV9` shadow** (a snapshot copy of the v9 `Workspace`/`Canvas`/`CanvasItem`/`PaneGroup` shapes, in `Legacy/WorkspaceV9.swift` so future live-type edits can't break the migration), then `WorkspaceMigrationV9toV10.migrate(_:) -> Workspace`.
4. unknown/future → reset-to-default + `.corrupt` sidecar (unchanged).
5. Run the existing repair chain, retargeted to v10 invariants (`normalizingSpecs()`/`normalizingActive()`).

`WorkspaceMigrationV9toV10.migrate` mapping (pure):
- **One Session** named from `v9.connection?.host ?? "Local"`, `connection = v9.connection`.
- **Groups → tabs**: one `Tab` per `PaneGroup` (group name → tab title); ungrouped panes → a leading `"Main"` tab; no groups → one `"Main"` tab.
- **Tab.root**: 1 pane → `.leaf(id)`; else an n-ary `.split(axis: .horizontal, children:)` of leaves, ordered by `frame.minX` then `minY` (deterministic, pinned in a test).
- **Session.specs** = `[paneID: item.spec]` preserving every `PaneID`+`PaneSpec`; `.claudeCode` spec kept while the enum still has the case (C1), rewritten `.claudeCode → .terminal` in the same atomic commit that removes the case (C3). Drop `frame`/`z`/`groupID`/`camera`/`bookmarks`/`maximizedPane`.
- `activePane = v9.focusedPane` if in tab; `zoomedPane = v9.maximizedPane` if in tab; `activeSessionID`/`activeTabIndex` from the focused pane's owner.
- `snippets` carried; `layoutPresets` carried (their embedded v9 canvases run the same item→tree transform → a one-tab template, or names-only if dropped).

`WorkspaceTransfer.formatVersion → 2`; import reuses the v9→v10 transform on `formatVersion: 1`; `maxItems` re-applied to `allPaneIDs().count`.

---

## Work breakdown

Ordered work-items. Each builds + tests green **standalone** and is **one atomic commit**. Branch off `main`: `feat/coding-workspace-redesign`. Full gate = `make check` (lint + build + test + golden); add `bash scripts/check-ios.sh` after any `#if os(iOS)` edit and `.build/release/slopdesk-loopback-validate --smoke` after any wire/FEC-adjacent item. Hosted CI does NOT enforce build/test/golden — **run locally**.

**Compile-gap mitigation (graft from P1+P3):** the domain swap (W2–W5) crosses a window where the package won't compile if landed strictly one-file-at-a-time (the store/views reference `Canvas`). Gate the old `CanvasView`/canvas solvers behind a compile flag `SLOPDESK_IDE_SHELL` (old path `#if !IDE_SHELL`); keep `swift build` green at **every** commit (W2 includes a minimal compiling `WorkspaceStore` shim if needed); only delete `Canvas*`/`CanvasView` in W5's atomic commit once `SplitTreeView` replaces them.

### Phase C1 — Domain model

**W1 — Identity + SplitNode + solver (pure).** Deps: none.
- Add: `Domain/Tree/{TreeIdentity.swift, SplitNode.swift, SplitNode+Codable.swift, SplitLayoutSolver.swift}` (SessionID/TabID/SplitNodeID can live in `PaneSpec.swift` instead).
- First-test: `Tests/SlopDeskClientUITests/Workspace/Tree/SplitNodeCodableTests.swift` (round-trip; decode-time repair: empty-split drop, single-child collapse, axis-flatten merge, dup-PaneID re-mint, bad-weight clamp, over-depth cap) + `SplitLayoutSolverTests.swift` (2/3-way flex partition, fixed-then-flex, minLeaf clamp, rects feed `FocusResolver`). Each asserts a value that fails before the type exists.
- Verify: `swift test --filter SplitNode && swift test --filter SplitLayoutSolver`.

**W2 — Session/Tab/Workspace v10 types + pure ops + facade.** Deps: W1.
- Add: `Domain/Tree/{Tab.swift, Session.swift, WorkspaceTreeOps.swift, SplitNode+Ops.swift}`. Change: `Domain/Workspace.swift` (rewrite to v10 shape + `allPaneIDs`/`activeTabPaneIDs`/`spec(for:)`/`defaultWorkspace`/`normalizing*`); bump `currentSchemaVersion = 10`. Gate old `CanvasView` behind `#if !IDE_SHELL`; add a minimal `WorkspaceStore` shim so the package builds.
- First-test: `WorkspaceTreeOpsTests.swift` — split (n-ary insert vs replace), close (collapse + flex redistribution + tab/session cascade), resizeDivider (sum-preserve), togglingZoom, breakPaneToTab, newTab/closeTab (≥1 invariant), newSession/closeSession, `allPaneIDs()` DFS order, `spec(for:)`, `Set(specs.keys)==Set(leafIDs)` invariant, `normalizing*` repairs. Revert-to-confirm-fail on each.
- Verify: `swift build && swift test --filter WorkspaceTreeOps`.

**W3 — v9→v10 migration + persistence version-peek.** Deps: W2.
- Add: `Legacy/WorkspaceV9.swift` (frozen mirror), `Store/WorkspaceMigrationV9toV10.swift`. Change: `Store/WorkspacePersistence.load()` (pre-decode peek branch), `Store/WorkspaceSchemaMigration.swift` (real v9→v10 step), `Store/WorkspaceTransfer.swift` (`formatVersion = 2` + import migration).
- First-test: `WorkspaceMigrationV9toV10Tests.swift` — hand-built v9 JSON (1 pane / N panes / grouped / focused+maximized / with `.claudeCode` / with a `.remoteGUI` carrying a `VideoEndpoint` / with a preset) → exact v10 tree; PaneID+spec preservation; deterministic `frame.minX` ordering; round-trip `encode(v10) |> decode == v10`. `WorkspacePersistenceMigrationTests.swift` — write a v9 file → `load()` yields migrated v10; future version → reset-aside + `.corrupt`. Proven to fail against today's `nil`-returning migration.
- Verify: `swift test --filter Migration && swift test --filter Persistence`.

**W4 — Store retarget (reconcile over the new tree).** Deps: W2, W3.
- Change: `Store/WorkspaceStore.swift` — `allLeafIDs()` → `workspace.allPaneIDs()`; the ~12 direct `workspace.canvas.allIDs()` sites (`:274, :327, :658, :1056, :1057, :1092, :1492, :1758, :2236, :2287, :2380`) → `workspace.allPaneIDs()`/`activeTabPaneIDs()`; `spec(for:)` (`:2346`) → `workspace.spec(for:)`; `defaultTitle` (`:2392`); add tree-mutation methods (splitPane/closePane/newTab/selectTab/newSession/move(.direction)/zoom) wrapping the pure ops + `reconcile()`; delete canvas/group/camera/snap/non-overlap/arrange/overview methods; `isPaneOnCanvas` → `isPaneInActiveTab`; `neighbourForRefocus` uses the new solver's frames; `defaultWorkspace()` → one Session/Tab/leaf. **Do not touch `reconcile()` body.** Model `Session.connection`; MVP all sessions share the one `AppConnection` (`// TODO(multi-host)`).
- First-test: `WorkspaceStoreReconcileTests.swift` (extend) with `FakePaneSession` — split materializes a registry handle; close orphans it; tab/session switch keeps ALL panes registered (full `allPaneIDs`) but active-tab focus follows; close-last-pane cascades close tab→session; `Set(registry.keys)==Set(allPaneIDs())` holds after random op sequences. Revert-to-confirm-fail.
- Verify: `swift test --filter WorkspaceStore`.

### Phase C2 — Shell + split UI

**W5 — IDE shell + SplitTreeView + chrome.** Deps: W4.
- Add: `Views/{SplitTreeView.swift, SessionDetailView.swift, TabBarView.swift, SessionSidebarView.swift, DividerHandle.swift, AgentStatusDot.swift}`. Change: `WorkspaceRootView.swift` (detail = `VStack(TabBarView, SplitTreeView)`; compact = per-tab carousel), `SlopDeskClientApp.swift:197` (`.windowResizability(.automatic)` + `.windowStyle(.hiddenTitleBar)`), `PaneChromeView.swift` (slim split-leaf header: kind glyph + OSC title + RTT badge + Claude status chip + split/zoom/close), `PaneCarouselView.swift` (per active tab on iOS). Delete: `FloatingPaneHandle.swift`, `CanvasView.swift`, `CanvasItemView.swift`, `Canvas.swift`, `Canvas+Codable.swift`, `Canvas+Ops.swift`, `CanvasSnap.swift`, `CanvasNonOverlap.swift`, `CanvasGeometry.swift` (+ canvas tests). Flip `SLOPDESK_IDE_SHELL` default ON. `PaneLeafView.swift` reused verbatim. `FocusResolver.swift` kept.
- First-test: GUI views are compiled + code-reviewed only (hang-safety — no SCStream/VT/Metal/libghostty in tests). Headless seam = `SplitLayoutSolver` (W1) + a pure `SplitTreeRenderModel` helper (which pane → which rect, zoom → full rect, dividers between adjacent children): `SplitTreeRenderModelTests.swift`. GUI proof = `bash scripts/check-macos.sh` screenshot (real Aqua session); `bash scripts/check-ios.sh` for the carousel.
- Verify: `swift build && swift test --filter SplitTreeRenderModel && bash scripts/check-macos.sh && bash scripts/check-ios.sh`.

**W6 — Keybindings + command palette + cheat sheet.** Deps: W5.
- Change: `WorkspaceCommands.swift` (`⌘D` split right, `⌘⇧D` split down, `⌘⇧W` close pane, `⌘⌥←/→/↑/↓` focus, `⌘⌥↩` zoom, `⌘T` new tab, `⌘⇧]`/`⌘⇧[` next/prev tab, `⌘1…9` select tab, `⌃⌘N` new session — all ⌘-prefixed so the focused terminal never swallows them), `CommandPaletteView.swift` (split/tab/session entries + typed filter chips + snippet/preset entries), `KeyboardCheatSheet.swift`.
- First-test: `TreeCommandRoutingTests.swift` — each command id maps to the correct store op (assert on the resulting `Workspace`, headless); `CommandPaletteEntriesTests.swift` — palette offers split/tab/session actions.
- Verify: `swift test --filter TreeCommandRouting && swift test --filter CommandPalette`.

### Phase C3 — Claude Code detection

**W7 — Claude detection core (new headless target).** Deps: none (parallel to C1/C2).
- Add SwiftPM target `Sources/SlopDeskAgentDetect/{ClaudeStatus.swift, ClaudeStatusMachine.swift, ClaudeManifestMatcher.swift}` (depends on nothing GUI/VT/transport → physically cannot import them); register in `Package.swift`.
- States: `none ⚪ | idle 🟢 | working 🟡 | blocked 🔴 | done 🔵` (+ stale dim). `ClaudeSignal` = enum over `foregroundProcess(name:)` / `hookSessionStart` / `hookUserPrompt` / `hookNotification(kind:label:)` / `hookStop` / `hookSessionEnd` / `manifestVerdict(ClaudeStatus)` / `oscTitle(String)` / `tick(now:)`. Pure `ClaudeStatusMachine.reduce(_:_:)`. `ClaudeStatus.urgency` for rollup; `Session.rollupStatus(_ perPane:) -> ClaudeStatus` (blocked > working > done > idle > none). `ClaudeManifestMatcher` = conservative bottom-buffer string/regex table (blocked only on a known approval-UI match; unknown → idle).
- First-test: `Tests/SlopDeskAgentDetectTests/{ClaudeStatusMachineTests,ClaudeManifestMatcherTests,ClaudeRollupTests}.swift` — every transition incl. stale-tick; manifest conservative; rollup most-urgent. No GUI/socket/PTY — feed signals directly. Revert-to-confirm-fail.
- Verify: `swift test --filter SlopDeskAgentDetect`.

**W8 — Extend HookIngest with the missing events.** Deps: none.
- Change: `Sources/SlopDeskInspector/HookIngest.swift` — add `Notification(permission_prompt)`, `Stop`, `SessionEnd` to `HookParser`/`HookPayload`/`EventBuilder` (the `blocked`/`done`/`none` transitions need them; today it covers only `SessionStart`/`PostToolUse`/`SubagentStop`).
- First-test: `Tests/SlopDeskInspectorTests/HookIngestTests.swift` (extend) + add fixtures `Fixtures/hook-notification-permission.json`, `hook-stop.json`, `hook-session-end.json` → assert the new payload cases parse; malformed → dropped (validate-then-drop). Proven to fail before the parser change.
- Verify: `swift test --filter HookIngest`.

**W9 — Wire types 26/27 + golden merge + client ingest.** Deps: W7. Touches wire → golden + loopback.
- Change: `Sources/SlopDeskProtocol/WireMessage.swift` (+`+Encode`/`+Decode`) — add `.foregroundProcess(name: String)` = type **26**, `.claudeStatus(state: UInt8, label: String)` = type **27**, both h→c CONTROL; update `messageType`/`channel`/encode/decode (manual binary, big-endian length-prefixed UTF-8, cap 256B, **validate-then-drop** on short/garbage). Confirm the decoder **drops** unknown CONTROL types (old-client compat: `SlopDeskError.unknownMessageType` path drops, not traps). Client transport ingest → `LivePaneSession.foregroundProcess`/feeds the state machine. **Surgically merge** two entries into `terminalWireMessages` in `golden/golden_vectors.json` (NEVER `>`-redirect the generator — drops the 13 frozen keys); the generator that emits this key is `Sources/slopdesk-corevectors/main.swift:664`. Update `docs/20-wire-protocol.md` (next free byte → 28).
- First-test: `Tests/SlopDeskProtocolTests/ClaudeWireCodecTests.swift` — encode/decode round-trip for 26/27, big-endian, truncated body → `nil`, unknown type byte drops. Pin the bytes.
- Verify: `swift test --filter ClaudeWire && bash scripts/golden-check.sh && .build/release/slopdesk-loopback-validate --smoke`.

**W10 — Host foreground-process watch + hook socket listener + installer.** Deps: W8, W9.
- Add: `Sources/SlopDeskHost/ForegroundProcessWatcher.swift` (in/around `MuxChannelSession`, which holds `masterFD`: `tcgetpgrp(masterFD)` → pgid → `proc_pidpath`/`proc_name` on a ~1Hz poll or kqueue `EVFILT_PROC`; emit type 26 on basename edge), `Sources/SlopDeskHost/AgentHookListener.swift` (AF_UNIX, line-framed `pane|event|title|body`, parse via the extended `SlopDeskInspector.HookParser`/`EventBuilder` → emit type 27, route into `InspectorServer` replay infra — do NOT rebuild the daemon). Add `slopdesk integration install claude` subcommand (writes `~/.claude/hooks/slopdesk-agent.sh`, patches `~/.claude/settings.json`); export `SLOPDESK_SOCKET_PATH` + `SLOPDESK_PANE_ID` into every PTY env (in `HostEnvironment.curated`).
- First-test: `Tests/SlopDeskHostTests/{ForegroundProcessWatcherTests,AgentHookListenerTests,AgentInstallerTests}.swift` — the pure `isClaude(path:)` basename-classifier + debounce/edge-trigger over a fake fd/proc-name source; hook line → correct `claudeStatus` emission + per-pane routing (no real socket); installer `settings.json` patch is pure-string-testable. (Assemble any secret-token-shaped fixture at runtime — push-protection trap.)
- Verify: `swift test --filter ForegroundProcessWatcher && swift test --filter AgentHook && swift test --filter AgentInstaller && swift build`.

**W11 — Remove `PaneKind.claudeCode` + runtime flag + manifest fallback wired live.** Deps: W3, W7, W9, W10.
- Change: drop `.claudeCode` from `PaneKind` (`PaneSpec.swift:46`) + every switch (`PaneLeafView.swift`, `LivePaneSession.swift`, `WorkspaceStore.swift`, `CommandInterpreter.swift:208`, `CommandPaletteView.swift`, `KeyboardCheatSheet.swift`, `SettingsScene.swift`, `WorkspaceRootView.swift`, `PaneKind.canReceiveText`/`isVideo`); add `LivePaneSession.claudeStatus: ClaudeStatus` (`@Observable`) reduced by `ClaudeStatusMachine` from types 26/27 + manifest + title; **re-gate `subscribeInspector()` from `kind == .claudeCode` to the runtime `claudeStatus != .none`** (dynamic open/close); rewrite the v9 migration map `.claudeCode → .terminal` (same commit removes the case); `HostServer.LaunchMode` default `.shell` (retire `--claude` auto-launch); `ClaudeCodeProfile` → launch preset (curated env applied per-session). Client manifest fallback: when `foregroundProcess == claude` and no hook feed, run `SlopDeskClaudeCode.TerminalModeTracker` + `ClaudeManifestMatcher` over `TerminalViewModel.ring`. Wire the chip into `PaneChromeView` + `AgentStatusDot` (sidebar rollup + tab pill).
- First-test: `ClaudeKindRemovalTests.swift` (no `.claudeCode` reachable; migration rewrites it; inspector does NOT open for a plain terminal), `ClaudeStatusRollupTests.swift` (already in W7 but assert the live wiring's rollup over a LivePaneSession set).
- Verify: `swift test --filter Claude && swift build && bash scripts/check-ios.sh`.

### Phase C4 — Settings

**W12 — EnvConfig bridge + settings models (headless).** Deps: none (touches video flags → golden re-prove). 
- Change: `Sources/SlopDeskVideoHost/QPController.swift` (`envInt` at `:25-26` reads `ProcessInfo.processInfo.environment` directly) + `LiveCongestionController.swift` + all `SLOPDESK_*` `static let` sites → route through a new shared `EnvConfig` (`enum EnvConfig { static var overrides: [String:String] = [:]; static func string(_ k) -> String? { overrides[k] ?? ProcessInfo.processInfo.environment[k] } }`); daemon/app `main()` loads `video-prefs.json` into `EnvConfig.overrides` **before** any `static let` is forced. Add: `Settings/{TerminalPreferences,VideoPreferences,AgentPreferences,KeybindingPreferences}.swift` (+ sidecar persistence) and `Settings/EnvBridge.swift` (`VideoPreferences.toEnv() -> [String:String]` keyed 1:1 to `SLOPDESK_*`).
- First-test: `EnvConfigTests.swift` — **behavior-preservation proof**: `EnvConfig.string(k)` with empty overrides ≡ `ProcessInfo.environment[k]`; override wins when set (revert-to-confirm-fail: a key resolves to the override only after the refactor). `EnvBridgeTests.swift` — `VideoPreferences.toEnv()["SLOPDESK_FEC_M"] == "2"` etc.; symmetric keys (`SLOPDESK_FEC_M/_K`, `SLOPDESK_MUX_WINDOW`) flagged "set on both ends". `*PreferencesTests.swift` — round-trip + sidecar read.
- Verify: `swift test --filter EnvConfig && swift test --filter EnvBridge && swift test --filter Preferences && make golden && .build/release/slopdesk-loopback-validate --smoke` (prove the video golden is byte-identical with empty overrides).

**W13 — Settings UI panels + Terminal config apply.** Deps: W12, W10 (Agents panel installer). 
- Change: `SettingsScene.swift` (widen frame; sidebar `TabView` panels: General · Appearance · **Terminal** · **Video & Network** (host-only vs symmetric, "applies on reconnect") · **Agents** (Claude hook install/uninstall button → W10 installer; notification routing) · Notifications · **Keyboard Shortcuts** (remappable, conflict highlighting) · **Connections** (promote `AppConnection.recentTargets` MRU) · **Advanced/JSON**; new `SettingsKey` cases `terminal.*`/`video.*`/`agents.*`/`keys.*`; retire the legacy Canvas/grid/snap toggles), `GhosttyTerminalView.swift:153` (`ghostty_config_load_string(TerminalPreferences → config string)` before `ghostty_config_finalize`, then read libghostty cell size + send a PTY resize before first keystroke — fixes the grid-mismatch blocker).
- First-test: `SettingsKeyTests.swift` (no dup keys, defaults), `TerminalConfigBuilderTests.swift` (pure `TerminalPreferences.ghosttyConfigString()` contains `font-family = …`). `ghostty_config_load_string` call site compiled + code-reviewed only (libghostty, hang-safety). GUI proof = `check-macos.sh`.
- Verify: `swift test --filter SettingsKey && swift test --filter TerminalConfigBuilder && swift build && bash scripts/check-macos.sh`.

### Phase C5 — Terminal features

**W14 — Parity backlog (one atomic commit per feature).** Deps: W5 (UI), W9 (wire for OSC 8).
- Sticky command header (#6 — reuses `commandStatus` type 23, no wire change; pin last command text atop `TerminalScreenView` on overflow). Scrollback search ⌘F (#5 — `ghostty_surface_binding_action(s,"start_search"/"navigate_search")` if the pinned 1.3.1 ABI exposes it, else client-side line search over `TerminalViewModel.ring`). OSC 8 hyperlink click-to-open (#7 — `HostOutputSniffer.finishOSC` add `case "8":` → new h→c type **28**, additive golden merge, client opens URL). Right-click context menu (#10 — `GhosttyLayerBackedView.rightMouseDown`: copy/paste/split/search). Launch presets / declarative layouts (#9 — repurpose `LayoutPreset` → Session/Tab template auto-running commands on open; carries the Claude curated env).
- First-test per feature on the pure piece: sniffer OSC 8 parse, search-over-ring index, preset→tree expansion. GUI wired + code-reviewed.
- Verify per feature: targeted `swift test --filter <Feature>` + `make check`; `bash scripts/golden-check.sh` + `loopback-validate --smoke` for the OSC 8 wire type; `check-macos.sh` for GUI-visible ones.

**W15 — Final gate (Phase D).** Deps: all.
- Verify: `make check` (lint + build + ~2300 tests + golden) green; `bash scripts/check-ios.sh`; `.build/release/slopdesk-loopback-validate --frames 120`; `bash scripts/check-macos.sh` end-to-end screenshot.

---

## Constraint checklist (golden corpus, headless, wire, float idioms) — how the plan preserves each

- **Golden corpus / wire freeze.** The terminal wire **IS** golden-pinned via the `terminalWireMessages` key in `golden/golden_vectors.json` (generator `Sources/slopdesk-corevectors/main.swift:664`; `WireMessage+Encode/Decode.swift` doc-comments confirm). New CONTROL types 26/27 (and 28 in C5) are **additive within wire version 1**, always **surgically merged** into `terminalWireMessages` — never `>`-redirected (drops the 13 frozen XCTest-pinned keys). Every wire item (W9, W14-OSC8) runs `bash scripts/golden-check.sh` (43 keys) + `slopdesk-loopback-validate`. The host still accepts only version 1; old clients drop unknown CONTROL types (validate-then-drop). No existing byte shifts — the layout redesign touches zero wire. The **video** golden is re-proven byte-identical by W12's `make golden` + loopback (empty `EnvConfig.overrides` ≡ today).
- **Headless-first.** The entire domain (SplitNode/Tab/Session/Workspace/ops/solver/migration — W1–W4), the Claude state machine + manifest matcher + rollup in the isolated `SlopDeskAgentDetect` target (W7, which *physically cannot* import GUI/VT/libghostty), the hook parser (W8), the wire codec (W9), the host watcher/listener/installer *pure decoders* (W10), and the settings models + `EnvConfig`/`EnvBridge` (W12) are all pure value types / pure functions with failing-first headless tests. GUI views (W5, W13, W14) are compiled + code-reviewed and proven via `check-macos.sh`/`check-ios.sh` — **no `SCStream`/`VTCompressionSession`/`VTDecompressionSession`/Metal/libghostty surface is instantiated in any test** (hang-safety rule). The watcher/listener are tested as pure parsers, never against a real socket/PTY.
- **Bit-exact float idioms.** Weight normalization in the solver/ops uses **separate `*`+`+`** and **ordered min/max** (`Double.maximum`/`Double.minimum`, never a bare `<`/`>` ternary), never `addingProduct`/`fma`. None of the FEC/QP/congestion float paths are edited — the only video-path change (W12 `EnvConfig` indirection) is behavior-preserving and pinned byte-identical.
- **FEC m==1 ≡ XOR, single C target, validate-then-drop.** Untouched — the redesign is client-UI + terminal-host-control + settings. `Sources/CSlopDeskSIMD` (GF(2⁸) NEON kernel, scalar xxHash) is out of scope, re-proven incidentally by `loopback-validate`/`make golden`. New wire decoders (26/27/28) and the hook-socket validate-then-drop on short/garbage; foreground watch uses ordinary Darwin syscalls; no new `unsafe`/C.
- **Migration safety.** First real migration: pre-decode version peek + **frozen `WorkspaceV9` mirror** (immunized against future live-type edits) + every `PaneID`+`PaneSpec` preserved (restored sessions reconcile identically) + round-trip tested; unknown/future versions still reset-to-default with a `.corrupt` sidecar (no brick-on-launch).
- **Atomic green layers + traps.** Each W-item is one atomic commit, builds + tests green standalone; the `SLOPDESK_IDE_SHELL` flag + the W5 atomic delete keep `swift build` green across the domain swap. The `.claudeCode`-enum removal is ordered across phases (C1 migration keeps the case; W11 removes it AND rewrites the migration map in one commit) so no commit references a deleted case. prek partial-pathspec trap honored (commit all related files together). `bash scripts/check-ios.sh` after W5/W11/W15.
