// ClipboardConfirmRequests — the phone's mailbox between the terminal surface's clipboard-write drain
// and a mounted view.
//
// The Mac has no use for this file and that is not an asymmetry in the DECISION, only in the two
// frameworks' idea of what "present a dialog" is. `NSAlert.beginSheetModal(for:)` can be called from
// inside a drain: the presenter IS a function. SwiftUI has no such function — a surface exists
// because something in a mounted tree says it does — so the drain cannot present, it can only ASK,
// and this is the thing it asks. ``ClipboardConfirmCard`` (`SlopDeskPhoneUI`) drains it.
//
// ⚠️ EVERY REQUEST IN HERE IS A LIVE CLIPBOARD-WRITE REQUEST pulled off the terminal surface's own
// sink (`TerminalSurfaceDriver`'s `takeClipboardWrites()` drain — the FFI boundary is pull-only, there
// are no callbacks), and ``TerminalSurfaceDriver/apply(_:)`` is holding the completion open until this
// file answers it EXACTLY ONCE. Two rules fall out, and both are enforced here rather than trusted to
// the renderer:
//
//  * A request is answered ONCE. ``answer(_:allow:)`` removes the entry BEFORE it calls the completion,
//    so a double-tap, or a renderer that answers a card it has already torn down, is a no-op rather than
//    a second `completeClipboardRead` against freed state.
//  * A request is never DROPPED to make room. A second ask arriving while one is up QUEUES — it does not
//    replace, and the mailbox never presents itself as empty while it holds one. Replacing would decide
//    the older question on the user's behalf, which is the whole gap this seam exists to close; dropping
//    the newer one would leak the surface's pending completion forever.
//
// It is a process-wide singleton for the same reason ``TerminalConfigBroadcaster`` is: the writer is
// the per-pane surface's drain loop, which has a `TerminalSurfaceDriver` and nothing else, and the
// reader is the app's one window.

import Foundation

/// The pending clipboard confirmations, oldest first. `@Observable`, so the mounted card re-renders when
/// one arrives or is answered.
@preconcurrency
@MainActor
@Observable
public final class ClipboardConfirmRequests {
    /// The one mailbox. The renderer view writes it from the surface's clipboard-write drain; the phone's root reads it.
    public static let shared = ClipboardConfirmRequests()

    /// One unanswered question: what to ask, and the completion the surface's drain is waiting on for the answer.
    ///
    /// `answer` is deliberately NOT public — nothing outside this type may call a completion, because
    /// calling it without removing the entry is the double-completion above. Renderers go through
    /// ``ClipboardConfirmRequests/answer(_:allow:)``.
    public struct Pending: Identifiable {
        /// Monotonic within the process, so a card can hold an identity across a re-render without
        /// holding the request itself.
        public let id: Int
        /// What is being asked, in either renderer's terms.
        public let reading: ClipboardConfirmPresentation
        let answer: (Bool) -> Void
    }

    /// The queue, oldest first.
    public private(set) var pending: [Pending] = []

    /// The question to put to the user right now, or `nil` when there is none.
    public var current: Pending? { pending.first }

    private var lastID = 0

    public init() {}

    /// File a confirmation. `answer` is the completion the surface's drain is waiting on: `true` = the affirmative button,
    /// `false` = Cancel. It runs exactly once, on the main actor, when the user decides — never before,
    /// and never because the app found the question inconvenient.
    public func ask(
        _ reading: ClipboardConfirmPresentation,
        answer: @escaping (Bool) -> Void,
    ) {
        lastID += 1
        pending.append(Pending(id: lastID, reading: reading, answer: answer))
    }

    /// Answer the request `id` with the user's verdict. Removes it FIRST, so a repeat call for the same
    /// `id` — a double-tap, a card answering on teardown after its button already did — does nothing.
    public func answer(_ id: Int, allow: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        request.answer(allow)
    }
}
