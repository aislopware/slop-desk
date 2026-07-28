import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The `#if os(iOS)` constants, asserted on the triple that actually selects them.
///
/// `swift test` compiles the macOS slice, so every one of these reads the OTHER branch there — a
/// macOS test asserting `platformDefaultFollowSessionFocus` is asserting `true` about a phone. These
/// run under `scripts/check-ios-tests.sh`, which loads this bundle into a booted simulator's `xctest`
/// agent, and they are the only place the iOS values are ever executed.
final class PlatformDefaultsTests: XCTestCase {
    /// The kind the client announces on `subscribe`, which is what the HOST branches on to make a
    /// phone size-passive (docs/45 §8.3 rule 3). `MuxChannelOpen` carries no client kind, so this
    /// single compile-time constant is the whole of "the host knows this is a phone" — get it wrong
    /// and an iPhone silently clamps a Studio's nvim to its own width.
    func testThisBuildAnnouncesItselfAsIOS() {
        XCTAssertEqual(WorkspaceClientKind.thisPlatform, .iOS)
        XCTAssertEqual(WorkspaceClientKind.thisPlatform.rawValue, 1)
    }

    /// The guided-sheet step filter reads the same fork.
    func testFirstLaunchKnowsItIsOnIOS() {
        XCTAssertEqual(FirstLaunchModel.currentPlatform, .iOS)
    }

    /// A phone attaches to LOOK at one session; a desk attaches to WORK (docs/45 §8.2). The default
    /// is the whole feature on iOS — nothing in the app turns it off, so a device that never visits
    /// Settings is running exactly this value.
    func testAFreshDeviceDoesNotFollowTheSharedFocus() {
        XCTAssertFalse(DevicePreferences.platformDefaultFollowSessionFocus)
        XCTAssertFalse(
            DevicePreferences().followSessionFocus,
            "a fresh device-prefs.json takes the platform default, or the fork is decorative",
        )
    }
}
