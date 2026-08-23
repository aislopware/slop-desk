# 30 — Client UI architecture (two shells: AppKit on macOS, SwiftUI on iOS)

Maintainer's map of the client UI: the target stack, the design floor, component→store bindings, env
seams, and the visual-verification rigs.

> **This doc was written for a UI that no longer exists, and was corrected on 2026-08-22 against the
> working tree.** Every claim below now carries a `file:line`. Two whole subsystems it described are
> DELETED and are kept here only as banners, because a reader who remembers them needs to be told they
> went rather than find the section quietly missing: the **Warp-clone design system** (`SlopDeskDesignSystem`,
> `WarpTheme`, `DesignTokens`, `#1D2022`) — demolished by `657a8f44` "rebuild L0 — demolish Warp-clone UI +
> delete DesignSystem target" (2026-06-24), superseded by `DECISIONS.md` §"Design system rebuild
> (2026-06-24)" — and the **Claude bottom bar** (`AgentInputFooter` and friends), pruned by `92472b0a`
> (2026-07-03). The doc's old framing — ONE SwiftUI target named `SlopDeskClientUI`, ONE
> `WorkspaceRootView`, a `⌘K` palette, an odiff pixel-diff harness — is stale in all four respects.
>
> For the split into two shells read **`docs/56-client-ui-split.md`** (it is the owner of the target
> stack; this doc summarises it and does not restate it). For the design language read `DESIGN.md`; for
> the store read `docs/22-workspace-architecture.md`; for `SLOPDESK_*` flags read
> `docs/46-gates-env-paths.md`.

## The target stack + the dependency direction

Dependencies point **down only** (`docs/56` §2 owns this table; `Package.swift` is the enforcement).

```
Sources/SlopDeskMacUI      AppKit + Metal + CoreAnimation    — macOS only  (Package.swift:611)
Sources/SlopDeskPhoneUI    SwiftUI                           — iOS only    (Package.swift:531)
        │  both depend on
        ▼
Sources/SlopDeskSlate      the DESIGN FLOOR: tokens in both  — BOTH        (Package.swift:499)
                           spellings, status-mark geometry,
                           the artwork
Sources/SlopDeskClientCore PRESENTATION LOGIC + the          — BOTH        (Package.swift:422)
                           COMPOSITION ROOT
Sources/SlopDeskDevicePanels  simulator + Android domain     — BOTH        (Package.swift:378)
Sources/SlopDeskWorkspaceCore the DOMAIN: store, connection, — BOTH        (Package.swift:321)
                           terminal, agent
Sources/SlopDeskWorkspaceModel value types                   — BOTH        (Package.swift:235)
```

**What changed.** The doc used to draw three boxes — `SlopDeskClientUI → SlopDeskWorkspaceCore →
SlopDeskDesignSystem` — and both ends of that chain are gone.

- **`SlopDeskDesignSystem` is DELETED** (`657a8f44`, 2026-06-24). `grep -rl SlopDeskDesignSystem
  Sources/` returns zero files. The design floor is `SlopDeskSlate`
  (`Sources/SlopDeskSlate/SlateDesign.swift:1`), 10 files, and it holds **values only** —
  `check-supervisor.sh` fails the build if a `some View` lands in it.
- **`SlopDeskClientUI` no longer exists as a target.** It was drained upward one surface at a time and
  then RENAMED to `SlopDeskPhoneUI` (`docs/56` §2, increment 63); the macOS half is
  `SlopDeskMacUI`. 103 Swift files each. The 33 files that still say the string `SlopDeskClientUI` all
  say it inside a comment narrating that history — there is no target and no `import` by that name.
- **Two floors the old diagram did not have** were carved out between the domain and the views:
  `SlopDeskClientCore` (presentation logic — palette, rail, overlays, settings catalog, chrome, plus the
  composition root) and `SlopDeskSlate`. The cut that makes them work is `docs/56` §2's: *`WorkspaceCore`
  is the domain, `ClientCore` is what a UI asks the domain for.*

Still true, and re-verified:

