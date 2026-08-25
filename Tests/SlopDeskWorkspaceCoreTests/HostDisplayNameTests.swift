// HostDisplayNameTests — pins the CROSSING, not the rule. Which strings are addresses and where a
// name ends is `slopdesk_workspace::host_name`'s, and its table of platform-MEASURED answers is the
// pin for that; restating any of it here would be the same rule in two languages. What only Swift can
// get wrong is the marshalling: the arena in, the answer out, and the empty answer that is a real
// answer rather than a missing one.

import XCTest
@testable import SlopDeskWorkspaceCore

final class HostDisplayNameTests: XCTestCase {
    func testTheDoorCarriesBothVerdictsAndBothShapesOfLabel() {
        XCTAssertTrue(HostDisplayName.isIPLiteral("192.168.1.7"))
        XCTAssertFalse(HostDisplayName.isIPLiteral("mac-studio.local"))
        XCTAssertEqual(HostDisplayName.shortLabel("mac-studio.local"), "mac-studio")
        // An IP's dots separate octets, not labels — never truncate "192.168.1.7" to "192".
        XCTAssertEqual(HostDisplayName.shortLabel("192.168.1.7"), "192.168.1.7")
    }

    /// The door spells an empty label `0`, which is also how it spells "no answer" — so the face must
    /// hand back `""` here and not crash on the `nil` the shared reader produces.
    func testAnEmptyNameCrossesBackAsAnEmptyLabel() {
        XCTAssertEqual(HostDisplayName.shortLabel(""), "")
        XCTAssertFalse(HostDisplayName.isIPLiteral(""))
    }
}
