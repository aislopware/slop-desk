import Foundation
import XCTest
@testable import AislopdeskHost

/// Audit #17 — host-side TERM/terminfo bootstrap (ssh / kitty model).
///
/// aislopdesk advertises `TERM=xterm-ghostty` so the libghostty client gets the kitty keyboard
/// protocol + DEC 2026. On a fresh remote host WITHOUT the ghostty terminfo entry, every
/// curses / TUI app degrades. ``TerminfoResolver`` auto-falls back to the universally-present
/// `xterm-256color` (#54700) unless the operator explicitly asked for it.
///
/// These tests pin the PURE decision (no I/O) and the resolution path with an INJECTED probe,
/// so they run headlessly + deterministically (they never depend on whether THIS machine
/// happens to have the ghostty terminfo installed).
final class TerminfoResolverTests: XCTestCase {
    // MARK: Pure decision — the three required cases

    func testResolvableGhosttyKeepsGhostty() {
        // ghostty requested + host CAN resolve it → keep ghostty (best features), no fallback.
        let result = TerminfoResolver.effectiveTerm(
            requested: .ghostty,
            explicitOverride: false,
            isGhosttyResolvable: true,
        )
        XCTAssertEqual(result.term, .ghostty)
        XCTAssertFalse(result.fellBack)
    }

    func testUnresolvableGhosttyFallsBackTo256Color() {
        // ghostty requested + host CANNOT resolve it → auto-fall back to xterm-256color (#54700).
        let result = TerminfoResolver.effectiveTerm(
            requested: .ghostty,
            explicitOverride: false,
            isGhosttyResolvable: false,
        )
        XCTAssertEqual(result.term, .xterm256)
        XCTAssertTrue(result.fellBack)
    }

    func testExplicitOverrideAlwaysWins() {
        // An explicit `--xterm256` request wins regardless of probing: even if the host could
        // resolve ghostty, the operator's deliberate choice is honoured and it is NOT a fallback.
        let resolvable = TerminfoResolver.effectiveTerm(
            requested: .xterm256,
            explicitOverride: true,
            isGhosttyResolvable: true,
        )
        XCTAssertEqual(resolvable.term, .xterm256)
        XCTAssertFalse(resolvable.fellBack, "an explicit choice is not an auto-fallback")

        let unresolvable = TerminfoResolver.effectiveTerm(
            requested: .xterm256,
            explicitOverride: true,
            isGhosttyResolvable: false,
        )
        XCTAssertEqual(unresolvable.term, .xterm256)
        XCTAssertFalse(unresolvable.fellBack)
    }

    // MARK: Pure decision — edge: a non-explicit .xterm256 still never "falls back"

    func testNonExplicitXterm256IsNotAFallback() {
        // xterm-256color is already universally resolvable, so a .xterm256 request never
        // triggers a fallback even when `explicitOverride` is false.
        let result = TerminfoResolver.effectiveTerm(
            requested: .xterm256,
            explicitOverride: false,
            isGhosttyResolvable: false,
        )
        XCTAssertEqual(result.term, .xterm256)
        XCTAssertFalse(result.fellBack)
    }

    // MARK: resolve() — wires the injectable probe to the decision

    func testResolveUsesProbeWhenGhosttyRequested() {
        // A ghostty request consults the probe.
        let resolvableProbe = GhosttyTerminfoProbe { true }
        let kept = TerminfoResolver.resolve(
            requested: .ghostty, explicitOverride: false, probe: resolvableProbe,
        )
        XCTAssertEqual(kept.term, .ghostty)
        XCTAssertFalse(kept.fellBack)

        let unresolvableProbe = GhosttyTerminfoProbe { false }
        let fell = TerminfoResolver.resolve(
            requested: .ghostty, explicitOverride: false, probe: unresolvableProbe,
        )
        XCTAssertEqual(fell.term, .xterm256)
        XCTAssertTrue(fell.fellBack)
    }

    func testResolveSkipsProbeForExplicitXterm256() {
        // An explicit .xterm256 must NOT even consult the probe (no infocmp spawn / stat for
        // a result we'd discard). We prove it by injecting a probe that fails the test if run.
        let probe = GhosttyTerminfoProbe {
            XCTFail("probe must not run for an explicit xterm-256color request")
            return true
        }
        let result = TerminfoResolver.resolve(
            requested: .xterm256, explicitOverride: true, probe: probe,
        )
        XCTAssertEqual(result.term, .xterm256)
        XCTAssertFalse(result.fellBack)
    }

    // MARK: Probe internals — terminfo directory search (injected fileExists, no real FS)

