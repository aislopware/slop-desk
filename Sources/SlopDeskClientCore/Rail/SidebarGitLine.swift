// SidebarGitLine — the project header's git DIALECT as the two halves read it, and the sections the
// navigator groups by.
//
// `main ↑2 ↓1 +3 !4 ?5 ~1 $2` is a language, not a label, and the language is
// `slopdesk_workspace::git_line`'s: which runs the line has, in what order, what each one MEANS, the
// weight it is set at, and which of them give up their place when the column narrows. This file is
// the face — it asks, and it SPELLS.
//
// ## What spelling means here, and why it is not a second dialect
//
// A run crosses as a role, one GLYPH and a number. Putting `↑` next to `2` is not a decision anyone
// can disagree with; CHOOSING `↑` is, and that choice never leaves Rust. The proof is on the record:
// a dead second Swift renderer spelled a conflict `=` where the dialect spells it `~`, and the two
// compiled side by side until the copy was deleted (docs/56 increment 45).
//
// The BRANCH is the one run this side supplies text for, because the text is the caller's own
// string. It is a NAME, which is why it truncates instead of compacting and why the rule carries
// only the one bit it actually reads: whether there was a branch to name at all.

import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// ``GitInk`` — the ROLE a run carries — is `SlopDeskWorkspaceModel`'s, because `SlopDeskSlate`
// resolves it to a hue and the design floor must not name this whole reading to do it. Everything
// else about the dialect is here.

// MARK: - The dialect

/// The three weights a run is set at — a second channel the palette cannot supply, and the one that
/// survives the hue set's CVD collapse (under protanopia `+staged` and `~conflicted` land close
/// enough to be indistinguishable by hue alone).
package enum GitWeight: Sendable {
    case regular
    case semibold
    case bold
}

/// One run of the git line: the text exactly as the dialect spells it, its role, and the weight the
/// rule sets it at.
///
/// The weight rides ALONG rather than being asked for by role. It is a function of the role, so a
/// second `weight(_ ink:)` lookup on this side would be a table already spelled once in Rust — and
/// the rule fills it in on the same crossing that decides the run exists.
package struct GitSegment: Equatable, Sendable {
    package let text: String
    package let ink: GitInk
    package let weight: GitWeight

    package init(text: String, ink: GitInk, weight: GitWeight) {
        self.text = text
        self.ink = ink
        self.weight = weight
    }
}

