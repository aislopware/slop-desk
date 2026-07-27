import Foundation
import XCTest

/// The one thing every GUI gate must do when it execs `SlopDesk.app`'s binary directly.
///
/// `scripts/check-macos.sh` and `scripts/check-video.sh` both launch the bundle binary rather than
/// `open`ing it, because LaunchServices does not forward the shell environment and the whole
/// automation seam is `SLOPDESK_*` env vars. That launch has one non-obvious requirement:
/// `-ApplePersistenceIgnoreState YES`. Without it AppKit brings the app up on its persistence path
/// and the app runs with **zero windows** — no window means no scene, and every seam these gates
/// depend on is a scene `.task`: the auto-connect, the workspace-document channel, the video pane.
/// The process sits happily in its run loop with no UI, no TCP and no UDP, and both gates then
/// "prove" whatever the desktop happened to look like.
///
/// RED before the fix: `check-video.sh` omitted the flag, so the first hardware run of the video
/// gate after the docs/45 cutover produced no client window, no session on the terminal daemon that
/// owns the workspace document, no UDP flow, and an empty client log — while still printing DONE.
/// (HW-confirmed 2026-07-28: `YES` ⇒ window + session + frames; omitted or `NO` ⇒ 0 windows, every
/// time.) `check-macos.sh` carried the flag and a comment explaining it; nothing made that a rule.
///
/// A text-level contract over a shell script is unusual, and deliberate: these gates only ever run
/// on real hardware from an Aqua session, so a silent regression in one costs a whole GUI cycle to
/// notice. The same discipline as `HostOutputSnifferGoldenGuardTests` reading the committed corpus
/// out of the working tree.
final class GuiGateLaunchContractTests: XCTestCase {
    /// The gates that exec the app binary directly. `scripts/` sits beside `Tests/` in the package
    /// root — walk up from this file rather than relying on a bundle resource (a script is not a
    /// SwiftPM resource; it is a working-tree artefact).
    private static let gateScripts = ["scripts/check-macos.sh", "scripts/check-video.sh"]

    private func scriptURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskClientUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent(relativePath)
    }

    /// The lines that actually INVOKE the binary: `"${APP_BIN}" …`. The `APP_BIN=…` assignment and
    /// the `pkill` process patterns never carry the braces inside quotes, so they drop out, and
    /// comments are stripped so prose about the flag can never satisfy the assertion.
    private func launchLines(of script: String) throws -> [String] {
        let source = try String(contentsOf: scriptURL(script), encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .filter { $0.contains("\"${APP_BIN}\"") }
    }

    /// REVERT-TO-FAIL: drop `-ApplePersistenceIgnoreState YES` from either gate's launch and this
    /// names the script and the line.
    func testEveryDirectAppLaunchIgnoresPersistedState() throws {
        for script in Self.gateScripts {
            let lines = try launchLines(of: script)
            XCTAssertFalse(
                lines.isEmpty,
                "\(script) no longer execs \"${APP_BIN}\" — either it switched to `open` (which cannot "
                    + "forward the SLOPDESK_* automation env) or this contract lost its subject.",
            )
            for line in lines {
                XCTAssertTrue(
                    line.contains("-ApplePersistenceIgnoreState YES"),
                    "\(script) execs the app binary without `-ApplePersistenceIgnoreState YES`, so the "
                        + "app launches with ZERO windows and every scene `.task` seam the gate depends "
                        + "on never runs. Offending line: \(line.trimmingCharacters(in: .whitespaces))",
                )
            }
        }
    }

    /// The video gate's connectivity checks must be FATAL. It once observed the UDP flow, printed a
    /// warning when it was missing, and carried on to a screenshot — so a client that never dialled
    /// still exited 0. A gate that cannot go red on the failure it exists to catch is not a gate.
    func testTheVideoGateFailsHardWhenNothingConnected() throws {
        let source = try String(contentsOf: scriptURL("scripts/check-video.sh"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("WARN: did not observe a client→host UDP flow"),
            "a missing UDP flow must exit non-zero, not warn and screenshot the desktop",
        )
        for expected in [
            "FAIL: no client→host UDP flow", // the video leg dialled
            "FAIL: slopdesk-hostd never accepted a workspace channel", // the document leg opened
            "FAIL: one auto-connect must attach exactly 1 shell", // one connect ⇒ one PTY
        ] {
            XCTAssertTrue(source.contains(expected), "check-video.sh lost its `\(expected)` assertion")
        }
    }
}
