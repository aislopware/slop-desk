import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the ⌘/ keyboard cheat sheet: it is GENERATED from the same `defaultBindings` table the menu bar
/// and palette use (so it can't drift), every workspace row resolves to a real glyph, and the curated
/// terminal/palette extras are present. The drift guard fails the moment a new bound command is added
/// without a cheat-sheet row.
@MainActor
final class KeyboardCheatSheetTests: XCTestCase {
    #if canImport(SwiftUI)

    func testSectionsAreNonEmptyAndEveryRowHasAGlyph() {
        let sections = KeyboardCheatSheet.sections()
        XCTAssertFalse(sections.isEmpty)
        for section in sections {
            XCTAssertFalse(section.items.isEmpty, "\(section.title) has no rows")
            for item in section.items {
                XCTAssertFalse(item.glyph.isEmpty, "\(item.label) has no glyph")
                XCTAssertFalse(item.label.isEmpty)
            }
        }
    }

    func testGlyphsMatchTheBindingsTable() {
        let all = KeyboardCheatSheet.sections().flatMap(\.items)
        // The generated glyphs come straight from defaultBindings via shortcutHint.
        XCTAssertTrue(all.contains { $0.glyph == "⌘N" }, "New pane → ⌘N")
        XCTAssertTrue(all.contains { $0.glyph == "⇧⌘B" }, "Broadcast → ⇧⌘B")
        XCTAssertTrue(all.contains { $0.glyph == "⌘\\" }, "Overview → ⌘\\")
        XCTAssertTrue(all.contains { $0.glyph == "⌥⌘A" }, "Select all panes → ⌥⌘A")
    }

    func testIncludesBookmarkAndTerminalSections() throws {
        let titles = KeyboardCheatSheet.sections().map(\.title)
        XCTAssertTrue(titles.contains("Viewport bookmarks"))
        XCTAssertTrue(titles.contains("Search & terminal"))
        let extras = try XCTUnwrap(KeyboardCheatSheet.sections().first { $0.title == "Search & terminal" }?.items)
        XCTAssertTrue(extras.contains { $0.glyph == "⌘K" }, "the palette chord is documented")
        XCTAssertTrue(extras.contains { $0.glyph == "⌘/" }, "the cheat sheet documents its own chord")
    }

    /// DRIFT GUARD: every workspace command actually bound in `defaultBindings` must be documented (the
    /// per-slot bookmark bindings are covered by the collapsed representative rows).
    func testEveryBoundWorkspaceCommandIsDocumented() {
        let covered = KeyboardCheatSheet.workspaceCommands
        for command in CommandInterpreter.defaultBindings.values {
            switch command {
            case .saveBookmark,
                 .recallBookmark:
                continue // collapsed into the "⌘1–9 / ⇧⌘1–9" rows
            default:
                XCTAssertTrue(
                    covered.contains(command),
                    "the ⌘/ cheat sheet is missing a row for \(command)",
                )
            }
        }
    }

    #endif
}
