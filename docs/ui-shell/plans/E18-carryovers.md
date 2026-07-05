# E18 carry-over directives (REQUIRED — fold into the E18 plan)

E18 (External drag-drop + tab reorder + web pane) inherits **no behavioral fix from E14** — E14
(Progress/notifications/privilege) closed all findings (base `daecb46` → polish `9ef8862`, all
`stillBroken:false`). This file carries what makes E18 a verify-first, reuse-heavy, mostly client-side
epic: (1) the VERIFY-NOT-REBUILD warning (tab reorder already built in E6); (2) the reuse-map for the
two new surfaces (external drop + web pane); (3) the headless/hang-safety rule for the WKWebView pane;
(4) the wire posture (default NO change); (5) the drag-drop/split/web traps.

## VERIFY-NOT-REBUILD (the headline — read current state before writing)

**Tab reorder is ALREADY BUILT in E6 — do NOT rebuild it.** The backlog's "Tab reorder manual drag
(shares E6 sort=Manual)" is largely SATISFIED:
- `Sources/SlopDeskClientUI/Columns/NavigatorColumn.swift:103` `handleTabDrop` + `:121`
  `.dropDestination(for: String.self)` = the live rail drag-reorder source + drop target.
- Routes → `WorkspaceStore.moveTab(from:to:)` / `moveTabRendered(from:to:)`
  (`Workspace/Store/WorkspaceStore+TabOrdering.swift:38/54`, both call `setTabSort(.manual)`) →
  pure `WorkspaceTreeOps.moveTab(from:to:in:)` / `moveTab(renderedOrder:from:to:in:)`
  (`Workspace/Domain/Tree/WorkspaceTreeOps+MoveTab.swift:16/51`).
- E6 polish2 already made the drag carry **tab IDENTITY (uuid), not rendered index** (a mid-drag
  `.updated` reshuffle still moves the dragged tab; foreign drops rejected; drag gated during search);
  `SlateTabRow.swift:162` exposes the Manual sort row.

→ E18 design MUST read the current rail-drag impl and only fill GENUINE gaps (drop-position indicator,
cross-section drag affordance) — do NOT re-implement `moveTab`/the rail drag. **(E9 lesson: the
current-state map can LIE — Git/Files were already fully built there. Grep + read before claiming a
surface is missing.)** If tab-reorder is already acceptance-complete, say so and spend the budget on
the two new surfaces.

## REUSE-FIRST seam map — the two GENUINELY-NEW surfaces

### A) External drag-drop overlay (NEW — only `.fileImporter` exists today)
NO `NSDraggingDestination` / file-`onDrop` / `NSItemProvider` external-drop path exists (only
`Settings/WorkspaceTransferDocument.swift` `.fileImporter`). Build the circular drop-zone overlay
(New-Tab / Insert-Path / Open-In-Place / Split-L / Split-R) NEW, but reuse the actuators:
- **Split-L / Split-R** → existing split machinery: `Chrome/SlateTitlebar.swift:177 split(_ axis:)`,
  `WorkspaceRootView.swift WorkspaceSplitRepresentable` (NSViewControllerRepresentable),
  `App/SlopDeskSplitViewController.swift`. Do NOT build a second split path.
- **New-Tab** → the existing new-tab op (same one ⌘T drives); honour New-Tab-Position + cwd-inherit
  (E3) when the drop creates a tab.
- **Insert-Path** (inject dropped path to PTY) and **folder→`cd`** → the SINGLE client→host ingress
  `Terminal/TerminalViewModel.swift:1098 sendInput(_ data:)`, as **VERBATIM literal UTF-8 — NEVER
  `SendKeysParser`** (the standing injection trap; cf. `BlockReRunEncoder` E11). For folder→cd reuse
  E10's cd-parent-helper in `Workspace/Domain/LinkActionPolicy.swift` (the
  `cd 'X' 2>/dev/null || cd '<parent>'\n` idiom) so a dropped FILE cd's to its parent, not errors.
- **Text-snippet inject** → `Workspace/Domain/Snippet.swift SnippetExpander.expand(...)`.
- **Open-In-Place** (open dropped file on host) → E10 already added side-effecting
  `MetadataVerb.openPath = 9` / `revealPath = 10` on E4's metadata channel — REUSE them; do NOT invent
  a new wire message for open/reveal.

**Honest host-resolution.** Dropped paths come from the LOCAL Finder drag; on a REMOTE host they may
not resolve. Inject verbatim regardless (optionally with an advisory toast) — do NOT block the drop.
For a host-side path-exists check, REUSE E4's metadata channel (a stat-style verb) — do NOT add a
fresh wire message.

