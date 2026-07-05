import XCTest
@testable import SlopDeskWorkspaceCore

/// E14/K11: pins the PURE ``PermissionStatus/dot(forAuthorization:)`` decision the macOS/iOS System
/// Permission status row renders — green = allowed, amber = will-prompt / unknown, red = blocked. Headless:
/// no `UNUserNotificationCenter` is instantiated (it traps without a bundle), the raw `UNAuthorizationStatus`
/// values are fed as plain Ints. Revert-to-confirm-fail: a mapping that collapsed unknown → green (a false
/// "allowed") or denied → amber would fail the asserts below.
final class PermissionStatusTests: XCTestCase {
    /// Apple's `UNAuthorizationStatus` raw values: 0 notDetermined, 1 denied, 2 authorized, 3 provisional,
    /// 4 ephemeral. Authorised / provisional / ephemeral all DELIVER → green; denied → red.
    func testAuthorizationStatusMapsToTheRightDot() {
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 2), .green, "authorized = allowed")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 3), .green, "provisional delivers quietly")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 4), .green, "ephemeral delivers")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 1), .red, "denied = blocked")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 0), .amber, "notDetermined will prompt")
    }

    /// Any UNRECOGNISED future status value is amber (the conservative "not proven allowed" default), never a
    /// false green nor a trap. Negative + large sentinel values are covered.
    func testUnknownStatusIsAmberNotGreen() {
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: 99), .amber, "an unknown future status is amber")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: -1), .amber, "a negative status is amber")
        XCTAssertEqual(PermissionStatus.dot(forAuthorization: Int.max), .amber, "a huge status is amber")
        XCTAssertNotEqual(PermissionStatus.dot(forAuthorization: 99), .green, "unknown must not read as allowed")
    }
}
