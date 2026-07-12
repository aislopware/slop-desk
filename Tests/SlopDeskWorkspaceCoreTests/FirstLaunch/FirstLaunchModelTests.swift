import XCTest
@testable import SlopDeskWorkspaceCore

/// The first-launch gating model is PURE and headless-pinned. These cover the three
/// jobs `FirstLaunchModel` owns: (1) the present-once gate (`shouldPresent`, suppressed under automation),
/// (2) the platform-filtered step set (macOS: all five; iOS: the three cross-platform steps), and (3) the
/// navigation + completion + finish state machine. No view / NSWindow / SCStream / VT is constructed
/// (hang-safety) — the gating is `nonisolated static`, the model `@MainActor @Observable`.
final class FirstLaunchModelTests: XCTestCase {
    // MARK: - shouldPresent (the present-once gate)

    /// A fresh install (`hasCompleted == false`, no automation) presents; a completed install does not; and an
    /// automation launch never presents even on a fresh install (the sheet must not steal the autoconnect
    /// focus). Revert-to-confirm-fail: a gate that ignored `automationActive` would present in the last case.
    func testShouldPresentGate() {
        XCTAssertTrue(FirstLaunchModel.shouldPresent(hasCompleted: false))
        XCTAssertFalse(FirstLaunchModel.shouldPresent(hasCompleted: true))
        XCTAssertFalse(
            FirstLaunchModel.shouldPresent(hasCompleted: false, automationActive: true),
            "automation must suppress the first-launch sheet",
        )
        XCTAssertFalse(FirstLaunchModel.shouldPresent(hasCompleted: true, automationActive: true))
    }

    // MARK: - Platform-filtered step set

    /// macOS gets all five steps in checklist order.
    func testMacOSStepsAreAllFiveInOrder() {
        XCTAssertEqual(
            FirstLaunchModel.steps(for: .macOS),
            [.onLaunch, .defaultTerminal, .installCLI, .theme, .installClaudeHooks],
        )
    }

    /// iOS drops the two macOS-only OS-integration steps (Default-Terminal, Install-CLI) but keeps the three
    /// cross-platform steps in the same relative order. Revert-to-confirm-fail: a filter that did not honour
    /// `isMacOnly` would leak the `/usr/local/bin` install step onto iOS.
    func testIOSStepsDropMacOnlySteps() {
        let ios = FirstLaunchModel.steps(for: .iOS)
        XCTAssertEqual(ios, [.onLaunch, .theme, .installClaudeHooks])
        XCTAssertFalse(ios.contains(.installCLI))
        XCTAssertFalse(ios.contains(.defaultTerminal))
    }

    /// The `isMacOnly` classification is exactly the two OS-integration steps (the rest cross-platform).
    func testIsMacOnlyClassification() {
        XCTAssertTrue(FirstLaunchStep.defaultTerminal.isMacOnly)
        XCTAssertTrue(FirstLaunchStep.installCLI.isMacOnly)
        XCTAssertFalse(FirstLaunchStep.onLaunch.isMacOnly)
        XCTAssertFalse(FirstLaunchStep.theme.isMacOnly)
        XCTAssertFalse(FirstLaunchStep.installClaudeHooks.isMacOnly)
    }

    // MARK: - Navigation state machine

    @MainActor
    func testAdvanceAndBackClampAtBounds() {
        let model = FirstLaunchModel(platform: .macOS, onFinish: { _ in })
        XCTAssertTrue(model.isFirstStep)
        XCTAssertFalse(model.isLastStep)
        XCTAssertEqual(model.currentStep, .onLaunch)
        XCTAssertEqual(model.stepNumber, 1)
        XCTAssertEqual(model.stepCount, 5)

        // back at the first step is a no-op (returns false, index stays).
        XCTAssertFalse(model.back())
        XCTAssertEqual(model.currentStep, .onLaunch)

        // advance through the steps.
        XCTAssertTrue(model.advance())
        XCTAssertEqual(model.currentStep, .defaultTerminal)
        XCTAssertTrue(model.advance())
        XCTAssertTrue(model.advance())
        XCTAssertTrue(model.advance())
        XCTAssertEqual(model.currentStep, .installClaudeHooks)
        XCTAssertTrue(model.isLastStep)
        XCTAssertEqual(model.stepNumber, 5)

        // advance at the last step is a no-op (returns false).
        XCTAssertFalse(model.advance())
        XCTAssertEqual(model.currentStep, .installClaudeHooks)

        // back walks it down again.
        XCTAssertTrue(model.back())
        XCTAssertEqual(model.currentStep, .theme)
        XCTAssertFalse(model.isLastStep)
    }

