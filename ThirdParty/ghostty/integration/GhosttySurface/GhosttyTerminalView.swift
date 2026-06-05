//
//  GhosttyTerminalView.swift
//  Rwork — the SwiftUI host for the ONLY terminal renderer (libghostty-only).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS DELIBERATELY OUTSIDE THE DEFAULT `swift build` GRAPH.
//  ─────────────────────────────────────────────────────────────────────────────
//  It is the production `TerminalRenderingView` conformer named in
//  `Sources/RworkClientUI/Terminal/TerminalRenderingView.swift` (the documented
//  extension point). Like its sibling `GhosttySurface.swift` (same directory) it is
//  NOT a member of any target in `/Package.swift`; it compiles only inside the
//  macOS/iOS GUI app target (WF-8) which (a) links `libghostty.xcframework` and
//  (b) imports the `CGhostty` clang module. A headless `swift build` / `swift test`
//  never sees it, so the core stays green with zero conditional-compilation hacks.
//
//  The WHOLE FILE is gated on `#if canImport(CGhostty)`. Until the xcframework lands
//  the `CGhostty` module does not exist, so this file compiles to NOTHING — it is
//  inert in every build available on this macOS-26.5 host. Its correctness is
//  verified by REVIEW against `GhosttySurface.swift` + `CGhostty/ghostty.h`, not by
//  compilation (see docs/21-HANDOFF.md "Activating the libghostty renderer").
//
//  ─────────────────────────────────────────────────────────────────────────────
//  API CORRECTNESS — every symbol this file relies on (so a reviewer can diff it)
//  ─────────────────────────────────────────────────────────────────────────────
//  From `GhosttySurface.swift` (the @MainActor Swift binding, same directory):
//    • init(app:platformView:cols:rows:contentScale:)   — line 120
//    • var onWrite: ((Data) -> Void)?                    — line 103  (OUT path)
//    • var onResize: ((UInt16, UInt16) -> Void)?         — line 198  (grid → host)
//    • func feed(_:)                                     — line 229  (IN path; model calls this)
//    • func setSize(cols:rows:)                          — line 252
//    • func setContentScale(_:)                          — line 272
//    • func key(_: ghostty_input_key_s) -> Bool          — line 300
//    • func text(_: String)                              — line 310
//    • func redraw()                                     — line 325
//    • func setFocus(_:)                                 — line 332
//    • func close()                                      — line 201
//  From `CGhostty/ghostty.h` (the C ABI), cited by header line:
//    • ghostty_init(uintptr_t, char**)                   — 1117  (process-wide, once)
//    • ghostty_config_new() / _finalize() / _free()      — 1123 / 1132 / 1124
//    • ghostty_runtime_config_s { userdata, wakeup_cb,
//        action_cb, read/confirm/write_clipboard_cb,
//        close_surface_cb, supports_selection_clipboard } — 1073
//    • ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t) — 1141
//    • ghostty_app_free(ghostty_app_t)                   — 1143
//    • ghostty_app_tick(ghostty_app_t)                   — 1144
//    • ghostty_app_t (void*) / ghostty_config_t (void*)  — 29 / 30
//    • ghostty_input_key_s { action, mods, consumed_mods,
//        keycode, text, unshifted_codepoint, composing }  — 322
//    • ghostty_input_action_e {RELEASE,PRESS,REPEAT}     — 120
//    • ghostty_input_mods_e {NONE,SHIFT,CTRL,ALT,SUPER,…}— 100
//
//  NOTE on the OUT path (keystrokes → host PTY stdin): the surface emits encoded
//  bytes via `onWrite`. This view routes them to `TerminalViewModel.sendInput(_:)`
//  (and grid resizes via `onResize` → `sendResize`). The model funnels them through
//  its `inputSink`/`resizeSink`, which the connection layer (`ConnectionViewModel`,
//  which holds the live `RworkClient`) points at `RworkClient.sendInput`/`sendResize`
//  on connect and clears on teardown. Going through the MODEL (not `model.surface
//  .onWrite` directly) decouples view-attach timing from connect timing — whichever
//  happens first, the sink is read at call time. NOW WIRED (was the remaining seam in
//  docs/21-HANDOFF.md).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREADING (doc 18 §C — libghostty calls are main-thread-only)
//  ─────────────────────────────────────────────────────────────────────────────
//  `GhosttySurface` is `@MainActor`, and SwiftUI representable callbacks + the
//  Metal layer view run on the main thread, so every surface call below is on main.
//  We never `await` between write_output → refresh → draw (the binding keeps that
//  trio synchronous inside `feed`).
//

