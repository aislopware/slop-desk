import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// The class byte has ridden `MuxChannelOpen` since the mux landed, but the CLIENT had no way to
/// set it: ``MuxClientTransport``'s acquire closure carried host, port, session, seq and cwd, and
/// every pane opened as class 0 because that is the only value the hop could express.
///
/// The widening is a Swift signature change inside `SlopDeskTransport` — not a wire change. What it
/// has to preserve is that every existing call site keeps opening a PANE: an accidental default of
/// anything else would route every terminal in the product into a class the host answers differently.
final class MuxClientTransportChannelClassTests: XCTestCase {
    /// Records what each acquisition hop was handed, from whichever task ran it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var classes: [UInt8] = []
        private var cwds: [String?] = []

        func append(channelClass: UInt8, cwd: String?) {
            lock.lock()
            classes.append(channelClass)
            cwds.append(cwd)
            lock.unlock()
        }

        var observedClasses: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            return classes
        }

        var observedCwds: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return cwds
        }
    }

    private static func nullAcquisition() async -> MuxAcquisition {
        await MuxAcquisition(
            channelID: 1,
            data: MuxSubChannel.makeNull(channel: .data),
            control: MuxSubChannel.makeNull(channel: .control),
        )
    }

    private func connect(_ transport: MuxClientTransport) async throws {
        try await transport.connect(
            host: "host",
            port: 1,
            resume: WireMessage.newSessionID,
            lastReceivedSeq: 0,
            handshakeTimeout: .seconds(1),
        )
    }

    /// The 6-arg form carries the class the caller asked for, all the way to the acquisition hop
    /// that puts it on the `channelOpen`.
    func testTheRequestedChannelClassReachesTheAcquisition() async throws {
        let recorder = Recorder()
        let transport = MuxClientTransport(
            channelClass: MuxChannelClass.paneObserver.rawValue,
            acquire: { _, _, _, _, channelClass, cwd in
                recorder.append(channelClass: channelClass, cwd: cwd)
                return await Self.nullAcquisition()
            },
            release: { _, _, _ in },
        )
        try await connect(transport)
        XCTAssertEqual(
            recorder.observedClasses, [MuxChannelClass.paneObserver.rawValue],
            "a read-only transport announces itself as one",
        )
    }

    /// The default is a PANE. Every shipped call site omits the argument, so this is what the
    /// product actually opens.
    func testTheDefaultChannelClassIsAPane() async throws {
        let recorder = Recorder()
        let transport = MuxClientTransport(
            acquire: { _, _, _, _, channelClass, cwd in
                recorder.append(channelClass: channelClass, cwd: cwd)
                return await Self.nullAcquisition()
            },
            release: { _, _, _ in },
        )
        try await connect(transport)
        XCTAssertEqual(recorder.observedClasses, [MuxChannelClass.pane.rawValue])
    }

    /// The 5-arg (cwd-carrying) compatibility overload still compiles and still routes identically:
    /// a pane, with the cwd hint intact.
    func testTheFiveArgOverloadStillOpensAPaneWithItsCwdHint() async throws {
        let recorder = Recorder()
        let transport = MuxClientTransport(
            acquire: { _, _, _, _, cwd in
                recorder.append(channelClass: MuxChannelClass.pane.rawValue, cwd: cwd)
                return await Self.nullAcquisition()
            },
            release: { _, _, _ in },
        )
        await transport.setInitialCwd("/Users/me/project")
        try await connect(transport)
        XCTAssertEqual(recorder.observedCwds, ["/Users/me/project"], "the 5-arg hop keeps its cwd hint")
    }

    /// And the 4-arg overload — the oldest shape, with neither cwd nor class — still connects.
    func testTheFourArgOverloadStillConnects() async throws {
        let recorder = Recorder()
        let transport = MuxClientTransport(
            acquire: { _, _, _, _ in
                recorder.append(channelClass: MuxChannelClass.pane.rawValue, cwd: nil)
                return await Self.nullAcquisition()
            },
            release: { _, _, _ in },
        )
        try await connect(transport)
        let sessionID = await transport.sessionID
        XCTAssertNotNil(sessionID, "the 4-arg hop still connects")
        XCTAssertEqual(recorder.observedClasses.count, 1)
    }
}
