#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// One session's injected input, as ARC sees it: an owner for `slopdesk_injector_*`.
///
/// ⚠️ **GUI-ONLY + TCC:** what is behind this handle drives real input, and needs three grants
/// (doc 05 §0) — **Accessibility** for the raise chain, **'Post Event'** for `CGEvent.post`, and
/// **Screen Recording** for the capture side that shares the session. Ship-outside-the-App-Store,
/// non-sandboxed. COMPILED + reviewed; the posting path is NEVER driven from tests.
///
/// ## What used to be here
///
/// 735 lines: the button-balance safety release, the raise policy and its throttle, the scroll
/// resampler and its timer, the swipe-back recogniser and its ⌘-bracket chord, the Parsec-style
/// tablet-point hover, and every coordinate map. None of it was a rule this file owned — each one
/// had a twin in `slopdesk-video` and an effect behind a door — and what actually held the file
/// together was two `DispatchQueue`s, a `DispatchSourceTimer` and three `NSLock`s. All of that is
/// `rust/slopdesk-ffi/src/injector.rs` now, including the two threads; the prose that recorded
/// WHY each threshold is what it is went with the rule it explains.
///
/// What is left is the one thing Swift still has to say: when this object dies, free the handle.
/// The session holds it across suspension points and hands it to a `Task`, so ARC — not a raw
/// pointer — is what keeps it alive to the last caller.
public final class InputInjector: @unchecked Sendable {
    /// The far side's whole injector: state, locks, and its own two threads.
    private let handle: OpaquePointer

    /// Whether the scroll resampler drives injection — read by the session's scroll-coalesce
    /// default before any injector exists, which is why it does not come off one.
    static var scrollResamplerActive: Bool { InjectorGateTable.resamplerActive }

    /// DISPLAY-SCOPED injector (the full-desktop pane): coordinates map against the display's CG
    /// bounds and there is NO target window or app — the raise chain is skipped entirely, because
    /// a posted event already delivers to whatever is frontmost, which for whole-desktop remoting
    /// is exactly right.
    public convenience init(
        displayBoundsCG: VideoRect,
        balance: InputButtonBalance = InputButtonBalance(),
    ) {
        self.init(pid: 0, windowID: 0, windowBoundsCG: displayBoundsCG, balance: balance)
    }

    /// - Parameter balance: the held-button/modifier state to START from. The default (empty) is
    ///   the fresh-session case; a transparent-reconnect rebuild passes the PREVIOUS injector's
    ///   ``balanceSnapshot`` so a button or modifier the user held ACROSS the reconnect still
    ///   matches its eventual up (an empty balance would classify that up as an orphan → suppress
    ///   → the terminating `CGEvent` is never posted → the host OS is stuck in drag/modifier
    ///   state).
    public init(
        pid: pid_t,
        windowID: CGWindowID,
        windowBoundsCG: VideoRect,
        balance: InputButtonBalance = InputButtonBalance(),
    ) {
        handle = InjectorGateTable.values.withUnsafeBufferPointer { gates in
            // Never null — the far side documents it, and there is no injector-less session to
            // fall back to: a nil here would silently stop every remote click.
            slopdesk_injector_new(
                gates.baseAddress, gates.count, Self.inputTrace,
                Int32(pid), windowID, HostDisplays.record(windowBoundsCG.cgRect), balance.wire,
            )
        }
    }

    deinit { slopdesk_injector_free(handle) }

    /// Re-points the coordinate mapping at the window's frame, as the geometry watcher sees it move.
    public func updateWindowBounds(_ bounds: VideoRect) {
        slopdesk_injector_update_bounds(handle, HostDisplays.record(bounds.cgRect))
    }

    /// The current held-button/modifier balance. The session actor reads this off the STALE
    /// injector at teardown and threads it into the replacement's seed.
    public var balanceSnapshot: InputButtonBalance {
        var held = SlopDeskInputBalance()
        guard slopdesk_injector_balance(handle, &held) else { return InputButtonBalance() }
        return InputButtonBalance(held)
    }

    /// Raises + focuses the target window, and returns IMMEDIATELY — the accessibility chain runs
    /// on the handle's own thread and self-throttles, so callers never wrap this in a main hop and
    /// the several raises one click fires coalesce to one.
    public func raiseTargetWindow() {
        slopdesk_injector_raise(handle)
    }

    /// Posts one remote input event.
    public func inject(_ event: InputEvent) {
        guard case let .text(string, _) = event else {
            _ = slopdesk_injector_inject(handle, event.wire, nil, 0)
            return
        }
        // The text arm alone carries bytes: the flat record names a string by OFFSET into a
        // datagram, and this side is holding the string rather than the datagram.
        let utf8 = Array(string.utf8)
        _ = utf8.withUnsafeBufferPointer {
            slopdesk_injector_inject(handle, event.wire, $0.baseAddress, $0.count)
        }
    }

    /// The session-wide input trace, which is deliberately not in the injector's own key list: it
    /// gates the session's tracing too, the host gate table already names it, and resolving one key
    /// through two tables is the drift those tables exist to delete. It crosses as a bool, and the
    /// swipe-nav trace is OR-ed with it on the far side. PRESENCE, so `=0` turns it on.
    private static let inputTrace = EnvConfig.string("SLOPDESK_INPUT_TRACE") != nil
}
#endif
