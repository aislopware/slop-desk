// PaletteRowPlatformTests — pins the one fact a palette row carries about itself: which half lists
// it.
//
// The defect under test is not a wrong answer, it is a SILENT one. Every actuator on the palette's
// coordinator defaults to an empty closure and a `.store` run arm may be a macOS-only `#if` with
// nothing in the else, so a row that is listed and inert is indistinguishable — at the keystroke —
// from a row that ran and had nothing to do. Three of the phone's rows were exactly that, and none
// of the palette's existing suites could see it, because every one of them runs on a Mac where all
// three are real.
//
// So the assertions here are about the OTHER half, which is why the table takes `mac` as an argument
// rather than reading the compiled slice: a Mac can ask what the phone lists, and that is the only
// place the answer is interesting.

import XCTest
@testable import SlopDeskClientCore

final class PaletteRowPlatformTests: XCTestCase {
    /// Every id the catalog serves is one the table declares — the near half of the pin the
    /// supervisor keeps in both directions. A row the table has never heard of is LISTED (a typo must
    /// not delete a verb in silence), so this is what would notice the typo.
    func testEveryServedRowIsDeclared() {
        let declared = Set(PaletteRowPlatform.declaredIDs)
        XCTAssertFalse(declared.isEmpty, "the table crossed empty")
        for row in ActionsPaletteSource.catalog {
            XCTAssertTrue(declared.contains(row.id), "\(row.id) is served by nobody's declaration")
        }
    }

    /// The three window verbs the phone cannot run are the three the phone is not offered.
    func testThePhoneIsNotOfferedTheWindowVerbsItCannotRun() {
        for verb in ["action.detachPane", "action.reattachAllPanes", "action.pinWindow"] {
            XCTAssertTrue(PaletteRowPlatform.lists(verb, mac: true), "\(verb) left the Mac's palette")
            XCTAssertFalse(PaletteRowPlatform.lists(verb, mac: false), "\(verb) is listed and inert")
        }
    }

    /// …and NOTHING else is withheld. A phone is not a reduced product: docs/56 §3 says layout
    /// diverges and capability does not, so a verb hidden for any reason other than a missing backing
    /// API is this test failing, whichever direction it drifts.
    func testNoOtherVerbIsWithheldFromEitherHalf() {
        let windowVerbs: Set = [
            "action.detachPane", "action.reattachAllPanes", "action.pinWindow",
        ]
        for id in PaletteRowPlatform.declaredIDs where !windowVerbs.contains(id) {
            XCTAssertTrue(PaletteRowPlatform.lists(id, mac: true), "\(id) left the Mac")
            XCTAssertTrue(PaletteRowPlatform.lists(id, mac: false), "\(id) left the phone")
        }
    }

    /// The compiled slice agrees with the table asked about that slice — the one place the `#if` in
    /// `PaletteRowPlatform` could be wired backwards without any other test noticing.
    func testTheCompiledSliceAsksTheTableAboutItself() {
        #if os(macOS)
        let mine = true
        #else
        let mine = false
        #endif
        for id in PaletteRowPlatform.declaredIDs {
            XCTAssertEqual(
                PaletteRowPlatform.lists(id), PaletteRowPlatform.lists(id, mac: mine),
                "\(id): this build asked the table about the other half",
            )
        }
    }

    /// The catalog this build serves is the declared table minus what this half withholds — the
    /// filter is real, and it is the only thing between the two.
    func testTheServedCatalogIsTheDeclaredTableMinusTheWithheld() {
        let served = Set(ActionsPaletteSource.catalog.map(\.id))
        let expected = Set(PaletteRowPlatform.declaredIDs.filter { PaletteRowPlatform.lists($0) })
        XCTAssertEqual(served, expected)
    }
}
