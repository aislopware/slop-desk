# E21 — Remote-window extension first-class through all UI-shell surfaces — CARRY-OVERS

> Read this in full before planning E21. Every item below is an **additional acceptance criterion** (or a **hard exclusion**) on top of the BACKLOG `## E21` section and `ES-E21-1…4` in `USER-STORIES.md`.

## 0. What E21 IS — and what it is NOT (read first)

E21 is the **user's headline feature**: the slopdesk-native *remote-window* (a `.remoteGUI` pane streaming a real host window over the UDP video path) must flow through **every UI-shell surface built in E1–E20 as a first-class peer of a terminal pane** — no surface may silently special-case it out.

**This is slopdesk-original — there is no reference screenshot for it** (the BACKLOG `specRefs` is empty by design). So:

- The **visual/behavioral standard is the EXISTING slopdesk UI-shell surfaces**, not a reference screenshot. A `.remoteGUI` pane must look and behave like a peer *within* the already-shipped E6 sidebar rows, E10 status bar, E11 Open-Quickly picker, E18 drop zones, the split/zoom container, and the floating-pane layer. Read `spec/user-interface__window-tab-split.md` and `spec/user-interface__open-quickly.md` only for the surrounding surface conventions — do **not** expect a remote-window mock to compare against.
- Because the standard is "matches the terminal-pane peer," the cheapest correct implementation usually routes `.remoteGUI` through the **same generic `PaneSpec.kind` path** the terminal pane already uses, rather than adding a parallel branch. Prefer that.

**E21 is overwhelmingly VERIFY-NOT-REBUILD.** Most of the machinery already exists (see §1). The E9/E18 lesson applies in force here: the BACKLOG scope was written in Phase 1 and **describes gaps that later epics already closed**. The design phase's FIRST job is a **current-state audit** of `.remoteGUI` participation per surface (§2) — then build ONLY the genuine gaps. Do not rebuild working code.

## 1. Reuse-map — existing infra (AUDIT each; do not rebuild)

Confirmed present on disk (`grep`-grounded 2026-06-28). Read each before planning against it (symbols can drift):

