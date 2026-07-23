// RailRowTelemetry — the pure resolution of a sidebar row's right-aligned telemetry slot: at most ONE
// value per row, picked by the badge's own precedence, rendered in the instrument voice. The slot answers
// the supervision questions a glance needs — "how long has this question been ignored", "how long has
// this turn run", "what did that command exit with" — without a click. Pure + clock-injected so every
// rule is unit-pinned headlessly (no view, no store).

import Foundation
import SlopDeskWorkspaceCore

/// The tone a telemetry value renders in. Colour is spent on exactly ONE number — the blocked-age
/// (an asked-AND-ignored question is live attention data); everything else stays on the grey ladder,
/// with `primary` as the ≥10-minute typographic escalation of a working turn (one luminance step, no
/// colour, no motion).
enum RailTelemetryTone: Equatable {
    case amber
    case secondary
    case primary
}

/// One resolved telemetry value: the ≤4-character text + its tone.
struct RailTelemetryValue: Equatable {
    let text: String
    let tone: RailTelemetryTone
}

enum RailRowTelemetry {
    /// Ages appear only once a state has lasted this long — a fresh question/turn/command needs no
    /// number; the slot stays empty (legible-or-absent, no placeholder).
    static let revealDelay: TimeInterval = 60
    /// A working turn this old escalates its age one luminance step (secondary → primary): the
    /// stuck-agent signal is a quietly brightening number, not colour or motion.
    static let workingEscalationDelay: TimeInterval = 600

    /// The clamped ≤4-character duration grammar: `42s` / `12m` / `1h04` / `>9h`. Fixed-width by
    /// construction so a ticking value can never change the column's layout.
    static func compactDuration(_ interval: TimeInterval) -> String {
        guard !interval.isLess(than: 0) else { return "0s" }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 10 { return "\(hours)h" + String(format: "%02d", minutes % 60) }
        return ">9h"
    }

    /// Resolve the row's one telemetry value (or `nil` for an empty slot), by badge precedence:
    ///   • awaitingInput → blocked-age (AMBER — the sole coloured number), from the attention stamp;
    ///   • error → a non-agent row shows the bare exit code immediately (the cross alarms, the number
    ///     informs); an agent row shows its time-in-error;
    ///   • running → the turn's elapsed (the `.working` edge stamps the attention clock), escalating
    ///     one luminance step past ``workingEscalationDelay``;
    ///   • command tiers → a determinate OSC 9;4 percent immediately when present, else the command's
    ///     elapsed (minute granularity — the grammar never shows seconds past the reveal delay, so a
    ///     command's number ticks at most once a minute: commands stay quiet);
    ///   • completed/finished → the unread-age of the finish;
    ///   • privilege markers / no badge → nothing.
    static func value(
        badge: TabBadgeKind?,
        isAgentSession: Bool,
        attentionAt: Date?,
        completedAt: Date?,
        commandStartedAt: Date?,
        progressPercent: String?,
        exitCode: Int32?,
        now: Date,
    ) -> RailTelemetryValue? {
        switch badge {
        case .awaitingInput:
            guard let age = revealedAge(since: attentionAt, now: now) else { return nil }
            return RailTelemetryValue(text: age, tone: .amber)
        case .error:
            if !isAgentSession, let exitCode {
                return RailTelemetryValue(text: clampedExitCode(exitCode), tone: .secondary)
            }
            guard let age = revealedAge(since: attentionAt, now: now) else { return nil }
            return RailTelemetryValue(text: age, tone: .secondary)
        case .running:
            guard let attentionAt, let age = revealedAge(since: attentionAt, now: now) else { return nil }
            let escalated = !now.timeIntervalSince(attentionAt).isLess(than: workingEscalationDelay)
            return RailTelemetryValue(text: age, tone: escalated ? .primary : .secondary)
        case .commandRunning,
             .commandBusy:
            if let progressPercent {
                return RailTelemetryValue(text: progressPercent, tone: .secondary)
            }
            guard let age = revealedAge(since: commandStartedAt, now: now) else { return nil }
            return RailTelemetryValue(text: age, tone: .secondary)
        case .completed,
             .finished:
            guard let age = revealedAge(since: completedAt, now: now) else { return nil }
            return RailTelemetryValue(text: age, tone: .secondary)
        case .caffeinate,
             .sudo,
             nil:
            return nil
        }
    }

    /// The compact age since `since`, or `nil` while it is younger than the reveal delay (or unknown).
    /// Ages measure time since the state's LAST EDGE (the stamps are edge-written), which is exactly
    /// the supervision question: "how long has it been like this".
    private static func revealedAge(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        let elapsed = now.timeIntervalSince(since)
        guard !elapsed.isLess(than: revealDelay) else { return nil }
        return compactDuration(elapsed)
    }

    /// The exit code clamped to the 4-character column — a shell code is 0…255, but the wire carries an
    /// `Int32`, so an out-of-band value must not push the rail sideways. Beyond 4 digits (or negative
    /// past `-999`) the number stops informing at a glance; the cross already alarms, so it degrades to
    /// `err` (the tooltip keeps the exact line).
    private static func clampedExitCode(_ code: Int32) -> String {
        let text = "\(code)"
        return text.count <= 4 ? text : "err"
    }
}
