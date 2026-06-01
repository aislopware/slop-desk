import XCTest
import RworkClient
import RworkTerminal
@testable import RworkClientUI

/// State-transition tests for the `@MainActor @Observable` ``TerminalViewModel``: it folds
/// `RworkClient.Event`s + `output` chunks into observable connection / title / byte-count /
/// exit state. Driven synchronously via `handle`/`ingestOutput` (the same path
/// `observe(client:)` uses), so the transitions are deterministic and need no network.
@MainActor
final class TerminalViewModelTests: XCTestCase {

    func testFirstOutputFlipsConnectingToConnected() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.connectionStatus, .idle)

        // observe() sets .connecting; simulate that precondition.
        model.markReconnecting()
        XCTAssertEqual(model.connectionStatus, .reconnecting)

        model.ingestOutput(Data("hello".utf8))
        XCTAssertEqual(model.connectionStatus, .connected, "first byte after reconnecting → connected")
        XCTAssertEqual(model.bytesReceived, 5)
    }

    func testTitleEvent() {
        let model = TerminalViewModel()
        model.handle(.title("~/proj — zsh"))
        XCTAssertEqual(model.title, "~/proj — zsh")
    }

    func testBellEventSetsAndClears() {
        let model = TerminalViewModel()
        XCTAssertFalse(model.bellPending)
        model.handle(.bell)
        XCTAssertTrue(model.bellPending)
        model.clearBell()
        XCTAssertFalse(model.bellPending)
    }

    func testExitEvent() {
        let model = TerminalViewModel()
        model.handle(.exit(code: 130))
        XCTAssertEqual(model.connectionStatus, .exited(code: 130))
    }

    func testDisconnectedEvent() {
        let model = TerminalViewModel()
        model.handle(.disconnected(reason: "stream ended (FIN)"))
        XCTAssertEqual(model.connectionStatus, .disconnected(reason: "stream ended (FIN)"))
    }

    func testReconnectedEventRestoresConnectedAndResumeSeq() {
        let model = TerminalViewModel()
        let sid = UUID()
        model.handle(.disconnected(reason: "drop"))
        model.markReconnecting()
        model.handle(.reconnected(sessionID: sid, resumeFromSeq: 42))
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.sessionID, sid)
        XCTAssertEqual(model.lastResumeSeq, 42)
    }

    func testOutputFeedsSurface() {
        final class CapturingSurface: TerminalSurface, @unchecked Sendable {
            var fed = Data()
            func feed(_ bytes: Data) { fed.append(bytes) }
            func setSize(cols: UInt16, rows: UInt16) {}
            func handleInput(_ bytes: Data) {}
            var onWrite: ((Data) -> Void)?
        }
        let surface = CapturingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data([0x41, 0x42]))
        model.ingestOutput(Data([0x43]))
        XCTAssertEqual(surface.fed, Data([0x41, 0x42, 0x43]), "model mirrors output into the renderer seam")
        XCTAssertEqual(model.bytesReceived, 3)
    }

    func testResetClearsState() {
        let model = TerminalViewModel()
        model.handle(.title("x"))
        model.ingestOutput(Data("abc".utf8))
        model.handle(.bell)
        model.reset()
        XCTAssertNil(model.title)
        XCTAssertEqual(model.bytesReceived, 0)
        XCTAssertFalse(model.bellPending)
        XCTAssertEqual(model.connectionStatus, .idle)
    }
}