#if canImport(CGhostty)

import SwiftUI
import QuartzCore          // CAMetalLayer
import RworkTerminal       // TerminalSurface protocol
import RworkClientUI       // TerminalRenderingView, TerminalViewModel
import CGhostty            // the clang module over ghostty.h (link "ghostty")

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Process-wide libghostty app handle

/// Owns the single process-wide `ghostty_app_t`. libghostty is initialized once per
/// process (`ghostty_init`, header 1117) and one `app` handle is shared by every
/// surface (`ghostty_app_new`, header 1141). Surfaces are created from it
/// (`GhosttySurface.init(app:…)`). `@MainActor` because all libghostty calls are
/// main-thread-only (doc 18 §C).
@MainActor
final class GhosttyApp {
    /// Lazily-created shared handle. The GUI process keeps it alive for its lifetime,
    /// so surfaces created from it (held by the Metal views) never outlive it.
    static let shared = GhosttyApp()

    let app: ghostty_app_t

    // Coalescing state for `wakeup_cb`. `nonisolated` because `requestAppTick` is invoked from
    // libghostty's OFF-main libxev threads (`renderer`/`io`).
    nonisolated(unsafe) private static var tickScheduled = false
    nonisolated private static let tickLock = NSLock()

    /// Schedules AT MOST ONE pending `ghostty_app_tick` on the main thread, collapsing a burst of
    /// high-rate `wakeup_cb` signals. Without this, the external-backend libxev loops (which can
    /// busy-tick) fire `wakeup_cb` thousands of times/sec; one `DispatchQueue.main.async` per signal
    /// floods the main queue and STARVES the MainActor — SwiftUI stops updating and the async connect
    /// never runs (pane stuck at "idle" while CPU spins). Coalescing keeps the main thread free.
    nonisolated static func requestAppTick() {
        tickLock.lock()
        if tickScheduled { tickLock.unlock(); return }
        tickScheduled = true
        tickLock.unlock()
        DispatchQueue.main.async {
            tickLock.lock(); tickScheduled = false; tickLock.unlock()
            MainActor.assumeIsolated { ghostty_app_tick(GhosttyApp.shared.app) }
        }
    }

    private init() {
        // 1. ghostty_init (header 1117): once per process, before any config/app.
        //    Signature is `int ghostty_init(uintptr_t, char**)` — argc/argv; we pass
        //    none (the embedder owns the CLI).
        _ = ghostty_init(0, nil)

        // 2. Config (header 1123 / 1132). Defaults are fine for the EXTERNAL backend;
        //    per-surface backend/callbacks are set in GhosttySurface, not here.
        let config = ghostty_config_new()
        ghostty_config_finalize(config)

        // 3. Runtime config (header 1073). The embedder must supply the callback set;
        //    for Rwork's external-backend viewer the surface's own write/resize
        //    callbacks carry the data path, so these app-level runtime callbacks are
        //    minimal no-ops (wakeup just ticks the app; clipboard/close are stubs the
        //    GUI coordinator can later enrich). All fields zero-initialized first.
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            // libghostty asks to be ticked on its main loop. THIS IS A CROSS-THREAD SIGNAL by design
            // — on macOS it fires from libghostty's `renderer`/`io` libxev threads, NOT the main
            // actor. COALESCED via `requestAppTick`: those external-backend loops can fire this at a
            // very high rate, and scheduling a `ghostty_app_tick` per signal floods the main queue and
            // STARVES the MainActor (SwiftUI + the async connect → pane hung at "idle" while CPU spun).
            // (A bare `MainActor.assumeIsolated` here would TRAP off-main — the historical launch crash.)
            GhosttyApp.requestAppTick()
        }
        // action_cb returns whether the action was handled; the viewer handles none
        // of the app-level actions (split/new-window/etc.) — return false.
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _ in }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }

        // 4. App (header 1141).
        self.app = ghostty_app_new(&runtime, config)

        // The config can be freed after app_new copies what it needs (header 1124).
        ghostty_config_free(config)
    }
}

// MARK: - GhosttyTerminalView (the TerminalRenderingView conformer)

