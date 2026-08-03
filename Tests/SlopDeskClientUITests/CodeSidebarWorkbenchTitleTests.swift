// CodeSidebarWorkbenchTitleTests — the panel strip's active-file readout, pinned against the shape
// the seeded `window.title` actually produces. The two constants under test (the `${separator}`
// default and the `${dirty}` marker) were decoded from the shipped 4.112 workbench bundle; if a
// code-server bump changes either, these are the tests that say so.

import XCTest
@testable import SlopDeskClientUI

final class CodeSidebarWorkbenchTitleTests: XCTestCase {
    func testCleanEditorReadsTheFileName() {
        let editor = CodeSidebarWorkbenchTitle.activeEditor(in: "CodeSidebarProxy.swift \u{2014} slop-desk")
        XCTAssertEqual(editor, CodeSidebarActiveEditor(name: "CodeSidebarProxy.swift", dirty: false))
    }

    func testDirtyEditorIsRecognizedByTheMarker() {
        let editor = CodeSidebarWorkbenchTitle.activeEditor(in: "\u{25CF} main.swift \u{2014} slop-desk")
        XCTAssertEqual(editor, CodeSidebarActiveEditor(name: "main.swift", dirty: true))
    }

    func testNonMacSeparatorIsAccepted() {
        // The em dash is the macOS browser's separator; every other platform gets " - ". Accepting
        // both keeps one parser for a later iOS client reading the same title.
        let editor = CodeSidebarWorkbenchTitle.activeEditor(in: "notes.md - slop-desk")
        XCTAssertEqual(editor, CodeSidebarActiveEditor(name: "notes.md", dirty: false))
    }

    func testBareProjectNameMeansNoEditorIsOpen() {
        // VS Code drops empty variables and collapses the separators around them, so an
        // editor-less workbench titles itself with just the root name — the component count is the
        // test, not a guess about what the string looks like.
        XCTAssertNil(CodeSidebarWorkbenchTitle.activeEditor(in: "slop-desk"))
        XCTAssertNil(CodeSidebarWorkbenchTitle.activeEditor(in: ""))
    }

    func testNoTitleYetIsNotAnEditor() {
        // A freshly minted webview publishes a nil title before the page ever loads.
        XCTAssertNil(CodeSidebarWorkbenchTitle.activeEditor(in: nil))
    }

    func testDirtyMarkerWithNoFileNameIsNotAnEditor() {
        // Defensive: a marker with nothing behind it must not render a naked dot in the strip.
        XCTAssertNil(CodeSidebarWorkbenchTitle.activeEditor(in: "\u{25CF}  \u{2014} slop-desk"))
    }

    func testProjectNameCarryingASeparatorStillYieldsTheFile() {
        // The split takes the FIRST component, so a project named with a dash cannot bleed into
        // the file name.
        let editor = CodeSidebarWorkbenchTitle.activeEditor(in: "app.ts \u{2014} my - project")
        XCTAssertEqual(editor, CodeSidebarActiveEditor(name: "app.ts", dirty: false))
    }
}
