#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

/// The quit-confirmation decision (a stray ⌘Q — `performKeyEquivalent: → terminate:` in
/// the log — killed the client mid-scroll and read as a CRASH). Pure policy; the NSAlert is GUI.
final class QuitConfirmPolicyTests: XCTestCase {
    func testInteractiveQuitWithOpenTabsConfirms() {
        XCTAssertTrue(QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: true, isAppleEventQuit: false, envValue: nil,
        ))
    }

    func testEmptyWorkspaceQuitsSilently() {
        XCTAssertFalse(QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: false, isAppleEventQuit: false, envValue: nil,
        ))
    }

    func testAppleEventQuitNeverConfirms() {
        // osascript `quit app` (deploy tooling) and logout/shutdown arrive as Apple Events — a modal
        // dialog there blocks automation or the whole logout.
        XCTAssertFalse(QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: true, isAppleEventQuit: true, envValue: nil,
        ))
    }

    func testEnvKillSwitchDisablesTheDialog() {
        XCTAssertFalse(QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: true, isAppleEventQuit: false, envValue: "0",
        ))
        // Any other value keeps the default-ON semantics (the repo's `!= "0"` idiom).
        XCTAssertTrue(QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: true, isAppleEventQuit: false, envValue: "1",
        ))
    }
}
#endif
