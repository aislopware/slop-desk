// BindingRowPlatformTests — pins the one fact a keybinding carries about itself: which half lists it.
//
// The palette's table closed three rows that were listed and inert. The registry those rows mirror
// kept listing the same three, in a different id space, across four more surfaces — and one of them
// is the chord table, where a listed row does not merely lie: it takes ⌥⌘P away from the terminal to
// run a macOS-only `#if` with nothing in its else.
//
// The assertions here are about the OTHER half, which is why the table takes `mac` as an argument
// rather than reading the compiled slice: a Mac can ask what the phone binds, and that is the only
// place the answer is interesting.

import XCTest
@testable import SlopDeskWorkspaceCore

final class BindingRowPlatformTests: XCTestCase {
    /// The nine generated `pane.select.N` slots. Undeclared on purpose — they are `Both`, they are
    /// minted by a loop rather than written out, and the table declares the ONE collapsed
    /// representative (`pane.selectN`) the cheat sheet actually shows in their place.
    private func isGeneratedSelectSlot(_ id: String) -> Bool { id.hasPrefix("pane.select.") }

    /// Every id the registry serves is one the table declares, and the other way round once the
    /// generated slots and their collapsed representative are set against each other. Either
    /// direction drifting is what would put a row back that no rule has heard of.
    func testTheServedRegistryAndTheDeclaredTableNameTheSameRows() {
        let declared = Set(BindingRowPlatform.declaredIDs.filter { BindingRowPlatform.lists($0) })
        XCTAssertFalse(declared.isEmpty, "the table crossed empty")
        var served = Set(WorkspaceBindingRegistry.allBindings.map(\.id).filter { !isGeneratedSelectSlot($0) })
        // `groupedForDisplay` appends the representative rather than storing it in the table, so it is
        // served by the cheat sheet without being in `allBindings`.
        served.insert(WorkspaceBindingRegistry.selectPaneRepresentative.id)
        XCTAssertEqual(served, declared)
    }

    /// The bindings whose BACKING is AppKit's, in this table's spelling — a second `NSWindow`, a
    /// window level, a window close and the process-global secure-input call. Nothing else may join
    /// this set: see the test below.
    private static let appKitBacked: Set = [
        "pane.detach", "pane.reattachAll", "view.pinWindow",
        "window.close", "view.secureKeyboardEntry",
    ]

    /// The verbs the phone cannot run are the ones the phone is not offered.
    func testThePhoneIsNotOfferedTheWindowBindingsItCannotRun() {
        for id in Self.appKitBacked {
            XCTAssertTrue(BindingRowPlatform.lists(id, mac: true), "\(id) left the Mac's registry")
            XCTAssertFalse(BindingRowPlatform.lists(id, mac: false), "\(id) is listed and inert")
        }
    }

    /// …and NOTHING else is withheld. docs/56 §3: layout diverges, capability does not. A binding
    /// hidden for any reason other than a missing backing API is this test failing.
    func testNoOtherBindingIsWithheldFromEitherHalf() {
        for id in BindingRowPlatform.declaredIDs where !Self.appKitBacked.contains(id) {
            XCTAssertTrue(BindingRowPlatform.lists(id, mac: true), "\(id) left the Mac")
            XCTAssertTrue(BindingRowPlatform.lists(id, mac: false), "\(id) left the phone")
        }
    }

    /// The compiled slice agrees with the table asked about that slice — the one place the `#if` in
    /// `BindingRowPlatform` could be wired backwards without any other test noticing.
    func testTheCompiledSliceAsksTheTableAboutItself() {
        #if os(macOS)
        let mine = true
        #else
        let mine = false
        #endif
        for id in BindingRowPlatform.declaredIDs {
            XCTAssertEqual(
                BindingRowPlatform.lists(id), BindingRowPlatform.lists(id, mac: mine),
                "\(id): this build asked the table about the other half",
            )
        }
    }

    /// Dropping a row drops its CHORD — the reason the filter is on the registry rather than on each
    /// display surface. A bound chord never reaches the PTY, so a half that keeps ⌥⌘P without being
    /// able to detach has swallowed the key to do nothing at all.
    func testAWithheldRowDoesNotHoldItsChordAgainstTheTerminal() throws {
        let detach = WorkspaceBindingRegistry.allBindings.first { $0.id == "pane.detach" }
        #if os(macOS)
        let chord = try XCTUnwrap(detach?.chord, "the Mac lost the detach chord")
        XCTAssertEqual(WorkspaceBindingRegistry.chordTable[chord], .detachPane)
        #else
        XCTAssertNil(detach, "the phone still carries a row it cannot run")
        XCTAssertFalse(
            WorkspaceBindingRegistry.chordTable.values.contains(.detachPane),
            "the phone still binds a chord to an action it cannot perform",
        )
        #endif
    }
}

// The two id spaces spell ONE feature two ways (`pane.detach` here, `action.detachPane` in the
// palette's catalog) and must withhold it identically. That cross-table pin is in Rust
// (`binding_rows::tests::the_two_tables_withhold_the_same_feature`), which is the only place both
// tables are in scope at once — the palette's near side lives in `SlopDeskClientCore`, a module this
// suite cannot see.
