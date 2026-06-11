//
//  GhosttySurface.swift
//  Aislopdesk — the ONLY terminal renderer (libghostty-only, no SwiftTerm, no fallback).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS DELIBERATELY OUTSIDE THE DEFAULT `swift build` GRAPH.
//  ─────────────────────────────────────────────────────────────────────────────
//  It is NOT a member of any target in /Package.swift. It compiles only inside the
//  macOS/iOS GUI app target (WF-8), which (a) links `libghostty.xcframework` built
//  by `ThirdParty/ghostty/build-libghostty.sh` and (b) imports the `CGhostty`
//  clang module (`ThirdParty/ghostty/integration/CGhostty/module.modulemap`).
//  Consequently a normal headless `swift build` / `swift test` never tries to
//  compile this file or link the framework — the 187-test core stays green with
//  zero conditional-compilation hacks in the core modules. See the integration
//  README for the wiring story.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  API CORRECTNESS — pinned source of truth
//  ─────────────────────────────────────────────────────────────────────────────
//  Fork:    daiimus/ghostty @ branch ios-external-backend
//  SHA:     21c717340b62349d67124446c2447bf38796540b
//  Header:  include/ghostty.h (1369 lines) — vendored verbatim at
//           ThirdParty/ghostty/integration/CGhostty/ghostty.h
//  Zig:     0.15.2 (build.zig.zon `minimum_zig_version`)
//
//  Every C symbol used below is cited with its header line number so a reviewer
//  can diff this binding directly against include/ghostty.h. NOTE the actual
//  fork API differs from the names quoted loosely in the spec:
//
//    spec name                      ACTUAL daiimus C symbol (header line)
//    ───────────────────────────    ───────────────────────────────────────────
//    ghostty_surface_feed_data   →  ghostty_surface_write_output(s, ptr, len)  (1185)
//    ghostty_surface_set_write_callback
//                                →  config.write_callback field, set at
//                                   ghostty_surface_new() time                 (467)
//    use_custom_io = true        →  config.backend_type = GHOSTTY_BACKEND_EXTERNAL (466 / 424)
//    resize                      →  ghostty_surface_set_size(s, wpx, hpx)      (1174)
//                                   + config.resize_callback                   (468)
//    keys                        →  ghostty_surface_key(s, ghostty_input_key_s) (1180)
//    text                        →  ghostty_surface_text(s, ptr, len)          (1184)
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREADING CONTRACT (doc 18 §C — libghostty threading, SOLVED-by-source)
//  ─────────────────────────────────────────────────────────────────────────────
//  `ghostty_surface_write_output` / `_refresh` / `_draw` MUST be called on the
//  main thread (confirmed reading VVTerm + the fork's own doc comment on
//  ghostty_surface_write_output: "NOT safe to call concurrently on the same
//  surface … typically the embedder calls this from a single I/O thread per
//  surface"). Swift's `@MainActor` does NOT propagate across the C boundary, so
//  this type is `@MainActor` to *guarantee* the call sites are on main:
//    • TCP receive loop (bg thread) → `await MainActor.run { surface.feed(d) }`
//      (here: the surface is `@MainActor`, so callers `await` into it).
//    • The C write-callback fires on libghostty's dedicated IO thread (the fork's
//      `External.zig`: "invoked on the IO thread"), NOT synchronously on main — even
//      replies generated during a main-thread `feed()` are emitted off-main via the IO
//      mailbox. So `onWrite` MUST be routed through `ghosttyOnMainActor` (the main hop is
//      REQUIRED, not a defensive fallback — see the write_callback below).
//    • Hazard (doc 18 §C): actor-suspension escape — do NOT `await` *between*
//      write_output → refresh → draw; keep that trio synchronous (it is, below).
//

import Foundation
import AislopdeskTerminal       // TerminalSurface protocol (the renderer seam)
import AislopdeskProtocol       // not strictly needed here; kept for parity with the seam
import CGhostty            // the clang module over include/ghostty.h (link "ghostty")

/// TEMPORARY render-path tracer, gated on the `AISLOPDESK_RENDER_DEBUG` env var. Used to diagnose
/// the macOS blank-glyph issue (terminal connected + fed bytes but no text painted). Writes to
/// stderr so a `Aislopdesk.app/Contents/MacOS/Aislopdesk` launch captures it. Remove once resolved.
let kRenderDebug = ProcessInfo.processInfo.environment["AISLOPDESK_RENDER_DEBUG"] != nil
@inline(__always) func rdbg(_ msg: @autoclosure () -> String) {
    if kRenderDebug { FileHandle.standardError.write(Data(("[RDBG] " + msg() + "\n").utf8)) }
}

