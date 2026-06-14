#if os(iOS)
import UIKit
#endif

/// The `@MainActor` arbiter that serializes first-responder ownership across the multiple
/// ``TerminalInputHost`` surfaces mounted at once on iPad-regular (docs/22 §7).
///
/// ## Why this exists
/// When the focused pane changes, the *outgoing* pane's `IMEProxyTextView` must resign before the
/// *incoming* one becomes first responder — otherwise UIKit briefly has two first responders
/// fighting, and because `becomeFirstResponder` is honoured a runloop hop later, two rapid focus
/// changes can land out of order and a stale callback steals focus back to the pane you just left
/// (the "I typed into the wrong pane" bug). Compact mode mounts exactly one host, so it sidesteps
/// this entirely; iPad-regular needs the coordination.
///
/// ## The pattern (resign-before-become + generation-reject)
/// `focus(_:)`:
/// 1. **Bumps** the pure ``FocusGenerationGuard`` to mint a fresh token (synchronously, on the
///    main actor) — this immediately invalidates any in-flight callback from a previous request.
/// 2. **Resigns** the currently-focused host's first responder FIRST, so there is never an overlap.
/// 3. Schedules the incoming host's `becomeFirstResponder`; the scheduled work captures the token
///    and verifies ``FocusGenerationGuard/isCurrent(_:)`` before claiming — a superseded request
///    (a newer `focus(_:)` arrived first) is dropped, so focus lands on exactly the last-requested
///    pane.
///
/// ## Registration
/// The Integrate phase wires each ``TerminalInputHost`` to ``register(_:for:)`` on appear and
/// ``unregister(_:)`` on dismantle, passing a lightweight ``FocusableInputHost`` adapter over its
/// `TerminalInputResponderView`. The coordinator never retains the view strongly past unregister,
/// and holds only the focus *intent*; it does not own the store's focus state (that stays in
/// `WorkspaceStore`). A view layer observes the store's `focusedPane` and calls `focus(_:)` here.
///
/// Cross-platform: the type compiles on macOS (where there is no UIKit first-responder model) so
/// the macOS build + tests are unaffected; the actual `becomeFirstResponder`/`resignFirstResponder`
/// calls are gated `#if os(iOS)`. The pure generation logic in ``FocusGenerationGuard`` is shared
/// and unit-tested on macOS.
@preconcurrency
@MainActor
public final class PaneFocusCoordinator {
    /// The thing the coordinator drives: one pane's first-responder surface. On iOS this is
    /// satisfied by the ``TerminalInputResponderView`` (or a thin adapter the Integrate phase
    /// supplies); modelling it as a protocol keeps the coordinator testable and lets the byte
    /// pipeline (`TerminalInputHost`) stay the integration seam rather than being imported here.
    ///
    /// The two methods mirror `UIResponder`: `resignFocus()` must drop first-responder status now;
    /// `becomeFocus()` must claim it. Implementations return the actual result so the coordinator
    /// can keep its bookkeeping honest (a `become` that UIKit refuses leaves no host marked
    /// focused).
    @preconcurrency
    @MainActor
    public protocol FocusableInputHost: AnyObject {
        /// Resign first-responder status immediately. Returns whether the resign took effect.
        @discardableResult
        func resignFocus() -> Bool
        /// Become first responder. Returns whether the claim took effect.
        @discardableResult
        func becomeFocus() -> Bool
    }

    /// The pure generation guard. A stale `becomeFocus` callback is rejected by token, so the last
    /// `focus(_:)` request always wins regardless of UIKit's async callback ordering.
    private var guardState = FocusGenerationGuard()

    /// Weak registry of mounted hosts keyed by pane. Weak so a dismantled host that forgot to
    /// unregister (or raced dismantle vs. a focus change) cannot be resurrected or leaked.
    private var hosts: [PaneID: WeakHost] = [:]

    /// The pane currently believed to hold first responder (the last successful `become`). `nil`
    /// before any focus, or after the focused host unregisters.
    public private(set) var focusedPane: PaneID?

    public init() {}

    // MARK: Registration (the Integrate-phase seam)

    /// Registers `host` as the input surface for `id`. Called by the host on appear. If `id` was
    /// already the focused pane (e.g. a re-mount after a regular↔compact projection flip), the
    /// host is re-focused so the keyboard re-targets the live surface without a generation bump
    /// race.
    public func register(_ host: FocusableInputHost, for id: PaneID) {
        hosts[id] = WeakHost(host)
        if focusedPane == id {
            // The focused pane's host was re-created; re-claim under a fresh generation.
            focus(id)
        }
    }

    /// Unregisters the host for `id` (called on dismantle). Clears the focused marker if this was
    /// the focused pane so a later `become` callback for it cannot resurrect a dead view.
    public func unregister(_ id: PaneID) {
        hosts[id] = nil
        if focusedPane == id { focusedPane = nil }
    }

