import XCTest
@testable import SlopDeskHost

/// Audit #17 — the host-side TERM/terminfo bootstrap (the ssh / kitty model).
///
/// **The decision itself moved.** The search order, the two on-disk layouts, the `infocmp` authority
/// and the whole fallback table are `rust/slopdesk-probe`'s `terminfo` module, tested there against
/// the same conventions (`docs/DECISIONS.md`, stage 25). What is pinned HERE is the half that is
/// about hostd: the two paths that reach an answer without a probe having said anything.
///
/// Neither case spawns: one returns before the fork by construction, and the other is aimed at a
/// binary that does not exist, so `Process.run()` throws and the degradation runs. The hang-safety
/// rule is intact — nothing here waits on a child.
final class TerminfoResolverTests: XCTestCase {
    override func tearDown() {
        unsetenv(HostProbe.binaryEnvKey)
        super.tearDown()
    }

    /// A request that IS the fallback is authoritative and must not consult the probe at all: there
    /// is nothing to fall back FROM, and it is not an auto-fallback, so nothing should be logged.
    ///
    /// Proven by aiming the probe at a path that cannot answer — if this consulted it, the answer
    /// would come back flagged as a fallback.
    func testAnExplicitXterm256NeverConsultsTheProbe() {
        setenv(HostProbe.binaryEnvKey, "/nonexistent/slopdesk-probe", 1)
        for explicit in [true, false] {
            let result = TerminfoResolver.resolve(requested: .xterm256, explicitOverride: explicit)
            XCTAssertEqual(result.term, .xterm256)
            XCTAssertFalse(
                result.fellBack,
                "a request that is already the fallback is a choice, not an auto-fallback",
            )
        }
    }

    /// A host that cannot BE asked advertises the fallback and reports it as one.
    ///
    /// Both halves matter. Advertising `xterm-ghostty` unchecked is what breaks every TUI app on a
    /// host without the entry; reporting `fellBack: false` would hide that from the one diagnostic
    /// the operator gets.
    func testAMissingProbeFallsBackAndSaysSo() {
        setenv(HostProbe.binaryEnvKey, "/nonexistent/slopdesk-probe", 1)
        let result = TerminfoResolver.resolve(requested: .ghostty, explicitOverride: false)
        XCTAssertEqual(result.term, .xterm256)
        XCTAssertTrue(result.fellBack, "an unverifiable entry is a fallback, and the log needs to say so")
    }

    /// The fallback hostd hands the probe is the entry that is present on effectively every Unix
    /// host. The probe resolves two names it is given and knows neither of them.
    func testTheFallbackIsTheUniversallyPresentEntry() {
        XCTAssertEqual(TerminfoResolver.fallback, .xterm256)
        XCTAssertEqual(TerminfoResolver.fallback.rawValue, "xterm-256color")
    }
}
