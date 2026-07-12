// AgentSettingsCardWiringTests
//
// The Agents settings card + the entire Agent-Behaviour toggle block read the app-owned
// `AgentHooksController` from `@Environment(\.agentHooksController)`. The macOS `Settings` scene injects it;
// the iOS `SettingsSheet` did NOT — so on iOS the controller resolved nil, the card was permanently
// `.disconnected` (Install/Uninstall impossible) and the whole behaviour block stayed greyed.
//
// These pin the FIX headlessly on the macOS `swift test` host (iOS view code rots silently — CLAUDE.md):
// - `AgentSettingsCard` (the ONE nil-controller fallback) maps nil → `.disconnected` + behaviour-disabled,
//   and an installed controller → `.installed` + behaviour-enabled;
// - the iOS `SettingsSheet` RETAINS the controller threaded into it so the card it hands that controller
//   resolves a LIVE state.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class AgentSettingsCardWiringTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AgentSettingsCardWiringTests." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeStore(_ name: String = #function) -> PreferencesStore {
        PreferencesStore(defaults: makeIsolatedDefaults(name), sidecarURL: nil, applyOnInit: false)
    }

    private func installedController() async -> AgentHooksController {
        let c = AgentHooksController(refreshStatus: { .init(installed: true, listenerActive: true) })
        await c.refresh()
        return c
    }

    // MARK: the nil-controller fallback (the iOS bug symptom)

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

    // MARK: the iOS settings sheet threads the controller

    func testIOSSettingsSheetRetainsInjectedControllerForAgentsCard() async {
        let controller = await installedController()
        let sheet = SettingsSheet(store: makeStore(), agentHooks: controller)
        XCTAssertTrue(
            sheet.agentHooks === controller,
            "the iOS SettingsSheet must retain the app's AgentHooksController so the Agents card + behaviour "
                + "toggles are live on iOS (regression: nil ⇒ permanently .disconnected & greyed)",
        )
        // The card the sheet hands that controller resolves a LIVE (non-disconnected) install state.
        XCTAssertEqual(AgentSettingsCard.installState(sheet.agentHooks), .installed)
        XCTAssertTrue(AgentSettingsCard.behaviourEnabled(sheet.agentHooks))
    }

    /// The default-nil sheet (a preview / no scene) keeps the disabled "Connect a session" card — never a crash
    /// and never a false live card.
    func testSettingsSheetWithoutControllerStaysDisconnected() {
        let sheet = SettingsSheet(store: makeStore())
        XCTAssertNil(sheet.agentHooks)
        XCTAssertEqual(AgentSettingsCard.installState(sheet.agentHooks), .disconnected)
        XCTAssertFalse(AgentSettingsCard.behaviourEnabled(sheet.agentHooks))
    }

    // MARK: the environment slot the wiring rides

    func testAgentHooksControllerEnvironmentRoundTrips() {
        var env = EnvironmentValues()
        XCTAssertNil(env.agentHooksController, "the slot defaults nil so an un-injected card is .disconnected")
        let controller = AgentHooksController()
        env.agentHooksController = controller
        XCTAssertTrue(env.agentHooksController === controller)
    }
}
#endif