### B) Web pane (NEW `PaneKind.web` + WKWebView)
`PaneKind` (`Workspace/Domain/PaneSpec.swift:48`) has terminal / remoteGUI / systemDialog / chooser —
NO `.web`. Unlike GUI-pane work that REUSED `.remoteGUI`, a web pane is genuinely NEW: add `case web`.
Use a **non-persistent** store: `WKWebsiteDataStore.nonPersistent()` (D9, no on-disk cookies/cache).
No `WKWebView`/`import WebKit` anywhere yet.

**HEADLESS / HANG-SAFETY (binding).** WKWebView is a GUI/WebKit component — same family as
`SCStream`/`VTCompression…`/Metal/a real `NSWindow`: **never instantiate it in a test, never in a
headless build.** Put it behind a SEAM exactly like the libghostty terminal renderer
(`TerminalRenderingView` / `TerminalRendererFactory` in `SlopDeskClientUI`): WKWebView compiled ONLY
inside the Xcode app target; the headless `swift build`/`swift test` slice renders a placeholder (the
`BuildStatusPlaceholderView` pattern). The PURE parts ARE testable and MUST be tested: URL
validation/normalization (validate-then-drop a malformed/non-http(s) URL, never force-unwrap), the
`PaneKind.web` plumbing/persistence (schema-version decode-fail-to-default), and drop-zone hit-test
geometry. WKWebView exists on iOS too (UIKit) — the seam serves both platforms.

## WIRE posture — default NO change

E18 is **client-side**: drops inject verbatim through the existing input seam; the web pane is local;
Open-In-Place reuses E10's verbs 9/10. So **set `touchesWire:false`** and `golden-check.sh` must show
the **33 emitted keys byte-identical + 13 frozen intact** (zero drift). The ONLY wire-touching
candidate is an optional host path-stat for the folder→cd warning — and it must REUSE E4's metadata
channel, not a new message. If a new message is truly unavoidable, apply the full type-32/`inputEcho`
golden discipline (hand-edit keeping the 13 frozen keys, docs/20 + DECISIONS, redeploy-together,
validate-then-drop). Default: no new wire.

## iOS — shared ClientUI, RUN check-ios.sh

- `NSDraggingDestination` / `NSItemProvider` are **AppKit/macOS-only** — gate macOS drag code
  `#if os(macOS)`. Prefer SwiftUI's cross-platform `.dropDestination(for:)` / `.onDrop(of:)` where it
  covers `.fileURL`/`.url`/`.text` on both platforms; otherwise provide the iOS drop via
  `UIDropInteraction`, or **document iOS external-drop as deferred + no-op** (honesty discipline — do
  not ship a dead iOS affordance).
- The web pane seam + `PaneKind.web` live in shared `SlopDeskWorkspaceCore`/`SlopDeskClientUI`.
- **`swift build` on macOS will NOT catch iOS rot → the gate MUST run `bash scripts/check-ios.sh`.**

## TRAPS specific to E18 (respect these)

- **Subclassing `NSSplitView` via `loadView()` CRASHES `_setupSplitView`** — observe
  `didResizeSubviewsNotification` instead (already done at `SlopDeskSplitViewController.swift:165` —
  do NOT regress when adding Split-L/R drop targets).
- **Drop-zone overlay hit-testing: `.contentShape` BEFORE `.position`** (HW-GUI-debug-loop lesson) so
  circular zones hit-test where drawn, not at their pre-offset origin.
- **Drag carries tab IDENTITY (uuid), not rendered index** — reuse E6's by-uuid drag; a mid-drag
  `.updated` reshuffle must still move the dragged tab. Do not regress to index-based.
- **Validate-then-drop on every drop** — unsupported UTType, foreign/empty payload, or malformed URL
  returns `false` and is dropped WITHOUT a crash; validate declared counts/lengths before allocating;
  never force-unwrap drop payload bytes.
- **Commit-on-`.onEnded`** for the drag gesture (divider memory); **drag gated during search** (E6).
- **No app-layer crypto/tokens**; the web pane is a non-persistent local view, not an auth surface.

## SCOPE (binding)

- **Tear-off into a new window is DEFERRED** (backlog) — do not build it.
- Horizontal tab-bar layout is **E19's** concern and is itself a DROPPED scope reduction
  (vertical-tabs-only) — NOTHING horizontal-tab here.

## Visual fidelity standard

`spec/user-interface__drag-and-drop.md` (circular drop-zone layout + five zones = the visual standard)
+ `spec/user-interface__files-and-links.md` are the prose standard; match any drag-drop screenshots
under `screenshots/`. ES-E18-1…ES-E18-4 are the acceptance stories. Any GUI-only fidelity (live
circular-zone overlay rendering, web pane chrome) that is headless-unprovable is a **Phase-3
HW-fidelity target** — flag it, don't fake a pixel proof.
