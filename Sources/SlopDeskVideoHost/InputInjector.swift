#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
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
/// 1. Raise + focus the target window (`NSRunningApplication.activate` + AX
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
    /// The CGEventSource whose `userData` we stamp = self-inject filter tag.
    private let eventSource: CGEventSource?

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
    private var scrollResampler = ScrollResampler()
    private var scrollTimer: DispatchSourceTimer?
    /// The tag of the latest forwarded scroll, stamped on the resampler's interpolated sub-events
    /// (so the self-inject filter still recognises them). Confined to `scrollQueue`.
    private var lastScrollTag: UInt32 = 0

    /// Swipe-back flick recogniser fed from ``inject(_:)``'s scroll arm. Injection is serial per
    /// session, so the lock is the same harmless insurance ``balance`` carries.
    private let swipeNavLock = NSLock()
    private var swipeNav = SwipeNavRecognizer(fireTravel: swipeNavTravel, trace: swipeNavTrace)

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

    /// The matched AX window element, cached after the first successful bounds-match so subsequent
    /// raises SKIP the O(app-windows) AX iteration (the dominant cost). The `AXUIElement` identity is
    /// stable across window move/resize (it names the same window), so it stays valid for the session;
    /// a stale element (window closed) just makes the best-effort AX calls no-op. `raiseQueue`-confined.
    private var cachedAXWindow: AXUIElement?

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
    /// positions the host cursor at exact coords — no warp needed; still tagged via ``stampAndPost`` so the
    /// `CursorSampler` self-inject filter keeps working). Applies to HOVER moves ONLY — DRAGS keep the warp
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
    /// receiving app is one where ⌘[ / ⌘] means history (``SwipeNavPolicy``), posts that key
    /// equivalent. Scroll posting itself is untouched — the page still rubber-bands natively.
    private static let swipeNavEnabled = EnvConfig.boolDefaultOn("SLOPDESK_SWIPE_NAV")
    /// Extra bundle ids for the swipe-nav allowlist (`SLOPDESK_SWIPE_NAV_APPS`, comma-separated).
    private static let swipeNavExtraApps = SwipeNavPolicy.extraApps(from: EnvConfig.string("SLOPDESK_SWIPE_NAV_APPS"))
    /// Lift-fire travel threshold in points (`SLOPDESK_SWIPE_NAV_TRAVEL`, default 80) — scales the
    /// recogniser's whole threshold family (arm = 0.3×, momentum confirm = 1.5×). Clamped so a
    /// typo can't make every scroll navigate (too low) or dead the feature silently (too high).
    private static let swipeNavTravel: Double = {
        guard let s = EnvConfig.string("SLOPDESK_SWIPE_NAV_TRAVEL"), let v = Double(s), v.isFinite,
              v >= 20, v <= 500 else { return 80 }
        return v
    }()

    /// Per-GESTURE swipe-nav decision trace (`SLOPDESK_SWIPE_NAV_TRACE`; also on under the full
    /// `SLOPDESK_INPUT_TRACE`). ≤2 stderr lines per gesture — cheap enough to leave on a daily
    /// driver, and the only way to see the real flick's travel/duration/dominance numbers when a
    /// swipe "didn't count" on hardware.
    private static let swipeNavTrace = ProcessInfo.processInfo
        .environment["SLOPDESK_SWIPE_NAV_TRACE"] != nil || inputTrace

    /// SCROLL RESAMPLE output rate (`SLOPDESK_SCROLL_RESAMPLE_HZ`, default **0 = OFF**). HW-measured:
    /// Chromium/Electron renders INJECTED smooth-scroll at a rate that climbs with the
    /// injection rate, only hitting the display's 60 fps near ~250 Hz (4× vsync); the wire delivers
    /// scroll at the client trackpad rate (~60–120 Hz, burstier under jitter), so a captured VS Code
    /// scroll renders a visibly juddery ~20–35 fps. When > 0, the bursty wire scroll is resampled
    /// (``ScrollResampler``) to a STEADY `Hz` stream via a timer, driving the source app's native
    /// 60 fps smooth-scroll — fixing it at the source, not client-side reprojection. `0` keeps the
    /// direct-post path (byte-identical). Set to `250` to enable. Clamped [60, 1000].
    private static let scrollResampleHz: Int = {
        // Resolve through `EnvConfig` (ProcessInfo env → settings overlay → nil) so a GUI setting
        // can drive it; an EMPTY overlay is byte-identical to the raw read. The parse + 0-default +
        // [60, 1000] clamp idiom is kept VERBATIM (this site clamps, not validate-then-default).
        guard let s = EnvConfig.string("SLOPDESK_SCROLL_RESAMPLE_HZ"), let v = Int(s), v > 0
        else { return 0 }
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
        eventSource = CGEventSource(stateID: .hidSystemState)
        if let eventSource {
            // Default suppression interval is 0.25s: after a posted/warped event, synthetic events
            // landing in that window can be eaten — why a click right after a warp-move sometimes
            // "didn't take". Zero it so injected events are never suppressed. (This property is the
            // modern equivalent of the obsoleted `CGEventSourceSetLocalEventsSuppressionInterval`.)
            eventSource.localEventsSuppressionInterval = 0
        }
    }

    deinit {
        // Stop the scroll-resample pump. The timer is never suspended (runs continuously once
        // started), so `cancel()` from any thread releases it cleanly — no suspend/resume balance
        // to honour. Safe even if never started (`nil`).
        scrollTimer?.cancel()
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
        // frontmost app, or an unreadable frontmost still runs the full raise.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
        let appEl = AXUIElementCreateApplication(pid)
        // Cap each blocking AX IPC so a hung/modal/beachballing target app fails fast (0.08s) instead
        // of the framework default (~6s) — best-effort, a missed raise just lands the click on the
        // already-frontmost window.
        AXUIElementSetMessagingTimeout(appEl, 0.08)
        // FAST PATH: reuse the cached window element — skips the O(app-windows) AX iteration, which
        // dominates the raise cost and is why this chain runs off the main actor at all.
        if let cached = cachedAXWindow {
            AXUIElementPerformAction(cached, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, cached)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, cached)
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }
        // Heuristic match the AX window to the tracked CGWindowID by frame (no public
        // map exists — doc 05 §4); defensive against same-title windows. Cache the match.
        let targetBounds = bounds
        for axWindow in axWindows where axWindowMatchesBounds(axWindow, targetBounds) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, axWindow)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, axWindow)
            cachedAXWindow = axWindow
            break
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
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

    /// Warp the cursor to an absolute point, then immediately re-associate the mouse and
    /// cursor so the warp's transient disassociation (which can swallow the next synthetic
    /// event) is cancelled. Together with the suppression interval = 0 set in `init`, this
    /// makes warp-then-post safe so absolute positioning never eats the following event.
    private func warp(to pt: CGPoint) {
        if Self.injectToPid { return } // test seam: don't hijack the global cursor (same-machine loopback)
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1)) // re-associate (true)
    }

    private func postMouseMove(normalized: VideoPoint, tag: UInt32) {
        let pt = target(normalized)
        // PARSEC PATH (`tabletMouse`, real-injection only — the loopback `injectToPid` seam keeps the
        // warp path below): ONE absolute tablet-point `.mouseMoved`, no warp/associate → 1 WindowServer
        // IPC not 3, so a hover flood no longer stalls SCStream capture. The event's `mouseCursorPosition`
        // positions the host cursor (verified macOS 26); the tablet subtype + absolute point fields give
        // delta-reading apps an absolute position. Stateless like the warp path (pure hover; drags go
        // through ``postMouseDrag``).
        if Self.tabletMouse, !Self.injectToPid {
            if let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .mouseMoved,
                mouseCursorPosition: pt,
                mouseButton: .left,
            ) {
                event.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint
                // Reuse the never-traps Int32 backstop: a malicious/corrupt mouseMove can carry a finite
                // huge coordinate (`readFiniteFloat64` rejects only NaN/Inf, and windowPoint doesn't
                // clamp), so `pt` can reach ~1e21 — a bare `Int64(_:)` would TRAP and crash the host on an
                // untrusted datagram. Int32 range (±2.1e9) dwarfs any real display; the CGEvent's
                // `mouseCursorPosition` does the actual positioning.
                event.setIntegerValueField(.tabletEventPointX, value: Int64(Self.clampToInt32(pt.x)))
                event.setIntegerValueField(.tabletEventPointY, value: Int64(Self.clampToInt32(pt.y)))
                stampAndPost(event, tag: tag)
            }
            return
        }
        // Absolute HOVER move: warp the cursor, then post `.mouseMoved` so apps reading deltas see
        // it (doc 05 §1). A button-held drag is NEVER inferred here — the client sends an explicit
        // `.mouseDrag` (see ``postMouseDrag``), so a move is always a pure hover. Inferring "button
        // held?" from host state would let a lost `mouseUp` strand that state, turning every later
        // hover into a phantom `.leftMouseDragged` (runaway selection). Stateless = no phantom drag.
        warp(to: pt)
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: pt,
            mouseButton: .left,
        ) {
            stampAndPost(event, tag: tag)
        }
    }

    /// Posts a drag-move: the `*MouseDragged` matching the held `button`, at `pt`. STATELESS — the
    /// CLIENT reported the button held (its view fired `mouseDragged`, distinct from `mouseMoved`), so
    /// the host never tracks held state. macOS selection/drag engines consume `*MouseDragged` between
    /// mouseDown/mouseUp; a bare `.mouseMoved` mid-gesture is ignored and can collapse a selection
    /// (a stray hover during drag-select would leave the user unable to select). Statelessness is also wire-reorder-safe: over UDP a
    /// drag can arrive before its `mouseDown`; the app ignores a dragged with no active session, then
    /// anchors on the down and extends to the final drag — so the range stays correct even if early
    /// drag samples are lost or reordered.
    private func postMouseDrag(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    ) {
        let pt = target(normalized)
        warp(to: pt)
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch button {
        case .left: (type, cgButton) = (.leftMouseDragged, .left)
        case .right: (type, cgButton) = (.rightMouseDragged, .right)
        case .other: (type, cgButton) = (.otherMouseDragged, .center)
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: pt,
            mouseButton: cgButton,
        ) else { return }
        // A real drag carries the originating click's clickState (1 = drag-select, 2 = word-by-word).
        // A fresh dragged event defaults to 0, which some selection engines treat as "not a drag" →
        // nothing selects. Match the down: SAME value on down, drags, and up (`postMouseButton` too).
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, Int(clickCount))))
        event.flags = cgFlags(modifiers)
        stampAndPost(event, tag: tag)
    }

    private func postMouseButton(
        button: MouseButton,
        normalized: VideoPoint,
        down: Bool,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    ) {
        let pt = target(normalized)
        // Warp before posting so a tap with no preceding move still lands at `pt` and the visible
        // cursor agrees with where the click registers. Safe now that suppression is 0 and `warp`
        // re-associates the cursor.
        warp(to: pt)
        let (cgButton, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case .left: (cgButton, downType, upType) = (.left, .leftMouseDown, .leftMouseUp)
        case .right: (cgButton, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
        case .other: (cgButton, downType, upType) = (.center, .otherMouseDown, .otherMouseUp)
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: down ? downType : upType,
            mouseCursorPosition: pt,
            mouseButton: cgButton,
        ) else { return }
        // A single click needs clickState = 1 to register reliably (focus / insertion point); 2 =
        // double, 3 = triple. MUST be set on BOTH down and up with the SAME value — a fresh CGEvent
        // doesn't reliably carry clickState = 1, so clicks "didn't take" or landed wrong.
        // (`mouseEventClickState`; Apple forum 685901.)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, Int(clickCount))))
        event.flags = cgFlags(modifiers)
        stampAndPost(event, tag: tag)
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
        // dx/dy arrive off the (untrusted) wire. `Int32(Double)` TRAPS on NaN/±inf or out-of-range
        // (e.g. a hostile `1e300`), so a crafted scroll datagram could crash the host.
        // `SlopDeskVideoProtocol` already rejects non-finite deltas at decode; this clamp is the
        // defence-in-depth backstop for a finite-but-huge value, and it can never trap.
        let phased = Self.scrollPhaseEnabled
        // A precise/continuous trackpad gesture must NOT be re-scaled: the OS derives inertial coast
        // velocity from the Began/Changed delta cadence, so scrollGain would desync the fling. Gain
        // only means anything for legacy discrete-wheel events. Keep it 1:1 whenever replaying a real
        // gesture (phase forwarding on AND continuous).
        let gain = (phased && continuous) ? 1.0 : Self.scrollGain
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Self.scaledScrollDelta(dy, gain: gain),
            wheel2: Self.scaledScrollDelta(dx, gain: gain),
            wheel3: 0,
        ) else { return }
        if phased {
            // Replay the forwarded gesture. `IsContinuous` follows the precise flag (1 for a trackpad
            // gesture incl. momentum tail, 0 for a genuine wheel notch). The two phase fields carry the
            // CoreGraphics integer codes verbatim and are mutually exclusive (client guarantees at most
            // one non-zero), so Chromium/AppKit drive native 1:1 inertial + rubber-band scrolling.
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
            if scrollPhase != 0 {
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase))
            }
            if momentumPhase != 0 {
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
            }
        } else {
            // A/B fallback (SLOPDESK_SCROLL_PHASE=0): the prior phase-less continuous behaviour.
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        stampAndPost(event, tag: tag)
    }

    /// Clamps a wire-supplied scroll delta into `Int32` without ever trapping. `NaN` → 0; ±inf and
    /// out-of-range magnitudes saturate to `Int32.min`/`Int32.max`. (The NaN check MUST come first —
    /// every NaN comparison is false, so it would otherwise fall through to the trapping `Int32(_:)`.)
    static func clampToInt32(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value.rounded())
    }

    /// Applies gain BEFORE the trap-free clamp, so a hostile wire delta × a large gain still
    /// saturates instead of trapping (`inf × gain` and overflow both land in the clamp's
    /// saturating branches).
    static func scaledScrollDelta(_ value: Double, gain: Double) -> Int32 {
        clampToInt32(value * gain)
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
    /// reads here (`NSRunningApplication`/`NSWorkspace`) are the same thread-safe calls
    /// ``performRaise`` makes off-main.
    private func fireSwipeNav(_ fired: SwipeNavRecognizer.Direction) {
        // Only drive apps where ⌘[ / ⌘] is history navigation — in an editor it EDITS TEXT
        // (outdent/indent), so an unknown app gets nothing beyond the scroll it already received.
        guard SwipeNavPolicy.isNavigable(bundleID: swipeNavTargetBundleID(), extraApps: Self.swipeNavExtraApps)
        else {
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[inject]: swipe-nav flick ignored (app not navigable)\n".utf8))
            }
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

    /// The app the translated key would land in: the tracked window's app for a WINDOW-scoped
    /// session, the frontmost app for a DISPLAY-scoped one (pid 0 — whole-desktop input goes to
    /// whatever is frontmost, exactly like the scroll it follows). Thread-safe AppKit reads only
    /// (`NSRunningApplication` / `NSWorkspace`), same as ``performRaise``'s off-main usage.
    private func swipeNavTargetBundleID() -> String? {
        if pid > 0 { return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func postKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag _: UInt32) {
        // A posted `CGEvent` key reaches even a SecurityAgent/coreauthd secure field: HW-proven on
        // Tahoe 26.5.1, a `CGEvent(.cghidEventTap)` keystroke fills the SecurityAgent password field
        // and authenticates while `IsSecureEventInputEnabled()` is true — Secure Event Input blocks
        // event-tap interception, NOT trusted HID-tap injection. A DriverKit virtual-HID keyboard
        // would add nothing: CGEvent already reaches every dialog the host can surface, and virtual-HID
        // would only matter at the login/lock screen, which the host can't capture anyway.
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: down)
        else { return }
        event.flags = cgFlags(modifiers)
        postKeyboardEvent(event)
    }

    /// Unicode text injection — layout-independent, the robust text path (doc 05 §3).
    ///
    /// The unicode string attaches to the **key-DOWN event ONLY**. Attaching it to BOTH edges
    /// double-inserts the text, so the key-up is posted bare — it just completes the keystroke so
    /// the app sees a balanced down/up pair (CGEvent contract).
    private func postText(_ string: String, tag _: UInt32) {
        let units = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else { return }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        // Force a MODIFIER-FREE insertion. A plain-text keystroke must never inherit a latched/residual
        // modifier from the shared `.hidSystemState` source — e.g. a ⌘ stuck after ⌘+Delete would make
        // this a ⌘-modified keystroke. `postKey` sets `flags` explicitly; only `postText` left them at
        // the source default, so clear them here on both edges.
        down.flags = []
        postKeyboardEvent(down)
        // Bare key-up: NO keyboardSetUnicodeString (would double-insert). Modifier-free, matching the down.
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
            up.flags = []
            postKeyboardEvent(up)
        }
    }

    /// Posts a KEYBOARD event at the HID tap, deliberately WITHOUT stamping `eventSourceUserData` —
    /// the one place that diverges from ``stampAndPost``.
    ///
    /// A host Vietnamese IME (the user runs **xkey** — xmannv/xkey) installs TWO taps: a HID tap
    /// (`.cghidEventTap`, head-insert) and a session tap (`.cgSessionEventTap`, tail-append) that
    /// exists to catch remote-desktop-injected keystrokes. It DEDUPES across them via
    /// `eventSourceUserData`: the HID tap marks an event handled so the session tap skips it. A
    /// keystroke posted to the HID tap carrying our NONZERO self-inject `tag` defeats that dedup —
    /// xkey's session tap re-processes it → DOUBLE Telex composition → garbage (verified with
    /// `scripts/inject-telex-probe.swift`: "ddaa" WITH nonzero userData yields "daa"; cleared, the
    /// correct "đâ"). Posting `userData = 0` restores the dedup so the IME composes exactly once.
    ///
    /// Keys are safe to leave untagged: the self-inject filter serves only the `CursorSampler` /
    /// `WindowGeometryWatcher` feedback loop, driven by POINTER/GEOMETRY events — a keystroke never
    /// moves the cursor or resizes the window, so it can't feed back. Mouse/scroll still go through
    /// ``stampAndPost`` (xkey only taps keyboard, so their tag is harmless to it and our watchers need it).
    private func postKeyboardEvent(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    /// Stamps the self-inject filter tag on `eventSourceUserData` then posts at the
    /// HID tap (doc 18 §A). The cursor/geometry watchers compare incoming NSEvent
    /// `eventSourceUserData` to drop events we injected ourselves. POINTER/SCROLL ONLY —
    /// keyboard events use ``postKeyboardEvent`` (untagged) so the host IME's tap-dedup
    /// is not defeated.
    private func stampAndPost(_ event: CGEvent, tag: UInt32) {
        event.setIntegerValueField(.eventSourceUserData, value: Int64(tag))
        if Self.injectToPid, pid != 0 {
            event.postToPid(pid) // test seam: deliver to the target app without moving the cursor
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func cgFlags(_ modifiers: InputModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// NONISOLATED: only thread-safe AX client reads (``AXUIElementCopyAttributeValue``), so it runs
    /// on ``raiseQueue`` with the rest of ``performRaise``.
    private func axWindowMatchesBounds(_ element: AXUIElement, _ targetBounds: VideoRect) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            return false
        }
        // The copies above succeeded → posRef/sizeRef are non-nil AXValues by the AX contract.
        // `as?` to a CoreFoundation type (AXValue) ALWAYS succeeds (a compile error), so the force
        // cast is the only valid downcast — it traps on an OS-contract break, the original intent.
        // swiftlint:disable:next force_cast
        let posValue = posRef as! AXValue
        // swiftlint:disable:next force_cast
        let sizeValue = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        // Tolerate sub-point rounding between AX and CGWindowBounds.
        return abs(Double(point.x) - targetBounds.origin.x) < 2
            && abs(Double(point.y) - targetBounds.origin.y) < 2
            && abs(Double(size.width) - targetBounds.size.width) < 2
            && abs(Double(size.height) - targetBounds.size.height) < 2
    }
}
#endif
