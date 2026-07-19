// SystemKeyCaptureController — the immersive-mode system-key capture actuator, macOS-only. While a
// remote-desktop video pane has immersive enabled and its window is key (the CALLER's conditions — this type
// only owns the mechanism), OS-reserved chords (⌘Tab, ⌘Space, ⌘`, F-keys, media keys arriving as plain F-keys)
// are intercepted by a CGEvent tap and delivered to the remote host via the injected `forward` closure instead
// of triggering local macOS actions. Every DECISION is the pure ``SystemKeyCapturePolicy`` (unit-pinned
// headlessly); this file is ONLY the tap/run-loop/observer lifecycle.
//
// TAP LOCATION — `.cgSessionEventTap`, not `.cghidEventTap`: the session tap is the earliest point a
// non-root, Accessibility-trusted process can FILTER events (HID placement is documented for root; a user
// process gains nothing there), and head-inserted (`.headInsertEventTap`) it still runs BEFORE the
// symbolic-hotkey layer that owns ⌘Tab/⌘Space — which is the whole point of immersive mode. Neither location
// sees secure-event-input keystrokes, so a password prompt is never sniffed either way.
//
// ACCESSIBILITY TRUST: an active (filtering) keyboard tap requires AX trust. Untrusted, `CGEvent.tapCreate`
// returns nil — ``engage(forward:keyWindow:)`` then returns `false` and the controller stays inert (never
// crashes); the caller surfaces ``promptForTrust()``.
//
// HANG-SAFETY: never instantiate this controller in a unit test — creating a live event tap needs AX trust
// and swallows the TEST RUNNER's (and the whole session's) keyboard. The decision table is pinned by
// `SystemKeyCapturePolicyTests`; the tap lifecycle is GUI-verified only.

#if os(macOS)
import AppKit

/// Owns ONE immersive-mode CGEvent tap: created on ``engage(forward:keyWindow:)``, torn down on
/// ``disengage()`` (the toggle, the ⌃⌥⌘E escape chord, unmount) / deinit. Default state is OFF — nothing is
/// captured until a caller engages, and there is no env flag. `@MainActor`: engage/disengage ride UI edges,
/// and the tap's run-loop source is added to the MAIN run loop so the callback lands on the main actor too.
///
/// SUSPEND ≠ DISENGAGE: losing the app's active state, the pane window's key state, or the caller's own
/// eligibility (pane focus / a writable sink) only SUSPENDS the tap — swallowing stops (keys flow to macOS
/// again, so there is never a trap) but the engagement, and therefore the user's toggle, SURVIVES, and
/// capture resumes by itself the moment every gate re-opens. The old tear-down-on-resign design made the
/// toggle silently flake off every time a popover/palette went key or the app briefly deactivated.
@preconcurrency
@MainActor
public final class SystemKeyCaptureController {
    /// The remote delivery seam, injected per-engage so this module never imports the video client: raw
    /// hardware keyCode (the remote host wants KEYCODES, not characters), the full `CGEventFlags.rawValue`,
    /// and the press/release edge (flagsChanged maps to the changed modifier's own down/up).
    public typealias Forward = (_ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool) -> Void

