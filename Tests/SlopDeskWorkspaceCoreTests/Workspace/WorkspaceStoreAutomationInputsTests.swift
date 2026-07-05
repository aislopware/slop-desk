import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the automation-input merge that backs the `open --args SLOPDESK_…=value` launch path
/// (used when a GUI-session launch cannot inject environment variables — e.g. over SSH).
///
/// The regression this guards is concrete: the app-global ``AppConnection`` target — the host every
/// pane actually connects to — must be seeded from the SAME inputs the bootstrap reads. A video
/// autoconnect passed via launch arguments has to carry the REAL host into the ``ConnectionTarget``,
/// not silently fall back to the `127.0.0.1` default. A same-host check (everything on `127.0.0.1`)
/// can never catch that fallback, so it is pinned here.
final class WorkspaceStoreAutomationInputsTests: XCTestCase {
    /// A matching `SLOPDESK_…=value` argument overrides the inherited environment; argv[0] and
    /// non-matching tokens are ignored; unrelated environment entries survive.
    func testArgumentsOverrideEnvironment() {
        let inputs = WorkspaceStore.automationInputs(
            environment: ["SLOPDESK_VIDEO_AUTOCONNECT_HOST": "127.0.0.1", "UNRELATED": "keep"],
            arguments: [
                "/path/to/SlopDesk", // argv[0] — skipped
                "SLOPDESK_VIDEO_AUTOCONNECT_HOST=100.107.14.250", // overrides the env value
                "not-an-assignment", // no '=' → ignored
                "OTHER_TOOL_FLAG=1", // wrong prefix → ignored
                "SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT=9000", // arg-only key
            ],
        )
        XCTAssertEqual(inputs["SLOPDESK_VIDEO_AUTOCONNECT_HOST"], "100.107.14.250")
        XCTAssertEqual(inputs["SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT"], "9000")
        XCTAssertEqual(inputs["UNRELATED"], "keep")
        XCTAssertNil(inputs["OTHER_TOOL_FLAG"])
    }

    /// A video autoconnect target supplied entirely via arguments resolves to a `ConnectionTarget`
    /// carrying the REAL host (not the `127.0.0.1` default).
    func testVideoTargetHostComesFromArguments() {
        let inputs = WorkspaceStore.automationInputs(
            environment: [:],
            arguments: [
                "/path/to/SlopDesk",
                "SLOPDESK_VIDEO_AUTOCONNECT_HOST=100.107.14.250",
                "SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT=9000",
                "SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT=9001",
                "SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID=470",
                "SLOPDESK_VIDEO_AUTOCONNECT_TITLE=UFO",
            ],
        )
        let resolved = WorkspaceStore.videoTarget(from: inputs)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.0.host, "100.107.14.250")
        XCTAssertNotEqual(resolved?.0.host, "127.0.0.1")
        XCTAssertEqual(resolved?.0.mediaPort, 9000)
        XCTAssertEqual(resolved?.0.cursorPort, 9001)
        XCTAssertEqual(resolved?.1.windowID, 470)
        XCTAssertEqual(resolved?.1.title, "UFO")
    }
}
