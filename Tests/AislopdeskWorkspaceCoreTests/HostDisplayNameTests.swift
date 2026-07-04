// HostDisplayNameTests — pins the pure parts of the host-identity resolution (the titlebar speaks
// hostnames, never IPs): the IP-literal detector and the first-DNS-label shortener. The reverse-DNS
// lookup itself is network-dependent and stays untested (its failure mode is the raw-host fallback).

import XCTest
@testable import AislopdeskWorkspaceCore

final class HostDisplayNameTests: XCTestCase {
    func testIPLiteralDetection() {
        XCTAssertTrue(HostDisplayName.isIPLiteral("192.168.1.7"))
        XCTAssertTrue(HostDisplayName.isIPLiteral("100.94.23.11"))
        XCTAssertTrue(HostDisplayName.isIPLiteral("fe80::1"))
        XCTAssertFalse(HostDisplayName.isIPLiteral("mac-studio"))
        XCTAssertFalse(HostDisplayName.isIPLiteral("mac-studio.local"))
        // A dotted name whose labels aren't all numeric is a NAME, not a literal.
        XCTAssertFalse(HostDisplayName.isIPLiteral("192.168.host"))
        XCTAssertFalse(HostDisplayName.isIPLiteral(""))
    }

    func testShortLabelTakesFirstDNSLabel() {
        XCTAssertEqual(HostDisplayName.shortLabel("mac-studio.local"), "mac-studio")
        XCTAssertEqual(HostDisplayName.shortLabel("herdr.example.com"), "herdr")
        XCTAssertEqual(HostDisplayName.shortLabel("macstudio"), "macstudio")
    }

    func testShortLabelPassesIPLiteralsThrough() {
        // An IP's dots separate octets, not labels — never truncate "192.168.1.7" to "192".
        XCTAssertEqual(HostDisplayName.shortLabel("192.168.1.7"), "192.168.1.7")
        XCTAssertEqual(HostDisplayName.shortLabel("fe80::1"), "fe80::1")
    }
}
