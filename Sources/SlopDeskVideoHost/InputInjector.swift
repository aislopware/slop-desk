#if os(macOS)
import AppKit
import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// Injects remote input into a tracked window using the **activate-then-control**
/// model (doc 18 §A — Dissolved-by-decision; doc 05).
///
/// ⚠️ **GUI-ONLY + TCC:** this code drives real input. It needs three TCC grants and
/// is ship-outside-the-Mac-App-Store / non-sandboxed (doc 05 §0):
/// 1. **Accessibility** — for `AXUIElementPerformAction(kAXRaiseAction)` + setting
///    `kAXFocusedWindow`/`kAXMainWindow`.
/// 2. **'Post Event' (a.k.a. "Accessibility / Input Monitoring" post)** — required by
///    `CGEvent.post` to synthesise HID events (doc 18 §B point 1).
/// 3. **Screen Recording** — the capture side (`WindowCapturer`) needs it; bundled
///    here for completeness.
/// COMPILED + reviewed; NEVER driven from tests.
///
/// Per-interaction flow (doc 18 §A, doc 05 §6):
/// 1. Raise + focus the target window (`slopdesk_app_activate` + AX
///    `kAXRaiseAction` / set `kAXFocusedWindow`) → it becomes frontmost.
/// 2. Map the event's normalised window coordinate → host-window CG point via
///    ``CoordinateMapping`` (no Y flip; the click point is CG top-left, doc 05 §2).
/// 3. `CGEvent.post(.cghidEventTap)` / `CGWarpMouseCursorPosition`, stamping
///    `eventSourceUserData` = the event's `tag` so the host can FILTER its own
///    self-injected events out of the cursor/geometry watchers (avoids loops).
public final class InputInjector: @unchecked Sendable {
    private let pid: pid_t
    private let windowID: CGWindowID
    /// The `kCGWindowBounds` (CG top-left points) of the target window, kept in sync
    /// by the geometry watcher so mapping stays correct as the window moves.
    private var windowBoundsCG: VideoRect
    private let boundsLock = NSLock()

    /// SAFETY button-balance. On a `mouseDown` for an already-held button it injects a synthetic
    /// release first, so a fresh click never starts inside a selection stranded by a lost
    /// `mouseUp`. Pure decision lives in ``InputButtonBalance``; the lock guards it (harmless
    /// insurance — in the ordered path injection is already serial). SEEDED at init (see
    /// ``balanceSnapshot``) so a transparent-reconnect injector rebuild carries the held state.
    private let balanceLock = NSLock()
    private var balance: InputButtonBalance

    /// SCROLL RESAMPLE state (active only when ``scrollResampleHz`` > 0). The resampler + its output
    /// timer are CONFINED to `scrollQueue` (a serial queue), so neither needs a lock. `postScroll`
    /// hands each arriving wire scroll to the resampler on this queue; the timer drains it at
    /// ``scrollResampleHz`` and posts the steady high-rate sub-events. See ``scrollResampleHz``.
    private let scrollQueue = DispatchQueue(label: "slopdesk.scroll-resample", qos: .userInteractive)
    /// Resampler drain-curve knob (`SLOPDESK_SCROLL_SPREAD`, default 3): each 4ms tick emits
    /// ~`residual/spread`, so a larger spread trails a LIGHT push out over more ticks (smoother
    /// slow scroll, ≈`(spread−1)·4ms` extra lag); `ScrollResampler.init` sanitizes to [1, 16].
    /// HW A/B (2026-07-21): at 2 a light push emitted a front-loaded chunk then a 1px trickle
    /// ("chưa mượt"); 3 spreads it over ~12ms and the light-push judder is gone, flick response
    /// unchanged (markers + first chunk still post on the ingest hop).
    private static let scrollSpread: Double = {
        guard let s = EnvConfig.string("SLOPDESK_SCROLL_SPREAD"), let v = Double(s) else { return 3.0 }
        return v
    }()

    /// Whether the scroll resampler drives injection (see ``scrollResampleHz``) — read by the
    /// session's scroll-coalesce default: the resampler already caps the post rate (the gate's
    /// anti-flood job), and stacking the 8ms summing gate UNDER it double-quantizes the stream
    /// into uneven chunk sizes (HW: the 60-100ms capture-stall bucket went 212 → 25 when the gate
    /// was lifted with the resampler on).
    static var scrollResamplerActive: Bool { scrollResampleHz > 0 }

    private var scrollResampler = ScrollResampler(spread: InputInjector.scrollSpread)
    private var scrollTimer: DispatchSourceTimer?
    /// The tag of the latest forwarded scroll, stamped on the resampler's interpolated sub-events
    /// (so the self-inject filter still recognises them). Confined to `scrollQueue`.
    private var lastScrollTag: UInt32 = 0

