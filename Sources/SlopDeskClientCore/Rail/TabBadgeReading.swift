// TabBadgeReading — what a fused ``TabBadgeKind`` SAYS, in words and in urgency, below either UI.
//
// The colours stay in the design floor (``SlopDeskSlate/StatusPresentation`` resolves a role to an
// ink); what lives here is the part no palette can supply: the WORD each state is spoken with, and
// which of the three attention roles it carries. Both are read by three surfaces — the Mac's AppKit
// rows, the phone's SwiftUI rows and the collapsed-sidebar strip — and a word spelled twice is a
// state VoiceOver reads two ways on two devices.

import SlopDeskWorkspaceCore

/// The three states that WAIT ON YOU, as roles rather than hues. The ink each takes is the view
/// floor's answer (``SlopDeskSlate/StatusPresentation/attentionInk(_:)``); the ORDER they rank in
/// is this file's, because the collapsed-group roll-up has to pick a loudest one and both halves
/// must pick the same.
package enum AttentionRole: Equatable, Sendable, CaseIterable {
    /// A question is blocking the agent. The most urgent — someone is waiting on a person.
    case awaiting
    /// Something broke.
    case failed
    /// A turn ended and the news is unread.
    case finished
}

package enum TabBadgeReading {
    /// The state's WORD — the row title's accessibility value, the roll-up's spoken label.
    package static func label(_ kind: TabBadgeKind) -> String {
        switch kind {
        case .running: "Agent working"
        case .commandRunning: "Loading"
        case .commandBusy: "Running"
        case .completed: "Completed"
        case .finished: "Finished"
        case .error: "Error"
        case .awaitingInput: "Awaiting input"
        case .caffeinate: "Caffeinated"
        case .sudo: "Privileged"
        }
    }

    /// The badge's attention role, or `nil` for the states that are merely BUSY or merely
    /// privileged. Busy is not attention: a spinning agent is not waiting for anyone.
    package static func attention(_ kind: TabBadgeKind) -> AttentionRole? {
        switch kind {
        case .awaitingInput: .awaiting
        case .error: .failed
        // The completed/finished split is the freshness machinery's, not the reader's: a fresh
        // flash and a settled unread finish are the same news at two ages.
        case .completed,
             .finished: .finished
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: nil
        }
    }

    /// The subset of ``attention(_:)`` that means *something is wrong or stopped and it is waiting on
    /// you* — the two roles that take their hue across a whole row title. A FINISH is deliberately
    /// absent: green is the "nothing is wrong, come look when you can" end of the ramp, and spending
    /// the row on it would leave the urgent pair nothing louder to be.
    package static func urgent(_ kind: TabBadgeKind) -> AttentionRole? {
        switch attention(kind) {
        case .awaiting: .awaiting
        case .failed: .failed
        case .finished,
             .none: nil
        }
    }

    /// The strongest attention role among a collapsed group's hidden rows — a waiting question
    /// outranks a failure outranks an unread finish, which is ``AttentionRole``'s own declaration
    /// order. `nil` when nothing inside waits, so the header's count keeps the muted metadata ink
    /// and folding a group never hides an agent that needs the eye.
    package static func rollup(_ badges: [TabBadgeKind?]) -> AttentionRole? {
        let present = Set(badges.compactMap(\.self).compactMap(attention))
        return AttentionRole.allCases.first { present.contains($0) }
    }
}
