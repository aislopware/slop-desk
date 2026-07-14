//
//  GhosttySurface.swift
//  SlopDesk — the ONLY terminal renderer (libghostty-only, no SwiftTerm, no fallback).
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
//  THREADING CONTRACT (doc 18 §C — libghostty threading, SOLVED-by-source;
//  REVISED 2026-06-12, docs/31 follow-up #5: the FEED path moved off-main)
//  ─────────────────────────────────────────────────────────────────────────────
//  The fork's actual C contract for `ghostty_surface_write_output` is SERIALIZATION,
//  not main-thread-ness (embedded.zig doc comment: "NOT safe to call concurrently on
//  the same surface … typically the embedder calls this from a single I/O thread per
//  surface"). `write_output` parses the whole VT stream ON THE CALLING THREAD under
//  `renderer_state.mutex` (Termio.processOutput) — that parse is real CPU the main
//  actor was paying per ingest pass. So:
//    • FEED (`feed`/`feedBatch`) is `nonisolated`: it enqueues onto a per-surface
//      serial `SerialFeedGate` queue — the "single I/O thread per surface" the fork
//      documents. write_output → refresh stay synchronous INSIDE one queue block
//      (doc-18-§C trio, now queue-internal); the present-arming `onContentChanged`
//      hops to main ASYNC (never sync — see the no-deadlock rule below).
//    • EVERYTHING ELSE (key/text/resize/redraw/selection/clipboard/draw) stays
//      `@MainActor`. All of those lock `renderer_state.mutex` internally, so running
//      them concurrently with a queue-side write_output is the fork's own blessed
//      topology (main API thread + one IO thread; Surface.zig draw comment).
//    • TEARDOWN: `close()` nils the main-side pointer, clears the queue-side pointer
//      box, then DEFERS `ghostty_surface_free` into the gate's drain completion
//      (`feedGate.close(onDrained:)` → main.async free) — core `Surface.deinit` joins
//      its threads and DESTROYS `renderer_state.mutex`, so an in-flight write_output
//      racing the free is a use-after-free of both the surface and the mutex; the
//      drain ordering is what makes the free safe. The close is deliberately
//      NON-BLOCKING: a feed block can transitively wait on MAIN (libghostty's VT
//      handlers forever-push into the 64-slot app mailbox drained only by
//      `ghostty_app_tick` on main), so a queue.sync barrier from main could deadlock
//      the app. Our own blocks still must never block on main (`main.async` only).
//    • The C write-callback fires on libghostty's dedicated IO thread (the fork's
//      `External.zig`: "invoked on the IO thread"), NOT synchronously on main — even
//      replies generated during a `feed()` are emitted off-main via the IO mailbox.
//      So `onWrite` MUST be routed through `ghosttyOnMainActor` (the main hop is
//      REQUIRED, not a defensive fallback — see the write_callback below).
//

import Foundation
import SlopDeskTerminal       // TerminalSurface protocol (the renderer seam)
import SlopDeskProtocol       // not strictly needed here; kept for parity with the seam
import CGhostty            // the clang module over include/ghostty.h (link "ghostty")

/// TEMPORARY render-path tracer, gated on the `SLOPDESK_RENDER_DEBUG` env var. Used to diagnose
/// the macOS blank-glyph issue (terminal connected + fed bytes but no text painted). Writes to
/// stderr so a `SlopDesk.app/Contents/MacOS/SlopDesk` launch captures it. Remove once resolved.
let kRenderDebug = ProcessInfo.processInfo.environment["SLOPDESK_RENDER_DEBUG"] != nil
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

/// libghostty-backed ``TerminalSurface`` — SlopDesk's only renderer.
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
/// `@MainActor` enforces the doc-18-§C main-thread contract at the type level for
/// everything EXCEPT the feed path: ``feed(_:)``/``feedBatch(_:)`` are `nonisolated`
/// enqueues onto the per-surface serial ``feedGate`` queue (docs/31 follow-up #5 — see
/// the header THREADING CONTRACT).
@MainActor
public final class GhosttySurface: @MainActor TerminalSurface, FeedBackpressuring, @MainActor TerminalSurfaceActions, @MainActor TerminalViewportSnapshotting, @MainActor TerminalSelectionControl {

    // MARK: Stored state

    /// The libghostty app handle (header line 29). One app process-wide; a surface
    /// is created from it. Held weakly-conceptually: the owning GUI coordinator
    /// keeps the app alive for the surface's lifetime.
    private let app: ghostty_app_t

