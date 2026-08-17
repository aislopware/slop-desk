# 56 — The client UI splits in two: AppKit on macOS, SwiftUI on iOS

> Read with [`DESIGN.md`](../DESIGN.md) (the visual language, unchanged by this split) and
> [`22-workspace-architecture.md`](22-workspace-architecture.md) (the store the two halves share).

`SlopDeskClientUI` was ONE SwiftUI target serving two products that have almost nothing in common.
This doc records the measurement that ended it, the two targets that replace it, and the boundary
that keeps them from growing back together.

## 1. The measurement

Taken on the tree at `287a3ba4`, over `Sources/SlopDeskClientUI` (183 files, 48 410 lines):

| | files | lines the compiler keeps |
| --- | --- | --- |
| whole target | 183 | 48 410 raw |
| macOS slice | 111 gated `#if os(macOS)` | 27 037 |
| iOS slice | 10 gated `#if os(iOS)` | 16 840 |
| compiles to NOTHING on iOS | 72 | — |

So the "shared" target was already two targets wearing one coat: 72 of its 183 files vanish on iOS,
and the halves overlap by far less than the file count suggests. Worse, the overlap that *does*
exist is mostly accidental — `CodeSidebarRecommendationTips` (838 lines), `WorkspaceControlBackend`
(308), `PaneDragCoordinator` (246) and `ClientControlServer` (171) all compile into the iOS app for
a code panel, a control socket and a pane-drag gesture that iOS does not have and will not get.

Two more facts decided the framework question for the macOS half:

- **The escape hatch is the norm, not the exception.** 53 files already `import AppKit`, with 19
  `NSView`/`NSViewController` subclasses, 13 `NSViewRepresentable`, 4 `NSViewControllerRepresentable`,
  21 `NSHostingView`/`NSHostingController` mount points and **32 `swiftui-introspect` call sites** —
  each one a place SwiftUI did not expose what the workspace needed. Every hard interaction in this
  app has already fallen out of SwiftUI and landed in AppKit: the divider drag
  (`FlatDividerSplitView`), the rail drag-and-drop (`HostWindowRowDragSource` +
  `HostWindowDropCatcher`, AppKit end-to-end after both SwiftUI DnD sides failed), the satellite
  windows (`SatellitePaneWindowController`, "NEVER a second SwiftUI `WindowGroup`"), and the split
  shell itself — the 2026-07-03 "Shell = pure SwiftUI `NavigationSplitView`" ruling was reverted in
  practice, and macOS runs `SlopDeskSplitViewController` today.
- **SwiftUI's development-speed argument is not being collected.** `grep '#Preview\|PreviewProvider'`
  over `Sources/` and `Tests/` returns **0**. The design loop here is pixel-verify against a
  screenshot (see the `build-verify` recipes), which AppKit runs identically.

And the usual reason not to rewrite a view layer does not apply: of 114 `SlopDeskClientUITests`
files (21 558 lines) only **11** import SwiftUI and **4** touch a `body`. The logic already lives
outside the views — that is the "pure decision + actuator" split this repo has been applying for a
year — so the suite survives a view-layer rewrite nearly intact.

## 2. The two targets

```
Sources/SlopDeskWorkspaceCore    pure logic, no view framework   — BOTH
Sources/SlopDeskWorkspaceModel   value types                     — BOTH
Sources/SlopDeskMacUI            AppKit + Metal + CoreAnimation  — macOS only
Sources/SlopDeskPhoneUI          SwiftUI                         — iOS only
```

`Apps/ClientApp-macOS` links `SlopDeskMacUI`; `Apps/ClientApp-iOS` links `SlopDeskPhoneUI`. Neither
app links the other's UI target, and `Apps/Shared/AppMain.swift` — the last file that pretended one
`@main` could serve both — forks into a per-app entry point.

**macOS = AppKit.** `NSWindow`, `NSSplitViewController`, `NSView` subclasses, `CALayer`,
`NSCollectionView`/`NSOutlineView` where a list is a list. Motion is CoreAnimation, not
`withAnimation` — the 118 `withAnimation`/`.animation(` sites and the 3 `matchedGeometryEffect`
morphs are the real work of the port, and they land as explicit `CAAnimation`/`NSAnimationContext`
so the pixel-verify loop measures what the code says.

**iOS = SwiftUI, and deliberately less app.** A phone is one pane, a keyboard and a way back to the
session list. The iOS half does NOT get: the code panel, the simulator panel, the Android panel,
satellite windows, floating panes, pane drag-and-drop, the pane switcher, hint mode, the control
socket, or four separate search overlays. It gets: connect, sessions/tabs, one terminal (or one
remote-GUI pane), find, settings, toasts.

## 3. The boundary

- **A view type never crosses.** `SlopDeskMacUI` and `SlopDeskPhoneUI` do not import each other and
  have no common view ancestor. If both halves want the same behaviour, the *decision* moves down
  into `SlopDeskWorkspaceCore` as a pure function and each half actuates it in its own framework.
  This is the same seam the store already uses; it is not a new idea, only a new place to apply it.
- **No `#if os(...)` inside either UI target.** A platform gate in a platform-specific target is a
  sign the file is in the wrong target. `make lint-supervisor` ratchets this.
- **Divergence is the point.** These are not two renderings of one design; they are two products
  against one host. A feature landing on macOS creates no obligation on iOS, and the reverse.

## 4. What moves to Rust

The split makes a second question answerable: with the view layer split by platform, everything left
that is neither AppKit nor SwiftUI is pure logic, and this repo's standing rule is that pure logic is
Rust (`CLAUDE.md`: "Rust is the default; perf parity is enough to move existing Swift. Only
SwiftUI/AppKit justifies staying in Swift"). The port list and its order live in §5 of this doc as
each stage lands.
