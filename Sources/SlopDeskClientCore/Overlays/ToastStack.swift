import CSlopDeskFFI
import Foundation

/// The Swift face of `slopdesk_workspace::toast`'s stack fold — which standing cards survive one
/// push, and in what order.
///
/// It is a face rather than a method on ``OverlayCoordinator`` because the coordinator is where the
/// CLOCK lives, and the clock is the one part of a toast's lifecycle that cannot cross: a dwell is
/// a `Task` per card. The rules around it — a stack is capped, a newer card for a pane replaces the
/// older rather than standing beside it, and the eviction eats the oldest end — are a fold over ids
/// and have no clock in them at all. `docs/62` §7 named the split; this is the near half of it.
package enum ToastStack {
    /// `stack` with `card` pushed on the end, deduped and trimmed.
    ///
    /// The door answers POSITIONS rather than cards, so nothing is copied across the boundary: the
    /// ids go over as one NUL-separated run, and what comes back is one byte per survivor. The
    /// pushed card is not in that answer because it is always last — asking for it would be asking
    /// Rust to hand back the argument.
    package static func pushing(_ card: Toast, onto stack: [Toast]) -> [Toast] {
        let standing = Array(stack.map(\.id).joined(separator: "\0").utf8)
        let incoming = Array(card.id.utf8)
        var kept = [UInt8](repeating: 0, count: stack.count)
        let survivors = standing.withUnsafeBufferPointer { standingBytes in
            incoming.withUnsafeBufferPointer { incomingBytes in
                kept.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_toast_push(
                        standingBytes.baseAddress, standingBytes.count,
                        incomingBytes.baseAddress, incomingBytes.count,
                        out.baseAddress, out.count,
                    )
                }
            }
        }
        return kept.prefix(survivors).map { stack[Int($0)] } + [card]
    }
}