    /// The opaque surface (header line 31). `nil` only after ``close()``. This is the
    /// MAIN-side gate: every @MainActor API guards on it, so nil-ing it in `close()`
    /// stops key/text/resize/redraw instantly. The FEED queue has its own pointer copy
    /// in ``feedTarget`` (cleared in the same teardown, before the barrier).
    private var surface: ghostty_surface_t?

    /// The feed queue's view of the C surface + the feed counter. Written on the main
    /// actor (publish in `init`, clear in the teardown), read under its lock by feed
    /// blocks — a feed block that runs after `close()` sees `nil` and no-ops.
    private final class FeedTarget: @unchecked Sendable {
        private let lock = NSLock()
        private var pointer: ghostty_surface_t?
        private var feedCount = 0

        func publish(_ surface: ghostty_surface_t?) {
            lock.lock()
            pointer = surface
            lock.unlock()
        }

        func take() -> ghostty_surface_t? {
            lock.lock()
            defer { lock.unlock() }
            return pointer
        }

        func bumpFeedCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            feedCount += 1
            return feedCount
        }
    }

    private let feedTarget = FeedTarget()

    /// The per-surface serial feed queue + teardown barrier + backpressure (docs/31
    /// follow-up #5). See `SerialFeedGate` for the mechanism and the no-deadlock rule.
    private let feedGate = SerialFeedGate(label: "slopdesk.ghostty.feed")

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
        feedTarget.publish(self.surface)   // the feed queue may now write_output
        rdbg("init: surface=\(self.surface != nil) scale=\(contentScale) cols=\(cols) rows=\(rows)")
    }

    /// Optional grid-resize observer (libghostty → host `TIOCSWINSZ`). The GUI
    /// coordinator sets this to emit a `resize` WireMessage.
    public var onResize: ((UInt16, UInt16) -> Void)?

    /// Fired after a STANDARD-clipboard write libghostty requested for THIS surface actually landed on
    /// the pasteboard (⌘C `copy_to_clipboard`, or an allowed OSC-52 write) — carrying the copied text.
    /// The view wires this to `TerminalViewModel.noteClipboardCopy` so the pane's transient `COPIED · N`
    /// chip lights. SELECTION-clipboard writes (the copy-on-select drag, routed to the private selection
    /// pasteboard) never fire it — a chip per drag tick would be spam. Kept a plain `(String) -> Void`
    /// so this ABI binding stays free of any workspace-core dependency.
    public var onClipboardWrite: ((String) -> Void)?

    /// Fired after each ``feed(_:)``. The embedding view sets this to request a present from its
    /// GATED display-link (`draw_now`). This dirty signal is what lets the renderer present new
    /// content WITHOUT a free-running per-frame `draw_now` — which kept libghostty's renderer libxev
    /// loop permanently kicked and busy-spinning at ~100% CPU.
    public var onContentChanged: (() -> Void)?

    /// E8 WI-9 (H14): OSC-22 pointer-shape observer. libghostty parses `OSC 22 ; <css-name> ST` from the
    /// remote program's byte stream and emits a `GHOSTTY_ACTION_MOUSE_SHAPE` action; the app-level
    /// `action_cb` (in `GhosttyApp`) recovers THIS surface from the action target and forwards the raw
    /// `ghostty_action_mouse_shape_e` value here as an `Int32`. The macOS view sets this to translate the
    /// raw shape (via the headless `PointerShapeMapping`) into an `NSCursor`. Kept as a plain `Int32` so
    /// this ABI binding stays free of any AppKit / workspace-core dependency (the cursor policy lives in
    /// the view). iOS leaves it unset (no pointer hardware → no-op).
    public var onMouseShape: ((Int32) -> Void)?

    /// E8 (H9 / ES-E8-6): mouse-hide-while-typing visibility observer. `mouse-hide-while-typing = true`
    /// (default ON) only makes libghostty DECIDE to hide the pointer; it then delegates the actual
    /// hide/show to the embedder via a `GHOSTTY_ACTION_MOUSE_VISIBILITY` action (`Surface.zig`
    /// `hideMouse`/`showMouse`). The app-level `action_cb` (in `GhosttyApp`) recovers THIS surface from the
    /// action target, resolves the raw `ghostty_action_mouse_visibility_e` via the headless
    /// `MouseVisibilityMapping`, and forwards the resulting `visible` Bool here. The macOS view sets this to
    /// drive `NSCursor.setHiddenUntilMouseMoves(!visible)` (mirroring ghostty's `setCursorVisibility`); kept
    /// as a plain `Bool` so this ABI binding stays AppKit-free. iOS leaves it unset (no pointer → no-op).
    public var onMouseVisibility: ((Bool) -> Void)?

    /// Viewport-scroll observer: libghostty's renderer emits a `GHOSTTY_ACTION_SCROLLBAR` action
    /// whenever the viewport/scrollback geometry changes (`terminal.Scrollbar`: `total` screen rows,
    /// viewport `offset` row, viewport `length` rows). The app-level `action_cb` recovers THIS surface
    /// from the action target and forwards the three raw values here; the view wires it to
    /// `TerminalViewModel.noteViewportScroll(atBottom:)` (the prompt-jump landed-flash settle signal).
    /// Kept plain `UInt64`s so this ABI binding stays free of any workspace-core dependency.
    public var onScrollbarChange: ((_ offset: UInt64, _ length: UInt64, _ total: UInt64) -> Void)?

    /// Reports whether the host terminal is on the ALTERNATE screen (a full-screen TUI owns the viewport).
    /// The view wires this to `TerminalViewModel.isAlternateScreen` (the real DECSET 1049/47/1047 parse from
    /// the client `TerminalModeTracker`) so the libghostty-initiated paste BACKSTOP (`write`/middle-click,
    /// which reaches `slopdeskConfirmUnsafePaste` WITHOUT going through the view's `requestPaste`) can apply
    /// the same alt-screen suppression rule as the ⌘V path. `nil` (or unset) ⇒ treat as the primary screen.
    public var isAlternateScreen: (() -> Bool)?

    /// Frees the surface (header 1160). Idempotent. Must run on the main thread.
    ///
    /// TEARDOWN ORDER (the deferred free is load-bearing — see the header contract):
    /// 1. nil the main-side pointer — key/text/resize/redraw stop immediately;
    /// 2. clear the feed queue's pointer box — not-yet-run feed blocks become no-ops;
    /// 3. `feedGate.close(onDrained:)` — NON-BLOCKING: an in-flight `write_output` can
    ///    transitively wait on MAIN (libghostty's VT handlers do a blocking forever-push
    ///    into the process-wide 64-slot app mailbox when it is full, and its ONLY
    ///    consumer is `ghostty_app_tick` on main — review finding). A `queue.sync`
    ///    barrier here would therefore deadlock the whole app (main waits for the feed
    ///    block, the feed block waits for main to tick). Instead the free is DEFERRED
    ///    into the gate's drain completion;
    /// 4. `ghostty_surface_free` then runs on main strictly after every feed block has
    ///    completed (core deinit destroys the renderer mutex an in-flight write_output
    ///    would dereference). The completion captures `self` STRONGLY: the C surface's
    ///    callbacks hold an UNRETAINED `userdata` pointer to this wrapper, so the
    ///    wrapper must outlive the C surface — the capture guarantees deinit cannot run
    ///    until after the free.
    /// Sendable wrapper for the C pointer crossing into the drain completion (the raw
    /// pointer itself is non-Sendable; ownership is unambiguous — close() is the only
    /// producer and the deferred free the only consumer).
    private struct SurfaceHandle: @unchecked Sendable { let pointer: ghostty_surface_t }

    public func close() {
        guard let s = surface else { return }
        surface = nil
        feedTarget.publish(nil)
        let handle = SurfaceHandle(pointer: s)
        feedGate.close { [self] in
            DispatchQueue.main.async {
                ghostty_surface_free(handle.pointer)
                withExtendedLifetime(self) {}
            }
        }
    }

    // `isolated deinit` (Swift 6.2+) guarantees the body runs on this type's actor
    // (the main actor), so it may touch the @MainActor-isolated `surface` (a
    // non-Sendable `ghostty_surface_t?`). SAFETY NET ONLY: the owning view's detach()
    // always calls close() first, which (a) makes this a no-op and (b) keeps `self`
    // alive past the deferred free — so reaching here with a LIVE surface means the
    // wrapper leaked without teardown. In that state the deferred-free path is illegal
    // (capturing `self` in deinit is resurrection) and letting the C surface outlive
    // the wrapper is a dangling-`userdata` UAF, so the synchronous barrier is the only
    // safe cleanup. Its main-dependent-block deadlock edge requires leak-without-
    // detach AND a mailbox-parked feed block simultaneously — accepted for a path
    // that should never execute.
    isolated deinit {
        if let s = surface {
            surface = nil
            feedTarget.publish(nil)
            feedGate.closeBarrier()
            ghostty_surface_free(s)
        }
    }

    // MARK: TerminalSurface — Data IN (off-main: the per-surface serial feed queue)

    /// Feeds inbound PTY/VT bytes into the renderer.
    ///
    /// `ghostty_surface_write_output(surface, ptr, len)` (header 1185) — "feeds data
    /// to the terminal emulator as if it came from a subprocess/PTY … processes the
    /// data through the terminal emulator and triggers a render."
    ///
    /// THREADING (docs/31 follow-up #5): `nonisolated` — this ENQUEUES onto the
    /// per-surface serial ``feedGate`` queue and returns. The fork's contract is
    /// per-surface serialization (its documented topology is exactly one I/O thread
    /// per surface calling this); the serial queue is that thread, and it moves the
    /// VT parse (which runs ON the calling thread under the renderer mutex) off the
    /// main actor. write_output → refresh stay synchronous INSIDE one queue block.
    public nonisolated func feed(_ bytes: Data) {
        enqueueFeed([bytes])
    }

    /// Batch variant: ONE queue block writes every chunk, then refreshes ONCE — under
    /// a backlog the renderer-thread wakeup + present arming are paid per batch, not
    /// per wire chunk.
    public nonisolated func feedBatch(_ chunks: ArraySlice<Data>) {
        enqueueFeed(Array(chunks))
    }

    /// Parks while the feed queue's un-parsed backlog is above high water — the ingest
    /// pump awaits this before each pass, keeping wire credit-at-consumption coupled to
    /// actual parse progress (see `SerialFeedGate`).
    public nonisolated func feedBackpressure() async {
        await feedGate.waitUntilBelowHighWater()
    }

    /// Enqueues one feed block: N × write_output + ONE refresh, then an ASYNC main hop
    /// for the present arming. `Data` is value-copied into the block (CoW — no race
    /// with the caller). The block captures `self` WEAKLY (a pending block must not
    /// delay deinit) and reads the C pointer from ``feedTarget`` at RUN time, so a
    /// block that runs after `close()` no-ops.
    ///
    /// ⚠️ NO-DEADLOCK RULE: nothing in this block may BLOCK on the main thread
    /// (`close()` runs the gate's `queue.sync` barrier FROM main). The only main
    /// interaction is the trailing `DispatchQueue.main.async`.
    private nonisolated func enqueueFeed(_ chunks: [Data]) {
        let total = chunks.reduce(0) { $0 + $1.count }
        guard total > 0 else { return }
        feedGate.enqueue(byteCount: total) { [feedTarget, weak self] in
            guard let s = feedTarget.take() else {
                rdbg("feed SKIPPED (surface closed) \(total)B")
                return
            }
            for chunk in chunks where !chunk.isEmpty {
                let n = feedTarget.bumpFeedCount()
                if kRenderDebug, n <= 6 || n % 50 == 0 { rdbg("feed #\(n) \(chunk.count)B") }
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    let cptr = base.assumingMemoryBound(to: CChar.self)
                    // header 1185 takes `uintptr_t` (imported as Swift `UInt`).
                    ghostty_surface_write_output(s, cptr, UInt(chunk.count))   // header 1185
                }
            }
            // Refresh = renderer-thread wakeup → updateFrame (rebuild cells). Safe from
            // this queue: it is only a libxev cross-thread async notify (Surface.zig
            // refreshCallback → queueRender), and processOutput already queues a render
            // under the lock anyway. Do NOT call `ghostty_surface_draw` here: the
            // present is driven by the view's gated display-link tick via
            // `layer.setNeedsDisplay()` (inside a CA commit) — a draw from a non-main
            // context sets layer contents that never commit to screen.
            ghostty_surface_refresh(s)   // header 1167
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    // Dirty signal → the view's gated tick presents. Arming MUST stay
                    // main (CADisplayLink pause/unpause is main-confined) and MUST be
                    // async (the no-deadlock rule above).
                    self.onContentChanged?()
                }
            }
        }
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

    /// Publishes the IME preedit (marked / composing) text so libghostty renders it at the
    /// cursor cell with the composing underline (core `renderer_state.preedit`).
    ///
    /// `ghostty_surface_preedit(surface, ptr, len)` (header 1189); `len` EXCLUDES any NUL
    /// (upstream `SurfaceView_AppKit.syncPreedit` passes `utf8CString.count - 1`). Pass `nil`
    /// to CLEAR a finished/cancelled composition — upstream calls
    /// `ghostty_surface_preedit(surface, nil, 0)` for that, and the Zig export only forms the
    /// slice when `len != 0` (embedded.zig 2566), so the nil pointer is never read.
    public func preedit(_ text: String?) {
        guard let surf = surface else { return }
        if var copy = text, !copy.isEmpty {
            copy.withUTF8 { buf in
                guard let base = buf.baseAddress else { return }
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cptr in
                    ghostty_surface_preedit(surf, cptr, UInt(buf.count))   // header 1189
                }
            }
        } else {
            ghostty_surface_preedit(surf, nil, 0)   // clear (the upstream idiom)
        }
    }

    /// Where the IME candidate window should anchor: the cursor cell's bottom-left in the
    /// hosting view's TOP-LEFT-origin POINT space (Surface.zig `imePoint` divides the pixel
    /// position by the content scale, so the values come back unscaled). `width` is the
    /// current preedit extent (0 when empty), `height` one cell.
    ///
    /// `ghostty_surface_ime_point(surface, &x, &y, &w, &h)` (header 1204).
    public func imePoint() -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let surf = surface else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surf, &x, &y, &w, &h)   // header 1204
        return (x, y, w, h)
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

    /// A flat, line-oriented text mirror of the FULL screen (visible viewport + retained scrollback) for
    /// the client-side ``TerminalSearchController`` (W14 #5 ⌘F find). Reads the whole screen via
    /// `ghostty_surface_read_text` (header 1220) over a `GHOSTTY_POINT_SCREEN` selection spanning top-left
    /// → bottom-right (the full scrollback range), then splits on newlines. libghostty owns the returned
    /// buffer, so we copy + `free_text` (the `defer`, every path). Returns `[]` when the surface is gone or
    /// the read fails (validate-then-drop). NOT a test path — the real surface hangs headless; the find
    /// engine itself is unit-tested against an in-memory buffer.
    public func scrollbackTextLines() -> [String] {
        guard let s = surface else { return [] }
        // The whole screen: SCREEN-space top-left to bottom-right (coord hints pick the extremes).
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_SCREEN
        sel.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        sel.bottom_right.tag = GHOSTTY_POINT_SCREEN
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        sel.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &text) else { return [] }   // header 1220
        defer { ghostty_surface_free_text(s, &text) }                       // libghostty owns the buffer
        guard let ptr = text.text else { return [] }
        // Split into lines (drop a single trailing empty so a final newline doesn't add a phantom row).
        var lines = String(cString: ptr).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The live grid COLUMN count (``TerminalSurfaceActions`` seam), used to map an unwrapped LOGICAL scrollback
    /// line index (into ``scrollbackTextLines()``, whose soft-wrapped rows are collapsed) to the PHYSICAL grid
    /// row `scroll_to_row:` addresses. Read from the measured `ghostty_surface_size` (header 1177), falling back
    /// to the mirrored `cols` seed before the first layout. `0` when the surface is gone (validate-then-drop).
    public func scrollbackGridColumns() -> Int {
        guard let s = surface else { return 0 }
        let sz = ghostty_surface_size(s)   // header 1177 → ghostty_surface_size_s
        return sz.columns > 0 ? Int(sz.columns) : Int(cols)
    }

    // MARK: TerminalViewportSnapshotting (E10 WI-2 — overlay geometry seam)
    //
    // The VISIBLE-grid text + cell geometry the E10 link-underline (WI-5) and Hint Mode (WI-9)
    // overlays consume to draw at the exact cell. Compiled + code-reviewed only (the real surface
    // hangs headless — the hang-safety rule); the pure rect math it feeds is unit-tested via
    // `TerminalCellMetrics` + `TerminalLinkDetector`. Headless/placeholder surfaces never conform, so
    // the overlays read `nil`/`[]` and simply do not render (the honest ceiling, never a faked underline).

    /// The VISIBLE viewport rows top→bottom (NOT the retained scrollback — that is
    /// ``scrollbackTextLines()``), ONE entry per DISPLAYED grid row so the array index EQUALS the grid row.
    ///
    /// E10 review FINDING 3 — the overlay-geometry contract. `ghostty_surface_read_text` over a multi-row
    /// VIEWPORT selection returns logically-UNWRAPPED lines (the correct COPY semantics — that is exactly
    /// what ``scrollbackTextLines()`` wants, so it stays untouched). But a soft-wrapped line occupying 2+
    /// grid rows then collapses to ONE array entry, shifting every later entry UP versus the actual grid
    /// AND pushing the long line's own `colStart` past the grid width. The E10 overlays (WI-5 ⌘-hold
    /// underline, WI-9 Hint Mode) index THIS array as the visible grid row via `metrics.rect(row:…)`, so a
    /// soft-wrapped URL/path — precisely the content these features target — would misalign. The fix is a
    /// PER-GRID-ROW read: each visible row is read with its OWN single-row selection
    /// (`GHOSTTY_POINT_COORD_EXACT`, top-left `(0, r)` → bottom-right `(cols-1, r)`). A selection bounded to
    /// one grid row reads only that row's cells — never the unwrapped logical line — so the array index now
    /// maps 1:1 to the grid row even across a soft-wrapped line.
    ///
    /// The grid extent comes from the measured ``ghostty_surface_size`` (falling back to the mirrored
    /// `cols`/`rows` seed before the first layout). If it is not yet known we degrade to the old
    /// whole-viewport read (``viewportTextRowsUnwrapped(_:)``) rather than render no overlay at all.
    ///
    /// The row→pixel mapping is now strictly per-grid-row; full VISUAL proof of the alignment is the GUI
    /// gate (`scripts/check-macos.sh`) — a GUI-only residual the headless core cannot pixel-verify, but the
    /// per-grid-row read is the correct fix. libghostty owns each returned buffer ⇒ copy + `free_text` on
    /// every path (validate-then-drop).
    public func viewportTextRows() -> [String] {
        guard let s = surface else { return [] }
        let sz = ghostty_surface_size(s)   // header 1177 → ghostty_surface_size_s
        let gridCols = sz.columns > 0 ? Int(sz.columns) : Int(cols)
        let gridRows = sz.rows > 0 ? Int(sz.rows) : Int(rows)
        // Extent not yet measured: degrade to the unwrapped whole-viewport read (a transient pre-layout
        // state) rather than return [] and blank the overlay.
        guard gridCols > 0, gridRows > 0 else { return viewportTextRowsUnwrapped(s) }
        var out: [String] = []
        out.reserveCapacity(gridRows)
        for row in 0..<gridRows {
            out.append(readViewportRow(s, row: row, cols: gridCols))
        }
        return out
    }

    /// Reads ONE visible grid row (`row`, 0-based) as text via a single-row VIEWPORT selection. The EXACT
    /// coord uses the explicit `x`/`y` fields (unlike the TOP_LEFT/BOTTOM_RIGHT extreme hints, which ignore
    /// them), so the selection is bounded to row `row`, columns `0 ..< cols`, and reads only that grid row's
    /// cells — never the unwrapped logical line. A failed / empty read yields `""` (an empty grid row),
    /// preserving the array-index ⟷ grid-row alignment. libghostty owns the buffer ⇒ copy + `free_text`.
    private func readViewportRow(_ s: ghostty_surface_t, row: Int, cols: Int) -> String {
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
        sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
        sel.top_left.x = 0
        sel.top_left.y = UInt32(row)
        sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
        sel.bottom_right.x = UInt32(cols - 1)
        sel.bottom_right.y = UInt32(row)
        sel.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &text) else { return "" }   // header 1220
        defer { ghostty_surface_free_text(s, &text) }                       // libghostty owns the buffer
        guard let ptr = text.text else { return "" }
        // A single-row selection returns just that row; strip a lone trailing newline if one is appended.
        var line = String(cString: ptr)
        if line.hasSuffix("\n") { line.removeLast() }
        return line
    }

    /// FALLBACK only (see ``viewportTextRows()``): the original single whole-viewport read split on `\n`.
    /// Used ONLY when the grid extent is not yet measured (pre-first-layout). It carries the documented
    /// soft-wrap mis-alignment, so it is a transient pre-layout degradation, never the steady state.
    private func viewportTextRowsUnwrapped(_ s: ghostty_surface_t) -> [String] {
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
        sel.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        sel.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &text) else { return [] }   // header 1220
        defer { ghostty_surface_free_text(s, &text) }                       // libghostty owns the buffer
        guard let ptr = text.text else { return [] }
        var lines = String(cString: ptr).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The live cell geometry in POINTS, or `nil` when there is no live surface (``close()``-d).
    ///
    /// The authoritative measured grid + cell extent come from `ghostty_surface_size` (header 1177 →
    /// `ghostty_surface_size_s`: `columns`/`rows` + `cell_width_px`/`cell_height_px`) once the font has
    /// laid out; this is a READ-only probe (unlike ``setSize(cols:rows:)`` it does NOT write back to the
    /// `cellWidthPx`/`cellHeightPx` seeds), falling back to those seeds + the mirrored `cols`/`rows`
    /// before the first render. libghostty measures cells in PIXELS, so we divide by the backing scale
    /// to hand the overlay POINTS (its coordinate space). The surface fills its hosting view, so the
    /// viewport origin is the view's top-left `(0, 0)` — the overlay is layered directly over the
    /// surface view in `TerminalLeafView` (WI-5). Plain `/` (no `addingProduct`/`fma` — CLAUDE.md §2
    /// habit, kept even though this is view geometry).
    public func cellMetrics() -> TerminalCellMetrics? {
        guard let s = surface else { return nil }
        let sz = ghostty_surface_size(s)   // header 1177 → ghostty_surface_size_s
        let cellWPx = sz.cell_width_px > 0 ? sz.cell_width_px : cellWidthPx
        let cellHPx = sz.cell_height_px > 0 ? sz.cell_height_px : cellHeightPx
        // Guard a zero/NaN backing scale (NaN > 0 is false → 1) so the px→pt divide can never blow up.
        let scale = contentScale > 0 ? CGFloat(contentScale) : 1
        let gridCols = sz.columns > 0 ? Int(sz.columns) : Int(cols)
        let gridRows = sz.rows > 0 ? Int(sz.rows) : Int(rows)
        return TerminalCellMetrics(
            cellWidth: CGFloat(cellWPx) / scale,
            cellHeight: CGFloat(cellHPx) / scale,
            cols: gridCols,
            rows: gridRows,
            originX: 0,
            originY: 0,
        )
    }

    // MARK: TerminalSelectionControl (the E17 ceiling lift — keyboard copy-mode seam)
    //
    // Backed by the fork's slopdesk C APIs (ghostty_surface_set_selection / clear_selection /
    // viewport_info — see ThirdParty/ghostty/README.md "the SLIM delta"). Compiled + code-reviewed
    // only (hang-safety rule); the pure cursor/motion state these feed is unit-tested against a
    // recording mock in the core package.

    /// The live viewport/extent/cursor readback in SCREEN coordinates, or `nil` when the surface is
    /// gone / the readback fails (validate-then-drop → copy-mode runs cursor-less, the honest ceiling).
    public func viewportInfo() -> TerminalViewportInfo? {
        guard let s = surface else { return nil }
        var info = ghostty_viewport_info_s()
        guard ghostty_surface_viewport_info(s, &info) else { return nil }
        return TerminalViewportInfo(
            viewportTopRow: Int(info.viewport_top_y),
            viewportRows: Int(info.viewport_rows),
            cols: Int(info.cols),
            totalRows: Int(info.total_rows),
            cursor: TerminalScreenPoint(col: Int(info.cursor_x), row: Int(info.cursor_y)),
        )
    }

    /// Sets the selection anchor→head (inclusive, SCREEN coordinates, either order — libghostty
    /// orders internally; `rectangle` = block select). libghostty clamps out-of-range points to the
    /// screen bounds and paints the selection natively (never a client-drawn rectangle). Negative
    /// coordinates are clamped to 0 here (the C ABI is unsigned).
    @discardableResult
    public func setSelection(anchor: TerminalScreenPoint, head: TerminalScreenPoint, rectangle: Bool) -> Bool {
        guard let s = surface else { return false }
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_SCREEN
        sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
        sel.top_left.x = UInt32(max(0, anchor.col))
        sel.top_left.y = UInt32(max(0, anchor.row))
        sel.bottom_right.tag = GHOSTTY_POINT_SCREEN
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
        sel.bottom_right.x = UInt32(max(0, head.col))
        sel.bottom_right.y = UInt32(max(0, head.row))
        sel.rectangle = rectangle
        return ghostty_surface_set_selection(s, sel)
    }

    /// Clears any selection (leaving visual mode). Safe when nothing is selected.
    public func clearSelection() {
        guard let s = surface else { return }
        ghostty_surface_clear_selection(s)
    }

    /// One SCREEN-coordinate row's text for the copy-mode word/column motions — the same
    /// single-row EXACT-point read as ``readViewportRow(_:row:cols:)`` but in SCREEN space, so the
    /// cursor row can be read even while the viewport scrolls. `nil` when the surface is gone or
    /// the read fails; `""` is a legitimately empty row.
    public func readScreenRow(_ row: Int) -> String? {
        guard let s = surface, row >= 0 else { return nil }
        let sz = ghostty_surface_size(s)   // header → ghostty_surface_size_s
        let gridCols = sz.columns > 0 ? Int(sz.columns) : Int(cols)
        guard gridCols > 0 else { return nil }
        var sel = ghostty_selection_s()
        sel.top_left.tag = GHOSTTY_POINT_SCREEN
        sel.top_left.coord = GHOSTTY_POINT_COORD_EXACT
        sel.top_left.x = 0
        sel.top_left.y = UInt32(row)
        sel.bottom_right.tag = GHOSTTY_POINT_SCREEN
        sel.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
        sel.bottom_right.x = UInt32(gridCols - 1)
        sel.bottom_right.y = UInt32(row)
        sel.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }                       // libghostty owns the buffer
        guard let ptr = text.text else { return nil }
        var line = String(cString: ptr)
        if line.hasSuffix("\n") { line.removeLast() }
        return line
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
    /// point (upstream shows a dialog); SlopDesk has no dialog, so it AUTO-APPROVES by passing
    /// `confirmed: true` there. Passing `false` on the confirm path would re-trip the same gate and
    /// recurse forever (stack overflow) — the `true` is what actually terminates the request.
    public func completeClipboardRead(_ string: String, state: UnsafeMutableRawPointer?, confirmed: Bool = false) {
        guard let s = surface else { return }
        string.withCString { cstr in
            ghostty_surface_complete_clipboard_request(s, cstr, state, confirmed)   // header 1212
        }
    }

    // MARK: Paste-protection approval (E8 / ES-E8-3)

    /// One-shot "the embedder already ran the paste-protection sheet for THIS paste and the user
    /// approved it" flag. The embedder sets it immediately before `performBindingAction("paste_from_clipboard")`
    /// (inside the SYNCHRONOUS approved-paste window) and clears it right after; while set, the next clipboard
    /// READ completion passes `confirmed: true` (allow_unsafe) so libghostty pastes WITHOUT re-evaluating its
    /// own (narrower) `isSafe` gate — preventing a SECOND confirmation dialog for a paste the user already
    /// authorised. Because the binding-action read fires synchronously on the main thread inside
    /// `performBindingAction`, this is effectively scoped to that call: it can never leak `allow_unsafe` into
    /// an unrelated OSC-52 read (those fire from a separate `feed` call stack, with the flag already cleared).
    public var pasteApprovedOnce: Bool = false

    /// The EXACT text the paste-protection sheet inspected + previewed, captured at decide time and set
    /// alongside ``pasteApprovedOnce`` inside the synchronous approved-paste window. `read_clipboard_cb`
    /// returns THIS (via ``consumeApprovedPaste()``) instead of RE-READING the live pasteboard, closing the
    /// TOCTOU where a hosted-PTY OSC-52 write (or the user copying elsewhere while the non-modal sheet is
    /// open) could swap the clipboard between the preview and the approved paste — so "Paste Anyway" pastes
    /// what the user reviewed, never newly-arrived bytes. `nil` on every non-approved read.
    public var approvedPasteText: String?

    /// Reads and CLEARS ``pasteApprovedOnce``/``approvedPasteText`` together — `read_clipboard_cb` calls
    /// this so an embedder-approved unsafe paste completes with `confirmed: true` exactly once AND pastes
    /// the reviewed snapshot (not a fresh pasteboard read). Every other read gets `(false, nil)`, keeping
    /// the default `confirmed: false` so the OSC-52 read access gate is never bypassed.
    public func consumeApprovedPaste() -> (approved: Bool, text: String?) {
        let approved = pasteApprovedOnce
        let text = approvedPasteText
        pasteApprovedOnce = false
        approvedPasteText = nil
        return (approved, text)
    }

    /// Reads and CLEARS ``pasteApprovedOnce`` — retained for callers that only need the confirmed flag.
    public func consumePasteApproval() -> Bool {
        let approved = pasteApprovedOnce
        pasteApprovedOnce = false
        approvedPasteText = nil
        return approved
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