- **`SlopDeskWorkspaceCore`** — the `Session → Tab → Pane` tree, `WorkspaceStore` (single mutation
  funnel), the split-tree solver + render model
  (`Workspace/Domain/Tree/SplitTreeRenderModel.swift:29`), `InputBarModel`
  (`Input/InputBarModel.swift:22`), `PreferencesStore`, the `WorkspaceBindingRegistry` catalog
  (`Workspace/Domain/WorkspaceBindingRegistry.swift:355`) and its routing
  (`Workspace/Store/WorkspaceBindingRouting.swift:59`), agent-detect rollups, and the seams
  `TerminalRendererFactory` (`Terminal/TerminalRenderingView.swift:53`) and `VideoWindowFactory`
  (`Video/VideoWindowSeam.swift:342`). No view bodies → unit-testable with no window server.
- **The `.id(PaneID)` identity hazard** — a leaf host is keyed by `PaneID` so a surface/connection is
  never reused across panes. Live on both halves:
  `Sources/SlopDeskPhoneUI/Pane/SplitContainer.swift:170`,
  `Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift:75`,
  `Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift:15`.
- **`RemoteWindowDiscovery`** is still DECLARED (`Video/VideoWindowSeam.swift:459`) — but see the
  remote-window banner below; nothing assigns its `shared` seam any more, so treat it as vestigial.
  **UNVERIFIED:** whether it is reachable at all on a shipping launch path.

## ~~The Theme abstraction~~ — DELETED (`657a8f44`, 2026-06-24)

**This section described the Warp seed+derive theme model, and every symbol in it is gone.** Empty
searches, all of them `grep -rl --include='*.swift' … Sources/ Tests/ Apps/` returning **0 files**:
`SlopDeskDesignSystem`, `Theme`-as-seeds, `WarpTheme`, `PureBlackDark`, `ResolvedColors`,
`DesignTokens` (and `DesignTokens.warpDark` / `.pureBlack`), the fixed scales
`WarpType`/`WarpSize`/`WarpSpace`/`WarpRadius`/`WarpBorder`/`WarpShadow`/`WarpMotion`, the contrast
pickers `fontColor(on:)` / `textMain(on:)`, and `AvatarCircle`. The three hex literals the section
pinned — `#1D2022`, teal `#19AAD8`, brand orange `#E8704E` / `#D97757` — return 0 files as well.
`@Environment(\.theme)` returns 0 files: **tokens are STATIC, not Environment**, deliberately, because
SwiftUI's Environment does not cross the `NSSplitViewController` boundary (`DECISIONS.md`, "Design
system rebuild (2026-06-24)").

What replaced it, in one paragraph — the authority is `DESIGN.md` and the header of
`Sources/SlopDeskSlate/SlateDesign.swift`, not this file:

- **There is no theme model, because there is no theme picker.** "ONE APPEARANCE" (user-directed
  2026-08-08): no light/dark slot, no follow-OS resolution, no runtime store. `Slate.theme` is a
  **constant** (`SlateDesign.swift:35-39`). The doc's "**To add a theme:** add a new `Theme` value…"
  recipe therefore describes an operation the codebase no longer has.
- **ONE ISLAND, four laws** (`SlateDesign.swift:9-32`): exactly one lifted surface (the terminal
  canvas); inside it, separation is a hairline; concentric geometry 16 / 8 / 8; and the ground is
  Alucard's cream **`#FFFBEB`**, a light frame under a dark island.
- **One brand accent:** the fixed Dracula purple, `#644AC9` light / `#9580FF` on dark
  (`SlateDesign.swift:46`). Identity hues stay off chrome glyphs.
- **Fonts moved out too.** The old `Fonts` (Hack mono + Roboto UI, bundled to mimic Warp) is gone; the
  bundled faces are JetBrains Mono + Symbols Nerd Font in their own target `SlopDeskFontFaces`
  (`Package.swift:257`, `Sources/SlopDeskFontFaces/NerdSymbolFont.swift:16`).

## Component inventory (and how each binds to the store)

All mutations still route through `WorkspaceStore` — that part of the old section survived. What did
not survive is "all views read `@Environment(\.theme)`" (0 files) and, more importantly, the premise
that each row names ONE view type. **Almost every row below is now two types, one per shell.**