/// Run a `@MainActor` `body` in response to a libghostty C callback that may fire on
/// **any** thread.
///
/// libghostty invokes `wakeup_cb` / `write_callback` / `resize_callback` from whatever
/// thread reaches them — it makes NO main-thread guarantee at the C boundary. On iOS the
/// draw/tick path is main-thread-driven (CADisplayLink + the `sync-updateframe` patch), so
/// these callbacks happen to land on main; a bare `MainActor.assumeIsolated` survived there
/// by luck. On **macOS** libghostty runs a dedicated **`renderer`** thread (plus a libxev
/// `io` thread): `wakeup_cb` is fired from that renderer thread
/// (`renderer.Thread.drawFrame` → `apprt.surface.Mailbox.push` → here), so a bare
/// `MainActor.assumeIsolated` TRAPS — `dispatch_assert_queue` → `EXC_BREAKPOINT` ~3 s after
/// launch. This helper is the fix: the macOS launch crash and the latent off-main hazard in
/// the write/resize data-path callbacks.
///
/// Contract: if already on the main thread, run **synchronously** — this preserves the
/// in-isolation, FIFO-ordered semantics the key-encode / `feed()` write path depends on
/// (doc 18 §C: keep write_output → refresh → draw synchronous, no suspension). Otherwise
/// hop to the main queue asynchronously. Either way `body` runs on the main actor.
///
/// ⚠️ Callers MUST copy any C-owned buffer (e.g. `Data(bytes:count:)`) BEFORE calling this:
/// on the async path the body outlives the C callback's stack frame.
@inline(__always)
func ghosttyOnMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

/// libghostty-backed ``TerminalSurface`` — Aislopdesk's only renderer.
///
/// Wraps a `ghostty_surface_t` (header line 31, opaque `void*`) configured for the
/// EXTERNAL backend (`GHOSTTY_BACKEND_EXTERNAL`, line 424) so it parses+renders the
/// raw VT byte stream that arrives over PATH 1 instead of spawning a local PTY.
///
/// - Data IN  (host PTY output → pixels): ``feed(_:)`` → `ghostty_surface_write_output`.
/// - Data OUT (keystrokes → host PTY stdin): the surface's `write_callback` → ``onWrite``.
/// - Resize: ``setSize(cols:rows:)`` → `ghostty_surface_set_size` (also drives a
///   `resize_callback` that the embedder may mirror to the host `TIOCSWINSZ`).
/// - Keys/text: ``key(_:)`` → `ghostty_surface_key`, ``text(_:)`` → `ghostty_surface_text`.
///
/// `@MainActor` enforces the doc-18-§C main-thread contract at the type level.
@MainActor
public final class GhosttySurface: @MainActor TerminalSurface {

    // MARK: Stored state

    /// The libghostty app handle (header line 29). One app process-wide; a surface
    /// is created from it. Held weakly-conceptually: the owning GUI coordinator
    /// keeps the app alive for the surface's lifetime.
    private let app: ghostty_app_t

    /// The opaque surface (header line 31). `nil` only after ``close()``.
    private var surface: ghostty_surface_t?

    /// Current grid, mirrored for `setSize` pixel conversion. libghostty's size API
    /// is in PIXELS (`ghostty_surface_set_size`, line 1174); we convert cols/rows ×
    /// cell size. The authoritative cell size comes from `ghostty_surface_size`
    /// (line 1175) once a render has measured the font; until then we use a seed.
    private var cols: UInt16
    private var rows: UInt16
    private var cellWidthPx: UInt32
    private var cellHeightPx: UInt32
    private var contentScale: Double

    /// Bytes the renderer wants to send back to the host (encoded keystrokes).
    /// The C `write_callback` fires on libghostty's IO thread; `ghosttyOnMainActor` hops it onto the
    /// main actor before this is invoked, so handlers may touch `@MainActor` state safely.
    public var onWrite: ((Data) -> Void)?

    // MARK: Init / lifecycle

