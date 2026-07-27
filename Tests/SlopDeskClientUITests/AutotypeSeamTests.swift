import XCTest
@testable import SlopDeskClientUI

/// The `SLOPDESK_AUTOTYPE` OUT-path proof seam's one rule: the single shot is spent on the SEND.
///
/// RED before the fix: the latch was set before the settle wait, so a pane torn down inside that
/// window consumed the shot without typing anything — and the pane that survived could never take
/// it. On hardware that is `check-macos.sh --connect` failing its OUT-path proof with no crash, no
/// Swift error, and not a single `[echo-probe]` line to point at.
@MainActor
final class AutotypeSeamTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AutotypeSeam.reset()
    }

    override func tearDown() {
        AutotypeSeam.reset()
        super.tearDown()
    }

    /// The ordinary launch: the marked pane connects and the command goes out once.
    func testTheMarkedPaneTypesTheCommandOnce() async {
        var sent: [Data] = []
        let outcome = await AutotypeSeam.run(
            command: "echo 42", isTarget: true, isConnected: true, settle: .zero,
            send: { sent.append($0) },
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(sent, [Data("echo 42\n".utf8)], "a trailing newline is what makes the shell RUN it")

        let second = await AutotypeSeam.run(
            command: "echo 42", isTarget: true, isConnected: true, settle: .zero, send: { _ in },
        )
        XCTAssertEqual(second, .alreadyFired, "a tab-switch remount must not repeat the command")
        XCTAssertEqual(sent.count, 1)
    }

    /// A pane that is not the target, is still dialling, has no terminal model or has no command asks
    /// for nothing — and leaves the shot untouched for the pane that does.
    func testAnUnqualifiedPaneNeverSpendsTheShot() async {
        let send: ((Data) -> Void)? = { _ in }
        for (target, connected, command, out) in [
            (false, true, "echo 42", send), (true, false, "echo 42", send),
            (true, true, nil, send), (true, true, "", send), (true, true, "echo 42", nil),
        ] as [(Bool, Bool, String?, ((Data) -> Void)?)] {
            let outcome = await AutotypeSeam.run(
                command: command, isTarget: target, isConnected: connected, settle: .zero, send: out,
            )
            XCTAssertEqual(outcome, .notRequested)
        }

        var sent = 0
        let outcome = await AutotypeSeam.run(
            command: "echo 42", isTarget: true, isConnected: true, settle: .zero, send: { _ in sent += 1 },
        )
        XCTAssertEqual(outcome, .sent, "the shot was never spent, so the real target still has it")
        XCTAssertEqual(sent, 1)
    }

    /// THE REGRESSION: a leaf torn down inside the settle wait typed nothing, so the next pane to
    /// come up can still take the shot. Before the fix the latch was already spent and the OUT path
    /// was dead for the rest of the launch.
    func testAPaneTornDownMidWaitReArmsTheShot() async {
        var sent: [Data] = []
        let doomed = Task { @MainActor in
            await AutotypeSeam.run(
                command: "echo 42", isTarget: true, isConnected: true, settle: .seconds(30),
                send: { sent.append($0) },
            )
        }
        // Let it get past the latch and into the wait, then tear its leaf down — exactly what SwiftUI
        // does to `.task` when the document replaces the pane it is keyed on.
        await Task.yield()
        doomed.cancel()
        let cancelled = await doomed.value

        XCTAssertEqual(cancelled, .rearmed)
        XCTAssertEqual(sent, [], "the doomed pane typed nothing")

        let survivor = await AutotypeSeam.run(
            command: "echo 42", isTarget: true, isConnected: true, settle: .zero,
            send: { sent.append($0) },
        )
        XCTAssertEqual(survivor, .sent, "the pane that survives can still prove the OUT path")
        XCTAssertEqual(sent, [Data("echo 42\n".utf8)])
    }
}
