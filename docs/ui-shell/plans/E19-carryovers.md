# E19 carry-over directives (REQUIRED — fold into the E19 plan)

E19 (Window options — pin · size modes · multi-session UI) inherits **no behavioral fix from E18**
(E18 closed all findings, base→finish `3c608fc`, all `stillBroken:false`). Carry-overs making E19 a
verify-first, reuse-heavy, fully client-side epic: (1) **scope reduction** (horizontal tab bar DROPPED);
(2) **verify-not-rebuild** (multi-session domain already built); (3) **reuse-map** for the new surfaces
(pin, window-size, session switcher); (4) **wire**: NO change; (5) **traps**.

## SCOPE REDUCTION (binding, user 2026-06-26) — DROP the horizontal tab bar

**`ES-E19-4` is DROPPED in full. Do NOT build it.** Its story — "switch to a horizontal (top/bottom)
tab-bar layout with auto-hide-tab-bar" — contradicts slopdesk being **vertical-tabs-only** by product
decision (E7-close commit `f3ea994`). Concretely:
- **NO** `layout` setting / Layout selector (Vertical Tabs / Tabs Top / Tabs Bottom).
- **NO** horizontal tab-bar view, **NO** `auto-hide-tab-bar` policy (the horizontal-bar one).
- The E7 `AppearanceSettingsTab` body carries a load-bearing PRODUCT-DECISION comment
  (`SettingsView.swift` ~line 1187) pinning vertical-tabs-only and explaining the absent layout selector
  is intentional, NOT a gap. **Keep that pin verbatim** — a reviewer must read the missing
  horizontal-layout option as deliberate. (You WILL edit the *adjacent* part of that comment — see
  A29/A18 — but the vertical-tabs-only pin must survive.)
- SSH-host filter is **N/A** to E19 (that was an E11 reduction; nothing SSH here).

So E19 = **A29 (window-size) + A30 (pin) + A31 (PiP substitute = pin) + A32 (multi-session switcher) +
A18 (vertical-sidebar auto-hide only)** — nothing horizontal.

## VERIFY-NOT-REBUILD (headline — read current state before writing)

**The multi-session DOMAIN is already fully built — do NOT rebuild it (E9 stale-map lesson).** Confirmed:
- `WorkspaceStore.selectSession(_:)` / `renameSession(_:to:)` / `closeSession(_:)` exist
  (`Workspace/Store/WorkspaceStore.swift` ~2721/2727/2780) → pure `WorkspaceTreeOps.selectSession` /
  `renameSession` / `closeSession`; `TreeWorkspace(sessions:[Session], activeSessionID:)` is the model.
- The GENUINE gap for **ES-E19-3 (A32)** is the VIEW: `NavigatorColumn` renders ONLY
  `store.tree.activeSession` (`Columns/NavigatorColumn.swift:318` `if let session = store.tree.activeSession`).
  Build a **session list / switcher** in the sidebar enumerating `store.tree.sessions`, showing the
  active one, calling the EXISTING `selectSession` on tap (rename→`renameSession`, close→`closeSession`).
  Do **not** invent new session ops. Match the sidebar session affordance in `screenshots/` +
  `spec/user-interface__window-tab-split.md`.

## REUSE-FIRST seam map — the genuinely-new surfaces

### A30 Pin Window / always-on-top (NEW — macOS only)
No `NSWindow.level = .floating` path exists today. Build on the EXISTING sanctioned NSWindow reach,
**never** `NSApplication.windows`:
- The scene exposes `.introspect(.window, on: .macOS(.v14,.v15,.v26)) { window in … }`
  (`SlopDeskClientApp.swift:499`) — the comment at `:21`/`:497` declares this the ONLY blessed
  WindowGroup-level NSWindow hook. Set `window.level = pinned ? .floating : .normal` there, driven by a
  store/chrome flag; guard for idempotency (the introspect callback re-fires — mirror the close-gate).
- **View → Pin Window** menu item: `Commands/WorkspaceCommands.swift` builds one `CommandMenu` per
  binding-category from `WorkspaceBindingRegistry`. Add a Pin action/binding as a View-menu
  discoverability item. **MENU-SHORTCUTLESS RULE (CI-gated):** `WorkspaceCommands.swift` carries NO
  `.keyboardShortcut` — Pin Window has no default chord anyway, so a menu Button suffices; for a chord,
  wire it focus-scoped locally (NOT in the global menu).
- macOS-only: `#if os(macOS)` the whole `.level` path; iOS has no floating-window concept (no-op).

### A31 Picture-in-Picture substitute → collapses into A30
PiP is `na-remote` (a pane is a UDP HEVC stream / a libghostty surface, not a compositable PiP layer).
The client is single-window, so the **"always-on-top of the active pane" substitute IS Pin Window
(A30)** — do NOT spin up a second floating `NSWindow` per pane (needs a second terminal/video surface =
expensive, and there is no second-window scene). **Document true PiP + per-pane float-window as
DEFERRED** — do not ship a dead "PiP" menu. The in-app `tab.floatingPanes` / `spec.floatingFrame` infra
(in `PaneSpec`/`WorkspaceTreeOps`/`SplitTreeRenderModel`) is *in-workspace* pane-float, unrelated to
window-level pin — don't conflate.