    /// Swipe-back flick recogniser fed from ``inject(_:)``'s scroll arm. Injection is serial per
    /// session, so the lock is the same harmless insurance ``balance`` carries.
    private let swipeNavLock = NSLock()
    private var swipeNav = SwipeNavRecognizer(
        fireTravel: swipeNavTravel, slowSwipe: swipeNavSlow, trace: swipeNavTrace,
    )

    /// Serial background queue for the window-raise AX chain: ~6–10 SYNCHRONOUS cross-process AX
    /// IPC calls (each capped at the 0.08s messaging timeout) + an O(app-windows) match loop —
    /// MEASURED 1–7s against a BACKGROUNDED target (the captured app is never frontmost while the
    /// client drives it, so the `frontmost == target` short-circuit never fires). On the MAIN ACTOR
    /// that starved the cursor-SHAPE refresh (`NSCursor.currentSystem` is main-only) for whole
    /// seconds → the refocus cursor-shape delay (HW-measured `shape-refresh main-hop waited 7380ms`).
    /// The raise is BEST-EFFORT (posted CGEvents deliver clicks regardless) and AX client APIs are
    /// thread-safe, so confining it here keeps the main actor free at no input-path cost.
    private let raiseQueue = DispatchQueue(label: "slopdesk.window-raise", qos: .userInitiated)

    /// Whether the full AX raise chain has run at least once for this session (the CLICK-latency
    /// fix). `raiseQueue`-confined (the raise chain runs off the main actor), so it needs no lock.
    private var hasRaisedTargetOnce = false

    /// When the last raise actually ran (the CLICK-latency throttle). One click fires SEVERAL raise
    /// requests (proactive focus, the mouseDown's `alwaysRaises`, each loss-resilient duplicate mouseUp,
    /// the first post-up move); without a throttle they pile up on ``raiseQueue``. Coalesce: skip a raise
    /// within ``raiseThrottle`` of the previous. Best-effort, so coalescing is harmless. `raiseQueue`-confined.
    private var lastRaiseAt: Date?
    private static let raiseThrottle: TimeInterval = 0.5

    /// The raise target, through ``slopdesk_ax_raiser_new``. The handle resolves the window at most
    /// ONCE and then reuses the element, which is what keeps a raise off the O(app-windows)
    /// accessibility walk; a stale element (window closed) just makes the best-effort calls no-op.
    /// `raiseQueue`-confined, and freed in ``deinit``.
    private let raiser: OpaquePointer?

    /// Test-only same-machine seam (`SLOPDESK_VIDEO_INJECT_TO_PID=1`): deliver events straight to
    /// the target PID via `postToPid` and SKIP the cursor warp, so a loopback host on the SAME
    /// Mac does not hijack the global cursor away from the client window being driven (which
    /// would fight an automated drag). PRODUCTION leaves this off — the remote user's real
    /// cursor must track via the HID warp. Ordering/selection semantics are unchanged; only the
    /// post tap + cursor move differ.
    private static let injectToPid = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_INJECT_TO_PID"] != nil
    private static let inputTrace = ProcessInfo.processInfo.environment["SLOPDESK_INPUT_TRACE"] != nil
    /// PARSEC-STYLE POINTER MOTION (`SLOPDESK_TABLET_MOUSE`, default ON; `=0` restores the warp path).
    /// A remote pointer stream is ~99% hover moves (≈150:1 vs buttons); the warp path injects each behind
    /// THREE synchronous WindowServer IPCs (`CGWarpMouseCursorPosition` +
    /// `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`), which under a hover flood saturates
    /// WindowServer and stalls SCStream capture — the desktop hitches exactly while the pointer moves
    /// (measured 61ms capture-gap). Parsec instead posts ONE event: a tablet-subtype
    /// (`kCGEventMouseSubtypeTabletPoint`) `.mouseMoved` carrying absolute `kCGTabletEventPointX/Y`, no
    /// warp/associate (disasm parsecd-150-104a @0x148a50). VERIFIED end-to-end on macOS 26 (the event alone
    /// positions the host cursor at exact coords — no warp needed; the door still stamps the self-inject
    /// tag, so the `CursorSampler` filter keeps working). Applies to HOVER moves ONLY — DRAGS keep the warp
    /// path so selection engines are byte-unchanged. Escape hatch `=0` for any app that special-cases the
    /// tablet subtype (games/canvas mouse-look — niche on a remote coding desktop).
    private static let tabletMouse = ProcessInfo.processInfo.environment["SLOPDESK_TABLET_MOUSE"] != "0"
    /// Scroll gain multiplier (`SLOPDESK_SCROLL_GAIN`, default 1.0 = byte-identical pass-through).
    /// The client forwards macOS's already-accelerated trackpad deltas 1:1 and the coalescer never
    /// merges/drops a scroll, so distance parity with a local gesture holds at 1.0; this knob is only
    /// for the "travel further per flick" feel A/B (Parsec-style boost). Clamped so a typo can't break scroll.
    private static let scrollGain: Double = {
        guard let s = ProcessInfo.processInfo.environment["SLOPDESK_SCROLL_GAIN"],
              let v = Double(s), v.isFinite, v >= 0.1, v <= 10 else { return 1.0 }
        return v
    }()

