// AgentSettingsCardTests — the pure nil-controller fallback, headless.
//
// docs/56: `AgentSettingsCard` itself descended to `SlopDeskClientCore` in batch 2 of the draining-floor
// split (it names no view framework — `AgentHooksController` is `SlopDeskWorkspaceCore`'s, and both
// static funcs return a plain enum / `Bool`). This pins the fallback the split carried down. The
// SwiftUI-side wiring — the `SettingsSheet` threading and the `@Entry` environment slot round trip —
// stayed in `Apps/ClientApp-iOS/Tests/AgentSettingsCardWiringTests.swift`, which is what its own
// header now says.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class AgentSettingsCardTests: XCTestCase {
    private func installedController() async -> AgentHooksController {
        let c = AgentHooksController(refreshStatus: { .init(installed: true, listenerActive: true) })
        await c.refresh()
        return c
    }

    func testNilControllerIsDisconnectedAndBehaviourDisabled() {
        XCTAssertEqual(
            AgentSettingsCard.installState(nil), .disconnected,
            "no injected controller ⇒ the card is .disconnected (NEVER a false 'Not Installed')",
        )
        XCTAssertFalse(
            AgentSettingsCard.behaviourEnabled(nil),
            "no injected controller ⇒ the Agent-Behaviour toggles are greyed (the exact iOS rot)",
        )
    }

    func testInstalledControllerIsLiveAndBehaviourEnabled() async {
        let controller = await installedController()
        XCTAssertEqual(controller.state, .installed)
        XCTAssertEqual(AgentSettingsCard.installState(controller), .installed)
        XCTAssertNotEqual(AgentSettingsCard.installState(controller), .disconnected)
        XCTAssertTrue(
            AgentSettingsCard.behaviourEnabled(controller),
            "an installed controller ⇒ the behaviour toggles are configurable",
        )
    }
}