| Old claim | Live truth | Evidence |
| --- | --- | --- |
| `WorkspaceRootView` composes `WindowTopBar` (35pt, native traffic lights + centered omnibar pill) over `[VerticalTabRail \| PanelSeparator \| SplitContainer]` | **Two roots.** macOS: `MacWorkspaceRootView` over the AppKit `SlopDeskSplitViewController`; the window runs `.hiddenTitleBar` (no system toolbar) and the chrome is the workspace's own `MacTitlebarBand`, height `Slate.Metric.titlebarHeight` — a derived token, not a 35pt literal. iOS: `WorkspaceRootView`, a stock `NavigationSplitView` over `NavigatorColumn`/`ContentColumn`. `WindowTopBar`, `VerticalTabRail`, `PanelSeparator` → **0 files**. | `Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift:1-38`; `Sources/SlopDeskPhoneUI/WorkspaceRootView.swift:1-24`; `Sources/SlopDeskMacUI/Chrome/MacTitlebarBand.swift:100`; `Sources/SlopDeskSlate/SlateDesign.swift:1411` |
| Top-bar actions → `store.toggleSidebarCollapsed()` / `overlay.openSettings()` / `overlay.openPalette(...)` | **Unchanged, all three live.** | `WorkspaceStore.swift:1636`; `Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift:609`, `:276` |
| `VerticalTabRail` + `RailControlBar` + `RailRowsBuilder` + `TabIconWithStatus` | `RailControlBar` and `TabIconWithStatus` → **0 files**. `RailRowsBuilder` survived the split by moving DOWN into the shared presentation floor, so both shells build the same rows. macOS draws them with `MacNavigatorColumn` / `MacSidebarRow` / `MacStatusMark`; iOS with `NavigatorColumn`. | `Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift:95`; `Sources/SlopDeskMacUI/Columns/`; `Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift` |
| New tab → `store.newTabDefault()` | **Renamed.** `store.newTab(kind:)`. `newTabDefault` → 0 files. | `WorkspaceStore.swift:1522` |
| `SplitContainer` renders `SplitTreeRenderModel.layout(...)` as ONE absolute-rect `ZStack` of `PaneContainer`s + `PaneDivider`s | **iOS only.** The Mac's canvas is the AppKit `MacSplitCanvasView` over `MacPaneContainer`/`MacPaneDivider`. The render model itself is shared and unchanged. | `Sources/SlopDeskPhoneUI/Pane/SplitContainer.swift:55`, `PaneContainer.swift:31`, `PaneDivider.swift:40`; `Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift`; `SplitTreeRenderModel.swift:29` |
| `PaneContainer` = `PaneHeader` over `TerminalLeafView` (blocks + `CwdPill` + `InputBar`) or `RemoteWindowLeafView` | `PaneHeader`, `CwdPill`, `RemoteWindowLeafView` and an `InputBar` **view** → **0 files** each. `InputBarModel` survives as the headless text-delivery path on both platforms. `TerminalLeafView` is two types (`MacTerminalLeafView` / `TerminalLeafView`); the video leaf is `MacGuiLeafView` / `GuiLeafView`; the pill row is `MacPaneStatusPills` / `PaneStatusPills`. | `Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift:7`; `Sources/SlopDeskWorkspaceCore/Input/InputBarModel.swift:22` |
| **Divider math:** `PaneMath.weightDelta(pixelIncrement:axisSpan:flexSum:)` | **The math is identical; the owner moved and the signature shrank.** `PaneMath` → 0 files. It is `SplitDividerHandle.weightDelta(pixelIncrement:)` now — the handle already carries `parentSpan` and `flexSum`, so they stopped being parameters. Still `Δpx · flexSum / parentSpan`, still the OWNING split's span, so a nested seam still tracks the cursor 1:1. | `Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift:116`, `:124-125`, `:192`; `Sources/SlopDeskMacUI/Pane/MacPaneDivider.swift:293` |
| Divider drag → `store.resizeDividerTree(...)`; **double-click → `store.balanceActivePaneSplits()`** | Drag is right. **The double-click claim is WRONG and the code says so in as many words:** double-click evens ONLY that seam, via `store.evenDividerTree(splitID:leadingChildIndex:)` — *"never `balanceActivePaneSplits()`, which rebalances the whole tab and wipes every other divider's dragged ratio."* `balanceActivePaneSplits` still exists; it is just not what a double-click does. | `WorkspaceStore.swift:1754`, `:3173`, `:1980`; `Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift:378-384` |
| `PaneDivider` uses `@GestureState` for the drag baseline | **True on iOS only.** The Mac divider is AppKit: a ghost-seam preview with a commit-on-release step, not a gesture-state baseline. | `Sources/SlopDeskPhoneUI/Pane/PaneDivider.swift:61`; `Sources/SlopDeskMacUI/Pane/MacPaneDivider.swift:11` |