### A29 window-size modes — BACK the E7-deferred rows (NEW — macOS only)
`window-size` = `remember` (default) / `grid` (`window-cols`×`window-rows`, def 80×24) / `frame`
(`window-width-px`×`window-height-px`, def 1000×600). Today the scene hard-codes
`.defaultSize(width:1280,height:800)` with **no `setFrameAutosaveName`** anywhere — genuinely new
client-window sizing:
- E7 **deliberately OMITTED** the "Window Size" picker (and the "Auto Hide Tabs Panel" row) as
  *deferred-until-backed* (E7 comment `SettingsView.swift` ~1192–1199: "omit the controls rather than
  ship dead UI"). E19 backs them, so **you MUST update that comment** — rewrite only the stale
  "deferred-until-backed" sentence; leave the vertical-tabs-only pin intact.
- New `SettingsKey`/`@Default` keys: `window-size` enum + `window-cols`/`window-rows` (Int) +
  `window-width-px`/`window-height-px` (Int), defaults 80×24 / 1000×600. Schema-version
  decode-fail-to-default per [[rwork-no-backcompat]].
- Apply via the SAME `.introspect(.window)` hook: `remember` → `window.setFrameAutosaveName(...)`;
  `grid` → compute px from cols×rows × live cell metrics, `window.setContentSize`; `frame` →
  `setContentSize(width×height px)`. Apply **once per window open** (idempotent guard) so a later manual
  resize isn't fought every render.
- **The cols×rows→pixels math (cell size + chrome insets, clamped to visible screen) MUST be a PURE
  function, unit-tested** — mirror `SlopDeskVideoHost/WindowPlacementMath.placement(...)` (clamps a size
  into display bounds with ordered-comparison / no-FMA idioms). The NSWindow
  `setContentSize`/`setFrameAutosaveName` glue is the only app-target part (hang-safety: never
  instantiate an `NSWindow` in a test).

### A18 vertical-sidebar auto-hide (`auto-hide-tabs-panel`) — IN SCOPE (NOT the dropped horizontal one)
The VERTICAL sidebar's single-tab auto-hide (`default` no-auto-hide / `always` shown / `auto`
hidden-when-one-tab) — vertical-tabs-compatible, so it survives the scope reduction. Reuse the existing
collapse machinery: `WorkspaceChromeState.toggleSidebar()` / `sidebarCollapsed`
(`App/WorkspaceChromeState.swift:23`), already wired to ⌘⇧L via `chrome.toggleSidebar`
(`WorkspaceRootView.swift:224`/`WorkspaceKeyDispatcher`). Add only the POLICY: on active-session
tab-count transition to/from 1, drive `sidebarCollapsed` when mode==`auto`. Keep it a pure policy
function (tab count + mode → desired collapsed) for headless testability; do NOT fight a manual ⌘⇧L
override (`auto` is a default state, not a lock).

## WIRE posture — NO change

E19 is **entirely client-side**: NSWindow.level, client-window sizing, sidebar auto-hide, session
switcher (`selectSession` exists). **Set `touchesWire:false`**; the gate's `golden-check.sh` MUST show
**33 emitted keys byte-identical + 13 frozen intact** (zero drift). No host round-trip for any E19
feature; do not add a wire message.

## iOS — shared ClientUI, RUN check-ios.sh

- Pin Window / window-size / always-on-top are **macOS NSWindow** concepts → `#if os(macOS)` gate them;
  iOS has no resizable/floating window (no-op, documented — no dead iOS toggle).
- The **multi-session switcher** IS relevant on iPad — session-list view + `selectSession` are shared
  `SlopDeskClientUI`/`SlopDeskWorkspaceCore`; ensure the switcher renders on iOS.
- `auto-hide-tabs-panel` policy is shared (sidebar exists on both).
- **`swift build` on macOS will NOT catch iOS rot → the gate MUST run `bash scripts/check-ios.sh`.**

## TRAPS specific to E19 (respect these)

- **NSWindow reach ONLY via the existing `.introspect(.window)` hook** — never `NSApplication.windows`
  (forbidden by the scene comment at `SlopDeskClientApp.swift:21`). Make every introspect callback
  idempotent (it re-fires) — follow the close-gate's `!isKeyWindow`-style guard.
- **Do NOT regress the E7 vertical-tabs-only product-decision comment** in `AppearanceSettingsTab` —
  rewrite only the stale "Window Size / Auto Hide Tabs Panel are deferred-until-backed" sentence (now
  backed); keep the "no horizontal layout selector — intentional" pin verbatim.
- **window-size math is a PURE, unit-tested function** (cols×rows×cell → clamped px), mirroring
  `WindowPlacementMath`; apply `setContentSize` **once per window open** (idempotent), never per render.
- **Validate-then-drop on size settings** — clamp `window-cols`/`window-rows`/`window-width-px`/
  `window-height-px` to sane bounds (≥1 col/row, ≤ screen); never force a 0×0 or off-screen-gigantic
  window; never force-unwrap a decoded setting.
- **Multi-session switcher reuses `selectSession`/`renameSession`/`closeSession`** — do NOT rebuild the
  session ops; render ALL `store.tree.sessions` without breaking the existing active-session tab list in
  `NavigatorColumn`.
- **Hang-safety:** never instantiate an `NSWindow` in a test — keep testable logic (pin flag, size math,
  auto-hide policy) store/pure-side; NSWindow glue is app-target-only, compiled+code-reviewed, not
  unit-tested.
- **No app-layer crypto/tokens**; pin/size/switcher are local view state.

## Fidelity standard

`spec/user-interface__window-tab-split.md` (Window section: Pin Window, PiP modes, `window-size`
remember/grid/frame) + the sidebar session affordance in `screenshots/` are the prose+visual standard.
Acceptance stories: ES-E19-1 (pin floats above other apps), ES-E19-2 (grid/frame/remember sizing),
ES-E19-3 (session list/switcher); **ES-E19-4 (horizontal tab bar) is DROPPED — mark it explicitly
out-of-scope, not unmet.** GUI-only fidelity (pin actually floating above other apps, live
session-switcher rendering, exact grid/frame pixel sizing) is headless-unprovable → a **Phase-3
HW-fidelity target** — flag it, don't fake a pixel proof.