    /// Creates an external-backend surface in `nsview`/`uiview`.
    ///
    /// The GUI app is responsible for `ghostty_init` (header 1117),
    /// `ghostty_config_new`/`_finalize` (1123/1132), and `ghostty_app_new` (1141)
    /// BEFORE constructing a `GhosttySurface`, and passes the resulting `app`
    /// handle plus the platform view here.
    ///
    /// - Parameters:
    ///   - app: a live `ghostty_app_t`.
    ///   - platformView: the `NSView*` (macOS) / `UIView*` (iOS) the Metal layer
    ///     attaches to. Passed via the surface config `platform` union (header 442).
    ///   - cols/rows: initial grid (mirrored to the host on first resize).
    ///   - contentScale: backing-scale factor (`ghostty_surface_set_content_scale`, 1170).
    public init(
        app: ghostty_app_t,
        platformView: UnsafeMutableRawPointer,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        contentScale: Double = 2.0
    ) {
        self.app = app
        self.cols = cols
        self.rows = rows
        // Seed cell size; replaced by the real measured size after first draw.
        self.cellWidthPx = 8
        self.cellHeightPx = 16
        self.contentScale = contentScale

        // ghostty_surface_config_new() (header 1156) returns a zero/default config
        // we then populate. backend_type + write_callback + resize_callback are the
        // EXTERNAL-IO fields (header 466-468).
        var config = ghostty_surface_config_new()

        // EXTERNAL backend = feed bytes via API, do not spawn a PTY (header 424/466).
        config.backend_type = GHOSTTY_BACKEND_EXTERNAL

        // Platform view (header 453-455, 434-445). Tag + union member.
        #if os(macOS)
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = platformView
        #else
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform.ios.uiview = platformView
        #endif
        config.scale_factor = contentScale

        // userdata (header 456): the opaque pointer the C callbacks recover `self`
        // from via ghostty_surface_userdata (header 1161). UNRETAINED — we own the
        // surface's lifetime (close()/deinit free it), so there is no retain cycle.
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        // OUT path: the C write callback (header 429 typedef; 467 field). Fired
        // synchronously on main from Ghostty's key encoder. `userdata` is the
        // surface itself (the fork's glue passes the surface, see embedded.zig
        // getTermioBackend wrapper) — we recover our Swift self via
        // ghostty_surface_userdata (header 1161), which we set below.
        config.write_callback = { (cSurface, dataPtr, len) in
            // cSurface: ghostty_surface_t ; dataPtr: const char* ; len: size_t
            guard let cSurface, let dataPtr, len > 0,
                  let ud = ghostty_surface_userdata(cSurface) else { return }
            let me = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
            let bytes = Data(bytes: dataPtr, count: len)   // copied before any main hop
            // libghostty fires write_callback on its dedicated IO thread (the fork's External.zig),
            // NOT synchronously on main — so the ghosttyOnMainActor hop below is REQUIRED, not an
            // optimization (it runs synchronously when already on main, else hops). Do NOT drop it:
            // calling onWrite → model?.sendInput on the IO thread trips @MainActor isolation / data
            // races on the model — the exact off-main crash class this hop exists to prevent.
            ghosttyOnMainActor {
                me.onWrite?(bytes)
            }
        }

        // resize_callback (header 432 typedef; 468 field): libghostty tells us the
        // grid changed (e.g. font reflow). We forward cols/rows to the host via the
        // SAME `onWrite`-adjacent seam in the GUI coordinator. Kept minimal here.
        config.resize_callback = { (cSurface, newCols, newRows, _, _) in
            guard let cSurface, let ud = ghostty_surface_userdata(cSurface) else { return }
            let me = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
            ghosttyOnMainActor {
                me.cols = newCols
                me.rows = newRows
                rdbg("resize_callback → grid \(newCols)x\(newRows)")
                // The GUI coordinator observes (cols,rows) to emit a `resize`
                // WireMessage to the host (TIOCSWINSZ). Surfaced via onResize hook
                // below to keep this type protocol-pure.
                me.onResize?(newCols, newRows)
            }
        }

        // ghostty_surface_new (header 1158). Must be on main thread. The config
        // already carries `userdata = self` so the C callbacks above can recover us.
        self.surface = ghostty_surface_new(app, &config)
        rdbg("init: surface=\(self.surface != nil) scale=\(contentScale) cols=\(cols) rows=\(rows)")
    }

    /// Optional grid-resize observer (libghostty → host `TIOCSWINSZ`). The GUI
    /// coordinator sets this to emit a `resize` WireMessage.
    public var onResize: ((UInt16, UInt16) -> Void)?

