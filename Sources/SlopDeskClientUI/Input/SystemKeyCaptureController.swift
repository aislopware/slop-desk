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
/// ``disengage()`` / app-resign / key-window-resign / deinit. Default state is OFF — nothing is captured until
/// a caller engages, and there is no env flag. `@MainActor`: engage/disengage ride UI edges, and the tap's
/// run-loop source is added to the MAIN run loop so the callback lands on the main actor too.
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

    /// Whether the tap is currently live. Read-only mirror for the caller's UI (the immersive badge).
    public private(set) var isEngaged = false

    /// Fired at the START of every ``disengage()`` — the auto-disengage paths (app-resign / window-resign /
    /// the ⌃⌥⌘E escape chord) tear the tap down without the caller's involvement, so a UI toggle mirroring
    /// ``isEngaged`` needs this to stay truthful. Set it before ``engage(forward:keyWindow:)``.
    public var onDisengage: (() -> Void)?

    // The CF handles are `nonisolated(unsafe)` so the nonisolated `deinit` can invalidate them (they are only
    // ever written on the main actor; CF invalidation is thread-safe). A leaked ENABLED tap would keep
    // swallowing the session's keys with no owner left to disengage it — deinit teardown is non-negotiable.
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var autoDisengageObservers: [any NSObjectProtocol] = []

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
        for token in autoDisengageObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// Engages capture: creates the session-level tap, arms the auto-disengage observers, and starts
    /// forwarding. Returns `false` — leaving the controller fully disengaged — when Accessibility trust is
    /// missing or tap creation fails; `true` when capture is live (or already was: idempotent, the existing
    /// engagement is kept untouched so a re-render can call it freely).
    ///
    /// - `forward`: the remote key delivery (see ``Forward``).
    /// - `keyWindow`: the pane's window, if the caller wants capture to auto-disengage the moment that window
    ///   resigns key (recommended — a swallowed keyboard on a non-key window is a trap). App-resign
    ///   auto-disengage is always armed regardless.
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
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        runLoopSource = source
        self.forward = forward
        forwardedDownKeyCodes = []
        isEngaged = true
        installAutoDisengageObservers(keyWindow: keyWindow)
        return true
    }

    /// Tears capture down: flushes release events for every key still forwarded-down (the remote host must
    /// never be left with stuck modifiers — the escape chord ends with ⌃⌥⌘ physically held), removes the
    /// observers, and invalidates the tap + run-loop source. Idempotent — the auto-disengage observers, the
    /// escape chord, and a manual caller can all race here harmlessly.
    public func disengage() {
        guard isEngaged else { return }
        isEngaged = false
        onDisengage?()
        if let forward {
            // Sorted for a deterministic release order (a Set iterates arbitrarily).
            for keyCode in forwardedDownKeyCodes.sorted() { forward(keyCode, 0, false) }
        }
        forwardedDownKeyCodes = []
        forward = nil
        for token in autoDisengageObservers { NotificationCenter.default.removeObserver(token) }
        autoDisengageObservers = []
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

    /// The main-actor body of the tap callback. Returns whether to SWALLOW the event (`nil` from the C
    /// callback). All policy is ``SystemKeyCapturePolicy``; this only actuates + re-arms.
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap whose callback stalls (`tapDisabledByTimeout`) or on certain user input
        // (`tapDisabledByUserInput`). Re-enable immediately — otherwise capture dies SILENTLY while the UI
        // still shows immersive as on, and every "swallowed" chord starts firing locally again. The wake
        // event itself is not a key event; pass it through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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

    /// Arms the auto-disengage safety net: capture NEVER survives the app resigning active (⌘Q passthrough,
    /// a mouse click into another app, a system dialog stealing focus), nor — when the caller supplies its
    /// window — that window resigning key. A swallowed keyboard while the pane is not even frontmost would be
    /// a trap with no visible cause. AppKit posts both notifications on the main thread (`queue: nil` =
    /// synchronous delivery, staying on the main actor).
    private func installAutoDisengageObservers(keyWindow: NSWindow?) {
        let resignApp = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.disengage() }
        }
        autoDisengageObservers.append(resignApp)
        guard let keyWindow else { return }
        let resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: keyWindow, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.disengage() }
        }
        autoDisengageObservers.append(resignKey)
    }
}
#endif
