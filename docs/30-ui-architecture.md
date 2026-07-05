# 30 — Client UI architecture (the rebuilt Warp-clone shell)

This is the maintainer's map of the SwiftUI client that ships in `Apps/`. It covers the module split, the
theme abstraction, the component inventory and how each binds to the store, the env seams the views honor,
and the headless ImageRenderer odiff harness. For the *why* (the L0 re-scope that deleted the old chrome and
rebuilt it as a 1:1 Warp clone), see `DECISIONS.md`; for the headless core invariants see the top-level
`CLAUDE.md`.

## Three modules + the dependency direction

```
SlopDeskClientUI   (SwiftUI views — the only target that imports SwiftUI view bodies)
        │  depends on
        ▼
SlopDeskWorkspaceCore   (headless logic / state / seams — no SwiftUI view bodies)
        │  depends on
        ▼
SlopDeskDesignSystem    (headless theme model + tokens — value types only)
```

Dependencies point **down only**. Nothing in `WorkspaceCore` or `DesignSystem` imports `ClientUI`, and
`DesignSystem` is leaf (it imports SwiftUI only for the thin `Color`/`KeyEquivalent`-bridging conveniences,
never an AppKit/UIKit view body). All three build headless.

- **`SlopDeskDesignSystem`** — the Warp **seed + derive** theme model (`Theme`, `WarpTheme`,
  `PureBlackDark`), the resolved-color layer (`ResolvedColors`), the view-facing token bundle
  (`DesignTokens`, exposed via `@Environment(\.theme)`), the fixed token scales
  (`WarpType`/`WarpSize`/`WarpSpace`/`WarpRadius`/`WarpBorder`/`WarpShadow`/`WarpMotion`), and bundled fonts
  (`Fonts`, Hack mono + Roboto UI under `Resources/Fonts`).
- **`SlopDeskWorkspaceCore`** — the proven domain: the `Session → Tab → Pane` tree, `WorkspaceStore`
  (the single mutation funnel), the split-tree solver + render model, `InputBarModel`, `PreferencesStore`,
  the `WorkspaceBindingRegistry` command catalog + routing, agent-detect rollups, and every seam
  (`TerminalRendererFactory`, `VideoWindowFactory`, `RemoteWindowDiscovery`, `SystemDialogDiscovery`,
  `TerminalSurface`). No SwiftUI view bodies → unit-testable with no window server.
- **`SlopDeskClientUI`** — thin SwiftUI views. Every mutation routes through `WorkspaceStore`; the views
  never write `tree` directly. Each leaf host view is keyed `.id(PaneID)` so a surface/connection is never
  reused across panes (the identity hazard).

## The Theme abstraction (and how to add a theme)

A **theme is a handful of seeds + the derivation formulas**, not a hardcoded palette. A `Theme` carries the
seeds (`background`/`foreground`/`accent`/optional `cursor`/`details`/16 ANSI) and derives everything else:
`neutral_n` = bg⊕fg@N%, `fgOverlay_n`, `accentOverlay_n`, WCAG-contrast-picked text tiers, and the fixed
`ui_*` literals. `ResolvedColors` does the derivation once; `DesignTokens` wraps it as SwiftUI `Color`s for
the views and adds the semantic pill/scrim/shadow tokens.

- **Default theme:** `DesignTokens.warpDark` (`WarpTheme.dark`) — background seed **#1D2022** (the live-Warp
  bundled chrome surface, `0x1D2022FF`), foreground #FFFFFF, terminal/theme accent teal #19AAD8. The
  agentic-UI brand orange (#E8704E / footer-brand tint #D97757) is a **separate** constant applied
  independently of the terminal accent.
- **Alternate:** `DesignTokens.pureBlack` (`PureBlackDark.pureBlack`) — same derivation, background #000000.

**To add a theme:** add a new `Theme` value (new seeds, reuse the derivation), expose a `DesignTokens` static
for it, and unit-pin its resolved tiers. Do NOT hardcode colors in views — read `@Environment(\.theme)` and
pull a named token. The contrast pickers (`resolved.fontColor(on:)` / `textMain(on:)`) keep ink legible over
any accent seed (e.g. `AvatarCircle` derives its initials ink this way, not a literal black).

## Component inventory (and how each binds to the store)

All views read `@Environment(\.theme)`; all mutations route through `WorkspaceStore`.

- **Window chrome** — `WorkspaceRootView` composes `WindowTopBar` (35pt, native traffic lights + centered
  omnibar pill) over `[VerticalTabRail | PanelSeparator | SplitContainer]`. Top-bar actions →
  `store.toggleSidebarCollapsed()` / `overlay.openSettings()` / `overlay.openPalette(...)`.
- **Vertical tab rail** — `VerticalTabRail` + `RailControlBar` (search field + view-options **Menu** +
  "+" new-tab) + `RailRowsBuilder` (pane-granularity rows with status icon + activity dot via
  `TabIconWithStatus`). New tab → `store.newTabDefault()`; rows select/close via the store.
- **Panes / split / blocks / input** — `SplitContainer` renders the pure `SplitTreeRenderModel.layout(...)`
  as ONE absolute-rect `ZStack` of `PaneContainer`s + `PaneDivider`s (never tree-relocated on a mode
  change). `PaneContainer` = `PaneHeader` over `TerminalLeafView` (terminal blocks + `CwdPill` + `InputBar`)
  or `RemoteWindowLeafView` (video, behind `VideoWindowFactory`). Divider drag →
  `store.resizeDividerTree(...)`; double-click → `store.balanceActivePaneSplits()`. **Divider math:** a
  pixel drag → a flex-weight delta via `PaneMath.weightDelta(pixelIncrement:axisSpan:flexSum:)`, where
  `axisSpan`/`flexSum` come from the handle's `parentSpan`/`flexSum` (the OWNING split's span + flex-weight
  sum) so the seam tracks the cursor 1:1 even for nested splits. `PaneDivider` uses `@GestureState` for the
  drag baseline so an interrupted drag can't leave a stale offset.