    /// `go(to:)` jumps to a step in the set and is a no-op for a step the platform filtered out (iOS has no
    /// Install-CLI step, so jumping there must not move the index out of the iOS set).
    @MainActor
    func testGoToStep() {
        let mac = FirstLaunchModel(platform: .macOS, onFinish: { _ in })
        mac.go(to: .theme)
        XCTAssertEqual(mac.currentStep, .theme)

        let ios = FirstLaunchModel(platform: .iOS, onFinish: { _ in })
        ios.go(to: .installCLI) // not in the iOS set → no-op
        XCTAssertEqual(ios.currentStep, .onLaunch)
        ios.go(to: .installClaudeHooks)
        XCTAssertEqual(ios.currentStep, .installClaudeHooks)
        XCTAssertTrue(ios.isLastStep) // iOS last step is Claude-hooks (3 steps)
        XCTAssertEqual(ios.stepCount, 3)
    }

    // MARK: - Completion + finish persistence

    @MainActor
    func testMarkCompleteTracksActionedSteps() {
        let model = FirstLaunchModel(platform: .macOS, onFinish: { _ in })
        XCTAssertFalse(model.isComplete(.installCLI))
        model.markComplete(.installCLI)
        XCTAssertTrue(model.isComplete(.installCLI))
        // Idempotent.
        model.markComplete(.installCLI)
        XCTAssertEqual(model.completed, [.installCLI])
    }

    /// `finish()` routes through the INJECTED sink (so the real `Defaults` write is never exercised in a unit
    /// test). Revert-to-confirm-fail: a `finish()` that did not call `onFinish(true)` leaves the flag unset.
    @MainActor
    func testFinishPersistsViaInjectedSink() {
        final class Box { var value: Bool? }
        let box = Box()
        let model = FirstLaunchModel(platform: .macOS, onFinish: { box.value = $0 })
        XCTAssertNil(box.value)
        model.finish()
        XCTAssertEqual(box.value, true)
    }

    // MARK: - CLIShellShim (the "Omit Prefix" snippet — PURE)

    /// The exposed function names are exactly the documented set, in order — no non-Claude agent verbs.
    func testShellShimFunctionNames() {
        XCTAssertEqual(CLIShellShim.functionNames, ["edit", "view", "watch", "jump", "learn"])
        XCTAssertFalse(CLIShellShim.functionNames.contains("codex"))
        XCTAssertFalse(CLIShellShim.functionNames.contains("opencode"))
    }

    /// With Allow-Overwrite OFF every function is guarded by `command -v … ||` so a user's own command is
    /// never clobbered; with it ON the guard is gone (unconditional define). Both wrap the resolved binary.
    func testShellShimSnippetGuardsOnOverwrite() {
        let safe = CLIShellShim.snippet(allowOverwrite: false, binary: "slopdesk")
        for name in CLIShellShim.functionNames {
            XCTAssertTrue(
                safe.contains("command -v \(name) >/dev/null 2>&1 || \(name)() { slopdesk \(name) \"$@\"; }"),
                "Allow-Overwrite OFF must guard \(name) with command -v",
            )
        }

        let force = CLIShellShim.snippet(allowOverwrite: true, binary: "slopdesk")
        XCTAssertFalse(
            force.contains("command -v"),
            "Allow-Overwrite ON defines functions unconditionally (no command -v guard)",
        )
        for name in CLIShellShim.functionNames {
            XCTAssertTrue(force.contains("\(name)() { slopdesk \(name) \"$@\"; }"))
        }
    }
}
