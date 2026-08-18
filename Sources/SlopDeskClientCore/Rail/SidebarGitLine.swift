// SidebarGitLine — the project header's git DIALECT, and the sections the navigator groups by.
//
// `main ↑2 ↓1 +3 !4 ?5 ~1 $2` is a language, not a label: the branch first, then only the NON-ZERO
// sigils in fixed order, each with a role that decides its ink and its weight, and a shedding ladder
// for the widths a real sidebar column actually offers. All of that is decision, none of it is
// drawing — which is why it lives here now that the header is an `NSView` on the Mac
// (``SlopDeskMacUI/MacSidebarHeaderView``) and a `View` on the phone. The two halves supply the
// palette; the dialect is one.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The dialect

/// What one run of the git line MEANS — the axis its ink and weight are chosen on. Roles, not
/// colours: the palette resolution belongs to whichever framework is drawing.
package enum GitInk: CaseIterable, Sendable {
    /// The branch name — identity, not a count.
    case branch
    /// `↑`/`↓` — where this branch sits against its upstream.
    case divergence
    /// `+` — staged and ready to commit.
    case staged
    /// `!` — unstaged worktree changes.
    case modified
    /// `?` — files git does not know about yet.
    case untracked
    /// `~` — an unmerged state. The one run that genuinely needs a human.
    case conflicted
    /// `$` — parked work.
    case stash
}

/// The three weights a run is set at — a second channel the palette cannot supply, and the one that
/// survives the hue set's CVD collapse (under protanopia `+staged` and `~conflicted` land close
/// enough to be indistinguishable by hue alone).
package enum GitWeight: Sendable {
    case regular
    case semibold
    case bold
}

/// One run of the git line: the text exactly as the dialect spells it, plus its role.
package struct GitSegment: Equatable, Sendable {
    package let text: String
    package let ink: GitInk

    package init(text: String, ink: GitInk) {
        self.text = text
        self.ink = ink
    }

    /// The run stripped to its SIGIL — the leading glyph the dialect gives it (`↑2` → `↑`), which is
    /// the whole run minus the count. `nil` for the branch: it is a NAME, not a sigil, so it has no
    /// compact form (it truncates instead).
    package var symbol: String? {
        guard ink != .branch else { return nil }
        return text.first.map(String.init)
    }
}

package enum SidebarGitLine {
    /// The git line SPLIT into its runs — one segment per sigil, in the fixed order the prompt-theme
    /// dialect every git prompt already taught the eye: `↑`/`↓` divergence, `+` staged, `!` modified,
    /// `?` untracked, `~` merge conflicts, `$` stash. Empty for a non-repo summary (a plain directory
    /// has no git concept).
    package static func segments(_ summary: PaneGitSummary) -> [GitSegment] {
        guard summary.hasRepo else { return [] }
        var parts = [GitSegment(
            text: summary.branch.isEmpty ? "detached" : summary.branch, ink: .branch,
        )]
        if summary.ahead > 0 { parts.append(GitSegment(text: "↑\(summary.ahead)", ink: .divergence)) }
        if summary.behind > 0 { parts.append(GitSegment(text: "↓\(summary.behind)", ink: .divergence)) }
        if summary.staged > 0 { parts.append(GitSegment(text: "+\(summary.staged)", ink: .staged)) }
        if summary.modified > 0 { parts.append(GitSegment(text: "!\(summary.modified)", ink: .modified)) }
        if summary.untracked > 0 {
            parts.append(GitSegment(text: "?\(summary.untracked)", ink: .untracked))
        }
        if summary.conflicted > 0 {
            parts.append(GitSegment(text: "~\(summary.conflicted)", ink: .conflicted))
        }
        if summary.stash > 0 { parts.append(GitSegment(text: "$\(summary.stash)", ink: .stash)) }
        return parts
    }

    /// The whole line as ONE string — the tooltip's second line and every accessibility label.
    /// `nil` for a non-repo summary. ``segments(_:)`` joined, so the painted line and the spoken one
    /// can never drift.
    package static func line(_ summary: PaneGitSummary) -> String? {
        let runs = segments(summary)
        guard !runs.isEmpty else { return nil }
        return runs.map(\.text).joined(separator: " ")
    }

    /// The header's SECOND line: the live git line under the folder name, so neither fights the other
    /// for one row's width. A COLLAPSED header folds it away (the hidden-row count speaks instead),
    /// and an empty result is also "no repo".
    package static func detailSegments(collapsed: Bool, summary: PaneGitSummary?) -> [GitSegment] {
        guard !collapsed, let summary else { return [] }
        return segments(summary)
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

    /// The weight one run is set at, on three rungs.
    ///
    /// Every COUNT is set heavy: the sigil runs are the readout, and at 10 pt mono a regular weight
    /// leaves them thin enough that the colour is doing all the work. The BRANCH stays regular — it
    /// is the line's identity, not a status, and keeping it light is what lets the counts read as a
    /// group. `~conflicted` goes one rung further still, on IMPORTANCE: one of these seven states is
    /// the one that stops work, said in a channel free of the palette.
    package static func weight(_ role: GitInk) -> GitWeight {
        switch role {
        case .branch: .regular
        case .conflicted: .bold
        case .divergence,
             .modified,
             .staged,
             .stash,
             .untracked: .semibold
        }
    }

    /// The STATUS runs stripped to their sigils — `↑2 ↓1 !3` → `↑ ↓ !` — for the line's compact form.
    /// The counts go; the roles stay, so a squeezed line still says exactly WHICH states are live.
    /// The branch is dropped (it has no sigil; it truncates instead), and the full numbers stay one
    /// hover away in the tooltip.
    package static func compactStatus(_ segments: [GitSegment]) -> [GitSegment] {
        segments.compactMap { segment in
            segment.symbol.map { GitSegment(text: $0, ink: segment.ink) }
        }
    }

    /// The order the status runs GIVE UP their place when the branch runs out of room, least
    /// important first. It is a ranking of "how much does knowing this right now change what I do
    /// next":
    ///
    /// `$` stash is work you parked on purpose. `↑↓` divergence is bookkeeping against a remote —
    /// unpushed commits are safely committed, and pushing is a thing you do on your own schedule.
    /// `?` untracked is usually build output and scratch files. Those three are worth a glance when
    /// there is room and worth nothing when there isn't. What survives is the WORKTREE: `+staged`,
    /// `!modified`, `~conflicted` — uncommitted work and broken merges, the states that decide
    /// whether this project is safe to leave.
    package static let shedLadder: [GitInk] = [
        .stash, .divergence, .untracked, .staged, .modified, .conflicted,
    ]

    /// The status runs left after giving up `level` RUNGS of ``shedLadder``. A rung is a ROLE, not a
    /// run: `↑` and `↓` are one fact about one remote and leave together, and a role the line never
    /// had costs no rung (so the rungs always narrow the readout — otherwise a clean-but-diverged
    /// repo would spend its whole ladder shedding sigils it does not have).
    ///
    /// The last runs standing are never shed — a git line that reports nothing is not a tighter
    /// readout, it is a missing one — so a repo whose only dirt is `↑2` keeps its `↑` however narrow
    /// the rail gets.
    package static func shedding(_ status: [GitSegment], to level: Int) -> [GitSegment] {
        var kept = status
        var shed = 0
        for role in shedLadder where shed < level {
            let remaining = kept.filter { $0.ink != role }
            guard remaining.count < kept.count else { continue } // the line never had this role
            guard !remaining.isEmpty else { break } // shedding it would leave nothing to read
            kept = remaining
            shed += 1
        }
        return kept
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