    /// Replay the forwarded trackpad gesture phase + inertia on the injected `CGScrollWheelEvent`
    /// (`kCGScrollWheelEventScrollPhase` / `…MomentumPhase`) so Chromium/AppKit run native 1:1
    /// continuous + rubber-band scrolling instead of per-notch easing. Default ON;
    /// `SLOPDESK_SCROLL_PHASE=0` falls back to the prior behaviour (IsContinuous=1, no phase) for A/B.
    private static let scrollPhaseEnabled: Bool = {
        let v = ProcessInfo.processInfo.environment["SLOPDESK_SCROLL_PHASE"]
        return !(v == "0" || v?.lowercased() == "false")
    }()

    /// SWIPE-BACK TRANSLATION (`SLOPDESK_SWIPE_NAV`, default ON; `=0` off). A forwarded phased
    /// scroll can NEVER trigger the browser's own two-finger history swipe — Chromium demands real
    /// `NSTouch` data or `trackSwipeEventWithOptions:` (both reject CGEvent-posted scrolls) and
    /// Safari behaves identically (probe-verified, six field variants). So the injector watches
    /// the stream it posts (``SwipeNavRecognizer``) and, when a completed flick qualifies AND the
    /// receiving app is one where ⌘[ / ⌘] means history (``SwipeNavHostConfig``), posts that key
    /// equivalent. Scroll posting itself is untouched — the page still rubber-bands natively.
    private static let swipeNavEnabled = SwipeNavHostConfig.enabled
    /// Lift-fire travel threshold in points (`SLOPDESK_SWIPE_NAV_TRAVEL`, default 80) — scales the
    /// recogniser's whole threshold family (arm = 0.3×, momentum confirm = 1.5×). Parse + clamp
    /// live in ``SwipeNavHostConfig`` so the client-feedback status push mirrors this exactly.
    private static let swipeNavTravel = SwipeNavHostConfig.fireTravel

    /// Slow-tier acceptance (`SLOPDESK_SWIPE_NAV_SLOW`, default ON; `=0` off): a deliberate slow
    /// swipe fires like native. Turn off to restore the v2 flick-only duration gate if slow
    /// fires ever collide with a horizontal-scrolling browser workload (sheets/maps).
    private static let swipeNavSlow = SwipeNavHostConfig.slowTier

    /// Per-GESTURE swipe-nav decision trace (`SLOPDESK_SWIPE_NAV_TRACE`; also on under the full
    /// `SLOPDESK_INPUT_TRACE`). ≤2 stderr lines per gesture — cheap enough to leave on a daily
    /// driver, and the only way to see the real flick's travel/duration/dominance numbers when a
    /// swipe "didn't count" on hardware.
    private static let swipeNavTrace = ProcessInfo.processInfo
        .environment["SLOPDESK_SWIPE_NAV_TRACE"] != nil || inputTrace

    /// SCROLL RESAMPLE output rate (`SLOPDESK_SCROLL_RESAMPLE_HZ`, default **250**; explicit
    /// `0`/garbage disables → direct-post path). HW-measured:
    /// Chromium/Electron renders INJECTED smooth-scroll at a rate that climbs with the
    /// injection rate, only hitting the display's 60 fps near ~250 Hz (4× vsync); the wire delivers
    /// scroll at the client trackpad rate (~60–120 Hz, burstier under jitter — and the session's
    /// scroll-coalesce gate sums it further), so a captured Chrome/VS Code scroll renders a visibly
    /// juddery ~20–35 fps. The resampler (``ScrollResampler``) re-emits the bursty wire scroll as a
    /// STEADY `Hz` stream via a timer (markers + the first chunk post immediately — flick response
    /// stays instant), driving the source app's native 60 fps smooth-scroll — fixing it at the
    /// source, not client-side reprojection. Default-ON verdict (2026-07-21 fast-LAN A/B): feel
    /// "nhẹ hơn"/closer to Parsec, capture fps unchanged, zero VT drops, no WindowServer-stall
    /// signature at 250 Hz. Clamped [60, 1000].
    private static let scrollResampleHz: Int = {
        // Resolve through `EnvConfig` (ProcessInfo env → settings overlay → nil) so a GUI setting
        // can drive it; an EMPTY overlay is byte-identical to the raw read.
        guard let s = EnvConfig.string("SLOPDESK_SCROLL_RESAMPLE_HZ") else { return 250 }
        guard let v = Int(s), v > 0 else { return 0 } // explicit 0/garbage ⇒ OFF (direct post)
        return max(60, min(1000, v))
    }()

