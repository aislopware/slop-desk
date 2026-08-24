// AppSupport — the macOS shell's app-level actuators: the quit drain and the window-close gate.
//
// They were the tail of `SlopDeskClientApp.swift` under one long `#if os(macOS)`. They land here
// whole, with the gate deleted rather than moved: this target is macOS, so saying so again in the file
// is noise (docs/56 §3).
//
// What they have in common is that each is an AppKit obligation the SwiftUI scene cannot express — a
// termination reply that must be deferred until an async drain finishes, a `windowShouldClose` that
// must ask the store and then answer synchronously — so each one is a shim between AppKit's protocol
// and the store's decision.
//
// The `openSettings` binder used to live here too. It went with the settings scene: ⌘, opens
// `config.toml` now, which needs no environment action and no shim.

import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

/// QUIT-DRAIN (orphaned-session leak — the clean-quit twin of the wifi-flap host detach/reattach fix): closing a
/// busy pane (⌘W) drops it from the tree + registry SYNCHRONOUSLY, but the actual host disconnect
/// (bye/channelClose) runs in a non-awaited background teardown task. A ⌘Q within that window kills the
/// process before the bye reaches the wire: the host soft-detaches the just-closed session into
/// `DetachedSessionStore` (default TTL: NEVER) while the client's persisted workspace no longer
/// references it — a permanently orphaned session whose agent keeps running with no owner.
/// ``WorkspaceStore/quiesce()`` exists exactly for this drain, wired here at its call site.
///
/// `applicationShouldTerminate` parks the quit (`.terminateLater`), saves the tree immediately (the
/// termination is async — the existing `willTerminateNotification` flush still runs after the reply
/// and stays the last word), drains via ``TerminationDrain`` (bounded — quit must NEVER hang on a wedged
/// teardown), then replies so AppKit finishes terminating.
///
/// The store rides a static seam because SwiftUI's `@NSApplicationDelegateAdaptor` instantiates the
/// delegate itself (`SlopDeskClientApp.init` cannot hand it instance state); weak — the App's `@State`
/// owns the store. With no store (never happens in production) the quit proceeds untouched.
@MainActor
final class SlopDeskAppTerminationDelegate: NSObject, NSApplicationDelegate {
    /// The single live store, injected by `SlopDeskClientApp.init()`.
    weak static var store: WorkspaceStore?
    /// The teardown-drain budget: generous for the in-flight bye/channelClose round trips, short enough
    /// that quit never feels hung (the losing quiesce keeps draining until the process exits anyway).
    static let drainTimeout: Duration = .seconds(2)
    /// One-shot: a second ⌘Q while the drain is pending must not spawn a second drain (each
    /// `.terminateLater` expects exactly one `reply`; the in-flight drain resolves the first request).
    private var draining = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        guard !draining else { return .terminateCancel } // drain in flight — its reply resolves the quit
        // QUIT-CONFIRM: guards against a stray ⌘Q reaching the app while the user is working the Host
        // Windows rail — `performKeyEquivalent: → terminate:` can fire with no real intent (a vanished
        // window reads as a CRASH; rcmd/XKey event-tap leaks are prime suspects). With any
        // tab open, an interactive quit asks first. Apple-Event quits (osascript, logout/shutdown)
        // skip the dialog — blocking automation or logout is worse than a stray quit.
        if QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: store.tree.sessions.contains { !$0.tabs.isEmpty },
            isAppleEventQuit: NSAppleEventManager.shared().currentAppleEvent != nil,
            envValue: ProcessInfo.processInfo.environment["SLOPDESK_QUIT_CONFIRM"],
        ), !Self.confirmQuit() {
            return .terminateCancel
        }
        draining = true
        // Persist BEFORE the async drain so even an interrupted drain window keeps the layout; the
        // willTerminate flush re-saves after the reply (idempotent, and the authoritative last word).
        store.saveImmediately()
        Task { @MainActor in
            await TerminationDrain.drain(timeout: Self.drainTimeout) { await store.quiesce() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The confirm dialog itself (GUI — the decision lives in ``QuitConfirmPolicy``). Return = Quit,
    /// Esc = Cancel: an intentional quit costs one keystroke; a stray one becomes a visible dialog
    /// instead of a vanished window.
    private static func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit SlopDesk?"
        alert.informativeText = "Host sessions keep running; your workspace reattaches on the next launch."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// PURE quit-confirmation decision (unit-pinned in `QuitConfirmPolicyTests`): interactive quits with
/// any open tab confirm; Apple-Event quits (automation, logout) and an explicit
/// `SLOPDESK_QUIT_CONFIRM=0` never do. An empty workspace quits silently — there is nothing to lose.
enum QuitConfirmPolicy {
    static func requiresConfirmation(
        hasOpenTabs: Bool, isAppleEventQuit: Bool, envValue: String?,
    ) -> Bool {
        guard envValue != "0" else { return false } // default-ON idiom (CLAUDE.md env table)
        return hasOpenTabs && !isAppleEventQuit
    }
}

/// QUIT-DRAIN: races an async drain `operation` against a bounded `timeout` and returns when EITHER
/// finishes — a clean teardown replies immediately, a wedged one never hangs the quit. Kept pure of
/// AppKit so the bound is unit-pinned headlessly (`TerminationDrainTests`); the delegate passes
/// `store.quiesce()`.
///
/// Shape: a continuation resumed exactly once by two racing `@MainActor` sibling tasks — deliberately
/// NOT a task group (the Swift-6 `@MainActor`-capture-in-`addTask` sendability trap). The losing side
/// runs to completion in the background: a timed-out quiesce keeps draining until the process dies
/// (harmless, and strictly better than not trying); a won race leaves only a finite sleep behind.
@MainActor
enum TerminationDrain {
    static func drain(timeout: Duration, operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task { @MainActor in
                await operation()
                gate.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
        }
    }

    /// Resumes the wrapped continuation at most once — `@MainActor`, so the two racing tasks serialize
    /// through it and a double-resume (both sides landing) is structurally impossible.
    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// A tiny WEAK holder for THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)`
/// closure so the `.onChange(of: chrome.pinned)` pin actuator can re-level the live window without the
/// forbidden `NSApplication.windows` scan. Deliberately NOT `@Observable` — mutating `window` must not trigger
/// a re-render; it is a pure capture slot the scene's `@State` storage keeps alive for the window's lifetime.
@MainActor
final class WeakWindowBox {
    weak var window: NSWindow?
}

/// The PURE window-close gate the macOS `windowShouldClose` consults. Factored out of the AppKit
/// delegate so the close decision is unit-testable WITHOUT an `NSWindow` (the hang-safety rule), and so the
/// gate can never strand the window: a parked close ALWAYS resolves here, rather than returning a bare
/// `false` with no path to close.
@MainActor
enum WindowCloseGate {
    /// Resolves a window-close attempt against `store` and returns whether the `NSWindow` may close NOW.
    ///
    /// Parks the confirmation per the active session's ``CloseConfirmationPolicy``
    /// (``WorkspaceStore/requestCloseWindow()``). When NO confirmation is required it returns `true`
    /// immediately (byte-identical to an unguarded default close, the persisted layout preserved). When one IS
    /// required it invokes `confirm` (the synchronous prompt) EXACTLY once and routes the user's choice:
    ///   - confirmed ⇒ ``WorkspaceStore/confirmPendingWindowClose()`` (close the active session — the window
    ///     maps 1:1 to a ``Session`` — which tears down its panes / stops any running processes) and return `true` so the
    ///     NSWindow then closes (the red-traffic-light intent);
    ///   - cancelled ⇒ ``WorkspaceStore/cancelPendingWindowClose()`` and return `false` (keep the window).
    ///
    /// Pure of AppKit (the only AppKit is inside the injected `confirm`), so a test drives every branch with a
    /// stub prompt and asserts the window can ALWAYS close once the user confirms.
    static func resolve(store: WorkspaceStore, confirm: () -> Bool) -> Bool {
        store.requestCloseWindow()
        guard store.pendingWindowClose != nil else {
            return true // no confirmation needed → close normally
        }
        if confirm() {
            store.confirmPendingWindowClose()
            return true
        }
        store.cancelPendingWindowClose()
        return false
    }
}

/// A transparent `NSWindowDelegate` shim that adds the window-close confirmation gate WITHOUT
/// displacing SwiftUI's own window delegate. It implements ONLY `windowShouldClose(_:)` and forwards every
/// other selector to the delegate SwiftUI installed (`next`), so SwiftUI's window bookkeeping is untouched.
///
/// On a close attempt it routes through ``WindowCloseGate/resolve(store:confirm:)`` (the window → active
/// ``Session`` map). When the configured ``CloseConfirmationPolicy`` says confirm, it presents a SYNCHRONOUS
/// confirmation (`NSAlert`) so the attempt always resolves — the window can never be stranded with an
/// unresolved park. The decision is store-side + unit-tested; only this NSWindow
/// plumbing + the alert is here.
@MainActor
final class WindowCloseConfirmationDelegate: NSObject, NSWindowDelegate {
    private let store: WorkspaceStore
    /// The delegate SwiftUI had installed; held strongly (NSWindow holds delegates weakly) so every
    /// non-`windowShouldClose` message keeps reaching SwiftUI's own delegate via forwarding. `nonisolated`
    /// so the `NSObject` runtime-forwarding overrides (themselves `nonisolated`) can read it — AppKit only
    /// touches a window delegate on the main thread, so the access is single-threaded in practice.
    private nonisolated(unsafe) let next: NSWindowDelegate?

    init(store: WorkspaceStore, next: NSWindowDelegate?) {
        self.store = store
        self.next = next
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        WindowCloseGate.resolve(store: store) { Self.confirmWindowClose() }
    }

    /// The synchronous close confirmation — an `NSAlert` whose "Close" button maps to `true`. Kept tiny +
    /// AppKit-only (the decision logic lives in ``WindowCloseGate``); presented app-modally (`runModal`) so
    /// `windowShouldClose` can return the user's choice inline — the window never closes until they answer.
    private static func confirmWindowClose() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = "Closing it ends the current session and stops any running processes."
        alert.addButton(withTitle: "Close") // first button ⇒ .alertFirstButtonReturn (the default action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Forward every selector this shim does not implement to SwiftUI's original delegate, so its window
    // bookkeeping (key/main/resize/restoration) is preserved.
    override nonisolated func responds(to aSelector: Selector?) -> Bool {
        if super.responds(to: aSelector) { return true }
        return next?.responds(to: aSelector) ?? false
    }

    override nonisolated func forwardingTarget(for aSelector: Selector?) -> Any? {
        if let next, next.responds(to: aSelector) { return next }
        return super.forwardingTarget(for: aSelector)
    }
}
