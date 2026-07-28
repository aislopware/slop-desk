import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// The container every SlopDesk sidecar resolves through, and the one variable that moves it.
///
/// RED before the fix: there was no shared resolver at all. Each sidecar called
/// `FileManager.urls(for: .applicationSupportDirectory …)` for itself, so the only way to move a
/// DAEMON's files off the developer's container was `CFFIXED_USER_HOME` — which also moves
/// `NSHomeDirectory()` and everything hanging off it. Four gates settled for `HOME`, which moves
/// neither, and swept the developer's own scrollback journals on every run.
final class AppSupportContainerTests: XCTestCase {
    func testTheOverrideMovesTheWholeContainer() {
        let url = SlopDeskAppSupport.directory(
            environment: ["SLOPDESK_APP_SUPPORT_DIR": "/tmp/slopdesk-gate-container"],
        )
        XCTAssertEqual(url?.path, "/tmp/slopdesk-gate-container")
    }

    /// `FOO="${BAR}"` with `BAR` unset is how a shell hands over an empty value by accident. Writing
    /// to `/` would be a worse answer than writing to the real container, so empty means unset.
    func testAnEmptyOverrideIsUnset() {
        let url = SlopDeskAppSupport.directory(environment: ["SLOPDESK_APP_SUPPORT_DIR": ""])
        XCTAssertEqual(url?.lastPathComponent, "SlopDesk")
        XCTAssertTrue(
            url?.path.contains("Application Support") == true,
            "an empty override must fall back to Application Support, not to the filesystem root",
        )
    }

    func testWithNoOverrideItIsApplicationSupportSlopDesk() {
        let url = SlopDeskAppSupport.directory(environment: [:])
        XCTAssertEqual(url?.lastPathComponent, "SlopDesk")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    /// The two files a host daemon owns under the container, both moved by the one variable.
    /// `parked-windows.json` is the one that matters most: `slopdesk-videohostd` READS it at launch
    /// (and AX-moves the windows it names), then UNLINKS it when its own parked set empties.
    func testTheDaemonSidecarsFollowTheContainer() {
        let env = ["SLOPDESK_APP_SUPPORT_DIR": "/tmp/slopdesk-gate-container"]
        XCTAssertEqual(
            EnvBridge.defaultSidecarURL(environment: env)?.path,
            "/tmp/slopdesk-gate-container/video-prefs.json",
        )
    }
}