/// libghostty-backed terminal renderer — Rwork's production `TerminalRenderingView`.
///
/// It hosts a Metal-backed platform view (`CAMetalLayer`) that owns a `GhosttySurface`
/// configured for the EXTERNAL backend. The data flow:
///
///  * **IN** (host PTY output → pixels): the `TerminalViewModel` already calls
///    `surface.feed(_:)` inside `ingestOutput(_:)`. This view just sets
///    `model.surface = <the GhosttySurface>` so the model's existing feed path lands
///    in libghostty. (`feed` → `ghostty_surface_write_output` + refresh + draw.)
///  * **OUT** (keystrokes → host PTY stdin): the view forwards platform key/text
///    events to `surface.key(_:)` / `surface.text(_:)`; libghostty encodes them and
///    emits the bytes via `surface.onWrite`, which the connection layer bridges to
///    `RworkClient.sendInput` (documented seam — see file header + doc 21).
///  * **Resize**: layout changes convert the view's pixel size → cols/rows and call
///    `surface.setSize(cols:rows:)`; the surface mirrors the grid to the host via
///    `surface.onResize`.
///  * **Render cadence**: libghostty drives its own draw from `feed`/`redraw`; the
///    view forces a `redraw()` on focus/occlusion/scale changes.
///
/// ⚠️ **GUI-ONLY:** needs a real screen + the libghostty xcframework. COMPILED +
/// reviewed; not driven from tests (mirrors `VideoWindowView`). This is the view the
/// app injects via `TerminalRendererFactory.shared`.
public struct GhosttyTerminalView: TerminalRenderingView {
    private let model: TerminalViewModel
    /// The pane's workspace focus (active tab's `focusedPane`). Drives the macOS keyboard FIRST
    /// RESPONDER — only the focused pane takes the keyboard — WITHOUT gating render-liveness (every
    /// visible pane stays libghostty-focused so an unfocused split sibling keeps repainting its output).
    private let isFocused: Bool

    /// `TerminalRenderingView` conformance. Defaults `isFocused` to `true` (single-pane / preview).
    public init(model: TerminalViewModel) {
        self.model = model
        self.isFocused = true
    }

    /// The workspace-aware initializer the app factory uses, carrying the pane's focus.
    public init(model: TerminalViewModel, isFocused: Bool) {
        self.model = model
        self.isFocused = isFocused
    }

    public var body: some View {
        GhosttyMetalLayerView(model: model, isFocused: isFocused)
            .accessibilityLabel(Text("Terminal"))
    }
}

// MARK: - Platform representable + Metal-backed view

#if os(macOS)

/// `NSViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: NSViewRepresentable {
    let model: TerminalViewModel
    /// The pane's workspace focus — drives the keyboard first responder (see ``GhosttyLayerBackedView``).
    var isFocused: Bool = true

    func makeNSView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        // Do NOT create the surface here. SwiftUI builds the representable for an off-window
        // probe/sizing pass too; creating the libghostty surface in that throwaway view spawns a
        // SECOND set of renderer/io threads (the 100%-CPU spin) and a duplicate surface
        // (detach-clobber). Just remember the model — the surface is created lazily once the view
        // enters a real window (`viewDidMoveToWindow`), so EXACTLY ONE surface exists per pane.
        view.model = model
        view.isFocusedPane = isFocused
        return view
    }

    func updateNSView(_ nsView: GhosttyLayerBackedView, context: Context) {
        nsView.model = model
        // Attach only on-window (idempotent). The off-window probe view never reaches here with a
        // window set, so it never calls `ghostty_surface_new`.
        if nsView.window != nil { nsView.attach(model: model) }
        // Apply the workspace focus: only the focused pane takes the keyboard first responder. A focus
        // change (Cmd-arrow / palette / click→store.focus) re-renders this representable with the new
        // value, so focus follows workspace intent reactively — no pane steals the keyboard on mount.
        nsView.isFocusedPane = isFocused
    }

    static func dismantleNSView(_ nsView: GhosttyLayerBackedView, coordinator: ()) {
        nsView.detach()
    }
}