    /// Whether the process holds Accessibility trust (`AXIsProcessTrusted`) — the precondition for a
    /// filtering keyboard tap. Callers gate their "Immersive Mode" affordance on this.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Triggers the system Accessibility-trust prompt (`AXIsProcessTrustedWithOptions` + prompt). macOS shows
    /// the dialog at most once per app; afterwards the user must flip the toggle in System Settings — callers
    /// should surface that path in UI text rather than calling this in a loop.
    public static func promptForTrust() {
        // The literal key, not `kAXTrustedCheckOptionPrompt`: that SDK constant is an (immutable-in-practice)
        // global `var`, which Swift 6 strict concurrency rejects from an isolated context. Its value is the
        // ABI-stable string "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Whether an engagement is live (the tap exists and the user's toggle is ON — capture itself may be
    /// SUSPENDED behind one of the gates). Read-only mirror for the caller's UI (the immersive badge).
    public private(set) var isEngaged = false

    /// Fired at the START of every ``disengage()`` — the ⌃⌥⌘E escape chord tears the tap down without the
    /// caller's involvement, so a UI toggle mirroring ``isEngaged`` needs this to stay truthful. Set it
    /// before ``engage(forward:keyWindow:)``. Suspensions never fire it — the engagement survives them.
    public var onDisengage: (() -> Void)?

    // The CF handles are `nonisolated(unsafe)` so the nonisolated `deinit` can invalidate them (they are only
    // ever written on the main actor; CF invalidation is thread-safe). A leaked ENABLED tap would keep
    // swallowing the session's keys with no owner left to disengage it — deinit teardown is non-negotiable.
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var suspendResumeObservers: [any NSObjectProtocol] = []

    // The three suspension gates — the tap actively swallows only while ALL are open. Each flips
    // independently (AppKit notifications for the first two, the caller for the third), so a popover going
    // key and a pane-focus change can overlap without fighting over one flag.
    private var appIsActive = true
    private var windowIsKey = true
    private var callerSuspended = false

    private var forward: Forward?
    /// Every keyCode forwarded DOWN but not yet UP (modifiers and regular keys alike). Flushed as releases on
    /// ``disengage()`` — the escape chord ⌃⌥⌘E guarantees three modifiers are physically down at disengage
    /// time, so without this flush the remote host would ALWAYS end up with stuck ⌃⌥⌘ after the escape hatch.
    private var forwardedDownKeyCodes: Set<UInt16> = []

    public init() {}

    deinit {
        // ALWAYS release the tap on deallocation (the stuck-modifier flush belongs to the explicit
        // `disengage()` path — a deinit while engaged means the owner is already gone). Invalidating the mach
        // port also guarantees the callback's unretained `userInfo` pointer to self is never dereferenced
        // after free.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        for token in suspendResumeObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// Engages capture: creates the session-level tap, arms the suspend/resume observers, and starts
    /// forwarding. Returns `false` — leaving the controller fully disengaged — when Accessibility trust is
    /// missing or tap creation fails; `true` when capture is live (or already was: idempotent, the existing
    /// engagement is kept untouched so a re-render can call it freely).
    ///
    /// - `forward`: the remote key delivery (see ``Forward``).
    /// - `keyWindow`: the pane's window, if the caller wants capture to auto-SUSPEND while that window is
    ///   not key (recommended — a swallowed keyboard on a non-key window is a trap) and resume when it goes
    ///   key again. App-active suspend/resume is always armed regardless.
    @discardableResult
    public func engage(forward: @escaping Forward, keyWindow: NSWindow? = nil) -> Bool {
        guard !isEngaged else { return true }
        // `tapCreate` fails quietly (nil) without AX trust; checking first gives the caller a deterministic
        // "surface promptForTrust()" signal instead of an indistinguishable generic failure.
        guard Self.isTrusted else { return false }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // filtering (not listen-only): returning nil from the callback swallows
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<SystemKeyCaptureController>.fromOpaque(userInfo).takeUnretainedValue()
                // The run-loop source lives on the MAIN run loop, so the callback always lands on the main
                // thread — assumeIsolated is a checked assertion of that, not a hop.
                let swallow = MainActor.assumeIsolated { controller.handleTapEvent(type: type, event: event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque(),
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.tap = tap
        runLoopSource = source
        self.forward = forward
        forwardedDownKeyCodes = []
        isEngaged = true
        // Seed the gates from the CURRENT app/window state (engage rides a click in the pane's window, so
        // both are normally open) and let `applyGates()` decide the tap's initial enablement.
        appIsActive = NSApp.isActive
        windowIsKey = keyWindow?.isKeyWindow ?? true
        callerSuspended = false
        installSuspendResumeObservers(keyWindow: keyWindow)
        applyGates()
        return true
    }

    /// The CALLER's suspension gate — pane focus lost, sink withheld (read-only), anything that should
    /// pause swallowing WITHOUT forgetting the user's toggle. While suspended, keys flow to macOS normally;
    /// capture resumes by itself when the caller re-opens the gate (and the app/window gates agree). No-op
    /// while disengaged.
    public func setSuspended(_ suspended: Bool) {
        guard isEngaged, callerSuspended != suspended else { return }
        callerSuspended = suspended
        applyGates()
    }

    /// Tears capture down FOR REAL (the toggle, the ⌃⌥⌘E escape chord, unmount): flushes release events for
    /// every key still forwarded-down (the remote host must never be left with stuck modifiers — the escape
    /// chord ends with ⌃⌥⌘ physically held), removes the observers, and invalidates the tap + run-loop
    /// source. Idempotent — the escape chord and a manual caller can race here harmlessly.
    public func disengage() {
        guard isEngaged else { return }
        isEngaged = false
        onDisengage?()
        flushForwardedDownKeys()
        forward = nil
        callerSuspended = false
        for token in suspendResumeObservers { NotificationCenter.default.removeObserver(token) }
        suspendResumeObservers = []
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource) // invalidation also removes it from the run loop
            self.runLoopSource = nil
        }
    }

    // MARK: - private

    /// Whether every suspension gate is open — the tap should be actively swallowing.
    private var gatesOpen: Bool { appIsActive && windowIsKey && !callerSuspended }

    /// Syncs the tap's enablement to the gates. Entering suspension flushes release events for every key
    /// still forwarded-down FIRST (the remote must not be left holding modifiers while the user works
    /// locally); resuming just re-enables — the tap picks up from live hardware state.
    private func applyGates() {
        guard isEngaged, let tap else { return }
        if gatesOpen {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            flushForwardedDownKeys()
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// Forwards a release for every keyCode delivered DOWN but not yet UP, then clears the ledger. Sorted
    /// for a deterministic release order (a Set iterates arbitrarily).
    private func flushForwardedDownKeys() {
        if let forward {
            for keyCode in forwardedDownKeyCodes.sorted() { forward(keyCode, 0, false) }
        }
        forwardedDownKeyCodes = []
    }

    /// The main-actor body of the tap callback. Returns whether to SWALLOW the event (`nil` from the C
    /// callback). All policy is ``SystemKeyCapturePolicy``; this only actuates + re-arms.
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap whose callback stalls (`tapDisabledByTimeout`) or on certain user input
        // (`tapDisabledByUserInput`). Re-enable immediately — otherwise capture dies SILENTLY while the UI
        // still shows immersive as on, and every "swallowed" chord starts firing locally again. Only while
        // the gates are open — a suspension-disabled tap must stay disabled. The wake event itself is not a
        // key event; pass it through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if gatesOpen, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch SystemKeyCapturePolicy.decision(keyCode: keyCode, flags: event.flags, type: type) {
        case .passThrough:
            return false
        case .disengage:
            // The escape chord ⌃⌥⌘E: tear down (which flushes the held modifiers to the remote) and swallow
            // the chord itself — it is a client-side control, typed into NEITHER machine.
            disengage()
            return true
        case .forwardAndSwallow:
            let isDown = SystemKeyCapturePolicy.isDown(keyCode: keyCode, flags: event.flags, type: type)
            if isDown {
                forwardedDownKeyCodes.insert(keyCode)
            } else {
                forwardedDownKeyCodes.remove(keyCode)
            }
            forward?(keyCode, event.flags.rawValue, isDown)
            return true
        }
    }

    /// Arms the suspend/resume safety net: capture never SWALLOWS while the app is not active (a mouse
    /// click into another app, a system dialog stealing focus) nor — when the caller supplies its window —
    /// while that window is not key (a popover, the palette, Settings, a second satellite). A swallowed
    /// keyboard while the pane is not even frontmost would be a trap with no visible cause. But the
    /// ENGAGEMENT survives: the matching did-become notifications re-open the gates so capture resumes
    /// without the user re-clicking the toggle. AppKit posts these on the main thread (`queue: nil` =
    /// synchronous delivery, staying on the main actor).
    private func installSuspendResumeObservers(keyWindow: NSWindow?) {
        suspendResumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        })
        suspendResumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        })
        guard let keyWindow else { return }
        suspendResumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: keyWindow, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setWindowKey(false) }
        })
        suspendResumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: keyWindow, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setWindowKey(true) }
        })
    }

    private func setAppActive(_ active: Bool) {
        appIsActive = active
        applyGates()
    }

    private func setWindowKey(_ key: Bool) {
        windowIsKey = key
        applyGates()
    }
}
#endif
