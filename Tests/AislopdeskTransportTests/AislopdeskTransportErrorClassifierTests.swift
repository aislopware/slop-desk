import Foundation
import XCTest
@testable import AislopdeskTransport

/// R15 #6 regression: the EADDRINUSE classifier the host-app uses to say "Port N is already in use"
/// must NOT misfire on unrelated errors whose text merely embeds the digits "48" (a port like 4843,
/// a different errno like 148, a buffer size like 1048576). The errno is matched only as a
/// digit-bounded standalone token, plus the canonical "in use" phrase.
final class AislopdeskTransportErrorClassifierTests: XCTestCase {
    func testCanonicalAddressInUsePhraseMatches() {
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("Address already in use"))
        XCTAssertTrue(AislopdeskTransportError
            .listenerDetailIndicatesAddressInUse("POSIXErrorCode: Address already in use"))
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("address already IN USE"))
    }

    func testNumericErrnoRenderingMatchesAsStandaloneToken() {
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("posix(48)"))
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("NWError errno 48"))
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("48"))
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("error 48: bind"))
    }

    func testEmbedded48DoesNotMisclassify() {
        // None of these are EADDRINUSE — "48" is part of a longer number, not a standalone errno.
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("could not bind port 4843"))
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("posix errno 148: network down"))
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("buffer size 1048576 exceeded"))
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("port 8048 refused"))
    }

    func testUnrelatedErrorsDoNotMatch() {
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("Network is down"))
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("Connection refused"))
        XCTAssertFalse(AislopdeskTransportError.listenerDetailIndicatesAddressInUse(""))
    }

    func testStandaloneTokenHelperBoundaries() {
        XCTAssertTrue(AislopdeskTransportError.containsStandaloneNumber("x 48 y", 48))
        XCTAssertTrue(AislopdeskTransportError.containsStandaloneNumber("48", 48))
        XCTAssertTrue(AislopdeskTransportError.containsStandaloneNumber("(48)", 48))
        XCTAssertFalse(AislopdeskTransportError.containsStandaloneNumber("4843", 48))
        XCTAssertFalse(AislopdeskTransportError.containsStandaloneNumber("148", 48))
        XCTAssertFalse(AislopdeskTransportError.containsStandaloneNumber("1048576", 48))
        // Multiple occurrences: a standalone one later in the string still matches.
        XCTAssertTrue(AislopdeskTransportError.containsStandaloneNumber("4843 then 48", 48))
    }
}

/// The host listener treats a stuck `.waiting(.posix(.EADDRINUSE))` (some OS versions surface a port
/// collision this way instead of `.failed`, and it never auto-recovers) as a FATAL bind conflict —
/// surfacing it immediately rather than burning the full readiness timeout. The critical SAFETY
/// property is the inverse: every OTHER waiting errno (the genuinely transient no-network ones the
/// framework auto-recovers from) must NOT be treated as fatal, or a host that started a half-second
/// before its network came up would false-fail. This pins the pure decision (`HostTransport` wires its
/// `.waiting` handler to it) without standing up a real `NWListener`.
final class WaitingBindConflictClassifierTests: XCTestCase {
    func testEADDRINUSEIsFatalInWaiting() {
        XCTAssertTrue(
            AislopdeskTransportError.waitingErrnoIsFatalBindConflict(EADDRINUSE),
            "a stuck .waiting on EADDRINUSE never auto-recovers → surface it immediately",
        )
        XCTAssertTrue(
            AislopdeskTransportError.waitingErrnoIsFatalBindConflict(48),
            "EADDRINUSE is errno 48",
        )
    }

    func testTransientNetworkErrnosKeepWaiting() {
        // SAFETY-CRITICAL: these are the retryable no-network conditions the framework auto-recovers
        // from. Misclassifying ANY of them as fatal would false-fail a host that merely started before
        // its network path was up. None may be treated as a fatal bind conflict.
        for errno in [ENETDOWN, ENETUNREACH, ETIMEDOUT, EAGAIN, ECONNREFUSED, EHOSTUNREACH, ENOTCONN] {
            XCTAssertFalse(
                AislopdeskTransportError.waitingErrnoIsFatalBindConflict(errno),
                "transient waiting errno \(errno) must keep waiting, not fail",
            )
        }
        XCTAssertFalse(
            AislopdeskTransportError.waitingErrnoIsFatalBindConflict(0),
            "errno 0 (no error) is not a bind conflict",
        )
    }

    /// The detail string a fatal-in-waiting EADDRINUSE produces (`String(describing:)` of the NWError)
    /// must classify as address-in-use downstream, so `HostController.describe` says "Port N is already
    /// in use" rather than a generic message. (Guards the wiring contract between the two helpers.)
    func testFatalWaitingDetailClassifiesAsAddressInUse() {
        XCTAssertTrue(AislopdeskTransportError.listenerDetailIndicatesAddressInUse("Address already in use"))
        XCTAssertTrue(AislopdeskTransportError
            .listenerDetailIndicatesAddressInUse("POSIXErrorCode(rawValue: 48): Address already in use"))
    }
}