/// A LAYER-HOSTING `NSView` for libghostty's macOS renderer.
///
/// CRITICAL — how libghostty presents on macOS (read from `renderer/Metal.zig`): libghostty
/// creates its OWN `IOSurfaceLayer` and installs it as THIS view's `layer` via the layer-HOSTING
/// pattern — `info.view.setProperty("layer", <IOSurfaceLayer>)` THEN `wantsLayer = true`. It does
/// NOT render into a `CAMetalLayer` / `nextDrawable`. Therefore this view must be a PLAIN,
/// initially layer-less `NSView` and must let libghostty own the `layer` slot.
///
/// A previous version force-installed its OWN `CAMetalLayer` (assigning `layer` + overriding
/// `makeBackingLayer`). That `CAMetalLayer` won the view's `layer` slot, so libghostty's
/// `IOSurfaceLayer` was never in the view hierarchy and never displayed — the terminal painted
/// BLANK even though `feed` delivered bytes and `draw_now` ticked (libghostty WAS rendering, into
/// an orphaned off-screen layer). Confirmed by a live Mac Studio repro + reading `Metal.zig`.
///
/// A `CADisplayLink` drives `ghostty_surface_draw_now` each display tick (see `renderDisplayLink`),
/// MIRRORING the iOS sibling, so the renderer thread flushes its lazily-rasterized glyphs. The
/// hosted layer's frame + contentsScale are sized in `layout()` (a layer-hosting view does not get
/// its hosted layer auto-resized to the view bounds).
final class GhosttyLayerBackedView: NSView {
    /// Strong owner of the surface. `TerminalViewModel.surface` is `weak`, so the view
    /// is the lifetime owner (the GUI owns it on main; `detach()`/`deinit` free it).
    private var surface: GhosttySurface?
    weak var model: TerminalViewModel?

    /// Whether THIS pane is the workspace's focused pane (set by `GhosttyMetalLayerView`). Drives the
    /// keyboard FIRST RESPONDER only — render-focus (`surface.setFocus(true)`) is kept ON for every
    /// visible pane in `attach()` so an unfocused split sibling keeps repainting. On a change to `true`
    /// the pane claims first responder; on `false` it does NOT resign (a sibling claiming FR resigns it).
    var isFocusedPane: Bool = true {
        didSet { if isFocusedPane != oldValue { applyKeyboardFocus() } }
    }