    /// Fired after each ``feed(_:)``. The embedding view sets this to request a present from its
    /// GATED display-link (`draw_now`). This dirty signal is what lets the renderer present new
    /// content WITHOUT a free-running per-frame `draw_now` — which kept libghostty's renderer libxev
    /// loop permanently kicked and busy-spinning at ~100% CPU.
    public var onContentChanged: (() -> Void)?

    /// Frees the surface (header 1160). Idempotent. Must run on the main thread.
    public func close() {
        if let s = surface {
            ghostty_surface_free(s)
            surface = nil
        }
    }

    // `isolated deinit` (Swift 6.2+) guarantees the body runs on this type's actor
    // (the main actor), so it may touch the @MainActor-isolated `surface` (a
    // non-Sendable `ghostty_surface_t?`). Without it, Swift 6 strict concurrency
    // rejects accessing `surface` from a nonisolated deinit. `close()` remains the
    // explicit teardown path; this is the safety net.
    isolated deinit {
        if let s = surface {
            ghostty_surface_free(s)
        }
    }

    // MARK: TerminalSurface — Data IN

    /// Feeds inbound PTY/VT bytes into the renderer.
    ///
    /// `ghostty_surface_write_output(surface, ptr, len)` (header 1185) — "feeds data
    /// to the terminal emulator as if it came from a subprocess/PTY … processes the
    /// data through the terminal emulator and triggers a render."
    ///
    /// THREADING: the fork documents this is NOT safe to call concurrently on one
    /// surface; `@MainActor` serializes all calls. We keep the
    /// write_output → refresh → draw trio SYNCHRONOUS (no `await` between them) to
    /// avoid the doc-18-§C actor-suspension-escape hazard.
    private var feedCount = 0
    public func feed(_ bytes: Data) {
        guard let s = surface, !bytes.isEmpty else {
            rdbg("feed SKIPPED surface=\(surface != nil) empty=\(bytes.isEmpty)")
            return
        }
        feedCount += 1
        if kRenderDebug, feedCount <= 6 || feedCount % 50 == 0 { rdbg("feed #\(feedCount) \(bytes.count)B") }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let cptr = base.assumingMemoryBound(to: CChar.self)
            // header 1185 takes `uintptr_t` (imported as Swift `UInt`).
            ghostty_surface_write_output(s, cptr, UInt(bytes.count))   // header 1185
        }
        // Coalescing redraw (VVTerm `scheduleCustomIORedraw` pattern). The render is
        // already triggered by write_output; refresh+draw force the next frame. Both
        // are main-thread-only (doc 18 §C).
        // Only REFRESH here (wakes the renderer thread → `updateFrame`, rebuilding cells from the
        // just-written state). Do NOT call `ghostty_surface_draw`: its present runs in THIS
        // MainActor-async (output-pump) context, where the implicit CATransaction never commits — it
        // sets the layer contents but they never appear on screen. The present is driven by the
        // view's gated tick via `layer.setNeedsDisplay()` → libghostty's IOSurfaceLayer `display`
        // callback, the SAME path a window RESIZE uses (you observed resize DOES repaint), which runs
        // INSIDE a CA commit so the new frame actually shows.
        ghostty_surface_refresh(s)   // header 1167 → renderer thread updateFrame (rebuild cells)
        onContentChanged?()          // dirty signal → the view's gated tick triggers the display present
    }

    // MARK: TerminalSurface — Resize

    /// Sets the terminal grid size; mirrored to the host via `resize`.
    ///
    /// libghostty sizes in PIXELS via `ghostty_surface_set_size(surface, w, h)`
    /// (header 1174). We convert cols/rows → pixels using the measured cell size
    /// from `ghostty_surface_size` (header 1175) when available. The host-side
    /// `TIOCSWINSZ` is driven from cols/rows by the GUI coordinator (a `resize`
    /// WireMessage), NOT from pixels.
    public func setSize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        guard let s = surface else { return }

        // Refresh measured cell metrics if the font has been laid out.
        let sz = ghostty_surface_size(s)            // header 1175 → ghostty_surface_size_s
        if sz.cell_width_px > 0 { cellWidthPx = sz.cell_width_px }
        if sz.cell_height_px > 0 { cellHeightPx = sz.cell_height_px }

        let widthPx  = UInt32(cols) * cellWidthPx
        let heightPx = UInt32(rows) * cellHeightPx
        ghostty_surface_set_size(s, widthPx, heightPx)   // header 1174

        // The host gets cols/rows (not pixels) — emit via the resize observer.
        onResize?(cols, rows)
    }

    /// The ACTUAL pixel extent of the rendered surface (`ghostty_surface_size`, header 1175 →
    /// `width_px`/`height_px`). libghostty rounds the surface DOWN to whole cells, so this is usually
    /// a few px SMALLER than the last ``setPixelSize(widthPx:heightPx:)``. The embedding MUST size the
    /// hosted `IOSurfaceLayer` to THIS extent — libghostty's size-checked async present
    /// (`IOSurfaceLayer.setSurface`) DISCARDS any frame whose IOSurface size != layer.bounds ×
    /// contentsScale, which otherwise freezes live repaint on the first (sync-presented) frame.
    public var renderedPixelSize: (width: UInt32, height: UInt32)? {
        guard let s = surface else { return nil }
        let sz = ghostty_surface_size(s)
        guard sz.width_px > 0, sz.height_px > 0 else { return nil }
        return (sz.width_px, sz.height_px)
    }

    /// Sets the surface size in ACTUAL layer PIXELS (the GUI layout path).
    ///
    /// libghostty sizes in pixels (`ghostty_surface_set_size`, header 1174) and derives
    /// the grid (cols/rows) from its OWN measured cell metrics, then fires
    /// `resize_callback` → ``onResize`` so the host gets the right `TIOCSWINSZ`. This is
    /// the correct GUI path: pass the layer's real pixel extent and let libghostty own the
    /// grid. (The cols/rows round-trip in ``setSize(cols:rows:)`` is only for headless/test
    /// drivers — using it from layout double-applies the cell size and oversizes the
    /// surface, which prevents the Metal layer from presenting.)
    public func setPixelSize(widthPx: UInt32, heightPx: UInt32) {
        guard let s = surface, widthPx > 0, heightPx > 0 else {
            rdbg("setPixelSize SKIPPED w=\(widthPx) h=\(heightPx) surface=\(surface != nil)")
            return
        }
        rdbg("setPixelSize \(widthPx)x\(heightPx)")
        ghostty_surface_set_size(s, widthPx, heightPx)   // header 1174
    }

    /// Updates the backing scale factor (e.g. moving between Retina/non-Retina).
    /// `ghostty_surface_set_content_scale` (header 1170).
    public func setContentScale(_ scale: Double) {
        contentScale = scale
        if let s = surface {
            ghostty_surface_set_content_scale(s, scale, scale)
        }
    }

    // MARK: TerminalSurface — Input

    /// Protocol entry point for already-encoded terminal bytes (headless drivers /
    /// tests). The REAL GUI input path routes physical keys through ``key(_:)`` and
    /// composed text through ``text(_:)`` so Ghostty does the kitty/DECCKM encoding
    /// (DECISIONS: "route every key via ghostty_surface_key"). For a raw byte blob
    /// we treat it as text input the surface should send to the host as-is.
    public func handleInput(_ bytes: Data) {
        text(String(decoding: bytes, as: UTF8.self))
    }

    /// Routes a physical key event through Ghostty's encoder.
    ///
    /// `ghostty_surface_key(surface, ghostty_input_key_s)` (header 1180). Ghostty
    /// reads live kitty_flags/DECCKM and encodes the correct bytes, then emits them
    /// via the `write_callback` → ``onWrite``. DECISIONS: route ALL keys here; do
    /// NOT hand-roll VT100 (the Lakr233 bypass is wrong for a remote PTY in
    /// kitty/DECCKM mode).
    ///
    /// - Returns: whether Ghostty consumed the key (header 1180 returns `bool`).
    @discardableResult
    public func key(_ event: ghostty_input_key_s) -> Bool {
        guard let s = surface else { return false }
        return ghostty_surface_key(s, event)   // header 1180
    }

    /// Sends committed text (IME / paste / printable input) to the surface.
    ///
    /// `ghostty_surface_text(surface, ptr, len)` (header 1184). For CJK/IME the GUI
    /// uses a hidden `UITextView` proxy (doc 17 §2.2) that funnels committed text
    /// here, while Ctrl/Alt+letter go through ``key(_:)``.
    public func text(_ s: String) {
        guard let surf = surface, !s.isEmpty else { return }
        var copy = s
        copy.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cptr in
                // header 1184 takes `uintptr_t` (imported as Swift `UInt`).
                ghostty_surface_text(surf, cptr, UInt(buf.count))   // header 1184
            }
        }
    }

    // MARK: TerminalSurface — Mouse / scroll / selection / clipboard
    //
    // Pointer + clipboard wiring (the second half of the GUI input path, after keys/text).
    // Each wrapper is a thin `guard let surface` over the C ABI, mirroring upstream Ghostty's
    // `Ghostty.Surface.swift:90-156` (`mouseCaptured`, `sendMouseButton`, `sendMousePos`,
    // `sendMouseScroll`, `perform(action:)`). The embedding NSView (`GhosttyLayerBackedView`)
    // forwards AppKit events here; libghostty owns mouse-reporting mode (X10/1000/1002/1003/SGR),
    // text selection, and bracketed-paste, so the embedder never hand-rolls any of it.

    /// Whether the terminal app has captured the mouse (enabled a mouse-reporting mode).
    /// `ghostty_surface_mouse_captured` (header 1188). Upstream: `Surface.swift:90`.
    /// When `true` the embedder must NOT treat a drag as a local text-selection gesture —
    /// libghostty is forwarding the motion to the remote program instead.
    public var mouseCaptured: Bool {
        guard let s = surface else { return false }
        return ghostty_surface_mouse_captured(s)   // header 1188
    }

    /// Sends a mouse button press/release. `ghostty_surface_mouse_button` (header 1189) returns
    /// whether libghostty CONSUMED the event (e.g. a right-click it turned into a paste, or a
    /// click the terminal program is reporting). Upstream: `Surface.swift:102-109`.
    @discardableResult
    public func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        guard let s = surface else { return false }
        return ghostty_surface_mouse_button(s, state, button, mods)   // header 1189
    }

    /// Reports the cursor position in POINTS (view-local, y-flipped by the caller so origin is
    /// top-left). libghostty applies `contentScale` internally — do NOT pre-multiply by the
    /// backing scale (header note: selection bounds are in "points"). `ghostty_surface_mouse_pos`
    /// (header 1193). Upstream: `Surface.swift:118-125`. Pass (-1, -1) to mark "cursor left the
    /// viewport" (the upstream `mouseExited` convention).
    public func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let s = surface else { return }
        ghostty_surface_mouse_pos(s, x, y, mods)   // header 1193
    }

    /// Sends a scroll-wheel delta with the packed precision/momentum mods. `deltaX`/`deltaY` are the
    /// raw `NSEvent.scrollingDelta*` (already ×2'd for precision by the caller, matching upstream).
    /// `ghostty_surface_mouse_scroll` (header 1197). Upstream: `Surface.swift:134-141`. The mods are a
    /// packed `ghostty_input_scroll_mods_t` (Int32: bit0 = precision, bits1-3 = momentum) the caller
    /// builds per `Ghostty.Input.swift:438-465`.
    public func sendMouseScroll(deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t) {
        guard let s = surface else { return }
        ghostty_surface_mouse_scroll(s, deltaX, deltaY, mods)   // header 1197
    }

    /// Forwards a trackpad pressure event (force-click stages). `ghostty_surface_mouse_pressure`
    /// (header 1201). Upstream: `SurfaceView_AppKit.swift:1039`. Reset to (0, 0) on mouse-up.
    public func sendMousePressure(stage: UInt32, pressure: Double) {
        guard let s = surface else { return }
        ghostty_surface_mouse_pressure(s, stage, pressure)   // header 1201
    }

    /// Whether the surface currently holds a text selection (`ghostty_surface_has_selection`,
    /// header 1216). Used by the embedder to decide whether Cmd-C has anything to copy.
    public func hasSelection() -> Bool {
        guard let s = surface else { return false }
        return ghostty_surface_has_selection(s)   // header 1216
    }

    /// Reads the current selection as a Swift `String`, or `nil` if there is none.
    ///
    /// `ghostty_surface_read_selection(surface, &text)` (header 1217) fills a `ghostty_text_s`
    /// (header 381) whose `text` is a NUL-terminated UTF-8 buffer OWNED BY libghostty; we copy it
    /// into a Swift `String` and then MUST `ghostty_surface_free_text` (header 1221) — the
    /// `defer` guarantees the free on every return path. Mirrors upstream
    /// `SurfaceView_AppKit.swift:1851-1854` (`String(cString: text.text)` + `free_text`).
    public func readSelection() -> String? {
        guard let s = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }   // header 1217
        defer { ghostty_surface_free_text(s, &text) }                        // header 1221 — libghostty owns the buffer
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)                                          // upstream copies via String(cString:)
    }

    /// Performs a named libghostty keybinding action (e.g. `copy_to_clipboard`,
    /// `paste_from_clipboard`, `select_all`). `ghostty_surface_binding_action(surface, cstr, len)`
    /// (header 1211) returns whether it ran. Upstream `Surface.swift:150-156` passes `len-1` (the
    /// UTF-8 byte length WITHOUT the trailing NUL) — replicated here. Routing paste through this
    /// (not hand-rolled bytes) lets libghostty apply bracketed-paste (DECSET 2004) itself.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else { return false }
        let len = action.utf8CString.count
        if len == 0 { return false }
        return action.withCString { cstr in
            ghostty_surface_binding_action(s, cstr, UInt(len - 1))   // header 1211 (len excludes NUL — upstream Surface.swift:154)
        }
    }

    /// Completes a pending clipboard READ request libghostty asked for via `read_clipboard_cb`.
    /// `ghostty_surface_complete_clipboard_request(surface, cstr, state, confirmed)` (header 1212)
    /// hands the host-pasteboard string back to the requesting OSC-52 / paste flow. Mirrors upstream
    /// `App.swift:360-368` (`completeClipboardRequest`). `state` is the opaque token the C callback
    /// supplied — passed straight back through so libghostty can resume the suspended request.
    ///
    /// `confirmed` is the access-gate answer. libghostty ships `clipboard-read = .ask` and
    /// `clipboard-paste-protection = true` by default, so the FIRST completion (from `read_clipboard_cb`)
    /// passes `confirmed: false` to EXERCISE the gate: for an OSC-52 read, or a paste of unsafe
    /// (non-bracketed, control-char) content, core then returns `UnauthorizedPaste`/`UnsafePaste` and
    /// re-asks via `confirm_read_clipboard_cb`. That confirm path is the embedder's approve/deny decision
    /// point (upstream shows a dialog); Aislopdesk has no dialog, so it AUTO-APPROVES by passing
    /// `confirmed: true` there. Passing `false` on the confirm path would re-trip the same gate and
    /// recurse forever (stack overflow) — the `true` is what actually terminates the request.
    public func completeClipboardRead(_ string: String, state: UnsafeMutableRawPointer?, confirmed: Bool = false) {
        guard let s = surface else { return }
        string.withCString { cstr in
            ghostty_surface_complete_clipboard_request(s, cstr, state, confirmed)   // header 1212
        }
    }

    // MARK: Render hooks (for the GUI coordinator / CVDisplayLink)

    /// Force a refresh + draw (e.g. on focus, occlusion change, or a display-link
    /// tick). Main-thread only (doc 18 §C). `_refresh` (1167) + `_draw` (1168).
    public func redraw() {
        guard let s = surface else { return }
        ghostty_surface_refresh(s)
        ghostty_surface_draw(s)
    }

    /// Non-coalescing frame request intended for a `CADisplayLink` (iOS). Signals
    /// libghostty's RENDERER THREAD (header 1169 `ghostty_surface_draw_now`) to run a
    /// full `updateFrame → rebuildCells → drawFrame` cycle. The glyph atlas + foreground
    /// cells are built LAZILY on that thread; the synchronous `ghostty_surface_draw` (in
    /// `feed`/`redraw`) can race ahead of glyph rasterization and present a zero-fg-cell
    /// frame — the background paints but glyphs do not. Driving this every display tick
    /// lets the renderer thread rasterize + present the glyphs (matches the upstream iOS
    /// embedding, which pairs a CADisplayLink with `draw_now`).
    public func drawNow() {
        guard let s = surface else { return }
        ghostty_surface_draw_now(s)
    }

    /// Focus state (header 1171 `ghostty_surface_set_focus`).
    public func setFocus(_ focused: Bool) {
        if let s = surface { ghostty_surface_set_focus(s, focused) }
    }

    /// Whether the underlying process/backend reported exit (header 1166).
    public var processExited: Bool {
        guard let s = surface else { return true }
        return ghostty_surface_process_exited(s)
    }
}