### ~~Claude bottom bar~~ — DELETED (`92472b0a`, 2026-07-03)

**The whole bullet described a bar that was pruned.** `AgentInputFooter`,
`AgentInputFooterCoordinator`, `AgentInputFooterAction`, `SuggestionPill` and `FileExplorerModel` each
return **0 files** from `grep -rl --include='*.swift' … Sources/`. So do the two pills it named by
label, `/remote-control` and Rich Input (`InputBarModel.toggleRichMode()` → 0 files). The ruling is
`92472b0a` *"refactor(prune): agent input surfaces — remove Composer, Prompt Queue, Send to Chat, and
the Fork-in actions"*; `docs/ui-shell/current-state/claude-agent.md:58` records the same finding
independently.

The one behaviour worth rescuing from the bullet, because it outlived its host: the green
"Enable … notifications" affordance recorded a per-agent flag **and** re-enabled the global OSC
delivery gate. That gate is still there and still default-ON — `SettingsKey.oscNotifications`
(`Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift:145`, default `true` at `:861`) —
reachable from Settings on both shells.

### Command palette / overlays

- **The chord is `⌘⇧P`, not `⌘K`.** The doc said ⌘K; the single catalogue says ⌘⇧P, in the action case
  (`WorkspaceBindingRegistry.swift:56`), in the registry's own summary (`:345`, `:353`) and at the
  binding row itself, which cites the spec and notes ⌘⇧P is free (`:644-648`). ⌘K appears nowhere. The
  other chords the registry names, for a reader who arrived here for one: ⌘T new tab, ⌘W close, ⌘D
  split-right, ⌘⇧D split-down, ⌃⌘+arrows focus, ⌘⇧↩ zoom, ⌘⇧]/⌘⇧[ next/prev tab, ⌘1…9 select pane,
  ⌘⇧L toggle Tabs panel, ⌃⌘T break-pane-to-tab, ⌘/ cheat sheet (`:353-354`), ⌘⇧O Open Quickly
  (`:122`, `:958-961`).
- **`OverlayCoordinator` is still the single owner** — and it moved down into `SlopDeskClientCore`, so
  both shells share one reducer (`Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift:30`).
  Its own header narrows the old claim: it owns **palette / settings / toasts** only; the busy-close
  modal is driven directly off the store's `pendingCloseSpec` (`OverlayCoordinator.swift:8-9`).
- **The view types are two apiece.** `CommandPaletteView`, `ConfirmModal` → 0 files. Live:
  `MacPalette` / `PaletteView`, `MacCloseConfirmation` / `ClipboardConfirmCard`, `MacToastStack` /
  `ToastStackView`, `MacCheatSheetPanel` / `KeyboardCheatSheetView`, `MacPaneSwitcher` /
  `PaneSwitcherOverlay`. `check-supervisor.sh:5702-5820` ratchets these pairs so one half cannot grow a
  surface the other lacks.
- **`PaletteDataSource` survived as a protocol**, not a type — the per-domain result providers plus the
  `SearchMixer` (`Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift:23`, `:39`).
- **The notification→toast bridge is no longer a one-shot flag in the root view.** `didBridgeNotifications`
  → 0 files. The composition fills the three sinks ONCE, in one shared file, because both shells were
  filling them separately and had already drifted: `Sources/SlopDeskClientCore/App/ClientNotificationSinks.swift:1-16`.

### ~~Remote window~~ — DELETED (`b7fb9c22`, 2026-07-22)

`RemoteWindowPicker` → **0 files**, and `overlay.openRemoteWindow(...)` is not a method on
`OverlayCoordinator`. The `.remoteGUI` pane kind was RETIRED: it is one of five discriminators an old
workspace file may still carry, and the decoder folds it to a plain `.terminal`
(`Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift:50`). The ruling is `b7fb9c22` *"feat(desktop)!:
remove remote-window mode; desktop-window domain groundwork"* — the pivot from per-window streaming to
**full-desktop** streaming. The live video pane is `PaneKind.desktop`, display-targeted rather than
CGWindowID-targeted (`PaneSpec.swift:41-45`), rendered by `MacGuiLeafView` / `GuiLeafView` behind the
surviving `VideoWindowFactory` (`Video/VideoWindowSeam.swift:342`).

## Keyboard / menu surface

**The old paragraph is not merely stale, it is REVERSED.** It described a hidden zero-size
`WorkspaceKeyboardBank` in `WorkspaceRootView.background` registering every chord via
`.keyboardShortcut`, with `WorkspaceChordBridge` converting `KeyChord` → `(KeyEquivalent, EventModifiers)`.
Both symbols return **0 files**, and the rule today is the opposite one:

- **macOS: one app-level `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`** owns chord dispatch —
  `Sources/SlopDeskMacUI/Input/WorkspaceKeyDispatcher.swift:1-17`. A `.keyboardShortcut` could not express
  what the table needs: a user `text:`/`csi:`/`esc:` literal-byte binding must SWALLOW its chord and inject
  bytes before libghostty's view sees it, an `unbind:` must suppress a default, and ⌘D must be claimed
  before libghostty's keymap eats it. The menu bar (`Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift:13-19`)
  therefore carries **NO `.keyboardShortcut` on any item** — a menu shortcut would double-fire alongside
  the monitor. The glyph still SHOWS on each row as a trailing `Text`, so the menu stays a faithful cheat
  sheet without binding the chord.
- **iOS: two responder rungs.** `TerminalInputHost` (the focused pane's responder) and
  `PhoneRootKeyResponder` (the chain's LAST responder, mounted on the app delegate because it must be an
  ancestor of every possible first responder) —
  `Sources/SlopDeskPhoneUI/Pane/PhoneRootKeyResponder.swift:1-14`. Between them the phone answers ⌘⇧P,
  ⌘T, ⌘D, ⌘1–9, ⌃⇥ and ⌘⇧O wherever the keyboard happens to be.
- **The `KeyChord` normalization is shared and headless** — `Sources/SlopDeskClientCore/Input/KeyChordNormalizer.swift`,
  AppKit-free so it is unit-tested without a window server.

Two invariants from the old paragraph DID survive, and are worth keeping:

- **One catalogue, so a glyph cannot drift.** The menu, the ⌘⇧P palette, the ⌘/ cheat sheet and the
  routing tests all read the one `bindings` table (`WorkspaceBindingRegistry.swift:344-348`).
- **Every chord is ⌘- or ⌥-prefixed**, so a bare key or a Ctrl-letter falls through to the focused
  terminal; no two bindings share a chord. Both pinned by `TreeCommandRoutingTests`
  (`WorkspaceBindingRegistry.swift:349-352`).

New since the split, and not in the old text: the shipped table is `declared` **filtered by platform**,
and the platform list is data owned by Rust (`slopdesk_workspace::binding_rows`), read through
`BindingRowPlatform` — `WorkspaceBindingRegistry.swift:357`, `:364`;
`Sources/SlopDeskWorkspaceCore/Workspace/Domain/BindingRowPlatform.swift:24`.

## Env seams honored

Verified unchanged — keep these names stable: `SLOPDESK_AUTOCONNECT_*` / `SLOPDESK_VIDEO_AUTOCONNECT_*`
(auto-connect + front-on-autoconnect; the video variant does still boot the DETACHED, display-targeted
desktop window, and video takes precedence over the plain terminal target) and
`SLOPDESK_SKIP_AUTO_RECONNECT`. Notification delivery is gated by `SettingsKey.oscNotifications`,
default-ON.

- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift:17-22` (the three-way
  bootstrap), `:56-64` (the video target's ports + window id)
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift:145`, `:861`

Two corrections to how this section pointed elsewhere:

- **"The app scene" is two scenes now** — `Sources/SlopDeskMacUI/SlopDeskMacApp.swift` and
  `Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift`. Neither reads the env directly: the composition root
  does, once, for both (`Sources/SlopDeskClientCore/App/ClientComposition.swift:1-12`, `:497`).
- **The full flag table is NOT in `CLAUDE.md` any more.** `grep -n 'Runtime env flags' CLAUDE.md`
  returns nothing; `CLAUDE.md`'s read-first table sends `SLOPDESK_*` to
  **`docs/46-gates-env-paths.md`**.

## ~~Headless ImageRenderer odiff harness~~ — the odiff half is gone; the rigs are not

**There is no odiff anywhere in the tree.** `grep -rn odiff` over `*.sh` / `Makefile` / `*.swift`
returns four hits, all of them comments in `Sources/SlopDeskMacUI/SlopDeskMacApp*.swift` naming a
"odiff reference geometry" a window restore avoids — no invocation, no `/opt/homebrew/bin/odiff`
dependency, no `warp-shots` directory (0 files), no `FullWindowSnapshotOdiffTests` (0 files). The
`≈ 3.64%` full-window figure and the per-component L2–L6 numbers are dead: they measured a diff against
a live-Warp screenshot, and there has been no Warp reference to diff against since `657a8f44`.

What replaced it is **two opt-in visual-verification rigs, and neither is a pixel-diff gate.** Both are
INERT under `swift test` / `make check` unless their env var is set, and both write PNGs a human or an
agent then READS:

- **Phone** — `Apps/ClientApp-iOS/Tests/SlateSnapshotRender.swift:1-8`. `ImageRenderer` over a
  hand-built mock of the real chrome from the same token layer. Gated on `SLOPDESK_SNAPSHOT_OUT`;
  run via `SIMCTL_CHILD_SLOPDESK_SNAPSHOT_OUT=… bash scripts/check-ios-tests.sh`.
- **Mac** — `Tests/SlopDeskMacUITests/MacChromeSnapshotRender.swift:1-22` and
  `MacRailStatusRollupRender.swift`. These mount the **real `NSView`s** (`MacSidebarRowView`,
  `MacNavigatorColumn`, `MacConnectionIsland`, `MacTitlebarBand`) and seed every state through the
  store, so what is photographed is what ships. Gated on `SLOPDESK_TABROW_SNAPSHOT_DIR`; run via
  `SLOPDESK_TABROW_SNAPSHOT_DIR=… swift test --filter MacChromeSnapshotRender`.

**The ground changed, and it is load-bearing.** The old text said the render stood on the `#1D2022`
theme base at scale 1.0. Both rigs now stand on `Slate.Surface.field` / `Slate.Native.Surface.field` —
the authored cream `#FFFBEB` (ONE ISLAND law 4) — and the Mac rig pins the layer tree to **@2x**. Both
files carry a ⚠️ banner explaining why: they used to render on `Surface.ground`, a semantic system grey
that appears nowhere in the shipping chrome, which voided the one job the harness has. If a future
render comes out grey, that is the line it crossed
(`SlateSnapshotRender.swift:18-25`, `MacChromeSnapshotRender.swift:23-32`).

Two sibling gates, re-verified:

- **Live GUI proof** (real Aqua + TCC, isolated `HOME`/`CFFIXED_USER_HOME`) is `scripts/check-macos.sh`.
  The old text's ":7799" is wrong — the `--connect` e2e host daemon binds `127.0.0.1:47420`
  (`scripts/check-macos.sh:52`, `:74`, `:314`).
- **The text-only design-system ratchet** is the `design-token-leaks` rule in
  `rust/slopdesk-invariants` (`src/rules/design_ratchets.rs`, ported from the `check-ds-leaks.sh` that
  used to hold it), and its target moved with the split: it guards `Sources/SlopDeskPhoneUI` against a
  raw font-size, corner-radius or fixed-height literal bypassing the `Slate.*` scale. It is not
  "repointed at the rebuilt overlay surfaces" — that phrasing predates the token layer's third life.
