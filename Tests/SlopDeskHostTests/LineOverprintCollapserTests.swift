import XCTest
@testable import SlopDeskHost

/// The overprint pass INSIDE ``ScrollbackReplayTransform``.
///
/// The pass itself is `rust/slopdesk-screend/src/overprint.rs`, and its behaviour is pinned there
/// — every revision-coverage rule, every verbatim bail-out, the carry cap, the compaction
/// threshold, the differential against the screen model, and the 2000-stream fuzz all live in
/// `rust/slopdesk-screend/tests/overprint.rs`. Re-asserting any of that here would be the
/// cross-language mirror this tree forbids.
///
/// What is left is the only claim that is genuinely about the SWIFT side: that the seven-pass
/// transform chain, which stays in Swift, actually reaches the pass — and that no environment
/// variable can make it stop.
final class LineOverprintCollapserTests: XCTestCase {
    override func setUpWithError() throws {
        try ScreendFixture.requireDaemon()
    }

    func testTransformCollapsesCommandOutputChurnEndToEnd() throws {
        var stream = "\u{1B}]133;A\u{07}% \u{1B}]133;B\u{07}\u{1B}]133;E;git push\u{07}git push"
        stream += "\u{1B}]133;C\u{07}\r\n"
        for percent in 0...100 { stream += "Enumerating objects: \(percent)% (37/3700)\r" }
        stream += "Enumerating objects: 100% (3700/3700), done.\n"
        stream += "To github.com:x/y.git\n"
        stream += "\u{1B}]133;D;0\u{07}"

        let raw = Data(stream.utf8)
        let transform = ScrollbackReplayTransform.make(environment: [:], reassertInputModes: false)
        let collapsed = try XCTUnwrap(transform)(raw)
        XCTAssertLessThan(collapsed.count, raw.count / 20, "progress churn must not survive replay")
        let text = try XCTUnwrap(String(bytes: collapsed, encoding: .utf8))
        XCTAssertTrue(text.contains("Enumerating objects: 100% (3700/3700), done."))
        XCTAssertTrue(text.contains("To github.com:x/y.git"))
        XCTAssertFalse(text.contains("Enumerating objects: 50%"))
    }

    /// There is no kill switch. `SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT=0` used to hand the churn
    /// back verbatim; it is gone, because megabytes of superseded percentage ticks is not a mode.
    func testThereIsNoKillSwitchForTheChurn() throws {
        var stream = ""
        for percent in 0...100 { stream += "Writing objects: \(percent)%\r" }
        stream += "done.\n"
        let raw = Data(stream.utf8)
        let env = ["SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT": "0"] // ignored — no such gate
        let transform = try XCTUnwrap(
            ScrollbackReplayTransform.make(environment: env, reassertInputModes: false),
        )
        XCTAssertLessThan(transform(raw).count, raw.count / 20)
    }
}
