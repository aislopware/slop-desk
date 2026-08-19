// CheatSheetContent — WHAT the ⌘/ keyboard reference sheet says, and how its runs of shortcuts are
// dealt into columns. Not a view: two of them draw this, one per platform.
//
// The Mac's sheet is an AppKit panel (``SlopDeskMacUI/MacCheatSheetPanel``) and the phone's is a
// SwiftUI card, and neither is allowed to know the other exists. What they may not do is each spell
// out the rows — so the rows are here, below both, as plain values: a title, and the chord that
// fires it. docs/56's rule read at the scale of one surface — layout diverges, capability does not.
//
// The rows come from the single source-of-truth binding table
// (``WorkspaceBindingRegistry/groupedForDisplay``) with each chord taken from the SAME registry the
// keyboard dispatcher fires (``WorkspaceBindingRegistry/glyph(for:)``), so a printed glyph can never
// drift from the chord that actually runs. The GLYPH IS GATED ON THE ROW'S OWN CHORD, never on the
// action's: the collapsed ⌘1…⌘9 representative's stand-in `.selectPane(1)` action resolves the real
// ⌘1 binding, and a row that bakes its hint into its title must not also carry a cap that says ⌘1.
//
// The column deal is `slopdesk_cheat_sheet_columns` — balanced by RENDERED HEIGHT rather than by
// section count, which is the difference between two level columns and one long category with three
// short ones floating beside it. Asking for one column is a real answer, and the phone asks for it.

import CSlopDeskFFI
import SlopDeskWorkspaceCore

/// One shortcut: what it does, and the key that does it. `glyph` is `nil` for the palette-/menu-only
/// verbs (and the collapsed ⌘1…⌘9 representative), which render no cap at all.
public struct CheatSheetRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let glyph: String?

    public init(id: String, title: String, glyph: String?) {
        self.id = id
        self.title = title
        self.glyph = glyph
    }
}

/// One run of shortcuts under its category heading — the unit the column deal moves.
public struct CheatSheetSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [CheatSheetRow]

    public init(id: String, title: String, rows: [CheatSheetRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// The reference sheet's content, and where each run of it goes. A caseless namespace — the sheet
/// owns NO state; its rows are the registry's own table and its only mutation is the coordinator's
/// `closeCheatSheet()`, which belongs to whoever drew it.
public enum CheatSheetContent {
    /// The card's headline, spelled once so the two platforms cannot disagree about what it is called.
    public static let title = "Keyboard Shortcuts"

    /// Every section, in the registry's declared display order (panes, tabs, focus, view), with the
    /// nine ⌘1…⌘9 select-tab chords already collapsed into one representative row.
    public static var sections: [CheatSheetSection] {
        WorkspaceBindingRegistry.groupedForDisplay.map { group in
            CheatSheetSection(
                id: group.category.rawValue,
                title: group.category.rawValue,
                rows: group.bindings.map { binding in
                    CheatSheetRow(
                        id: binding.id,
                        title: binding.title,
                        // Gated on the ROW's chord, not the action's — see the file header.
                        glyph: binding.chord == nil
                            ? nil
                            : WorkspaceBindingRegistry.glyph(for: binding.action),
                    )
                },
            )
        }
    }

    /// `sections`, dealt into `columns` columns and returned column-major — one array per column, in
    /// the order they should be laid left to right. Always exactly `max(1, columns)` arrays, so a
    /// caller can zip them against its own column views without an emptiness check.
    public static func dealt(_ sections: [CheatSheetSection], into columns: Int) -> [[CheatSheetSection]] {
        let width = max(1, columns)
        let assignment = columnAssignment(rowCounts: sections.map(\.rows.count), columns: width)
        var buckets = [[CheatSheetSection]](repeating: [], count: width)
        for (section, column) in zip(sections, assignment) where buckets.indices.contains(column) {
            buckets[column].append(section)
        }
        return buckets
    }

    /// Which column each section belongs in, asked of `slopdesk_cheat_sheet_columns` — greedy
    /// shortest-first over rendered height (a section costs its rows plus its own header line).
    ///
    /// A negative or oversized row count is not a thing the registry can produce; it is clamped into
    /// `UInt32` here rather than trapping, so this stays total over anything a caller hands it.
    public static func columnAssignment(rowCounts: [Int], columns: Int) -> [Int] {
        guard !rowCounts.isEmpty else { return [] }
        let counts = rowCounts.map { UInt32(clamping: $0) }
        var out = [UInt32](repeating: 0, count: rowCounts.count)
        let written = counts.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { room in
                slopdesk_cheat_sheet_columns(
                    source.baseAddress,
                    source.count,
                    UInt32(clamping: Swift.max(1, columns)),
                    room.baseAddress,
                    room.count,
                )
            }
        }
        // The door answers the count it NEEDS; it always needs exactly one index per section, so a
        // short answer can only mean a lent buffer it refused to tear — fall back to column zero.
        guard written == rowCounts.count else { return [Int](repeating: 0, count: rowCounts.count) }
        return out.map { Int($0) }
    }
}
