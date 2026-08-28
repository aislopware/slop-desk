// PaneMoveEscapeMonitorController — escape-to-cancel for an in-flight pane-move drag, macOS-only. Owns ONE
// local `.keyDown` monitor: installed on ``arm(onCancel:)``, removed on ``disarm()``, and nothing else.
//
// WHY A MONITOR AND NOT THE CANCEL KEY EVERY OTHER SURFACE USES. The pane-move drag is a plain
// `DragGesture`; it never takes keyboard focus (the terminal the grab started over still holds it), so
// `.onKeyPress(.escape)` — the SwiftUI `slateCancelKey(perform:)` this client spelled Esc with, and now
// AppKit's `cancelOperation(_:)` beside ``UIKeyCommand/slateCancel(action:)`` — can never
// be delivered it. A local `NSEvent` monitor reads the key regardless of first-responder
// state, which is the same reason `MacKeybindingsEditor`'s chord recorder is one. The phone cannot use this
// mechanism at all (UIKit has no local monitor) and takes first responder instead — `PaneMoveEscapeResponder`,
// docs/56 increment 44. One behaviour, two mechanisms, and neither of them knows what cancelling MEANS: the
// closure comes from the single mount in the canvas.
//
// WHY IT IS HERE, AND NOT IN THE VIEW FILE IT WAS WRITTEN IN. It was `PaneMoveEscapeMonitor`'s `Coordinator`
// inside the old shared SwiftUI target's `Pane/PaneMoveAffordance.swift` — an `NSViewRepresentable` whose `makeNSView`
// returned a bare `NSView()`, because SwiftUI has no other way to hang a LIFETIME on something that is not a
// drawing. That is the whole tell. docs/56 §3: *a framework call is not a view; a `some View` is* — and
// increment 54's amendment to increment 40 says the rest of it, about this type's twin two files over:
// **a `CGEvent` tap draws nothing, so the direction was never up.** An `NSEvent` monitor draws nothing
// either. It descends, beside ``SystemKeyCaptureController`` and ``SecureKeyboardEntryController``, the two
// input actuators with exactly this shape.
//
// THE TRAP THAT MADE IT URGENT RATHER THAN TIDY. Left in the SwiftUI file, the AppKit canvas rewrite has
// nowhere to read Esc from except a SECOND monitor of its own — and two local monitors on one `NSEvent`
// stream do not layer, they RACE: whichever AppKit installed last runs first, both see the same keyDown, and
// a drag cancels twice or the swallow returns `nil` from one monitor while the other is still deciding. The
// AppKit column will call this controller directly, with no view at all, which is the point of the descent.
//
// THE FAILURE THIS TYPE IS ONE INVARIANT AWAY FROM, AND WHY THE SEAMS ARE INJECTED. A monitor left installed
// after the drag ends eats Escape for the WHOLE APP: no crash, no log, nothing in the UI — the user reports
// "Escape stopped working" and there is not a thing to grep for. The invariant is therefore a BALANCE (one
// remove per install, never two, never zero), and a balance can only be pinned by counting the calls, which
// is ``SecureKeyboardEntryController``'s argument for injecting `EnableSecureEventInput` verbatim. Installing
// a real monitor in a test would neither count anything nor be free — the test runner's own keyDown stream is
// what it would attach to.
//
// REJECTED, and recorded so it is not re-proposed:
//   • `var isActive: Bool { didSet { … } }` — the shape the Coordinator had. It reads fine from a SwiftUI
//     `updateNSView` that runs every drag frame and badly from anywhere else: the arm EDGE becomes implicit
//     in an assignment, and the AppKit caller inherits a property to keep in sync instead of a verb to call.
//     `engage`/`disengage` and `teardown` are the two neighbours' spelling; `arm`/`disarm` is this one's.
//   • Folding the phone's half in behind an `#else`. Its mechanism is a `UIView` that becomes first
//     responder — genuinely a view, genuinely UIKit, and it stays in the UI target where increment 44 put it.
//     What crosses down is the mechanism that draws nothing, not the pair.
//   • A `deinit` safety net. The monitor token is a non-`Sendable` `Any`, and a nonisolated `deinit` cannot
//     touch it — `WorkspaceKeyDispatcher` records the same constraint for the same token type. The balance is
//     the OWNER's: the representable disarms in `dismantleNSView`, and the AppKit column will disarm where it
//     tears the drag down. That is why the balance is pinned by tests rather than by a destructor.

#if os(macOS)
import AppKit
import CSlopDeskFFI

