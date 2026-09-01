// TerminalScrollPhase — where a pointer scroll is in its life, in ONE vocabulary for both shells.
//
// AppKit and UIKit say this in two entirely different ways: `NSEvent` carries a `phase` and a
// SECOND `momentumPhase`, where a `UIPanGestureRecognizer` carries one `state` and hands its
// momentum to a separate deceleration. Neither maps onto the other, and the far side needs neither
// — it needs the one question "may this scroll rest between two rows, or is a snap owed now".
//
// The snap waits for MOMENTUM rather than for the fingers, which is the whole reason `ended` is not
// simply "the gesture stopped": a trackpad fling keeps delivering deltas after the lift, and a snap
// taken there would be undone by every one of them.

import CSlopDeskFFI

/// Where a pointer scroll is in its life, as `slopdesk_term_surface_scroll_points` reads it.
public enum TerminalScrollPhase: Sendable, Equatable {
    /// A discrete wheel notch, or any source that reports no phase at all — a keyboard verb, a
    /// programmatic scroll. Settles immediately: there is no gesture to wait for.
    case discrete
    /// The fingers are down, or a fling is still throwing deltas.
    case live
    /// The gesture AND its momentum are both over.
    case ended

    var code: UInt8 {
        switch self {
        case .discrete: UInt8(SLOPDESK_TERM_SCROLL_PHASE_DISCRETE)
        case .live: UInt8(SLOPDESK_TERM_SCROLL_PHASE_LIVE)
        case .ended: UInt8(SLOPDESK_TERM_SCROLL_PHASE_ENDED)
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public extension TerminalScrollPhase {
    /// The phase an `NSEvent`'s two phase words add up to.
    ///
    /// Read as one question rather than two because that is what they are: a wheel notch carries
    /// neither word and is ``discrete``; anything that names a momentum is the FLING, which is live
    /// until it names its own end; and only once both are done — or the gesture ended with no
    /// momentum at all — is the scroll over.
    init(gesture: NSEvent.Phase, momentum: NSEvent.Phase) {
        if momentum.contains(.ended) || momentum.contains(.cancelled) {
            self = .ended
        } else if !momentum.isEmpty {
            self = .live
        } else if gesture.contains(.ended) || gesture.contains(.cancelled) {
            // A gesture that ends with no momentum word is over here. One that ends INTO a fling
            // arrives again with a momentum phase, and the `.live` branch above catches it before
            // this line can settle it early.
            self = .ended
        } else if gesture.isEmpty {
            self = .discrete
        } else {
            self = .live
        }
    }
}
#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit

public extension TerminalScrollPhase {
    /// The phase a pan recogniser's state names.
    ///
    /// A `UIPanGestureRecognizer` has no momentum of its own — the deceleration a scroll view would
    /// run is not in this path, because the terminal drives the offset itself — so the lift IS the
    /// end, and there is no fling left to fight the snap.
    init(state: UIGestureRecognizer.State) {
        self =
            switch state {
            case .began,
                 .changed: .live
            default: .ended
            }
    }
}
#endif
