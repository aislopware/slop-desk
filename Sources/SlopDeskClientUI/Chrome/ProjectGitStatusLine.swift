// ProjectGitStatusLine — the sidebar SECTION HEADER's trailing git segment: ONE compact git line per
// project (the panes of a section share a repo, so the per-row git line was N copies of the same
// truth — it moved up here). Speaks the INSTRUMENT voice at the header's own size (MERIDIAN L2) in
// the `__git_ps1` ASCII dialect (`>`ahead `<`behind `+ ! ?`), ONE quiet tone for every count — a
// rainbow of 10pt tokens read as noise, and colour is rationed to the sole state that blocks work
// (conflict, err-red). The branch recedes to the header gray so the section TITLE stays the anchor.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The header's git segment. States:
///   • clean repo → just the muted branch (absence of dirt sigils IS the clean signal — no badge),
///   • dirty → branch + only the NON-ZERO sigils, fixed order `> < + ! ?` then conflict then `$`,
///   • conflicted → the `=N` token reads in err-red, semibold — the one COLOUR in the line, spent on
///     the one state where a token being scan-past-able has a real cost (a merge blocking work).
///     Plain text, no background plate. Hard cut, never animated (MERIDIAN L3).
///   • non-repo summary → renders nothing (a plain-directory section has no git concept; a
///     placeholder would be ornament — legible-or-absent).
/// The BRANCH pre-truncates (``cappedBranch(_:max:)``) so the sigil counts — the glanceable payload —
/// can never be eaten by view-level tail truncation.
struct ProjectGitStatusLine: View {
    let summary: PaneGitSummary

    var body: some View {
        if summary.hasRepo {
            HStack(spacing: Slate.Metric.space1) {
                Text(Self.mainLine(summary))
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.State.header)
                    .lineLimit(1)
                if summary.conflicted > 0 {
                    Text("=\(summary.conflicted)")
                        .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Status.err)
                        .lineLimit(1)
                }
                if summary.stash > 0 {
                    Text("$\(summary.stash)")
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The branch + the `> < + ! ?` run as ONE attributed string (conflict + stash render as separate
    /// views — the conflict is the line's one colour, the stash its own muted tone). Every count reads
    /// in the SAME secondary tone, one step brighter than the header-gray branch: the counts are the
    /// payload, the branch the context — hierarchy from luminance, not hue.
    @MainActor
    static func mainLine(_ g: PaneGitSummary) -> AttributedString {
        func token(_ text: String) -> AttributedString {
            var seg = AttributedString(text)
            seg.foregroundColor = Slate.Text.secondary
            return seg
        }
        var line = AttributedString(cappedBranch(g.branch.isEmpty ? "detached" : g.branch))
        if g.ahead > 0 { line += token(" >\(g.ahead)") }
        if g.behind > 0 { line += token(" <\(g.behind)") }
        if g.staged > 0 { line += token(" +\(g.staged)") }
        if g.modified > 0 { line += token(" !\(g.modified)") }
        if g.untracked > 0 { line += token(" ?\(g.untracked)") }
        return line
    }

    /// Middle-ellipsis cap for a long branch name, applied at BUILD time: a view-level
    /// `.truncationMode` truncates the whole `Text` — the trailing counts included — so the branch
    /// must give way first. 8 + `…` + tail keeps both the `feature/` prefix context and the tail
    /// qualifier (`…-fix-login`). Pure + static so the rule is unit-pinned.
    static func cappedBranch(_ branch: String, max: Int = 18) -> String {
        guard branch.count > max, max > 9 else { return branch }
        return branch.prefix(8) + "…" + branch.suffix(max - 9)
    }
}
#endif
