// TabBadgeReading — the near-side FACE of `slopdesk_agent::badge`'s reading half.
//
// The colours stay in the design floor (``SlopDeskSlate/StatusPresentation`` resolves a role to an
// ink); what crossed is the part no palette can supply: the WORD each state is spoken with, and
// which of the three attention roles it carries. Both are read by three surfaces — the Mac's AppKit
// rows, the phone's SwiftUI rows and the collapsed-sidebar strip — and a word spelled twice is a
// state VoiceOver reads two ways on two devices.
//
// It lives on `slopdesk-agent` and not on a workspace crate because that crate already owns the
// ladder that FUSES a pane's signals into one badge. The word a state is read aloud with and the
// role it carries are readings of that same type; a second nine-case enum beside it would be the
// drift pair the one-implementation rule exists for.

import CSlopDeskFFI

/// The three states that WAIT ON YOU, as roles rather than hues. The ink each takes is the view
/// floor's answer (``SlopDeskSlate/StatusPresentation/attentionInk(_:)``); the ORDER they rank in
/// is the far side's, because the collapsed-group roll-up has to pick a loudest one and every
/// surface must pick the same.
package enum AttentionRole: Equatable, Sendable, CaseIterable {
    /// A question is blocking the agent. The most urgent — someone is waiting on a person.
    case awaiting
    /// Something broke.
    case failed
    /// A turn ended and the news is unread.
    case finished

    /// The role a code names. `0` is "waits on nobody", which is what BUSY answers.
    init?(code: UInt8) {
        switch code {
        case 1: self = .awaiting
        case 2: self = .failed
        case 3: self = .finished
        default: return nil
        }
    }
}

package enum TabBadgeReading {
    /// The state's WORD — the row title's accessibility value, the roll-up's spoken label.
    package static func label(_ kind: TabBadgeKind) -> String {
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_agent_badge_label(kind.ffiByte, out, cap)) }
        return blob.isEmpty ? "" : wsRuns(blob, count: 1)[0]
    }

    /// The badge's attention role, or `nil` for the states that are merely BUSY or merely
    /// privileged. Busy is not attention: a spinning agent is not waiting for anyone.
    package static func attention(_ kind: TabBadgeKind) -> AttentionRole? {
        AttentionRole(code: slopdesk_agent_badge_attention(kind.ffiByte))
    }

    /// The subset of ``attention(_:)`` that means *something is wrong or stopped and it is waiting on
    /// you* — the two roles that take their hue across a whole row title. A FINISH is deliberately
    /// absent: green is the "nothing is wrong, come look when you can" end of the ramp, and spending
    /// the row on it would leave the urgent pair nothing louder to be.
    package static func urgent(_ kind: TabBadgeKind) -> AttentionRole? {
        AttentionRole(code: slopdesk_agent_badge_urgent(kind.ffiByte))
    }

    /// The strongest attention role among a collapsed group's hidden rows — a waiting question
    /// outranks a failure outranks an unread finish, which is ``AttentionRole``'s own declaration
    /// order. `nil` when nothing inside waits, so the header's count keeps the muted metadata ink
    /// and folding a group never hides an agent that needs the eye.
    ///
    /// One crossing for the whole group: a row wearing no badge lends the sentinel byte, so an
    /// all-clear row and a row this build cannot name answer alike.
    package static func rollup(_ badges: [TabBadgeKind?]) -> AttentionRole? {
        let bytes = badges.map { $0?.ffiByte ?? UInt8(SLOPDESK_AGENT_BADGE_NONE) }
        let code = bytes.withUnsafeBufferPointer { lent in
            slopdesk_agent_badge_rollup(lent.baseAddress, lent.count)
        }
        return AttentionRole(code: code)
    }

    /// Whether a badge is a COMMAND's outcome, and which one. The finish tiers fuse both speakers,
    /// so `agentFinish` decides: the agent's turn ending is the mark column's check, a command's exit
    /// is the trailing slot's. `.error` is always a command's — `ClaudeStatus` has no error case.
    ///
    /// It is a badge READING rather than `RailRowsBuilder`'s, which is where it was written: the
    /// builder is welded to `WorkspaceStore` (``RailRowsBuilder/failedBlock(for:badge:store:)``) and
    /// cannot descend, while this is a pure function of a badge and a `Bool` that both the receipt
    /// and the design floor's ``StatusPresentation`` have to read. The builder keeps
    /// ``RailRowsBuilder/commandReceipt(badge:agentFinish:blocks:failedBlock:processLabel:)``, which
    /// calls through to here, so the mark resolver and the slot's text still read one rule.
    package static func commandOutcome(badge: TabBadgeKind?, agentFinish: Bool) -> CommandOutcome? {
        let code = slopdesk_agent_badge_command_outcome(badge.map { Int8($0.ffiByte) } ?? -1, agentFinish)
        return CommandOutcome(code: code)
    }
}

/// A finished command's OUTCOME — the two readings the trailing slot has (docs/DECISIONS.md
/// round 24). A fact about the row's command blocks; only the INK it reads in
/// (``SlopDeskSlate/StatusPresentation/outcomeInk(_:)``) is a view decision.
package enum CommandOutcome: Equatable, Sendable {
    /// Exit 0 (or a completion the shell reported no code for).
    case succeeded
    /// A non-zero exit, or a held-red `OSC 9;4;2`.
    case failed

    init?(code: UInt8) {
        switch code {
        case 1: self = .succeeded
        case 2: self = .failed
        default: return nil
        }
    }
}
