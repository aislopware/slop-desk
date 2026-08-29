import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// The container every SlopDesk sidecar resolves through.
///
/// The RULE — the one variable that moves the container, and the empty value that reads as unset —
/// is `slopdesk-hostlaunch`'s `record::app_support_dir_in`, unit-tested there on both branches
/// without an environment to arrange. What is left on this side is the BASE and the file name, so
/// that is what is asserted here: the sidecar lands inside the container the door answered, under
/// its one name.
///
/// RED before the port: the rule was spelled a third time in Swift, over a base
/// `FileManager` resolves and a base the daemons resolve from `HOME` — two answers to one question,
/// which is how four gates came to sweep the developer's own container.
final class AppSupportContainerTests: XCTestCase {
    func testTheSidecarLandsInTheContainerUnderItsOneName() throws {
        let url = try XCTUnwrap(EnvBridge.defaultSidecarURL())
        XCTAssertEqual(url.lastPathComponent, "video-prefs.json")
        XCTAssertTrue(url.path.hasPrefix("/"), "a sidecar location is absolute: \(url.path)")
    }

    /// The container is a DIRECTORY the file hangs off, never the file itself — an off-by-one in
    /// the join would leave `video-prefs.json` sitting where the container should be.
    func testTheContainerIsTheDirectoryAboveTheSidecar() throws {
        let url = try XCTUnwrap(EnvBridge.defaultSidecarURL())
        XCTAssertFalse(
            url.deletingLastPathComponent().lastPathComponent.isEmpty,
            "the sidecar must hang off a named container: \(url.path)",
        )
    }
}
