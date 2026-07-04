// SlateMonogramTests — pins the pure identity → presentation maths behind the host monogram plate
// (MERIDIAN C2). The whole point of the plate is that a host's colour is DERIVED, never stored: the same
// identity must resolve to the same initials + hue on every client, forever — so the mapping is frozen
// here (a change would silently recolour every user's hosts).

import XCTest
@testable import AislopdeskClientUI

final class SlateMonogramTests: XCTestCase {
    // MARK: - Initials

    func testInitialsTakeFirstLettersOfFirstTwoComponents() {
        XCTAssertEqual(MonogramIdentity.initials(of: "mac-studio"), "MS")
        XCTAssertEqual(MonogramIdentity.initials(of: "herdr.local"), "HL")
        XCTAssertEqual(MonogramIdentity.initials(of: "macbook pro"), "MP")
    }

    func testInitialsOfSingleComponentTakeFirstTwoCharacters() {
        XCTAssertEqual(MonogramIdentity.initials(of: "macstudio"), "MA")
        XCTAssertEqual(MonogramIdentity.initials(of: "m"), "M")
    }

    func testInitialsOfNumericHostUseDigits() {
        // An IP identity still gets a stable two-glyph plate (digits are legitimate initials).
        XCTAssertEqual(MonogramIdentity.initials(of: "192.168.1.7"), "11")
    }

    func testInitialsFallBackForEmptyOrSeparatorOnlyIdentity() {
        XCTAssertEqual(MonogramIdentity.initials(of: ""), "?")
        XCTAssertEqual(MonogramIdentity.initials(of: "--..--"), "?")
    }

    // MARK: - Hue

    func testHueMatchesFNV1aKnownAnswerVector() {
        // FNV-1a 64("a") is the published constant 0xAF63DC4C8601EC8C — the hue is that hash mod 360.
        // Pinned against the STANDARD vector (not this function's own output), so the hash can never
        // silently drift to a different algorithm without recolouring being caught here.
        let fnv1aOfA: UInt64 = 0xAF63_DC4C_8601_EC8C
        XCTAssertEqual(MonogramIdentity.hue(of: "a"), Double(fnv1aOfA % 360))
    }

    func testHueIsDeterministicAndInRange() {
        for identity in ["mac-studio", "macbook-pro", "herdr", "192.168.1.7", ""] {
            let hue = MonogramIdentity.hue(of: identity)
            XCTAssertEqual(hue, MonogramIdentity.hue(of: identity), "hue must be pure for \(identity)")
            XCTAssertGreaterThanOrEqual(hue, 0)
            XCTAssertLessThan(hue, 360)
            XCTAssertEqual(hue, hue.rounded(), "hue is a whole degree (hash mod 360)")
        }
    }

    func testDistinctIdentitiesGetDistinctHues() {
        // The two real fleet hosts must not collide (spot-check, not a collision-freedom claim).
        XCTAssertNotEqual(MonogramIdentity.hue(of: "mac-studio"), MonogramIdentity.hue(of: "macbook-pro"))
    }
}