    /// Claims the keyboard first responder iff this is the focused pane and on-window. Never resigns
    /// here (the sibling that becomes focused makes ITSELF first responder, which resigns this one) and
    /// never touches `surface.setFocus` (render-focus stays on for repaint — the multi-pane fix).
    private func applyKeyboardFocus() {
        guard isFocusedPane, let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Drives libghostty's renderer thread via `ghostty_surface_draw_now`. GATED on `presentTicks`:
    /// it presents only when there is something new, NOT every display frame. An UNCONDITIONAL
    /// per-tick `draw_now` kept the renderer thread's `draw_now` mach-port permanently ready, so its
    /// libxev loop busy-spun in `kqueue.Loop.tick` at ~100% CPU — flooding the main thread and
    /// starving the async connect (pane stuck "idle"). Gating lets the loop block in `kevent()` when
    /// idle → CPU ~0. (Verified by profiling on a Mac Studio.)
    private var renderDisplayLink: CADisplayLink?

    /// Frames still owed to the renderer (set by `requestPresent`, drained by `renderTick`). Counts
    /// a few — not 1 — so the renderer thread's LAZY glyph rasterization flushes over the next ticks
    /// after new content arrives.
    private var presentTicks = 0

    /// Pending work items of the post-resize "settle present burst" (see `scheduleSettlePresentBurst`).
    /// Held so a CONTINUOUS drag coalesces to ONE burst: each new `layout()` cancels the prior array
    /// before scheduling, so only the LAST settle's burst survives. A FIXED, finite array → the burst
    /// is provably bounded and self-terminating (it never reschedules itself).
    private var settleItems: [DispatchWorkItem] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Do NOT set `wantsLayer`, assign a `layer`, or override `makeBackingLayer`: libghostty
        // installs its OWN `IOSurfaceLayer` as this view's layer (layer-hosting) during
        // `ghostty_surface_new` (in `attach`). Pre-installing a layer here fights that and the
        // terminal renders blank (the lesson of the orphaned-CAMetalLayer bug above).
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Ask for the next few display ticks to present (drain new content / flush lazy glyphs).
    func requestPresent(_ ticks: Int = 3) {
        if kRenderDebug { rdbg("requestPresent(\(ticks)) [was \(presentTicks)]") }
        presentTicks = max(presentTicks, ticks)
    }

    /// Post-resize REPAINT-RESIDUAL fix (idle-prompt-prefix-blank-after-resize).
    ///
    /// After a resize SETTLES, the host applies the coalesced `TIOCSWINSZ` → `SIGWINCH` → zsh and
    /// libghostty's IO thread reflows the local grid; the renderer thread rebuilds the cells and
    /// presents them via the ASYNC path (`drawFrame(false)` → `setSurface`), which is size-discarded
    /// if the rendered IOSurface no longer matches `layer.bounds × scale`. Meanwhile the only
    /// size-UNCONDITIONAL present — the gated `renderTick` → `setSurfaceSync` — has already drained its
    /// ≤3 `presentTicks` (within ~3 display frames), so it is asleep by the time (i) the renderer
    /// thread's reflow frame completes and (ii) zsh's redraw bytes arrive ~1 RTT later. Result: the
    /// idle editing-prompt prefix stays BLANK until the next content event re-arms a present.
    ///
    /// FIX: after the LAST layout, keep the sync-present path alive for a BOUNDED window by injecting a
    /// FIXED, finite series of `requestPresent` ticks spaced over ~400ms, so those late frames/bytes get
    /// painted, THEN it stops. Each new `layout()` cancels the prior burst first, so a long continuous
    /// drag coalesces to exactly ONE burst that starts only after the drag settles.
    ///
    /// PROVABLY BOUNDED / cannot busy-spin: the schedule is a HARD-CODED array (≤ `kSettleBurstMs.count`
    /// work items), each item does a single `requestPresent(2)` and NOTHING reschedules — after the last
    /// item fires, no further work is posted. `renderTick` keeps its `guard presentTicks > 0` gate
    /// untouched, so between/after the ≤2-tick bursts the renderer's libxev loop blocks in `kevent()`
    /// and CPU returns to ~0. Total extra work per settle ≤ `kSettleBurstMs.count × 2` presents.
    private static let kSettleBurstMs: [Int] = [50, 120, 200, 300, 400]

    private func scheduleSettlePresentBurst() {
        // Coalesce a continuous drag to ONE burst: drop any burst scheduled by an earlier layout pass
        // so only the LAST (settled) layout's burst runs.
        for item in settleItems { item.cancel() }
        settleItems.removeAll(keepingCapacity: true)
        for ms in Self.kSettleBurstMs {
            let item = DispatchWorkItem { [weak self] in self?.requestPresent(2) }
            settleItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
        }
    }

    /// libghostty installs its layer + spawns its renderer/io threads inside `ghostty_surface_new`,
    /// so the surface is created ONLY once the view is in a real window — never for SwiftUI's
    /// off-window probe pass (which would spawn a duplicate surface + thread set that busy-spins).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if let model { attach(model: model) }
            startRenderTickIfNeeded()
            requestPresent(8)   // prime the initial glyph flush
            // Claim the keyboard ONLY if this is the workspace's focused pane. In a multi-pane split
            // every pane used to call `makeFirstResponder` on mount, so the LAST-mounted pane stole the
            // keyboard regardless of `store.focusedPane` (focus-stealing bug). Render-liveness is
            // SEPARATE: `attach()` keeps `surface.setFocus(true)` on every visible pane (an unfocused
            // libghostty surface idles its renderer and freezes — hardware-confirmed), so unfocused
            // split siblings still repaint; only the keyboard FR is gated. Deferred so the window is key.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFocusedPane, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        } else {
            renderDisplayLink?.invalidate()   // off-window: stop ticking so a detached view never spins
            renderDisplayLink = nil
        }
    }

    /// Idempotent: builds the surface on first call (only when on-window), then attaches it to the
    /// model. Safe to call repeatedly from `updateNSView` / `viewDidMoveToWindow`.
    func attach(model: TerminalViewModel) {
        self.model = model
        guard window != nil else { return }   // never spawn a surface for the off-window probe view
        if surface == nil {
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(window?.backingScaleFactor ?? 2.0)
            )
            // OUT path: encoded keystrokes → model input sink → live RworkClient.sendInput.
            s.onWrite = { [weak model] (data: Data) in model?.sendInput(data) }
            // Grid changes (font reflow) → model resize sink → host TIOCSWINSZ.
            s.onResize = { [weak model] (cols: UInt16, rows: UInt16) in model?.sendResize(cols: cols, rows: rows) }
            // New inbound bytes were fed → ask the gated tick to present. This is the dirty signal
            // that REPLACES a free-running per-frame `draw_now` (the spin source). Without it the
            // gated tick would never present live output.
            s.onContentChanged = { [weak self] in self?.requestPresent() }
            self.surface = s
        }
        // attachSurface(_:) (not `model.surface = surface`) so the model REPLAYS its retained byte
        // ring into a rebuilt surface (tab switch / reshape). No-op replay when unchanged.
        if let surface { model.attachSurface(surface) }
        surface?.setFocus(true)
        requestPresent(8)   // flush whatever the replay just fed
    }

    private func startRenderTickIfNeeded() {
        guard renderDisplayLink == nil, window != nil,
              ProcessInfo.processInfo.environment["RWORK_NO_TICK"] == nil else { return }
        let link = displayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        renderDisplayLink = link
    }

    @objc private func renderTick() {
        // GATED present. Idle → return WITHOUT presenting, so the renderer thread's libxev loop
        // blocks in `kevent()` and CPU drops to ~0 (the cure for the 100% spin). After new content
        // (`requestPresent` from feed / attach-replay / layout) present for a few ticks so the
        // renderer thread's lazily-rasterized glyphs flush.
        //
        // Drive libghostty's IOSurfaceLayer `display` callback → `drawFrame(true)` → `present(sync)`
        // → `setSurfaceSync`, INSIDE a CA commit so the new contents ACTUALLY appear. This is the
        // SAME present path a window RESIZE uses (`needsDisplayOnBoundsChange`) — the only path
        // observed to update the screen on real hardware. `feed`'s `refresh` already rebuilt the cells
        // on the renderer thread, so the `drawFrame(true)` invoked here renders the FRESH frame. Runs
        // on the runloop (display-link tick); GATED on `presentTicks` so idle is a cheap no-op (no
        // 100%-CPU spin, no MainActor starvation). `displayIfNeeded()` forces the `display` synchronously
        // this tick rather than waiting for the next CA pass.
        guard presentTicks > 0 else { return }
        if kRenderDebug { rdbg("renderTick DISPLAY (ticks=\(presentTicks))") }
        presentTicks -= 1
        layer?.setNeedsDisplay()
        layer?.displayIfNeeded()
    }

    func detach() {
        renderDisplayLink?.invalidate()
        renderDisplayLink = nil
        // Cancel any pending settle-present burst so a torn-down view never fires `requestPresent`.
        for item in settleItems { item.cancel() }
        settleItems.removeAll(keepingCapacity: true)
        let detaching = surface
        surface = nil
        detaching?.close()
        // Pass the detaching surface so the model clears its `surface` ONLY if this is the surface it
        // currently feeds. A stale duplicate view's detach must NOT nil the live (on-screen) surface
        // — that froze the visible terminal on its initial replay while new output was dropped.
        model?.detachSurface(detaching)
    }

    deinit {
        // @MainActor not available in deinit; the surface's own deinit frees the
        // ghostty_surface_t. We rely on detach() (dismantleNSView) as the explicit path.
    }

    // MARK: Resize → grid

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        // Pass ACTUAL pixel extent; libghostty derives the grid from its measured cell metrics, rounds
        // the surface to whole cells, and fires resize_callback → onResize (host TIOCSWINSZ).
        let pxW = UInt32(max(1, Int((bounds.width * scale).rounded())))
        let pxH = UInt32(max(1, Int((bounds.height * scale).rounded())))
        surface?.setContentScale(Double(scale))
        surface?.setPixelSize(widthPx: pxW, heightPx: pxH)
        // Size libghostty's HOSTED `IOSurfaceLayer` to the RAW VIEW BOUNDS (points) — NOT the
        // cell-rounded `renderedPixelSize` read-back. libghostty treats `layer.bounds × contentsScale`
        // as its SINGLE size-of-truth: `surfaceSize()` (renderer/Metal.zig) recomputes width/height
        // from it at the head of every `drawFrame`, and its async present's discard guard
        // (IOSurfaceLayer.zig) compares the rendered IOSurface against that same product. A
        // layer-hosting view does NOT auto-size its hosted layer, so the embedding must set it.
        //
        // RESIZE-CORRUPTION FIX ("vỡ"): sizing the layer to `renderedPixelSize/scale` made
        // layer.bounds a few px SMALLER than the view during a drag-resize, and each continuous
        // layout() wrote a DIFFERENT wrong size. The gated renderTick presents via the SYNC path
        // (`displayIfNeeded` → IOSurfaceLayer `display` → `setSurfaceSync`), which has NO size check,
        // so a frame rendered against the stale layer.bounds was shown unconditionally; with
        // contentsGravity = topLeft + clipsToBounds, the size-mismatched IOSurface anchored top-left
        // and the uncovered/over-extended edge tore (the "vỡ"). Pinning layer.bounds == view.bounds
        // makes drawFrame render an IOSurface that EXACTLY matches the layer, so the sync present lands
        // a correct frame and any late async frame from a prior size is correctly discarded. This
        // mirrors the iOS sublayer (sized to raw bounds, layoutSubviews) and upstream ghostty (which
        // never sets layer.frame). The initial-attach present still lands: bounds×scale == pxW/pxH that
        // was just handed to setPixelSize, so libghostty's IOSurface matches the layer on first frame
        // too (cell rounding only affects grid cols/rows, not screen.width/height = the raw input).
        if let hosted = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = CGRect(origin: .zero, size: bounds.size)
            hosted.contentsScale = scale
            CATransaction.commit()
        }
        rdbg("macOS layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) scale=\(scale) px=\(pxW)x\(pxH) rendered=\(surface?.renderedPixelSize.map { "\($0.width)x\($0.height)" } ?? "nil")")
        surface?.redraw()
        requestPresent()   // a layout/resize changed the grid → present the reflowed frame
        // BOUNDED settle burst: keep the sync-present path alive for ~400ms after the LAST layout so a
        // late renderer-thread reflow frame / late host (zsh) redraw bytes get painted even though the
        // initial `requestPresent()` ticks drain within a few display frames. Finite + self-terminating
        // (see `scheduleSettlePresentBurst`); a continuous drag coalesces to one burst.
        scheduleSettlePresentBurst()
    }

    // MARK: Input forwarding → libghostty encoder

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // CTRL+<key> → LEGACY C0 control byte (the universal-interrupt fix). The host shell (oh-my-zsh
        // / a plugin) enables the kitty keyboard protocol, which makes libghostty's encoder emit a
        // CSI-u ESCAPE for Ctrl-C/Z/D/… (e.g. `^[[3;5u`) instead of the raw control byte. A remote
        // FOREGROUND program that is NOT kitty-aware — a plain `sleep`/`cat`, or the shell between
        // prompts — never sees `0x03`, so Ctrl-C cannot interrupt it (HARDWARE-CONFIRMED broken). The
        // remote PTY is a SEPARATE process from this client terminal, so we cannot rely on the host
        // popping the protocol per-command. macOS already resolves Ctrl+<key> to its C0 control
        // character in `event.characters` (Ctrl-C → U+0003, Ctrl-[ → U+001B, Ctrl-Space → U+0000,
        // Ctrl-? → U+007F), so for a control-modified key that yields a single C0/DEL scalar we send
        // that raw byte directly — bypassing the kitty encoder — so interrupt/EOF/suspend + the C0
        // line-editing keys always reach the host. Plain + non-control keys still go through libghostty
        // unchanged (kitty stays available to the host for everything else). Cmd-combos are app
        // shortcuts and are NOT intercepted here.
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           let chars = event.characters,
           chars.unicodeScalars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F {
            model?.sendInput(Data(chars.utf8))
            return
        }

        // Route every other key through libghostty's encoder (DECISIONS: never hand-roll VT).
        // ghostty_input_key_s (header 322): action / mods / keycode / text /
        // unshifted_codepoint / composing.
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        // `text` is a borrowed const char* for the keypress duration; bind the chars.
        if let chars = event.characters, !chars.isEmpty {
            let copy = chars
            copy.withCString { cstr in
                key.text = cstr
                _ = surface?.key(key)
            }
        } else {
            key.text = nil
            _ = surface?.key(key)
        }
    }

    override func keyUp(with event: NSEvent) {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        key.text = nil
        _ = surface?.key(key)
    }

    override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // DO NOT drop libghostty render-focus here. Losing the KEYBOARD first responder to a sibling
        // pane must NOT idle this surface's renderer — an unfocused libghostty surface stops presenting
        // and FREEZES on its last frame (hardware-confirmed), which is exactly the multi-pane
        // "unfocused pane goes stale" bug. Render-focus is kept ON for every visible pane (set in
        // `attach()`); only the keyboard moves to the newly-focused pane. (A pane truly leaving the
        // screen is `detach()`'d, which closes the surface — so it never needs an unfocus here.)
        return super.resignFirstResponder()
    }

    /// Maps AppKit modifier flags → libghostty mods (header 100).
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        // `ghostty_input_mods_e` is a PLAIN C enum (ghostty.h:99-111 — no
        // flag_enum/NS_OPTIONS attribute), so the Clang importer's `init?(rawValue:)`
        // is FAILABLE and only succeeds for declared enumerators. An OR-accumulated
        // value (e.g. SHIFT|CTRL = 3) is not an enumerator, so the labeled init would
        // return nil → both a type mismatch (optional vs. non-optional return) and a
        // runtime break. Use the importer's UNLABELED non-failable init over the raw
        // integer instead — matches upstream Ghostty.Input.swift `ghosttyMods`.
        return ghostty_input_mods_e(raw)
    }
}