- **`PaneKind.remoteGUI`** — `Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSpec.swift:52`. Plumbed across ~30 files already.
- **Picker + connect overlay = ALREADY MOUNTED** — `Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift:52` `ConnectHostView`, `:56` `RemoteWindowPickerModal` (both ride E2's `OverlayCoordinator`/`OverlayHostView` mount). So **ES-E21-1's "open from the workspace" is largely DONE** — audit it end-to-end (does selecting a window actually create a `.remoteGUI` pane?), don't re-mount.
- **Picker domain/view** — `RemoteWindowPickerView.swift`, `RemoteWindowPickerModal.swift`, `RemoteWindowModel.swift`, `WorkspaceStore+RemoteWindow.swift`. Over-wire window discovery already uses **VideoControl types 7/8** (see memory `slopdesk-remote-window-picker`) — these EXIST; do not invent a new discovery channel.
- **Render path (app-target/runtime only)** — `GuiLeafView.swift`, `PaneContainer.swift` (`.remoteGUI` case), `Video/RemoteGUIDisplay.swift`, `Video/VideoWindowSeam.swift`, `Video/WindowRebind.swift`. This is the **hang-safety-sensitive** code (SCStream/VTDecompression/Metal family) — see §3.
- **Sidebar rows / badges (E6)** — `Rail/RailRowsBuilder.swift`, `Chrome/TabBadgeView.swift`, `Workspace/Tabs/TabBadge.swift`. These are **kind-generic** (driven by `PaneSpec`); a `.remoteGUI` pane probably already gets a row — audit icon/subtitle/status-dot correctness, not existence.
- **Status bar (E10)** — `Terminal/StatusBarModel.swift` (already has 1 `.remoteGUI` ref — partial).
- **Read-only gate (E17)** — `WorkspaceStore+ReadOnly.swift` (2 `.remoteGUI` refs). **CRITICAL nuance in §2.7.**
- **Drag-drop (E18)** — `Workspace/Domain/Drop/DropActionResolver.swift` (no `.remoteGUI` ref — audit).
- **Floating panes** — DECISIONS.md:151 declares floating panes already shipped (`PaneSpec.floatingFrame` additive v11, a `FloatingPaneView` card, pure `WorkspaceTreeOps` toggle/spawn/move/resize/raise + clamp, ⌘⇧F / ⌃⌘F chords, no-teardown invariant). **AUDIT whether this is real and whether a `.remoteGUI` pane can be floated.** The BACKLOG's "floating-pane renderer in SplitContainer (covers the gap that also blocks composer-pin/float)" was very likely **already closed** by that work — if so, E21's float scope shrinks to "ensure a remote-window pane participates in the existing float machinery." (If `FloatingPaneView` is NOT actually on disk, that's the one genuine net-new render piece — but verify first.)
- **Open-Quickly (E11)** — `OpenQuicklyModel` + `OpenQuicklyView`. **No `.remoteGUI` ref found → genuine gap** (Opened results don't include remote-window panes).
- **Palette (E2/E11)** — `Palette/PaletteDataSource.swift`, `Palette/PaletteModel.swift` already reference `.remoteGUI` (partial — audit completeness).
- **Zoom** — out-of-tree render-only `Tab.zoomedPane` (DECISIONS §redesign); siblings stay mounted at opacity 0 (no surface rebuild). Audit `.remoteGUI` zoom.

## 2. The gap list to AUDIT then fill (per acceptance story)

For ES-E21-4 ("every surface treats `.remoteGUI` as a first-class peer; no special-casing that drops it"), the design must produce a **surface-by-surface audit table** {surface, currentState, gap, plannedChange, reuseTarget} and make each surface pass. Likely-genuine gaps, in priority order:

1. **Open-Quickly participation (ES-E21-2)** — `.remoteGUI` panes must appear in Open-Quickly "Opened" (and "All") results, selectable to switch/focus, like a terminal pane. Currently absent. Reuse the existing `OpenQuicklyModel` "Opened = WorkspaceStore panes" source — the fix is almost certainly *removing a terminal-only filter*, not new UI.
2. **Floating a remote-window pane (ES-E21-3)** — a `.remoteGUI` pane can be made floating and renders as a draggable/resizable card in the split container. Audit the existing float machinery (DECISIONS.md:151) first; wire `.remoteGUI` into it (Float ⌘⇧F / Pane-menu) honoring the **one-surface / no-teardown** invariants. Do **not** rebuild a float renderer if `FloatingPaneView` already exists.
3. **Read-only gate covers the remote-window INPUT ingress (ES-E21-2)** — **the subtle correctness item.** E17's read-only gate sits at `TerminalViewModel.sendInput` (keys/paste/IME funnel through there). But a `.remoteGUI` pane's input is **mouse motion / clicks / keycodes forwarded on the VIDEO INPUT path** (`InputMotionCoalescer`, keycode-forward — see memory `rwork-video-input`), which **does not pass through `sendInput`**. So a "read-only" remote-window pane could still accept mouse/keyboard unless the gate is extended to the video-input seam. Find the single client→host ingress for remote-window input and gate it on the same per-pane read-only flag (pure policy testable headlessly; the actual event post is app-target). The pill/rail-lock from E17 should also show on a read-only `.remoteGUI` pane.
4. **Drag-drop zones (E18)** — audit `DropActionResolver` / pane drop zones with a `.remoteGUI` neighbor: Split-L/R must work with a remote-window pane as a sibling; the pane must be a valid drop *target context* and not crash on a foreign drop. **Drop-to-CREATE a remote-window is almost certainly OUT of scope** (remote windows are created via the picker, not a file drop) — state that explicitly rather than building it.
5. **Sidebar row + badge (E6)** — audit that a `.remoteGUI` pane gets a correct rail row: a sensible icon (a display/window glyph, not a terminal `>_`), a subtitle (host / window title), and the status dot reflecting the video connection state (`PaneConnectionStatus`). Per-host badge → see §4 exclusion.
6. **Status bar (E10)** — audit that the bottom status bar shows correct content for a focused `.remoteGUI` pane (host, pane-kind label, connection state) and doesn't render terminal-only fields (cwd/exit-code) as empty/garbage.
7. **Zoom + palette switch + first-class peer sweep** — a `.remoteGUI` pane zooms (⌘⏎) without a surface rebuild; is switchable from the command palette; and a final grep sweep confirms no surface enumerates kinds in a way that **drops** `.remoteGUI` (e.g. a `switch` with `.terminal`/`.web` arms and a `default` that no-ops, or a `case .terminal:` guard that silently excludes it).

## 3. Binding constraints (hard rules)

- **Hang-safety (load-bearing).** NEVER instantiate `SCStream` / `VTCompressionSession` / `VTDecompressionSession` / a Metal device / a real `NSWindow` / `WKWebView` in a test. The remote-window **render** (`GuiLeafView`/`RemoteGUIDisplay`/`VideoWindowSeam`/`WindowRebind`) is exactly this family — it is **app-target/runtime-only behind the seam**, compiled & code-reviewed, never unit-instantiated. Tests cover only the **pure** parts: PaneKind plumbing, Open-Quickly inclusion logic, the read-only policy decision, floating-frame geometry/clamp math, sidebar-row/status-bar model derivation, picker model. (Same discipline as E18's `WebLeafView` and the video host/client.)
- **Wire: default `touchesWire:false`.** The remote-window video path and the picker discovery (VideoControl 7/8) already have their wire. E21 is **client-side surface wiring** — expect **no golden change**. IF (only if) a genuine new over-wire need appears, EXTEND the existing VideoControl channel (validate-then-drop, hand-edit golden surgically so the **13 frozen keys survive**, host+client redeploy-together per no-backcompat, update `docs/20` + `DECISIONS.md`). Re-run the HW loopback-validate after any FEC/packetizer/reassembler touch (you almost certainly won't touch it).
- **No app-layer crypto/auth/pairing/tokens.** The security boundary is the trusted WireGuard mesh. Do not add any.
- **Untrusted input.** Any datagram/parser on the remote-window path: validate-then-drop, validate counts/lengths before allocating, never force-unwrap attacker-controlled input, read interop booleans as `byte != 0`.
- **Input injection stays VERBATIM / native.** Remote-window input forwards **keycodes** (not Unicode) and coalesced mouse motion on the video input path — never route it through `SendKeysParser`.
- **Menu/keybind hygiene.** `WorkspaceCommands.swift` carries **no `.keyboardShortcut`** (the menu-shortcutless lint rule); chords are registered via the keybind registry. Any new Float/Read-Only-on-remoteGUI command obeys this.
- **Headless-first + iOS rots silently.** The picker, Open-Quickly, sidebar, status bar, read-only policy are **shared `SlopDeskClientUI`** → set `touchesIOS:true` and the gate MUST run `scripts/check-ios.sh`. Guard any macOS-only render/window glue with `#if os(macOS)`; provide an iOS path or an explicit, documented no-op for the remote-window render on iOS (memory `rwork-duplicate-cursor-hide`: iOS keeps the cursor overlay).

## 4. Scope reductions / exclusions (do NOT build)

- **Per-host badge in pickers / multi-host UI = DEFERRED, do not build dead UI.** DECISIONS.md:123 keeps per-session multi-host *schema-reserved but deferred* — "MVP shares the one `AppConnection`." There is no live multi-host today, so a per-host badge would be inert chrome. Document it as a deferred extension point (single-host MVP); do **not** ship a multi-host selector/badge with no backing data. (This is E21's analog of the E11 SSH-filter / E19 horizontal-tab-bar exclusions.)
- **Drop-to-create a remote-window pane** (from a file/URL drop) = out of scope (remote windows come from the picker). State it; don't build it.
- **True PiP / per-pane OS float window** = already DEFERRED at E19 (single-window client; "true PiP + per-pane float-window DEFERRED, don't ship dead PiP"). E21's "floating" means the **in-app `FloatingPaneView` card** in the split container, not an OS-level child window.
- **The horizontal/top tab bar and the SSH-host filter** remain globally dropped (user, 2026-06-26) — irrelevant here but do not reintroduce.

## 5. Definition of done

- The surface-by-surface audit table is satisfied: a `.remoteGUI` pane is a first-class peer in palette, Open-Quickly, sidebar (row+badge+status), status bar, drag-drop (as a sibling/target), zoom, read-only (input actually blocked on the video-input seam + pill shown), and floating (draggable/resizable card) — ES-E21-1…4 all met, each with a headless test where the logic is pure (Open-Quickly inclusion, read-only policy on the remote-window seam, floating geometry, first-class-peer enumeration — revert-to-confirm-fail, no tautologies).
- Gate green: `swift build` + `make lint` + `swift test` + **`scripts/check-ios.sh` BUILD SUCCEEDED** (shared ClientUI) + **golden zero-diff** (expected `touchesWire:false`; if you did touch the wire, golden hand-edited with 13 frozen keys intact).
- No surface special-cases `.remoteGUI` out (the final grep sweep is clean).
- Commit straight to **main**, no branch, no push.

## 6. Notes for the design agent

- Frame the plan as an **audit → fill-genuine-gaps** epic, not a build-from-scratch. Lead the plan with the surface audit table.
- This is the LAST integration epic before **E20** (CLI parity + watch + first-launch). Nothing routes deferrals *into* E21 from earlier epics (checked) — but E21 itself may surface follow-ups for E20 (e.g. an `slopdesk` CLI verb to open a remote window) — record those as follow-ups, don't build them here.
- Expect a small, surgical diff concentrated in `OpenQuicklyModel`, the read-only seam, the float wiring, and a few enumeration sites — plus tests. If the design proposes large new files, that's a signal it's rebuilding something that already exists — re-audit.
