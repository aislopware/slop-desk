// SecureKeyboardEntryController — the macOS Secure Keyboard Entry actuator (E17 ES-E17-4 / WI-7).
//
// "Secure Keyboard Entry" engages macOS's PROCESS-GLOBAL `EnableSecureEventInput()` so no other
// process can sniff keystrokes while the remote shell is at a hidden-password prompt (`sudo` / `ssh` /
// `login` / `read -s` / `getpass` — the host signals the termios `ECHO` edge over wire type 31, which the
// client folds into ``TerminalViewModel/hostNoEcho``).
//
// The OS API is REFERENCE-COUNTED: every `EnableSecureEventInput()` MUST be balanced by exactly one
// `DisableSecureEventInput()`, or secure input LEAKS process-wide (the keyboard stays "secured" for every
// app until the leak is released — a notorious macOS footgun). This controller owns that balance through a
// SINGLE `engaged: Bool` (never a raw counter that could double-enable or leak): it calls `enable` on the
// false→true edge, `disable` on the true→false edge, and never the same direction twice in a row. So even a
// flood of identical `setHostNoEcho(true)` calls enables once, and a pane close / app resign / echo-restore
// disables once — exactly balanced.
//
// The process-global API is INJECTED (`enable` / `disable` seams) so the balance is unit-testable WITHOUT
// touching the real `EnableSecureEventInput()` (which would secure the TEST RUNNER's keyboard). The default
// seams call the real API on macOS and are NO-OPS on iOS — secure event input is a macOS-only concept, so
// the whole type compiles for iOS and simply never engages there (`shouldEngage` is `false` off macOS).

import Foundation
import SlopDeskWorkspaceCore
#if os(macOS)
import AppKit // NSApplication.didResign/BecomeActiveNotification — the app-frontmost edge that gates the lock
import Carbon
#endif

/// Reference-balanced owner of macOS Secure Keyboard Entry for ONE pane (E17 ES-E17-4 / WI-7). Engages
/// `EnableSecureEventInput()` iff `(autoSecureInput && hostNoEcho) || manualOn` while the app is active, and
/// guarantees a single balanced `DisableSecureEventInput()` on the inverse edge / pane teardown / app resign
/// / echo restored. The process-global API is injected so tests assert the enable/disable BALANCE without
/// ever calling the real (test-runner-securing) API. `@MainActor` — secure event input is a main-thread / UI
/// concern, and the driving model hooks all fire on the main actor.
@preconcurrency
@MainActor
public final class SecureKeyboardEntryController {
    /// The process-global ENABLE seam. Default: `EnableSecureEventInput()` on macOS, a no-op elsewhere.
    /// Injected so tests count calls without securing the test runner's keyboard. `@MainActor` — secure event
    /// input is a main-thread concern, and it lets a test's counter closure mutate its main-actor state.
    private let enable: @MainActor () -> Void
    /// The process-global DISABLE seam. Default: `DisableSecureEventInput()` on macOS, a no-op elsewhere.
    private let disable: @MainActor () -> Void

    /// The center the app-frontmost edge is observed through (``observeAppActivity()``). Injected (default
    /// `.default`) so tests post the real `NSApplication` active/resign notifications to a private center and
    /// assert the held reference is released WITHOUT depending on the global app state.
    private let notificationCenter: NotificationCenter
    /// The retained `NSApplication` active/resign observer tokens (macOS-only; empty otherwise). Removed on
    /// ``teardown()`` so a torn-down pane's controller leaves no live observer (and no leaked lock) behind.
    private var appActivityObservers: [any NSObjectProtocol] = []

    /// Whether THIS controller currently holds ONE `EnableSecureEventInput()` reference (i.e. has called
    /// `enable` without a matching `disable`). The single source of balance — every state change reconciles
    /// against it so `enable`/`disable` are perfectly paired. Public-read so the owner can mirror it onto the
    /// pill (``TerminalViewModel/secureInputActive``) if it drives the indicator off the actuator directly.
    public private(set) var engaged = false

    /// The "Auto Secure Input" setting (`auto-secure-input`): when ON, a host no-echo prompt engages
    /// secure input automatically. When OFF, only the manual toggle engages it.
    private var autoSecureInput: Bool
    /// The host's termios-`ECHO` state inverted: `true` while the remote shell is at a no-echo password
    /// prompt (driven by wire type 31 → ``TerminalViewModel/hostNoEcho`` → the leaf).
    private var hostNoEcho = false
    /// The manual Edit ▸ Secure Keyboard Entry toggle (engages secure input regardless of `autoSecureInput`).
    private var manualOn = false
    /// Whether the app is frontmost/active. Secure input is disengaged while the app is backgrounded / the
    /// window resigns key (no input path can fire there) and re-engaged on return — so the process-global
    /// lock never lingers across an app switch.
    private var appActive = true