    /// Drops a host by identity regardless of which pane it is keyed under (defensive cleanup for
    /// a dismantle that raced a re-register under the same pane id).
    public func unregister(host: FocusableInputHost) {
        for (id, weak) in hosts where weak.value === host {
            hosts[id] = nil
            if focusedPane == id { focusedPane = nil }
        }
    }

    // MARK: Focus transfer (resign-before-become + generation-reject)

    /// Transfers first responder to the pane `id`, resigning the outgoing host first and rejecting
    /// any stale async claim by generation.
    ///
    /// Order (the load-bearing sequence):
    /// 1. Mint a fresh generation token — invalidates every in-flight callback at a stamp.
    /// 2. Resign the outgoing host synchronously (no two-first-responder overlap window).
    /// 3. Schedule the incoming host's `become`, gated on the token still being current.
    public func focus(_ id: PaneID) {
        // 1. New generation: any previously-scheduled become() is now stale.
        let token = guardState.begin()

        // 2. Resign the outgoing host FIRST (before anyone else can become first responder).
        if let outgoing = focusedPane, outgoing != id {
            hosts[outgoing]?.value?.resignFocus()
        }

        // Mark intent now so a re-entrant register/unregister during this turn sees it; the
        // become below may revise it back to nil if UIKit refuses or the host vanished.
        focusedPane = id

        guard let incoming = hosts[id]?.value else {
            // No live host yet (it hasn't mounted). It will re-claim itself in `register` because
            // `focusedPane == id`. Keep the intent recorded.
            return
        }

        // 3. Claim first responder. UIKit honours becomeFirstResponder a runloop hop later, so we
        // defer the claim and re-check the generation: if a newer focus() landed meanwhile, this
        // callback is stale and must NOT steal focus back.
        scheduleBecome(incoming, id: id, token: token)
    }

    /// Re-asserts first responder for `id` even when the bookkeeping already records it as focused
    /// (BUG-K). `focus(_:)` short-circuits a redundant re-claim via `syncFocusCoordinator`'s
    /// `focusedPane != focused` guard; but on a TAB SWITCH the new tab's host can register while the
    /// coordinator's `focusedPane` still equals the new id from a prior life (or be (re)mounted without
    /// holding UIKit first responder), so a guarded `focus(_:)` would skip the claim and the new tab's
    /// terminal never takes the keyboard. This forces a fresh generation + re-claim regardless of the
    /// current bookkeeping; the ``FocusGenerationGuard`` token semantics are unchanged (still minted by
    /// `begin()`, still reject a superseded async callback), so a later `focus(_:)` still wins.
    public func reassertFocus(_ id: PaneID) {
        let token = guardState.begin()
        if let outgoing = focusedPane, outgoing != id {
            hosts[outgoing]?.value?.resignFocus()
        }
        focusedPane = id
        guard let incoming = hosts[id]?.value else {
            // The host hasn't mounted yet; it will re-claim itself in `register` (focusedPane == id).
            return
        }
        scheduleBecome(incoming, id: id, token: token)
    }

    /// Schedules the deferred `become`, re-validating the generation token at fire time so a
    /// superseded request is dropped. On iOS this hops the main runloop (matching UIKit's async
    /// first-responder honouring + ``TerminalInputHost``'s own `DispatchQueue.main.async` claim);
    /// elsewhere it claims directly (there is no UIKit responder chain to race).
    private func scheduleBecome(_ host: FocusableInputHost, id: PaneID, token: Int) {
        #if os(iOS)
        // weak self + weak host: a dismantle between schedule and fire must not resurrect either.
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host else { return }
            claimIfCurrent(host, id: id, token: token)
        }
        #else
        claimIfCurrent(host, id: id, token: token)
        #endif
    }

    /// The generation-reject gate: claim first responder for `host` only if `token` is still the
    /// current generation AND `id` is still the intended focus. A stale callback is dropped.
    private func claimIfCurrent(_ host: FocusableInputHost, id: PaneID, token: Int) {
        guard guardState.isCurrent(token) else { return } // superseded by a newer focus()
        guard focusedPane == id else { return } // intent moved on
        // The host may have unregistered (dismantled) between schedule and fire.
        guard hosts[id]?.value === host else { return }
        if !host.becomeFocus() {
            // UIKit refused (host not in a window yet / mid-transition). Don't claim a focus we
            // don't actually hold; a subsequent register/focus will retry.
            if focusedPane == id { focusedPane = nil }
        }
    }

    // MARK: -

    /// A weak box so the registry never keeps a dismantled host alive.
    private struct WeakHost {
        weak var value: FocusableInputHost?
        init(_ value: FocusableInputHost) { self.value = value }
    }
}
