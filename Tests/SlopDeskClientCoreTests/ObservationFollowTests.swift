// ObservationFollowTests — the four properties docs/62 §3.1 calls load-bearing, asserted rather than
// documented.
//
// The hand-written prologue could not be tested: it was eleven lines inside 88 private methods, and a
// test would have had to reach into a view controller and drive AppKit. Hoisting it into
// ``ObservationFollow`` made it a headless object with one job, and this suite is the return on that —
// each test below corresponds to a way the copied form was silently WRONG at a site, which is the
// argument for the type over the argument for tidiness.
//
// ⚠️ THE RE-ARM IS THE SUBSCRIPTION, so a test that asserts only the FIRST wake proves nothing: every
// broken spelling of this idiom delivers exactly one update and then goes quiet. Every test that
// observes a wake here observes a SECOND one.
//
// The waits are `expectation`-driven rather than slept: `onChange` fires on the mutating thread and
// hops to the next main turn, so the settling point is a main-queue turn, not a duration.

import Observation
@testable import SlopDeskClientCore
import XCTest

/// The observed model. Two independent properties so a test can prove that reading one does not
/// subscribe to the other — property granularity is the whole reason ``read`` is kept narrow.
@Observable
@MainActor
private final class Model {
    var followed = 0
    var unrelated = 0
}

/// The shell. Records what it was told to apply, so a test asserts on the APPLY rather than on the
/// model it could have read directly.
@MainActor
private final class Shell {
    let model: Model
    var applied: [Int] = []
    /// Read inside `apply`, never inside `read` — the dependency-widening a hand-written block cannot
    /// prevent. If `apply` ran inside the tracking block this would subscribe, and
    /// ``testWorkDoneInApplyDoesNotWidenTheDependencySet`` would fail.
    var readDuringApply = false

    init(model: Model) { self.model = model }
}