    func testProbeFindsGhosttyUnderXSubdirectory() {
        // The conventional `x/xterm-ghostty` layout under a system dir resolves.
        let env = ["HOME": "/Users/dev"]
        let target = "/usr/share/terminfo/x/xterm-ghostty"
        let exists = GhosttyTerminfoProbe.terminfoEntryExists(
            term: "xterm-ghostty",
            environment: env,
            fileExists: { $0 == target },
        )
        XCTAssertTrue(exists)
    }

    func testProbeFindsGhosttyUnderHexSubdirectory() {
        // Some `tic` builds store the entry under `<hex-of-first-char>/<name>` (78 == 'x').
        let env = ["HOME": "/Users/dev"]
        let target = "/Users/dev/.terminfo/78/xterm-ghostty"
        let exists = GhosttyTerminfoProbe.terminfoEntryExists(
            term: "xterm-ghostty",
            environment: env,
            fileExists: { $0 == target },
        )
        XCTAssertTrue(exists)
    }

    func testProbeHonoursTERMINFOEnvOverride() {
        // $TERMINFO is searched first.
        let env: [String: String] = ["TERMINFO": "/custom/ti", "HOME": "/Users/dev"]
        let target = "/custom/ti/x/xterm-ghostty"
        let exists = GhosttyTerminfoProbe.terminfoEntryExists(
            term: "xterm-ghostty",
            environment: env,
            fileExists: { $0 == target },
        )
        XCTAssertTrue(exists)
    }

    func testProbeMissesWhenNoEntryAnywhere() {
        let env = ["HOME": "/Users/dev"]
        let exists = GhosttyTerminfoProbe.terminfoEntryExists(
            term: "xterm-ghostty",
            environment: env,
            fileExists: { _ in false },
        )
        XCTAssertFalse(exists)
    }

    func testSearchDirectoriesOrderAndContents() {
        // $TERMINFO, then ~/.terminfo, then $TERMINFO_DIRS (non-empty elements), then system.
        let env: [String: String] = [
            "TERMINFO": "/a",
            "HOME": "/Users/dev",
            "TERMINFO_DIRS": "/b::/c", // the empty middle element is skipped (compiled default)
        ]
        let dirs = GhosttyTerminfoProbe.searchDirectories(environment: env)
        XCTAssertEqual(dirs.first, "/a")
        XCTAssertTrue(dirs.contains("/Users/dev/.terminfo"))
        XCTAssertTrue(dirs.contains("/b"))
        XCTAssertTrue(dirs.contains("/c"))
        XCTAssertFalse(dirs.contains(""), "empty TERMINFO_DIRS element must be skipped")
        // System dirs are always appended.
        XCTAssertTrue(dirs.contains("/usr/share/terminfo"))
    }

    // MARK: Probe internals — infocmp fallback when the directory search misses

    func testLiveProbeFallsBackToInfocmpExitZero() {
        // Directory search misses, but `infocmp xterm-ghostty` exits 0 → resolvable.
        let resolvable = GhosttyTerminfoProbe.liveProbe(
            term: "xterm-ghostty",
            environment: ["HOME": "/Users/dev"],
            fileExists: { _ in false },
            infocmpExitStatus: { _ in 0 },
        )
        XCTAssertTrue(resolvable)
    }

    func testLiveProbeInfocmpNonZeroMeansUnresolvable() {
        let unresolvable = GhosttyTerminfoProbe.liveProbe(
            term: "xterm-ghostty",
            environment: ["HOME": "/Users/dev"],
            fileExists: { _ in false },
            infocmpExitStatus: { _ in 1 },
        )
        XCTAssertFalse(unresolvable)
    }

    func testLiveProbeInfocmpUnavailableIsUnresolvable() {
        // infocmp couldn't even be launched (nil) AND no dir entry → treat as unresolvable
        // (caller then safely falls back to xterm-256color).
        let result = GhosttyTerminfoProbe.liveProbe(
            term: "xterm-ghostty",
            environment: ["HOME": "/Users/dev"],
            fileExists: { _ in false },
            infocmpExitStatus: { _ in nil },
        )
        XCTAssertFalse(result)
    }

    func testLiveProbeDirectoryHitShortCircuitsInfocmp() {
        // When the directory search hits, infocmp must NOT run (cheapest-first ordering).
        let result = GhosttyTerminfoProbe.liveProbe(
            term: "xterm-ghostty",
            environment: ["HOME": "/Users/dev"],
            fileExists: { _ in true },
            infocmpExitStatus: { _ in
                XCTFail("infocmp must not run when the directory search already hit")
                return 1
            },
        )
        XCTAssertTrue(result)
    }
}