#elseif os(iOS)

/// `UIViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: UIViewRepresentable {
    let model: TerminalViewModel
    /// Signature parity with the macOS sibling. iOS keyboard focus is owned by `TerminalInputHost`
    /// (doc 17 §2.5), and every visible surface stays render-focused, so this is currently inert here.
    var isFocused: Bool = true

    func makeUIView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        view.attach(model: model)
        return view
    }

    func updateUIView(_ uiView: GhosttyLayerBackedView, context: Context) {
        uiView.attach(model: model)
    }

    static func dismantleUIView(_ uiView: GhosttyLayerBackedView, coordinator: ()) {
        uiView.detach()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the `GhosttySurface`.
///
/// Physical-key + IME text forwarding on iOS is handled by the existing UIKit
/// table-stakes host (`RworkClientUI.TerminalInputHost` — doc 17 §2.5), which already
/// routes presses/IME to `RworkClient.sendInput`. This view focuses on hosting the
/// Metal layer + surface; the input-host integration is the documented follow-up seam.
final class GhosttyLayerBackedView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var surface: GhosttySurface?
    private weak var model: TerminalViewModel?
    /// Drives libghostty's renderer thread each display tick via `ghostty_surface_draw_now`.
    /// REQUIRED for glyphs: libghostty rasterizes glyphs + rebuilds foreground cells lazily
    /// on its render thread; without a steady tick the synchronous `feed`-time draw can
    /// present a background-only frame (no text) and never self-correct.
    private var displayLink: CADisplayLink?

    func attach(model: TerminalViewModel) {
        self.model = model
        if surface == nil {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(scale)
            )
            // OUT path: libghostty-encoded keystrokes → model sink → live RworkClient.
            // On iOS the physical-key/IME forwarding is owned by `TerminalInputHost`
            // (doc 17 §2.5), but routing onWrite here too is harmless+correct: it carries
            // whatever the surface itself encodes, and the model sink is the single funnel.
            s.onWrite = { [weak model] (data: Data) in
                model?.sendInput(data)
            }
            s.onResize = { [weak model] (cols: UInt16, rows: UInt16) in
                model?.sendResize(cols: cols, rows: rows)
            }
            self.surface = s
        }
        // attachSurface(_:) (not `model.surface = surface`) so the model REPLAYS its retained
        // byte-ring into a rebuilt surface — the iOS compact-carousel flip dismantles + rebuilds
        // the representable EMPTY while the connection (and host scrollback) is untouched. No-op
        // replay when the instance is unchanged.
        if let surface {
            model.attachSurface(surface)
        }
        surface?.setFocus(true)

        // Start the render-thread pacing tick (idempotent). 60 fps is plenty for a
        // terminal; libghostty coalesces (its updateFrame is dirty-gated, so idle ticks
        // are cheap no-ops).
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(renderTick))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func renderTick() {
        surface?.drawNow()
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        let detaching = surface
        surface = nil
        detaching?.close()
        // Identity-gated detach (see the macOS sibling): a stale duplicate view's detach must not nil
        // the live surface the model is still feeding.
        model?.detachSurface(detaching)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        // CRITICAL (iOS): libghostty renders into an `IOSurfaceLayer` it adds as a
        // SUBLAYER of this view's layer (`Metal.zig` `addSublayer:`) — and it NEVER sizes
        // that sublayer. UIKit does not auto-resize a manually-added sublayer, so it stays
        // 0×0; `drawFrame()` then reads `bounds × contentsScale == 0` and silently
        // early-returns (renderer/generic.zig zero-size guard) → blank screen, no error.
        // (macOS works because libghostty makes its layer the view's *backing* layer,
        // which AppKit auto-sizes.) Size every sublayer to our bounds + scale.
        layer.sublayers?.forEach { sub in
            sub.frame = bounds
            sub.contentsScale = scale
        }
        let pxW = UInt32(max(1, Int((bounds.width * scale).rounded())))
        let pxH = UInt32(max(1, Int((bounds.height * scale).rounded())))
        surface?.setContentScale(Double(scale))
        // Pass ACTUAL layer pixels; libghostty derives the grid + fires resize_callback.
        surface?.setPixelSize(widthPx: pxW, heightPx: pxH)
        surface?.redraw()
    }
}

#endif  // os(macOS) / os(iOS)

#endif  // canImport(CGhostty)
