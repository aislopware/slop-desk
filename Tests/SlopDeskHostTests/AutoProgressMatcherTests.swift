import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The host-side auto-progress feature: the PURE ``AutoProgressMatcher`` ("Auto
/// Progress-Bar Commands") + its wiring into the ``CommandBlockSegmenter`` C / D marks, which
/// synthesizes an INDETERMINATE OSC-9;4 spinner for a configured slow command and clears it on exit.
///
/// Non-tautological by construction: every assertion pins the matcher / segmenter output against
/// HAND-WRITTEN literal expectations (a fixed `[String]` list, a literal `.progress(state:percent:)`
/// frame), never against a recomputation of the code's own output. Every case would FAIL on the
/// un-fixed tree (the un-fixed segmenter has no auto-progress capability at all).
final class AutoProgressMatcherTests: XCTestCase {
    // MARK: - Pure matcher

    func testGitPushMatchesButGitStatusDoesNot() {
        // Whitespace-delimited PREFIX match: `git push` is a leading-token prefix of `git push origin
        // main`, but `git status` shares only the first token → no match.
        XCTAssertTrue(AutoProgressMatcher.matches(
            commandLine: "git push origin main",
            prefixes: AutoProgressMatcher.builtInPrefixes,
        ))
        XCTAssertFalse(AutoProgressMatcher.matches(
            commandLine: "git status",
            prefixes: AutoProgressMatcher.builtInPrefixes,
        ))
    }

    func testSingleTokenCommandMatches() {
        XCTAssertTrue(AutoProgressMatcher.matches(
            commandLine: "curl https://example.com/big-file",
            prefixes: AutoProgressMatcher.builtInPrefixes,
        ))
        // A bare single-token command equal to a single-token prefix matches.
        XCTAssertTrue(AutoProgressMatcher.matches(commandLine: "curl", prefixes: ["curl"]))
    }

    func testEmptyPrefixListDisablesMatching() {
        // Clearing the field disables auto-progress entirely: an empty list never matches.
        XCTAssertFalse(AutoProgressMatcher.matches(commandLine: "curl https://x", prefixes: []))
    }

    func testLeadingAndRepeatedWhitespaceTrimmed() {
        // Leading / repeated whitespace is normalised by the tokenizer, so it never defeats the match.
        XCTAssertTrue(AutoProgressMatcher.matches(commandLine: "   git   push   origin", prefixes: ["git push"]))
    }

    func testPrefixMatchIsCaseSensitive() {
        // Prefixes are case-sensitive — `GIT PUSH` is a different command than `git push`.
        XCTAssertFalse(AutoProgressMatcher.matches(commandLine: "GIT PUSH origin", prefixes: ["git push"]))
    }

    func testTokenWiseMatchHasNoSubstringFalsePositive() {
        // Token-wise prefix (not raw substring): `curl` must NOT match `curlie`, and `git push` must NOT
        // match `git pushing` — a substring prefix would wrongly fire on both.
        XCTAssertFalse(AutoProgressMatcher.matches(commandLine: "curlie http://x", prefixes: ["curl"]))
        XCTAssertFalse(AutoProgressMatcher.matches(commandLine: "git pushing", prefixes: ["git push"]))
    }

    func testParsePrefixesUnsetReturnsBuiltInList() {
        // env UNSET (nil) ⇒ the default built-in list.
        XCTAssertEqual(AutoProgressMatcher.parsePrefixes(envValue: nil), AutoProgressMatcher.builtInPrefixes)
    }

    func testParsePrefixesEmptyStringDisables() {
        // env SET-but-EMPTY ⇒ [] (disabled) — distinct from UNSET.
        XCTAssertEqual(AutoProgressMatcher.parsePrefixes(envValue: ""), [])
    }

    func testParsePrefixesSplitsTrimsAndDropsBlankLines() {
        // Newline separates entries (an entry may be a multi-word prefix); each is trimmed, blanks dropped.
        XCTAssertEqual(
            AutoProgressMatcher.parsePrefixes(envValue: "git push\n  curl  \n\n\trsync\n"),
            ["git push", "curl", "rsync"],
        )
    }

    // MARK: - HostEnvironment resolution (the ONE shared site — set identically host + client)

    func testHostEnvironmentResolvesPrefixesFromTheEnvBridge() {
        let key = HostEnvironment.autoProgressCommandsEnvKey
        // UNSET ⇒ built-in; SET-EMPTY ⇒ disabled; SET ⇒ parsed entries.
        XCTAssertEqual(HostEnvironment.autoProgressPrefixes(environment: [:]), AutoProgressMatcher.builtInPrefixes)
        XCTAssertEqual(HostEnvironment.autoProgressPrefixes(environment: [key: ""]), [])
        XCTAssertEqual(
            HostEnvironment.autoProgressPrefixes(environment: [key: "git push\ncurl"]),
            ["git push", "curl"],
        )
    }

    // MARK: - Segmenter wiring (C → spinner, D → clear; real 9;4 suppresses the synthetic)

    private let esc = "\u{1B}"
    private let bel = "\u{07}"
    private func b() -> String { "\(esc)]133;B\(bel)" }
    private func c() -> String { "\(esc)]133;C\(bel)" }
    private func d(_ exit: Int = 0) -> String { "\(esc)]133;D;\(exit)\(bel)" }
    /// A program-emitted OSC 9 sequence (e.g. `progress9("4;3")` = `ESC]9;4;3 BEL`).
    private func progress9(_ body: String) -> String { "\(esc)]9;\(body)\(bel)" }
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testMatchedCommandEmitsSpinnerAtCAndClearAtD() {
        var seg = CommandBlockSegmenter(autoProgressPrefixes: ["git push"])
        _ = seg.ingest(bytes(b() + "git push origin main" + c() + "Enumerating objects\n" + d(0)))
        // The synthetic indeterminate spinner (state 3) at the C mark, then the clear (state 0) at D.
        XCTAssertEqual(seg.drainAutoProgress(), [
            .progress(state: 3, percent: 0),
            .progress(state: 0, percent: 0),
        ])
    }

    func testSpinnerEmittedAtCStrictlyBeforeClearAtD() {
        // Incremental: the spinner is queued the moment the C mark arrives (before the command finishes),
        // and the clear only when the D mark arrives — proving the C → spinner / D → clear ordering.
        var seg = CommandBlockSegmenter(autoProgressPrefixes: ["curl"])
        _ = seg.ingest(bytes(b() + "curl https://example.com" + c()))
        XCTAssertEqual(seg.drainAutoProgress(), [.progress(state: 3, percent: 0)], "spinner at C")
        _ = seg.ingest(bytes("partial output\n" + d(0)))
        XCTAssertEqual(seg.drainAutoProgress(), [.progress(state: 0, percent: 0)], "clear at D")
    }

    func testUnmatchedCommandEmitsNoSyntheticProgress() {
        var seg = CommandBlockSegmenter(autoProgressPrefixes: ["git push"])
        _ = seg.ingest(bytes(b() + "git status" + c() + "clean\n" + d(0)))
        XCTAssertEqual(seg.drainAutoProgress(), [], "a non-matching command must emit nothing")
    }

    func testEmptyPrefixListDisablesSyntheticProgress() {
        var seg = CommandBlockSegmenter(autoProgressPrefixes: [])
        _ = seg.ingest(bytes(b() + "curl https://example.com" + c() + "ok\n" + d(0)))
        XCTAssertEqual(seg.drainAutoProgress(), [], "an empty prefix list disables auto-progress entirely")
    }

    func testRealProgressBeforeCSuppressesTheSyntheticSpinner() {
        // A program-driven OSC 9;4 observed in the block BEFORE the C decision → the synthetic spinner is
        // fully suppressed (the program owns the indicator; the live sniffer carries its real progress).
        var seg = CommandBlockSegmenter(autoProgressPrefixes: ["curl"])
        _ = seg.ingest(bytes(b() + "curl https://x" + progress9("4;3") + c() + "ok\n" + d(0)))
        XCTAssertEqual(seg.drainAutoProgress(), [], "a real 9;4 in the block suppresses the synthetic spinner")
    }

    func testRealProgressAfterCSuppressesTheSyntheticClear() {
        // Realistic ordering: the spinner is emitted at C; the program THEN drives its own 9;4 in the
        // output, so the synthetic CLEAR at D is suppressed (no double-driving). With the synthetic clear
        // gone, the badge is cleared by the program's own 9;4;0 if it sends one — and FAILING THAT, by the
        // CLIENT on the OSC-133-D command-finish edge (`TerminalViewModel` resets `progress` on `.idle`,
        // and `WorkspaceStore.handleCommandCompleted` clears the per-pane mirror), so no stuck spinner remains.
        var seg = CommandBlockSegmenter(autoProgressPrefixes: ["curl"])
        _ = seg.ingest(bytes(b() + "curl https://x" + c() + "start" + progress9("4;1;50") + "done\n" + d(0)))
        XCTAssertEqual(
            seg.drainAutoProgress(),
            [.progress(state: 3, percent: 0)],
            "spinner at C, but the synthetic clear is suppressed once the program drives its own 9;4",
        )
    }
}