    @preconcurrency
    public init(
        autoSecureInput: Bool = SettingsKey.autoSecureInputEnabled,
        enable: @escaping @MainActor () -> Void = {
            #if os(macOS)
            EnableSecureEventInput()
            #endif
        },
        disable: @escaping @MainActor () -> Void = {
            #if os(macOS)
            DisableSecureEventInput()
            #endif
        },
        notificationCenter: NotificationCenter = .default,
    ) {
        self.autoSecureInput = autoSecureInput
        self.enable = enable
        self.disable = disable
        self.notificationCenter = notificationCenter
    }

    /// Whether secure input SHOULD be engaged right now: the app must be active AND either the auto path
    /// (`autoSecureInput && hostNoEcho`) or the manual toggle is on. Computed identically on every platform so
    /// the inputs are always read; iOS inertness comes from the DEFAULT seams being no-ops there (secure event
    /// input does not exist on iOS) and the pill being independently gated off in the model — engaging is then
    /// an observable no-op off macOS.
    private var shouldEngage: Bool {
        appActive && ((autoSecureInput && hostNoEcho) || manualOn)
    }

    /// Reconciles `engaged` against ``shouldEngage`` — the ONE place `enable`/`disable` are called, so they
    /// stay perfectly balanced. A no-op when already in the desired state (idempotent: a flood of identical
    /// inputs enables/disables at most once).
    private func reconcile() {
        let want = shouldEngage
        if want, !engaged {
            engaged = true
            enable()
        } else if !want, engaged {
            engaged = false
            disable()
        }
    }

    /// Updates the "Auto Secure Input" setting live (the Settings toggle) and reconciles.
    public func setAutoSecureInput(_ on: Bool) {
        autoSecureInput = on
        reconcile()
    }

    /// Sets the host no-echo state (a password prompt is up / has cleared) and reconciles. Driven from
    /// ``TerminalViewModel/onHostEchoChanged`` (wire type 31). Echo restored (`false`) disengages the auto path.
    public func setHostNoEcho(_ on: Bool) {
        hostNoEcho = on
        reconcile()
    }

    /// Sets the manual Secure-Keyboard-Entry toggle and reconciles (the Edit-menu / palette manual override).
    public func setManualOn(_ on: Bool) {
        manualOn = on
        reconcile()
    }

    /// Flips the manual Secure-Keyboard-Entry toggle (the menu/palette action) and reconciles.
    public func toggleManual() {
        manualOn.toggle()
        reconcile()
    }

    /// Sets whether the app/window is active and reconciles — disengages while backgrounded / on window
    /// resign (no input can fire) and re-engages on return, so the process-global lock never lingers.
    public func setAppActive(_ on: Bool) {
        appActive = on
        reconcile()
    }

    /// Starts observing the app-frontmost edge so the held `EnableSecureEventInput()` reference is RELEASED
    /// whenever slopdesk is no longer frontmost (the user ⌘-Tabs away — e.g. to a password manager — while a
    /// remote no-echo prompt is still up) and RE-ACQUIRED on return. Without this the process-global lock would
    /// leak to other apps' keyboards while we are backgrounded (a user-hostile macOS footgun). Idempotent (a
    /// repeat call while already observing is a no-op) and torn down by ``teardown()``. A no-op off macOS, where
    /// secure event input does not exist. Driven by `NSApplication` active/resign notifications, which AppKit
    /// always posts on the main thread, so the observer lands on the main actor (`queue: nil` = synchronous).
    public func observeAppActivity() {
        #if os(macOS)
        guard appActivityObservers.isEmpty else { return }
        let resign = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        }
        let become = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        }
        appActivityObservers = [resign, become]
        #endif
    }

    /// Force-disengages on pane close (the leaf teardown). Releases the held `EnableSecureEventInput()`
    /// reference exactly once if engaged — idempotent, so calling it twice never double-disables (the leak
    /// hazard in reverse) — and removes the app-activity observers so a torn-down controller leaves no live
    /// observer behind. Leaves the inputs untouched (the controller is being discarded).
    public func teardown() {
        for token in appActivityObservers { notificationCenter.removeObserver(token) }
        appActivityObservers.removeAll()
        if engaged {
            engaged = false
            disable()
        }
    }
}