/// Escape-to-cancel for ONE pane-move drag. Armed while the drag is in flight and disarmed the instant it is
/// not, so Esc is the drag's key only for as long as there is a drag — at rest the monitor does not exist and
/// cannot shadow Escape for the terminal, an overlay, or a sheet.
///
/// `@MainActor`: arm/disarm ride gesture edges, and a local `NSEvent` monitor's handler is delivered on the
/// main thread, so the cancel closure lands on the main actor too.
@preconcurrency
@MainActor
package final class PaneMoveEscapeMonitorController {
    /// The per-event question the installed monitor asks: hardware key code in, "swallow this event" out.
    /// The monitor seam owns the `NSEvent` and hands over only the number, which is all the decision needs —
    /// and is what lets the balance be tested without an `NSEvent` in sight.
    package typealias KeyReader = @MainActor (UInt16) -> Bool

    /// The install seam. Default: a local `.keyDown` monitor whose handler returns `nil` (swallow) when the
    /// reader says so and the event untouched otherwise. Injected so tests COUNT installs — see the header.
    private let install: @MainActor (@escaping KeyReader) -> Any?
    /// The remove seam, taking back the exact token `install` returned. Default: `NSEvent.removeMonitor`.
    private let remove: @MainActor (Any) -> Void

    /// The live monitor token, or `nil` when disarmed. The single source of the balance: install writes it,
    /// remove clears it, and neither runs unless it changes.
    private var monitor: Any?
    /// What Escape means, supplied per-arm by whoever owns the drag. Cleared on ``disarm()`` so a finished
    /// drag's closure is not kept alive by an idle controller.
    private var onCancel: () -> Void = {}

    /// Whether a monitor is installed right now. Read-only mirror for a caller that wants to assert its own
    /// lifetime against this one.
    package var isArmed: Bool { monitor != nil }

    @preconcurrency
    package init(
        install: @escaping @MainActor (@escaping KeyReader) -> Any? = { reader in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Every key the reader does not claim is returned UNTOUCHED, so typing during a drag still
                // reaches the terminal; `nil` SWALLOWS, so the key that cancels is never also typed into it.
                guard reader(event.keyCode) else { return event }
                return nil
            }
        },
        remove: @escaping @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) },
    ) {
        self.install = install
        self.remove = remove
    }

    /// Arms Escape-to-cancel and (re)binds what it does. Idempotent on the MONITOR — a caller driven by a
    /// SwiftUI `updateNSView` calls this on every drag frame — but the closure is rebound every time, so the
    /// controller can never cancel through a stale drag's captured state.
    ///
    /// A refused install (AppKit returns `nil`) leaves the controller disarmed rather than half-armed, and the
    /// next call simply tries again. That was `PaneMoveEscapeResponder`'s rule on the other platform too, and
    /// it survives that type: docs/62 stage E.2 dissolves it into ``UIKeyCommand/slateCancel(action:)``, which
    /// a responder either publishes or does not. A half-taken grab is what strands a keyboard.
    package func arm(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        guard monitor == nil else { return }
        monitor = install { [weak self] keyCode in self?.readKey(keyCode) ?? false }
    }

    /// Removes the monitor and forgets the drag's cancel. Idempotent, and it never removes a token it did not
    /// install — the two halves of the balance the header names. Safe to call from a teardown that races the
    /// drag's own end: on a normal release both run, and the second is a no-op.
    package func disarm() {
        onCancel = {}
        guard let monitor else { return }
        // Cleared BEFORE the seam runs: `remove` is the caller's closure in a test and AppKit's in production,
        // and a re-entrant `arm` from either must find the controller already disarmed rather than install a
        // second monitor over a token that is on its way out.
        self.monitor = nil
        remove(monitor)
    }

    /// The one decision, per key. The cancel key is named by the crate that already has to know its number
    /// (`slopdesk_key_capture_is_escape`), and modifiers are deliberately not consulted — ⌘Esc and ⌥Esc bail
    /// out of a drag, which is the phone's rule too.
    ///
    /// The armed check is FIRST, and it is not redundant with the removal. `remove` takes the monitor out of
    /// the stream, but AppKit may already have an event in flight for a handler it is about to drop, so a
    /// disarmed controller can still be asked. Deciding on the cleared `onCancel` alone would cancel nothing
    /// — correct — and still return `true`, which SWALLOWS the key: the drag ends and the user's Escape
    /// vanishes, closing no sheet and dismissing no overlay. Once, invisibly, and only under a race.
    private func readKey(_ keyCode: UInt16) -> Bool {
        guard monitor != nil, slopdesk_key_capture_is_escape(keyCode) else { return false }
        onCancel()
        return true
    }
}
#endif
