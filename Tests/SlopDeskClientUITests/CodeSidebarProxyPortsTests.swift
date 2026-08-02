#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

/// ``CodeSidebarProxyPorts`` — the loopback proxy's pure port derivation. Only this part of the
/// proxy is unit-tested; the listener/relay are real network objects (never constructed in tests).
final class CodeSidebarProxyPortsTests: XCTestCase {
    func testCandidateIsStableAcrossCalls() {
        // The whole point: the SAME project root maps to the SAME local port in every process, so
        // the workbench origin (and its localStorage) survives app relaunches. Swift's `Hasher` is
        // process-seeded and would break this — the derivation is hand-rolled FNV-1a.
        XCTAssertEqual(
            CodeSidebarProxyPorts.candidate(for: "/Users/x/proj", attempt: 0),
            CodeSidebarProxyPorts.candidate(for: "/Users/x/proj", attempt: 0),
        )
    }

    func testCandidatesStayInTheDynamicRange() {
        for root in ["/", "/a", "/Users/x/some/deep/project", String(repeating: "p", count: 300)] {
            for attempt in 0..<8 {
                let port = CodeSidebarProxyPorts.candidate(for: root, attempt: attempt)
                XCTAssertGreaterThanOrEqual(port, CodeSidebarProxyPorts.rangeBase)
                XCTAssertLessThan(
                    UInt64(port), UInt64(CodeSidebarProxyPorts.rangeBase) + CodeSidebarProxyPorts.rangeSize,
                )
            }
        }
    }

    func testAttemptsStrideToDistinctPorts() {
        // The bind-collision fallback must actually move: every attempt for one root is distinct.
        let ports = Set((0..<8).map { CodeSidebarProxyPorts.candidate(for: "/p", attempt: $0) })
        XCTAssertEqual(ports.count, 8)
    }

    func testDistinctRootsDiverge() {
        // Not a guarantee (16000 slots), but these two colliding would mean a degenerate hash.
        XCTAssertNotEqual(
            CodeSidebarProxyPorts.candidate(for: "/Users/x/alpha", attempt: 0),
            CodeSidebarProxyPorts.candidate(for: "/Users/x/beta", attempt: 0),
        )
    }
}
#endif
