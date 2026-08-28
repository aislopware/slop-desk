// OutlinePresentation — the near-side FACE of `slopdesk_workspace::outline`.
//
// The Outline tab's two readings: how long ago a row ran, and how it ended. Both are pure mappings, and
// both stayed free of `Slate` and of any view framework, so the ONLY theme-coupled part is each shell's
// own `Gutter → colour` map.
//
// THE CLOCK STAYS HERE. `relativeTime(from:now:)` still takes two `Date`s and subtracts them, because a
// door that read a clock would answer differently for the same inputs — which is not a rule. What crosses
// is the count of whole seconds and the BUCKETING of it: a single coarse unit, integer arithmetic only,
// and a future `from` clamped to "now" rather than rendered with a minus in it.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

public enum OutlinePresentation {
    /// Relative time from `from` to `now`: sub-second → "now", then "34s ago" / "4m ago" / "2h ago" /
    /// "3d ago" — the Outline row's exact shape. It carries the "ago" suffix that a bare duration render
    /// (an uptime, an elapsed count) does NOT, because the suffix is read only by the Outline.
    ///
    /// The delta is truncated to whole seconds HERE and bucketed on the far side, so clock skew — a
    /// `from` in the future — crosses as a negative count and clamps there rather than at each caller.
    public static func relativeTime(from: Date, now: Date) -> String {
        let seconds = Int64(now.timeIntervalSince(from))
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_ws_outline_relative_time(seconds, out, cap)) }
        return wsRuns(blob, count: 1)[0]
    }

    /// The Outline row's exit-status gutter bucket — grey while running, green on success, red on a
    /// non-zero exit. The view maps this to `Slate.Status.ok` / `.err` / `Slate.Text.tertiary`, so this
    /// enum is the testable classification and the colour map is the only theme-coupled part.
    public enum Gutter: Equatable, Sendable {
        /// Still executing (no OSC 133 `D` yet) — a grey dot.
        case running
        /// Finished with exit 0 / no reported code — a green check.
        case succeeded
        /// Finished with a non-zero exit code — a red cross.
        case failed

        /// The code this bucket crosses as — the shared order both sides index.
        var code: UInt8 {
            switch self {
            case .running: 0
            case .succeeded: 1
            case .failed: 2
            }
        }

        /// The bucket a code names. Anything unrecognised reads as the neutral running dot: claiming an
        /// outcome for a block that never reported one is the one wrong answer here.
        init(code: UInt8) {
            switch code {
            case 1: self = .succeeded
            case 2: self = .failed
            default: self = .running
            }
        }
    }

    /// Classifies a block's ``CommandBlock/status`` into a ``Gutter`` bucket (reusing the value type's own
    /// `running` / `succeeded` / `failed(code:)` derivation, so the host status and the Outline never
    /// disagree on what counts as success).
    public static func gutter(for block: CommandBlock) -> Gutter {
        let status: Gutter =
            switch block.status {
            case .running: .running
            case .succeeded: .succeeded
            case .failed: .failed
            }
        return Gutter(code: slopdesk_ws_outline_gutter(status.code))
    }
}
