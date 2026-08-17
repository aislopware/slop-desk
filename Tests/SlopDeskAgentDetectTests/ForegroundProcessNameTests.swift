import XCTest
@testable import SlopDeskAgentDetect

/// ``ForegroundProcessName`` — the three doors over `rust/slopdesk-agent`'s `process` module.
///
/// What is pinned here is the MARSHALLING, not the rules: the crate's own suite owns which names are
/// wrappers and which paths are version-shaped, and duplicating that here would be a second
/// spelling of it. What can only fail on this side is the crossing — a name that comes back
/// truncated, an empty answer read as a refusal, or a byte count taken from the wrong buffer.
///
/// These cases arrived from `ForegroundProcessWatcherTests`, which drove a `ForegroundProcessDetector`
/// that nothing in the host had constructed since agent detection was fused into one machine per
/// pane. Its basename assertions were the only live thing in the file — they were reaching this door
/// through two forwarding faces — so they moved to the module that owns it and the reducer went.
final class ForegroundProcessNameTests: XCTestCase {
    func testABasenameIsTheLastPathComponentAndSurvivesTheCrossing() {
        XCTAssertEqual(ForegroundProcessName.basename(of: "/usr/local/bin/claude"), "claude")
        XCTAssertEqual(ForegroundProcessName.basename(of: "zsh"), "zsh", "a bare name is already its basename")
        XCTAssertEqual(
            ForegroundProcessName.basename(of: "claudefoo"),
            "claudefoo",
            "the basename is not trimmed to a prefix — the exact-match classifier depends on it",
        )
    }

    /// An empty answer is an ANSWER here, not a refusal. The §4 convention reads a zero return as
    /// "there is none", so a door whose real answer can be empty has to be read for what it means:
    /// an unresolved foreground process is the empty name, which clears presence.
    func testAnEmptyNameCrossesAsEmptyRatherThanUnchanged() {
        XCTAssertEqual(ForegroundProcessName.basename(of: ""), "")
        XCTAssertEqual(ForegroundProcessName.canonicalName(of: ""), "")
        XCTAssertFalse(ForegroundProcessName.isSensitive(processName: ""), "unresolved is not sensitive")
    }

    /// The Claude Code native installer names the executable FILE by its version, so the basename
    /// alone would read as `2.1.218` in the sidebar's shell-label slot and defeat the exact-basename
    /// `claude` match. One case each way, to pin that the two doors do not answer the same thing.
    func testAVersionNamedExecutableCanonicalisesToItsAppDirectory() {
        XCTAssertEqual(
            ForegroundProcessName.canonicalName(of: "/Users/a/.local/share/claude/versions/2.1.218"),
            "claude",
        )
        XCTAssertEqual(
            ForegroundProcessName.basename(of: "/Users/a/.local/share/claude/versions/2.1.218"),
            "2.1.218",
            "the raw basename is the version — which is why the canonical door exists",
        )
        XCTAssertEqual(ForegroundProcessName.canonicalName(of: "/usr/local/bin/claude"), "claude")
    }

    /// A long name is the case a fixed near-side buffer would silently cut. The door answers the
    /// byte count it needs, so the retry has to happen on this side or the tail goes missing.
    func testALongNameIsNotTruncatedByTheCrossing() {
        let long = String(repeating: "a", count: 4096)
        XCTAssertEqual(ForegroundProcessName.basename(of: "/opt/\(long)"), long)
        XCTAssertEqual(ForegroundProcessName.canonicalName(of: long), long)
    }
}