- **Claude bottom bar** — `AgentInputFooter` (mounted only when `claudeStatus != .none`) over an
  `AgentInputFooterCoordinator` (the single dispatch site for the typed `AgentInputFooterAction`s). Pills:
  "+" add-context (toggles the file explorer), "/remote-control" (opens the remote picker via the overlay
  coordinator), "File explorer" (`FileExplorerModel`), "Rich Input" (`InputBarModel.toggleRichMode()` — the
  input field actually goes multi-line), Settings, cwd chip, and the green "Enable … notifications"
  `SuggestionPill` (records a per-agent flag **and** re-enables the global OSC delivery gate via
  `PreferencesStore`).
- **Command palette / overlays** — the single `OverlayCoordinator` owns the ⌘K command palette
  (`CommandPaletteView`/`PaletteDataSource`, sourced from `WorkspaceBindingRegistry`), the Settings overlay,
  the busy-close `ConfirmModal`, and the toast stack (`ToastStackView`). `WorkspaceRootView` bridges the
  store's notification sinks to toasts **once** (a `didBridgeNotifications` one-shot — the bridge chains, so
  re-running it would duplicate).
- **Remote window** — `RemoteWindowPicker` (over `RemoteWindowDiscovery`) → `overlay.openRemoteWindow(...)`
  opens a `.remoteGUI` pane streaming a host window through `RemoteWindowLeafView` / `VideoWindowFactory`.

### Keyboard / menu surface

`WorkspaceKeyboardBank` (hidden zero-size button bank in `WorkspaceRootView.background`) registers **every**
`WorkspaceBindingRegistry` chord via `.keyboardShortcut`, each firing `WorkspaceBindingRegistry.route(...)`
into the store. `WorkspaceChordBridge` converts a headless `KeyChord` → SwiftUI `(KeyEquivalent,
EventModifiers)`. The palette's displayed `shortcut:` labels and the real bindings both read the ONE
registry catalog, so they cannot drift (the "no dead chord / glyph cannot drift" invariant). Every chord is
⌘/⌥-prefixed (registry-guarded) so bare keys / Ctrl-letters fall through to the terminal.

## Env seams honored

The app scene preserves the automation/runtime seams (keep these names stable):
`SLOPDESK_AUTOCONNECT_*` / `SLOPDESK_VIDEO_AUTOCONNECT_*` (auto-connect + front-on-autoconnect),
`SLOPDESK_SYSTEM_DIALOG_PANES` (system-dialog pane spawn), `SLOPDESK_SKIP_AUTO_RECONNECT`. Notification
delivery is gated by `SettingsKey.oscNotifications` (default-ON). See the top-level `CLAUDE.md` "Runtime env
flags" table for the full set and the default idiom.

## Headless ImageRenderer odiff harness

Pixel fidelity is measured by **headless `ImageRenderer` snapshot tests** (`*SnapshotOdiffTests` in
`Tests/SlopDeskClientUITests/`), NOT by instantiating a live window (hang-safety: no `SCStream`/`VT*`/Metal
/libghostty in a test). Each test hand-assembles the SAME production components in an EAGER layout (lazy /
interactive / `GeometryReader` containers swapped for eager ones so they materialize offscreen), renders at
scale 1.0 over the `#1D2022` theme base, and odiffs against a live-Warp reference crop.

- **Run:** `swift test --filter FullWindowSnapshotOdiffTests` (or the per-component `L2…L6…OdiffTests`). The
  tests need `odiff` at `/opt/homebrew/bin/odiff`; absent that they skip gracefully. They write
  `render-*.png` + `diff-*.png` to the scratchpad `warp-shots` dir and **LOG** the percentage — they are
  INFORMATIONAL, never `XCTFail` on a pixel delta (pixel parity is iterated toward).
- **Current fidelity:** full-window composite **≈ 3.64%** changed pixels. This over-counts true chrome drift
  (the live screenshot has the OS traffic-lights cluster + real shell/agent text where the render paints a
  static placeholder); the per-component L2–L4 numbers are the precise metric.
- **Live GUI proof** (real Aqua + TCC, on macStudio, isolated home :7799) is `scripts/check-macos.sh`; the
  text-only design-system ratchet is `scripts/check-ds-leaks.sh` (scrim/shadow + font/radius leak guard,
  repointed at the rebuilt overlay surfaces).