package enum SidebarGitLine {
    /// The git line SPLIT into its runs — the branch, then one segment per non-zero count in the
    /// dialect's order. Empty for a non-repo summary: a plain directory has no git concept.
    package static func segments(_ summary: PaneGitSummary) -> [GitSegment] {
        runs(summary).map { spelled($0, branch: summary.branch) }
    }

    /// The whole line as ONE string — the tooltip's second line and every accessibility label.
    /// `nil` for a non-repo summary. ``segments(_:)`` joined, so the painted line and the spoken one
    /// can never drift.
    package static func line(_ summary: PaneGitSummary) -> String? {
        let runs = segments(summary)
        guard !runs.isEmpty else { return nil }
        return runs.map(\.text).joined(separator: " ")
    }

    /// Whether the header's SECOND line — the live git line under the folder name, so neither fights
    /// the other for one row's width — has anything to say. A COLLAPSED header folds it away (the
    /// hidden-row count speaks instead), and a directory with no repo has nothing there either.
    ///
    /// Answers the SUMMARY rather than the written line: the ladder folds from counts, so a caller
    /// handed only the writing would have to give it back to be re-read at a narrower width.
    package static func detailSummary(collapsed: Bool, summary: PaneGitSummary?) -> PaneGitSummary? {
        guard !collapsed, let summary, summary.hasRepo else { return nil }
        return summary
    }

    /// The header's muted trailing slot: the hidden-row count while COLLAPSED. An open header keeps
    /// the slot empty; its git line lives on the second line. `nil` guards the impossible empty group.
    package static func trailingCount(collapsed: Bool, count: Int) -> String? {
        collapsed && count > 0 ? "\(count)" : nil
    }

    /// The header's hover tooltip: the full project path (the name line deliberately shows only the
    /// basename), then the git line.
    package static func tooltip(projectKey: String?, summary: PaneGitSummary?) -> String? {
        let parts = [projectKey, summary.flatMap(line)].compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The READOUT alone, `level` rungs of the shed ladder given up, spelled as BARE SIGILS — the
    /// line's compact form. The counts go; the roles stay, so a squeezed line still says exactly
    /// WHICH states are live. The branch is dropped (it has no sigil; it truncates instead), and the
    /// full numbers stay one hover away in the tooltip.
    ///
    /// One call rather than a shed followed by a compaction: the two were always applied together,
    /// the rule folds them in one crossing, and a caller holding a half-shed line was never a thing
    /// this dialect meant to offer.
    package static func compactStatus(_ summary: PaneGitSummary, shedding level: Int) -> [GitSegment] {
        var out = emptyRuns()
        var counts = counts(summary)
        let written = out.withUnsafeMutableBufferPointer { runs in
            slopdesk_git_line_shed(&counts, level, runs.baseAddress, runs.count)
        }
        return out.prefix(min(written, out.count)).compactMap { run in
            run.sigil.scalar.map {
                GitSegment(text: String($0), ink: role(run.ink), weight: rung(run.weight))
            }
        }
    }

    // MARK: - The crossing

    /// The line's runs, straight off the rule.
    private static func runs(_ summary: PaneGitSummary) -> [SlopDeskGitRun] {
        var out = emptyRuns()
        var counts = counts(summary)
        let written = out.withUnsafeMutableBufferPointer { runs in
            slopdesk_git_line_runs(&counts, runs.baseAddress, runs.count)
        }
        return Array(out.prefix(min(written, out.count)))
    }

    /// One run, written. The SIGIL is the rule's; the branch's text is the caller's.
    private static func spelled(_ run: SlopDeskGitRun, branch: String) -> GitSegment {
        guard let sigil = run.sigil.scalar else {
            // The branch. `detached` is the rule's reading of an empty name — this side supplies the
            // word for it, which is a label like any other and not part of the dialect.
            return GitSegment(
                text: run.detached ? "detached" : branch, ink: role(run.ink),
                weight: rung(run.weight),
            )
        }
        return GitSegment(
            text: "\(sigil)\(run.count)", ink: role(run.ink), weight: rung(run.weight),
        )
    }

    /// The summary as the rule reads it: counts, and the one bit the branch NAME decides.
    private static func counts(_ summary: PaneGitSummary) -> SlopDeskGitCounts {
        SlopDeskGitCounts(
            has_repo: summary.hasRepo,
            detached: summary.branch.isEmpty,
            ahead: clamped(summary.ahead),
            behind: clamped(summary.behind),
            staged: clamped(summary.staged),
            modified: clamped(summary.modified),
            untracked: clamped(summary.untracked),
            conflicted: clamped(summary.conflicted),
            stash: clamped(summary.stash),
        )
    }

    /// A count as the rule's `uint32_t`. Saturating rather than trapping: these are counts a REMOTE
    /// host folded, and a rail that crashes on a repo with four billion untracked files is a worse
    /// answer than one that reports four billion.
    private static func clamped(_ count: Int) -> UInt32 {
        UInt32(Swift.max(0, Swift.min(count, Int(UInt32.max))))
    }

    /// The buffer both doors fill — a stack-sized array, because the rule's own ceiling bounds it.
    private static func emptyRuns() -> [SlopDeskGitRun] {
        [SlopDeskGitRun](
            repeating: SlopDeskGitRun(ink: 0, weight: 0, sigil: 0, count: 0, detached: false),
            count: Int(SLOPDESK_GIT_MAX_RUNS),
        )
    }

    /// One wire role as this side's enum. An unknown byte reads as the branch — the one run that
    /// carries no count, so a disagreement costs a sigil rather than inventing a number.
    private static func role(_ wire: UInt8) -> GitInk {
        switch Int32(wire) {
        case SLOPDESK_GIT_INK_DIVERGENCE: .divergence
        case SLOPDESK_GIT_INK_STAGED: .staged
        case SLOPDESK_GIT_INK_MODIFIED: .modified
        case SLOPDESK_GIT_INK_UNTRACKED: .untracked
        case SLOPDESK_GIT_INK_CONFLICTED: .conflicted
        case SLOPDESK_GIT_INK_STASH: .stash
        default: .branch
        }
    }

    /// One wire rung as this side's enum, on the same reading: an unknown byte is the lightest one.
    private static func rung(_ wire: UInt8) -> GitWeight {
        switch Int32(wire) {
        case SLOPDESK_GIT_WEIGHT_SEMIBOLD: .semibold
        case SLOPDESK_GIT_WEIGHT_BOLD: .bold
        default: .regular
        }
    }
}

private extension UInt32 {
    /// This scalar as a character, or `nil` for the branch's sentinel. Tested BEFORE the decode: NUL
    /// is a scalar like any other, so `UnicodeScalar(0)` is a real character that would spell the
    /// branch as a blank.
    var scalar: Character? {
        guard self != UInt32(SLOPDESK_GIT_NO_SIGIL) else { return nil }
        return UnicodeScalar(self).map(Character.init)
    }
}

// MARK: - The sections a column groups into

/// One rendered navigator section: an optional `header` (the group title; `nil` ⇒ the ungrouped flat
/// list), the section's normalized By-Project key (the ``WorkspaceStore/projectGitSummary`` lookup
/// for the header's git segment; `nil` ⇒ the "Other" bucket), and the rows in render order.
///
/// Identity is the group's stable key so a list diff does not churn when a sibling section's
/// contents change.
package struct SidebarSection: Identifiable, Equatable, Sendable {
    package let id: String
    package let header: String?
    package let projectKey: String?
    package let rows: [RailRow]
}

package enum SidebarSections {
    /// Map the always-on By-Project grouping onto the FILTERED rail rows, then attach a stable
    /// identity to each surviving section. Renders via the PER-PANE sectioning
    /// (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``) so a split tab's panes bucket into
    /// their OWN projects and the section header cannot flicker with focus; sections and rows follow
    /// creation order.
    package static func sections(
        _ rows: [RailRow], tabOrder: [TabID], query: String,
    ) -> [SidebarSection] {
        RailRowsBuilder.sectionedByProject(rows, tabOrder: tabOrder, query: query)
            .enumerated()
            .map { index, group in
                SidebarSection(
                    id: "\(index)|\(group.header ?? "")", header: group.header,
                    projectKey: group.projectKey, rows: group.rows,
                )
            }
    }

    /// The collapse-set key for a section: its normalized project key, or the sentinel for the
    /// keyless "Other" bucket (whose `projectKey` is `nil` but which still collapses).
    package static func collapseKey(_ projectKey: String?) -> String {
        projectKey ?? "\u{2205}other"
    }

    /// Does the FOCUSED pane live in this group? The header's own ink step reads it, and it is pure
    /// over the rows plus the tree's focus so the marking rule is unit-pinnable.
    @MainActor
    package static func holdsFocus(rows: [RailRow], store: WorkspaceStore) -> Bool {
        guard let focused = store.tree.activeSession?.activeTab?.activePane else { return false }
        return rows.contains { $0.id == focused }
    }

    /// The zero states, in the order a column asks them: nothing open at all, then nothing matching
    /// what was typed. The distinction is the whole reason there are two — "no matching tabs" under
    /// an empty field would report a failure nobody asked for.
    package static func emptyLine(rows: [RailRow], sections: [SidebarSection]) -> String? {
        if rows.isEmpty { return "No tabs open" }
        return sections.isEmpty ? "No matching tabs" : nil
    }
}
