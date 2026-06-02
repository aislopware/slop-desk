//
//  GhosttySurface.swift
//  Rwork — the ONLY terminal renderer (libghostty-only, no SwiftTerm, no fallback).
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
//    • The C write-callback fires SYNCHRONOUSLY on the main thread from Ghostty's
//      key encoder, so `onWrite` is invoked on main; we hand bytes to the client
//      without blocking the encoder.
//    • Hazard (doc 18 §C): actor-suspension escape — do NOT `await` *between*
//      write_output → refresh → draw; keep that trio synchronous (it is, below).
//

import Foundation
import RworkTerminal       // TerminalSurface protocol (the renderer seam)
import RworkProtocol       // not strictly needed here; kept for parity with the seam
import CGhostty            // the clang module over include/ghostty.h (link "ghostty")

/// libghostty-backed ``TerminalSurface`` — Rwork's only renderer.
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
    /// Invoked on the main thread from the C `write_callback`.
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
            let bytes = Data(bytes: dataPtr, count: len)
            // Already on the main thread (encoder fires synchronously on main).
            MainActor.assumeIsolated {
                me.onWrite?(bytes)
            }
        }

        // resize_callback (header 432 typedef; 468 field): libghostty tells us the
        // grid changed (e.g. font reflow). We forward cols/rows to the host via the
        // SAME `onWrite`-adjacent seam in the GUI coordinator. Kept minimal here.
        config.resize_callback = { (cSurface, newCols, newRows, _, _) in
            guard let cSurface, let ud = ghostty_surface_userdata(cSurface) else { return }
            let me = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
            MainActor.assumeIsolated {
                me.cols = newCols
                me.rows = newRows
                // The GUI coordinator observes (cols,rows) to emit a `resize`
                // WireMessage to the host (TIOCSWINSZ). Surfaced via onResize hook
                // below to keep this type protocol-pure.
                me.onResize?(newCols, newRows)
            }
        }

        // ghostty_surface_new (header 1158). Must be on main thread. The config
        // already carries `userdata = self` so the C callbacks above can recover us.
        self.surface = ghostty_surface_new(app, &config)
    }

    /// Optional grid-resize observer (libghostty → host `TIOCSWINSZ`). The GUI
    /// coordinator sets this to emit a `resize` WireMessage.
    public var onResize: ((UInt16, UInt16) -> Void)?

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
    public func feed(_ bytes: Data) {
        guard let s = surface, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let cptr = base.assumingMemoryBound(to: CChar.self)
            // header 1185 takes `uintptr_t` (imported as Swift `UInt`).
            ghostty_surface_write_output(s, cptr, UInt(bytes.count))   // header 1185
        }
        // Coalescing redraw (VVTerm `scheduleCustomIORedraw` pattern). The render is
        // already triggered by write_output; refresh+draw force the next frame. Both
        // are main-thread-only (doc 18 §C).
        ghostty_surface_refresh(s)   // header 1167
        ghostty_surface_draw(s)      // header 1168
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
        guard let s = surface, widthPx > 0, heightPx > 0 else { return }
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
