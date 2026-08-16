#if os(macOS)
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The PURE `String → struct` parsing that is still HERE: `parseLsof`, plus the byte-budget predicate
/// behind the one subprocess `HostMetadataProbe` still spawns. They take NO syscall, so the hang-safety
/// rule does NOT apply — they are unit-tested directly (the surrounding I/O paths stay
/// compiled-and-reviewed only).
///
/// **The git parsing left this file with the code.** The porcelain header/line parsers, the status-nibble
/// packing, the Claude slug and the diff-base ladder now live in `rust/slopdesk-probe` and are tested
/// there, over the same conventions and with the same independent literals (`docs/DECISIONS.md`,
/// stage 24). Keeping a Swift copy of those assertions would be a cross-language mirror of a parser that
/// no longer exists on this side.
///
/// Each assertion is written to FAIL on a regressed parser (revert-to-confirm-fail on each guard) and none
/// is tautological: every expected value is an INDEPENDENT literal of the documented `lsof -F` convention,
/// never derived from the function under test.
///
/// `#if os(macOS)` — `HostMetadataProbe` is macOS-only (it spawns `lsof` and reads Darwin `proc_*`).
final class HostMetadataProbeParsingTests: XCTestCase {
    // MARK: - parseLsof (`-F cn` field output; port after the LAST colon; malformed → drop)

    /// A `c<cmd>` command line then several `n<addr>` lines: each well-formed address yields one port (the
    /// integer after the LAST `:`, so IPv6 `[::1]:443` resolves to 443), malformed lines are SKIPPED, and
    /// the current command name is carried onto every port.
    func testLsofParsesAddressesAndSkipsMalformed() {
        let output = """
        cnode
        n*:8080
        n127.0.0.1:80
        n[::1]:443
        nfoo
        n*:notaport
        """
        let ports = HostMetadataProbe.parseLsof(output, proto: .tcp)
        // Three well-formed addresses; the two malformed lines (`nfoo` no colon, `n*:notaport` non-numeric)
        // are dropped — count == 3 proves the validate-then-drop, not 5.
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(
            ports[0],
            MetadataCodec.PortInfo(port: 8080, proto: MetadataCodec.PortProtocol.tcp.rawValue, procName: "node"),
        )
        XCTAssertEqual(ports[1].port, 80)
        XCTAssertEqual(ports[2].port, 443, "the port is the integer after the LAST colon (IPv6-safe)")
        XCTAssertTrue(ports.allSatisfy { $0.procName == "node" }, "the active `c` command name carries onto every port")
    }

    /// The `proto` argument is carried onto each parsed `PortInfo` (here `.udp` → raw byte 1).
    func testLsofCarriesProtocol() {
        let ports = HostMetadataProbe.parseLsof("cnode\nn*:9000", proto: .udp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].proto, MetadataCodec.PortProtocol.udp.rawValue)
        XCTAssertEqual(ports[0].port, 9000)
    }

    /// A `n<addr>` with no preceding `c<cmd>` still yields a port, with an empty command name (no trap).
    func testLsofAddressWithoutCommandHasEmptyName() {
        let ports = HostMetadataProbe.parseLsof("n*:5000", proto: .tcp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 5000)
        XCTAssertEqual(ports[0].procName, "")
    }

    // MARK: - captureBudgetExceeded (the PURE byte-budget predicate behind the one remaining spawn)

    /// The drain loop's stop condition: exactly `cap` bytes is WITHIN budget (false), `cap + 1` EXCEEDS
    /// it (true), so a child that will not stop talking cannot grow this side without bound. The cap is
    /// the same 15 MiB the builder holds opaque payloads to — kept in step here so the two never drift,
    /// even though the only subprocess left on this side is an `lsof` that prints kilobytes. Pure: no
    /// `Process` spun (the hang-safety rule).
    func testCaptureBudgetBoundary() {
        let cap = MetadataResponseBuilder.defaultMaxOpaquePayloadBytes
        XCTAssertFalse(HostMetadataProbe.captureBudgetExceeded(0), "an empty capture is within budget")
        XCTAssertFalse(HostMetadataProbe.captureBudgetExceeded(cap), "exactly the cap is within budget (no trim)")
        XCTAssertTrue(
            HostMetadataProbe.captureBudgetExceeded(cap + 1),
            "cap + 1 exceeds the budget, so the drain stops rather than following a child that never ends",
        )
    }
}
#endif