    /// - Parameter balance: the held-button/modifier state to START from. The default (empty) is
    ///   the fresh-session case; a transparent-reconnect rebuild passes the PREVIOUS injector's
    ///   ``balanceSnapshot`` so a button/modifier the user held ACROSS the reconnect still matches
    ///   its eventual up (an empty balance would classify that up as an orphan → suppress → the
    ///   terminating CGEvent is never posted → host OS stuck in drag/modifier state).
    /// DISPLAY-SCOPED injector (the full-desktop pane): coordinates map against the display's CG
    /// bounds and there is NO target window/app — the AX raise chain is skipped entirely
    /// (`CGEvent.post(.cghidEventTap)` already delivers to whatever is frontmost / under the
    /// cursor, which for whole-desktop remoting is exactly right).
    public convenience init(
        displayBoundsCG: VideoRect,
        balance: InputButtonBalance = InputButtonBalance(),
    ) {
        self.init(pid: 0, windowID: 0, windowBoundsCG: displayBoundsCG, balance: balance)
    }

    public init(
        pid: pid_t,
        windowID: CGWindowID,
        windowBoundsCG: VideoRect,
        balance: InputButtonBalance = InputButtonBalance(),
    ) {
        self.pid = pid
        self.windowID = windowID
        self.windowBoundsCG = windowBoundsCG
        self.balance = balance
        // A display-scoped injector (full-desktop pane, pid 0) has no target window to raise, so it
        // holds no raiser at all rather than one that would answer no forever.
        raiser = pid > 0 ? slopdesk_ax_raiser_new(pid, windowID) : nil
        // REGIME BANNER: one line per injector naming the swipe-nav threshold family, so a field
        // log spanning host restarts/deploys self-describes which recognizer produced each
        // verdict — an early audit log carried two lines from a stale build that were
        // identifiable only by their message format having since changed.
        if Self.swipeNavTrace, Self.swipeNavEnabled {
            let travel = Int(Self.swipeNavTravel)
            let slow = Self.swipeNavSlow ? "on" : "off"
            let graceLo = Int(SwipeNavRecognizer.flickMaxDuration * 1000)
            let graceHi = Int(SwipeNavRecognizer.slowGraceMaxDuration * 1000)
            let bandHi = Int(SwipeNavRecognizer.slowDominance)
            let bandLo = Int(SwipeNavRecognizer.slowRelaxedDominance)
            let refractoryMs = Int(SwipeNavRecognizer.refractory * 1000)
            var line = "slopdesk-videohostd[inject]: swipe-nav regime(pid \(pid) win \(windowID))"
            line += " fireTravel=\(travel) slow=\(slow) grace=\(graceLo)→\(graceHi)ms"
            line += " band=\(bandHi)×@\(travel * 2)→\(bandLo)×@\(travel * 3)"
            line += " refractory=\(refractoryMs)ms\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    deinit {
        // Stop the scroll-resample pump. The timer is never suspended (runs continuously once
        // started), so `cancel()` from any thread releases it cleanly — no suspend/resume balance
        // to honour. Safe even if never started (`nil`).
        scrollTimer?.cancel()
        slopdesk_ax_raiser_free(raiser)
    }

    public func updateWindowBounds(_ bounds: VideoRect) {
        boundsLock.lock()
        windowBoundsCG = bounds
        boundsLock.unlock()
    }

    /// The current held-button/modifier balance (a value snapshot, taken under the balance lock).
    /// The session actor reads this off the STALE injector at teardown and threads it into the
    /// replacement injector's `init(balance:)`, so a transparent auto-reconnect never wipes the
    /// knowledge of what the user is physically holding (the stuck-drag/stuck-⌘ reconnect fix).
    public var balanceSnapshot: InputButtonBalance {
        balanceLock.withLock { balance }
    }

    private var bounds: VideoRect {
        boundsLock.lock()
        defer { boundsLock.unlock() }
        return windowBoundsCG
    }

    // MARK: Activate-then-control

    /// Raises + focuses the target window so it is frontmost before posting events
    /// (doc 18 §A). Combines AX raise (reorders even when full app activation is
    /// throttled on macOS 14+) with `activate()` (doc 05 §4 caveat). NONISOLATED: the AX chain
    /// runs on ``raiseQueue`` (off the main actor), so callers never need to wrap it in a main hop.
    public func raiseTargetWindow() {
        // OFF-MAIN: hop the whole AX chain onto ``raiseQueue`` and return IMMEDIATELY — running it
        // here instead of the caller's `Task { @MainActor }` keeps the MAIN ACTOR free for the
        // cursor-SHAPE refresh it was starving. Safe: best-effort + AX client APIs are thread-safe.
        raiseQueue.async { [weak self] in self?.performRaise() }
    }

    /// The actual raise, CONFINED to ``raiseQueue`` (off the main actor). Serial + throttled so the
    /// several raise requests one click fires coalesce.
    private func performRaise() {
        // A display-scoped injector (full-desktop pane, pid 0) has no target window/app to raise —
        // whole-desktop input goes to whatever is frontmost, exactly like a local user.
        guard pid > 0 else { return }
        // Skip the whole chain when the target app is ALREADY frontmost and we have raised at least
        // once. Errs toward raising (``InputInjectorRaisePolicy``): a backgrounded window, a different
        // frontmost app, or an unreadable frontmost still runs the full raise. The read is the
        // WindowServer query (``HostFrontmostApp``) — the daemon's NSWorkspace snapshot freezes at
        // first access, which here could wrongly SKIP the raise forever once the frozen pid matched.
        let frontmostPID = HostFrontmostApp.frontmostPID()
        let willRaise = InputInjectorRaisePolicy.shouldRaise(
            frontmostPID: frontmostPID,
            targetPID: pid,
            firstInteraction: !hasRaisedTargetOnce,
        )
        if Self.inputTrace {
            let f = frontmostPID.map(String.init) ?? "nil"
            FileHandle.standardError
                .write(
                    Data(
                        "slopdesk-videohostd[inject]: raise decision frontmost=\(f) target=\(pid) first=\(!hasRaisedTargetOnce) -> \(willRaise ? "RAISE(full AX chain)" : "SKIP(no AX)")\n"
                            .utf8,
                    ),
                )
        }
        guard willRaise else { return }
        // THROTTLE back-to-back raises within one click (see ``lastRaiseAt``): the first runs; the
        // rest (proactive focus + duplicate ups + post-up move) return instantly, so ``raiseQueue``
        // is never churned by N futile AX chains per click.
        if let lastRaiseAt, Date().timeIntervalSince(lastRaiseAt) < Self.raiseThrottle { return }
        lastRaiseAt = Date()
        hasRaisedTargetOnce = true
        // The whole chain — resolve the window once, raise it, point kAXMainWindow and
        // kAXFocusedWindow at it — is ``slopdesk_ax_raiser_raise``. `bounds` is lent only as the
        // fallback the door uses when the private id symbol resolves NOTHING for any candidate, the
        // locked-screen case; a frame-only match mis-binds when two panes of the same app share an
        // identical frame (both parked at the shared VD's origin, doc 05 §4).
        _ = slopdesk_ax_raiser_raise(raiser, HostDisplays.record(bounds.cgRect))
        _ = slopdesk_app_activate(pid)
    }

    // MARK: Event posting (tagged for self-inject filtering)

    /// Posts a remote input event. The window must already be raised (call
    /// ``raiseTargetWindow()`` for the first event of an interaction).
    public func inject(_ event: InputEvent) {
        // SAFETY auto-release: clear a button left stuck by a lost/never-sent `mouseUp` BEFORE
        // posting a fresh `mouseDown` on it, so a click never begins inside a phantom selection.
        let plan = balanceLock.withLock { balance.plan(for: event) }
        if let stuck = plan.preRelease, case let .mouseDown(_, n, _, mods, tag) = event {
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[inject]: SAFETY pre-release of stuck \(stuck) before mouseDown\n"
                            .utf8))
            }
            postMouseButton(button: stuck, normalized: n, down: false, clickCount: 1, modifiers: mods, tag: tag)
        }
        if plan.suppress {
            // A duplicate up from the client's loss-resilient 3× send (button already
            // released) — drop it so the host never posts a spurious extra *MouseUp.
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[inject]: suppressed duplicate mouseUp (button not held)\n".utf8))
            }
            return
        }
        switch event {
        case let .mouseMove(n, tag):
            postMouseMove(normalized: n, tag: tag)
        case let .mouseDown(button, n, clickCount, mods, tag):
            postMouseButton(
                button: button,
                normalized: n,
                down: true,
                clickCount: clickCount,
                modifiers: mods,
                tag: tag,
            )
        case let .mouseUp(button, n, clickCount, mods, tag):
            postMouseButton(
                button: button,
                normalized: n,
                down: false,
                clickCount: clickCount,
                modifiers: mods,
                tag: tag,
            )
        case let .mouseDrag(button, n, clickCount, mods, tag):
            postMouseDrag(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
        case let .scroll(dx, dy, _, scrollPhase, momentumPhase, continuous, tag):
            postScroll(
                dx: dx,
                dy: dy,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: continuous,
                tag: tag,
            )
            translateSwipeNavIfNeeded(
                dx: dx,
                dy: dy,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: continuous,
            )
        case let .key(keyCode, down, mods, tag):
            postKey(keyCode: keyCode, down: down, modifiers: mods, tag: tag)
        case let .text(string, tag):
            postText(string, tag: tag)
        }
    }

    private func target(_ normalized: VideoPoint) -> CGPoint {
        CoordinateMapping.windowPoint(normalized: normalized, windowBounds: bounds).cgPoint
    }

    /// Where a posted event is DELIVERED. `0` is the HID tap, which is the production path; the
    /// same-machine loopback seam (`SLOPDESK_VIDEO_INJECT_TO_PID`) instead names the target pid, so
    /// a host driving a client on the same Mac does not hijack the global cursor away from the
    /// window under test.
    private var deliverTo: Int32 {
        Self.injectToPid && pid != 0 ? Int32(pid) : 0
    }

    /// One pointer event, spelled for ``slopdesk_inject_pointer``. Every field is a decision this
    /// class already made; the door builds and posts, and makes none of its own.
    private func pointerSpec(
        kind: Int32,
        button: MouseButton,
        at pt: CGPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
        warp: Bool,
        tablet: Bool = false,
    ) -> SlopDeskInjectPointer {
        SlopDeskInjectPointer(
            x: pt.x,
            y: pt.y,
            tag: tag,
            to_pid: deliverTo,
            kind: UInt8(kind),
            button: button.rawValue,
            click_count: clickCount,
            modifiers: modifiers.rawValue,
            warp: warp,
            tablet: tablet,
        )
    }

    private func postMouseMove(normalized: VideoPoint, tag: UInt32) {
        // PARSEC PATH (`tabletMouse`, real-injection only — the loopback `injectToPid` seam keeps the
        // warp path): ONE absolute tablet-point move, no warp/associate → 1 WindowServer IPC not 3,
        // so a hover flood no longer stalls SCStream capture. Otherwise the absolute HOVER move:
        // warp the cursor, then post `.mouseMoved` so apps reading deltas see it (doc 05 §1).
        //
        // A button-held drag is NEVER inferred here — the client sends an explicit `.mouseDrag` (see
        // ``postMouseDrag``), so a move is always a pure hover. Inferring "button held?" from host
        // state would let a lost `mouseUp` strand that state, turning every later hover into a
        // phantom `.leftMouseDragged` (runaway selection). Stateless = no phantom drag.
        let tablet = Self.tabletMouse && !Self.injectToPid
        _ = slopdesk_inject_pointer(pointerSpec(
            kind: SLOPDESK_INJECT_MOVE,
            button: .left,
            at: target(normalized),
            clickCount: 1,
            modifiers: [],
            tag: tag,
            warp: !Self.injectToPid && !tablet,
            tablet: tablet,
        ))
    }

    /// Posts a drag-move: the `*MouseDragged` matching the held `button`. STATELESS — the CLIENT
    /// reported the button held (its view fired `mouseDragged`, distinct from `mouseMoved`), so the
    /// host never tracks held state. Statelessness is also wire-reorder-safe: over UDP a drag can
    /// arrive before its `mouseDown`; the app ignores a dragged with no active session, then anchors
    /// on the down and extends to the final drag — so the range stays correct even if early drag
    /// samples are lost or reordered.
    private func postMouseDrag(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    ) {
        _ = slopdesk_inject_pointer(pointerSpec(
            kind: SLOPDESK_INJECT_DRAG,
            button: button,
            at: target(normalized),
            clickCount: clickCount,
            modifiers: modifiers,
            tag: tag,
            warp: !Self.injectToPid,
        ))
    }

    private func postMouseButton(
        button: MouseButton,
        normalized: VideoPoint,
        down: Bool,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    ) {
        // Warp before posting so a tap with no preceding move still lands at the mapped point and
        // the visible cursor agrees with where the click registers. Safe because the door zeroes the
        // source's suppression interval and re-associates the cursor after every warp.
        _ = slopdesk_inject_pointer(pointerSpec(
            kind: down ? SLOPDESK_INJECT_DOWN : SLOPDESK_INJECT_UP,
            button: button,
            at: target(normalized),
            clickCount: clickCount,
            modifiers: modifiers,
            tag: tag,
            warp: !Self.injectToPid,
        ))
    }

    /// Routes a forwarded wire scroll. With ``scrollResampleHz`` == 0 (default) it posts the event
    /// DIRECTLY (legacy, byte-identical). When enabled, it hands the event to the resampler on
    /// `scrollQueue`: marker phases (Began/Ended/momentum boundaries) post immediately, while the
    /// continuous stream accumulates and the timer drains it at the steady high output rate.
    private func postScroll(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        tag: UInt32,
    ) {
        guard Self.scrollResampleHz > 0 else {
            postScrollEvent(
                dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase,
                continuous: continuous, tag: tag,
            )
            return
        }
        scrollQueue.async { [weak self] in
            guard let self else { return }
            lastScrollTag = tag
            let markers = scrollResampler.ingest(
                dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase, continuous: continuous,
            )
            for m in markers {
                postScrollEvent(
                    dx: m.dx, dy: m.dy, scrollPhase: m.scrollPhase, momentumPhase: m.momentumPhase,
                    continuous: m.continuous, tag: tag,
                )
            }
            // Emit the FIRST resampled chunk on THIS hop (no full-tick wait) so a fresh scroll moves
            // pixels immediately (P1 zero-latency); the timer then maintains the steady output rate.
            if let sub = scrollResampler.drain() {
                postScrollEvent(
                    dx: sub.dx, dy: sub.dy, scrollPhase: sub.scrollPhase, momentumPhase: sub.momentumPhase,
                    continuous: sub.continuous, tag: tag,
                )
            }
            ensureScrollTimer()
        }
    }

    /// Lazily starts the ≈`scrollResampleHz` output timer on `scrollQueue` (idempotent). It runs
    /// continuously once started — each tick is a cheap drain that no-ops while the residual is idle —
    /// so there is no suspend/resume balance to get wrong; ``deinit`` cancels it.
    private func ensureScrollTimer() {
        if scrollTimer != nil { return }
        let interval = 1.0 / Double(Self.scrollResampleHz)
        let timer = DispatchSource.makeTimerSource(queue: scrollQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(500_000))
        timer.setEventHandler { [weak self] in
            guard let self, let sub = scrollResampler.drain() else { return }
            postScrollEvent(
                dx: sub.dx, dy: sub.dy, scrollPhase: sub.scrollPhase, momentumPhase: sub.momentumPhase,
                continuous: sub.continuous, tag: lastScrollTag,
            )
        }
        scrollTimer = timer
        timer.resume()
    }

    /// Builds + posts ONE scroll `CGEvent` (pixel units + replayed phase/momentum/continuous flags).
    /// The single emission point for BOTH the direct path and the resampler's interpolated sub-events.
    private func postScrollEvent(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        tag: UInt32,
    ) {
        let phased = Self.scrollPhaseEnabled
        // A precise/continuous trackpad gesture must NOT be re-scaled: the OS derives inertial coast
        // velocity from the Began/Changed delta cadence, so scrollGain would desync the fling. Gain
        // only means anything for legacy discrete-wheel events. Keep it 1:1 whenever replaying a real
        // gesture (phase forwarding on AND continuous).
        let gain = (phased && continuous) ? 1.0 : Self.scrollGain
        _ = slopdesk_inject_scroll(SlopDeskInjectScroll(
            dx: dx,
            dy: dy,
            gain: gain,
            tag: tag,
            to_pid: deliverTo,
            scroll_phase: scrollPhase,
            momentum_phase: momentumPhase,
            continuous: continuous,
            phased: phased,
        ))
    }

    // MARK: Swipe-back translation (see `swipeNavEnabled`)

    /// ANSI key POSITIONS (layout-independent virtual keycodes, HIToolbox `kVK_ANSI_*`): the same
    /// values the client sends for real keystrokes, interpreted by the host layout like any other
    /// forwarded key.
    private static let keyLeftBracket: UInt16 = 0x21 // kVK_ANSI_LeftBracket → ⌘[ = history back
    private static let keyRightBracket: UInt16 = 0x1E // kVK_ANSI_RightBracket → ⌘] = forward
    private static let keyCommand: UInt16 = 0x37 // kVK_Command — the chord bracket (see below)
    private static let keyRightCommand: UInt16 = 0x36 // kVK_RightCommand — same latch, right side

    /// Feeds the recogniser and, on a qualifying completed flick, posts ⌘[ / ⌘] to the app the
    /// scroll is landing in. On the default direct-post path the chord runs strictly AFTER the
    /// gesture's `ended` scroll was posted; in resample mode (`SLOPDESK_SCROLL_RESAMPLE_HZ` > 0)
    /// the flushed residual + `ended` marker post asynchronously on `scrollQueue`, so the fire is
    /// hopped onto that same serial queue — FIFO then guarantees the navigation key still lands
    /// after the gesture's own scroll stream (and never between a residual's ⌘-latched window).
    private func translateSwipeNavIfNeeded(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
    ) {
        guard Self.swipeNavEnabled else { return }
        let (fired, traceLine) = swipeNavLock.withLock { () -> (SwipeNavRecognizer.Direction?, String?) in
            let f = swipeNav.ingest(
                dx: dx,
                dy: dy,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: continuous,
                now: ProcessInfo.processInfo.systemUptime,
            )
            return (f, swipeNav.takeTraceLine())
        }
        if let traceLine {
            // Tagged with the session's capture target so two concurrent injectors (two panes)
            // stay attributable in the shared stderr log.
            FileHandle.standardError
                .write(Data("slopdesk-videohostd[inject]: swipe-nav(pid \(pid) win \(windowID)) \(traceLine)\n".utf8))
        }
        guard let fired else { return }
        if Self.scrollResampleHz > 0 {
            scrollQueue.async { [weak self] in self?.fireSwipeNav(fired) }
        } else {
            fireSwipeNav(fired)
        }
    }

    /// The allowlist check + chord post for one recognised flick (see
    /// ``translateSwipeNavIfNeeded`` for when this runs directly vs on `scrollQueue`). AppKit
    /// reads here (the `slopdesk_app_*` doors) are the same thread-safe calls
    /// ``performRaise`` makes off-main.
    private func fireSwipeNav(_ fired: SwipeNavRecognizer.Direction) {
        // Only drive apps where ⌘[ / ⌘] is history navigation — in an editor it EDITS TEXT
        // (outdent/indent), so an unknown app gets nothing beyond the scroll it already received.
        guard SwipeNavHostConfig.eligible(bundleID: swipeNavTargetBundleID()) else {
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[inject]: swipe-nav flick ignored (app not navigable)\n".utf8))
            }
            return
        }
        // WINDOW-scoped sessions: the chord posts at the HID tap, which delivers to the OS's
        // KEY-FOCUS holder — not necessarily this session's target app. The allowlist above
        // answered "is the PANE's app navigable"; this answers "will the chord actually land
        // there". If another app holds focus right now, posting would outdent/indent in whoever
        // has it — suppress instead, and kick the raise chain so an immediate retry lands in
        // the (now raised) target. A nil frontmost read passes through: best-effort, matching
        // ``performRaise``'s trust in the same z-order proxy.
        if pid > 0, let front = HostFrontmostApp.frontmostPID(), front != pid {
            if Self.swipeNavTrace {
                let line = "slopdesk-videohostd[inject]: swipe-nav(pid \(pid) win \(windowID)) "
                    + "suppressed (target not frontmost, front pid \(front))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            raiseTargetWindow()
            return
        }
        if Self.inputTrace {
            FileHandle.standardError
                .write(Data("slopdesk-videohostd[inject]: swipe-nav → \(fired == .back ? "⌘[ back" : "⌘] forward")\n"
                        .utf8))
        }
        let keyCode = fired == .back ? Self.keyLeftBracket : Self.keyRightBracket
        // BRACKETED chord, never a bare flagged pair: a synthetic key posted with `maskCommand` on
        // both edges LATCHES ⌘ onto the shared `.hidSystemState` source (probe-verified: every
        // later flag-less synthetic event — scrolls included — then inherits ⌘, turning ordinary
        // scrolling into browser zoom). Posting the real ⌘ key down/up around the letter, with the
        // release carrying EMPTY flags, is exactly the shape a forwarded client chord has
        // (`flagsChanged` sends the modifier edges) and leaves the source state clean.
        //
        // EXCEPT when the user PHYSICALLY holds ⌘ (the balance saw the real modifier down and no
        // release yet): the latch is already real, and a synthetic ⌘-up would be consumed by the
        // balance as the one legitimate release — the user's actual release later dedupes away,
        // stranding the host un-⌘'d mid-hold. Ride the real modifier instead: letter pair only.
        let commandHeld = balanceLock.withLock {
            balance.heldModifierKeys.contains(Self.keyCommand)
                || balance.heldModifierKeys.contains(Self.keyRightCommand)
        }
        if !commandHeld { postKey(keyCode: Self.keyCommand, down: true, modifiers: .command, tag: 0) }
        postKey(keyCode: keyCode, down: true, modifiers: .command, tag: 0)
        postKey(keyCode: keyCode, down: false, modifiers: .command, tag: 0)
        if !commandHeld { postKey(keyCode: Self.keyCommand, down: false, modifiers: [], tag: 0) }
    }

    /// The app whose NAVIGABILITY the translation is judged against: the tracked window's app
    /// for a WINDOW-scoped session (whether the chord will actually LAND there is re-checked
    /// separately at fire time — see ``fireSwipeNav``'s frontmost gate), the frontmost app for
    /// a DISPLAY-scoped one (pid 0 — whole-desktop input goes to whatever is frontmost, exactly
    /// like the scroll it follows). The frontmost read is the WindowServer query
    /// (``HostFrontmostApp``), NOT `NSWorkspace`: the daemon's NSWorkspace snapshot freezes at
    /// first access, which here means firing ⌘[ into whatever app happened to be frontmost the
    /// first time this process looked — an OUTDENT in an editor the user switched to later.
    private func swipeNavTargetBundleID() -> String? {
        if pid > 0 { return HostFrontmostApp.bundleID(of: pid) }
        return HostFrontmostApp.bundleID()
    }

    /// A key edge. Posted at the HID tap and deliberately NOT tagged — see the door's own note on
    /// why a stamped keystroke defeats a host IME's tap-dedup and composes Telex twice.
    ///
    /// A posted key reaches even a SecurityAgent/coreauthd secure field: HW-proven on Tahoe 26.5.1,
    /// an HID-tap keystroke fills the SecurityAgent password field and authenticates while
    /// `IsSecureEventInputEnabled()` is true — Secure Event Input blocks event-tap interception, NOT
    /// trusted HID-tap injection. A DriverKit virtual-HID keyboard would add nothing: this already
    /// reaches every dialog the host can surface, and virtual-HID would only matter at the
    /// login/lock screen, which the host cannot capture anyway.
    private func postKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag _: UInt32) {
        _ = slopdesk_inject_key(keyCode, down, modifiers.rawValue)
    }

    /// Unicode text injection — layout-independent, the robust text path (doc 05 §3).
    private func postText(_ string: String, tag _: UInt32) {
        let bytes = Array(string.utf8)
        _ = bytes.withUnsafeBufferPointer { utf8 in
            slopdesk_inject_text(utf8.baseAddress, utf8.count)
        }
    }
}
#endif
