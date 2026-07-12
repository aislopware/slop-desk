import Foundation

// MARK: - TabOrderingEngine (the pure By-Project key helpers)

/// The PURE helpers behind the sidebar's single layout: sections are ALWAYS bucketed by the By-Project key
/// and both sections and rows follow first-appearance in `session.tabs` (creation order) — there is no
/// grouping/sort hamburger, `.byDate` buckets, `.updated` recency sort, or manual drag-reorder; see
/// `docs/DECISIONS.md` for the rationale. The bucketing itself lives in
/// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` (per-PANE, so a split tab's panes land in
/// their respective projects); these two statics are the shared key-normalization/header rules so every
/// caller derives identical sections from a key. No SwiftUI, no I/O — fully headless-testable.
public enum TabOrderingEngine {
    /// Normalize a raw project key for BUCKETING: trim whitespace, strip trailing slashes (but keep root
    /// `/`), and treat an empty result as absent (`nil` ⇒ the "Other" bucket). The trailing-slash strip is
    /// load-bearing — a pane's cwd (`/work/alpha`) and its git toplevel (`/work/alpha/`, or vice-versa) or a
    /// `cd foo/` differ only by a trailing `/` yet name the SAME project; without normalizing they would
    /// split one directory into two identically-titled sections.
    public static func normalizedProjectKey(_ key: String?) -> String? {
        guard let key else { return nil }
        var trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The section header for a project key — its last path component (`/Users/me/proj/foo` → `foo`),
    /// falling back to the whole (trimmed) key when there is no `/`-delimited component; a `nil`/blank key is
    /// the "Other" bucket. Mirrors the basename helper in ``TabBadgeResolver`` (split on `/`, last non-empty
    /// component).
    public static func projectSectionHeader(for key: String?) -> String {
        guard let key, case let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return "Other" }
        guard let last = trimmed.split(separator: "/", omittingEmptySubsequences: true).last else {
            return trimmed
        }
        return String(last)
    }
}
