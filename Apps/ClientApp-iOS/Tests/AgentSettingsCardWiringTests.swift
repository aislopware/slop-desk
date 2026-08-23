// AgentSettingsCardWiringTests
//
// The Agents settings card + the entire Agent-Behaviour toggle block read the app-owned
// `AgentHooksController` from `@Environment(\.agentHooksController)`. The macOS `Settings` scene injects it;
// the iOS `SettingsSheet` did NOT — so on iOS the controller resolved nil, the card was permanently
// `.disconnected` (Install/Uninstall impossible) and the whole behaviour block stayed greyed.
//
// These pin the FIX headlessly on the iOS triple (docs/56 F4c: `SettingsSheet` is `SlopDeskPhoneUI`, which
// only the simulator bundle compiles — `slopdesk-gate ios-tests`; a macOS `swift test` sees an empty
// module and would assert nothing):
// - the iOS `SettingsSheet` RETAINS the controller threaded into it so the card it hands that controller
//   resolves a LIVE state;
// - the `@Entry` environment slot the wiring rides round-trips.
//
// docs/56: the ONE nil-controller fallback (`AgentSettingsCard.installState(_:)` / `.behaviourEnabled(_:)`)
// moved to `SlopDeskClientCore` in batch 2 of the draining-floor split — it named no view framework — and
// its own pin moved with it to `Tests/SlopDeskClientCoreTests/AgentSettingsCardTests.swift`. What is left
// here is the half that genuinely needs a view: the sheet and the environment slot. `SlopDeskClientCore`
// is `@testable`-imported for `AgentSettingsCard`, which is `package`: this bundle is an Xcode target
// OUTSIDE the SwiftPM package, so a plain `import` cannot see a `package` declaration at all.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskPhoneUI

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
