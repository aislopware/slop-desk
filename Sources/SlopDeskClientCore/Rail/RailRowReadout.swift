// RailRowReadout — the FACE over `slopdesk_workspace::sidebar_row`'s detail ladder.
//
// The row's live-detail line is ONE source at a time, hard cut between them, and the resolved line
// is the thing you'd focus the tab to find out — since the otty reset it rides the row's hover
// TOOLTIP (the rendered row is bare: title + one trailing slot). It EARNS its place: there are no
// structural filler rungs (cwd echoes, shell identity, shortcut hints — derivable or decorative),
// so a settled row's tooltip is path + history alone and a detail line always means "something is
// happening here".
//
// The ladder, the title-echo suppression and the trim on the failed command are all
// `slopdesk_ws_sidebar_row_detail`'s; what is left here is packing seven spans into one arena in
// the door's own precedence order.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

package enum RailRowReadout {
    /// The row's one readout source, resolved across the door in a single crossing.
    ///
    /// Every input is pre-gated by the CALLER — each is handed over only when its own state holds
    /// (`.needsPermission` and a non-empty label for the question, a live inspector feed for the
    /// scent, an unseen finish for the done line). That gating is why the presence of a span, and
    /// not its emptiness, is what lights a rung.
    ///
    /// The failure is passed as its two halves rather than as a resolved line: the door decides
    /// whether an exit code with a blank command says anything at all, and the trimmed command it
    /// answers with is the one string here that is not already one of ours.
    package static func resolve(
        question: String?,
        scent: String?,
        workingLabel: String?,
        doneLine: String?,
        exitCode: Int32?,
        failedCommand: String?,
        commandLine: String? = nil,
        title: String = "",
    ) -> String? {
        var arena = WsStrings()
        // The door's own order — index 0 is the top of the ladder and index 6 is the title.
        let spans = [
            arena.span(question),
            arena.span(scent),
            arena.span(workingLabel),
            arena.span(doneLine),
            arena.span(failedCommand),
            arena.span(commandLine),
            arena.span(title),
        ]
        assert(spans.count == Int(SLOPDESK_WS_SIDEBAR_ROW_DETAIL_SPANS))
        let blob = spans.withUnsafeBufferPointer { lentSpans in
            arena.bytes.withUnsafeBufferPointer { lent in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_sidebar_row_detail(
                        lent.baseAddress, lent.count,
                        lentSpans.baseAddress, lentSpans.count,
                        exitCode != nil, out, cap,
                    ))
                }
            }
        }
        // The door's `0` — an empty delivery — is "nothing live", which is the resting state and
        // never a placeholder. A lit rung whose own text was blank reads the same way: the caller
        // gates every prose rung on a non-empty label already.
        guard !blob.isEmpty else { return nil }
        let line = wsRuns(blob, count: 1)[0]
        return line.isEmpty ? nil : line
    }
}