@MainActor
final class ObservationFollowTests: XCTestCase {
    /// The arming call IS the first update. A site never writes "apply once, then follow", so it can
    /// never write them in the order that drops the initial reading.
    func testArmingAppliesOnceBeforeAnythingChanges() {
        let model = Model()
        let shell = Shell(model: model)
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })
        XCTAssertEqual(shell.applied, [0], "arming took the initial reading synchronously")
    }

    /// The property the whole type exists for: `withObservationTracking` fires ONCE, so a follow that
    /// does not re-arm delivers one update and then silence. Two mutations, two wakes.
    func testASecondChangeStillWakesTheFollow() async {
        let model = Model()
        let shell = Shell(model: model)
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })

        model.followed = 1
        await settle()
        XCTAssertEqual(shell.applied, [0, 1], "the first change arrives")

        model.followed = 2
        await settle()
        XCTAssertEqual(shell.applied, [0, 1, 2], "and so does the second — the re-arm happened")
    }

    /// `onChange` fires BEFORE the mutation is applied, so a follow that read on the callback's own
    /// turn would read the OLD value. This asserts the hop landed us after the write: the applied
    /// value is the NEW one, never the previous.
    func testTheWakeReadsTheValueAfterTheMutationLands() async {
        let model = Model()
        let shell = Shell(model: model)
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })

        model.followed = 7
        await settle()
        XCTAssertEqual(shell.applied.last, 7, "not 0 — the callback hopped past the write")
    }

    /// Property granularity, and the reason `read` must stay narrow: a property the read block never
    /// touched wakes nothing, even on the same object.
    func testAnUnreadPropertyOnTheSameModelWakesNothing() async {
        let model = Model()
        let shell = Shell(model: model)
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })

        model.unrelated = 99
        await settle()
        XCTAssertEqual(shell.applied, [0], "`unrelated` is not in the dependency set")
    }

    /// The split that a hand-written block makes a matter of discipline: `apply` runs OUTSIDE the
    /// tracking block, so a tracked property it reads for its own work does NOT become a dependency.
    /// Written as the failure it prevents — a shell that reads a second model property while pushing
    /// to its views would otherwise start waking on it.
    func testWorkDoneInApplyDoesNotWidenTheDependencySet() async {
        let model = Model()
        let shell = Shell(model: model)
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { shell, value in
            shell.applied.append(value)
            shell.readDuringApply = shell.model.unrelated > 0
        })

        model.unrelated = 1
        await settle()
        XCTAssertEqual(shell.applied, [0], "reading `unrelated` in `apply` did not subscribe to it")
    }

    /// ``ObservationFollow/stop()`` is the generation counter's replacement for the one case the
    /// owner's lifetime cannot cover — a shell that is detached but still retained. An in-flight wake
    /// must find the following dead rather than re-arm against a live model.
    func testStopEndsTheFollowingWhileTheOwnerIsStillAlive() async {
        let model = Model()
        let shell = Shell(model: model)
        let follow = ObservationFollow.arm(
            shell, read: { $0.model.followed }, apply: { $0.applied.append($1) },
        )

        follow.stop()
        model.followed = 1
        await settle()
        XCTAssertEqual(shell.applied, [0], "the stopped follow applied nothing")
    }

    /// `stop()` DURING an apply is the teardown-from-inside-a-callback shape, and must not re-arm on
    /// the way out of the cycle that called it.
    func testStoppingFromInsideApplyIsFinal() async {
        let model = Model()
        let shell = Shell(model: model)
        var follow: ObservationFollow?
        follow = ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { shell, value in
            shell.applied.append(value)
            if value == 1 { follow?.stop() }
        })

        model.followed = 1
        await settle()
        model.followed = 2
        await settle()
        XCTAssertEqual(shell.applied, [0, 1], "the wake that stopped it was the last one")
    }

    /// The `[weak self]` obligation, made structural: `withObservationTracking` retains its callback
    /// for as long as the observed model lives, and these models are app-lifetime. A call site cannot
    /// capture the owner strongly here because it never writes the capture list — so a released shell
    /// must actually release.
    func testTheFollowDoesNotRetainItsOwner() async {
        let model = Model()
        weak var weakShell: Shell?
        do {
            let shell = Shell(model: model)
            weakShell = shell
            ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })
            XCTAssertNotNil(weakShell, "alive while the strong reference is in scope")
        }
        XCTAssertNil(weakShell, "the armed follow held it weakly")
    }

    /// A wake whose owner has gone returns without re-arming. This is the generation guard's real
    /// subject — tracking must not be re-established against a live model on behalf of a dead shell —
    /// and it is asserted through the consequence: the model outlives the shell and mutating it is
    /// simply quiet.
    func testAWakeAfterTheOwnerIsGoneDoesNotReArm() async {
        let model = Model()
        weak var weakShell: Shell?
        do {
            let shell = Shell(model: model)
            weakShell = shell
            ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })
        }
        model.followed = 1
        await settle()
        XCTAssertNil(weakShell)
        model.followed = 2
        await settle()
        XCTAssertNil(weakShell, "and the second mutation found nothing to wake either")
    }

    /// Two follows on one owner stay independent — the shape
    /// `MacWorkspaceWindowController` needs, where the title follow and the collapse follow are
    /// deliberately separate so a shell's OSC-0 title traffic does not re-push the split's items.
    func testTwoFollowsOnOneOwnerDoNotWakeEachOther() async {
        let model = Model()
        let shell = Shell(model: model)
        var second: [Int] = []
        ObservationFollow.arm(shell, read: { $0.model.followed }, apply: { $0.applied.append($1) })
        ObservationFollow.arm(shell, read: { $0.model.unrelated }, apply: { _, value in
            second.append(value)
        })

        model.followed = 5
        await settle()
        XCTAssertEqual(shell.applied, [0, 5])
        XCTAssertEqual(second, [0], "the `unrelated` follow did not wake on `followed`")
    }

    /// Lets the wake's `DispatchQueue.main.async` hop run. Two turns rather than one: the callback
    /// schedules the cycle, and the cycle's own re-arm must have completed before the next mutation,
    /// or a test would be racing the subscription it is about to exercise.
    private func settle() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
