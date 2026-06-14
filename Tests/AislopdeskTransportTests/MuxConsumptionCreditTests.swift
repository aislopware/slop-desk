import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskTransport

/// Credit-at-CONSUMPTION contract (the end-to-end backpressure restore): windowAdjust
/// grants fire ONLY when the channel's real consumer reports consumption via
/// `MuxSubChannel.noteConsumed` — never at demux time — so a flood can no longer buffer
/// without bound downstream of the demux, and a slow consumer transitively pauses the
/// producing peer at ~one window.
final class MuxConsumptionCreditTests: XCTestCase {
    /// Loopback where the host floods output and the CLIENT's grant emissions are spied:
    /// delivering several windows' worth of threshold-crossing bytes with NO noteConsumed
    /// must emit ZERO grants (this exact assertion was FALSE before the change — demux-time
    /// crediting granted immediately).
    func testNoGrantWithoutConsumption() async throws {
        let (clientControlRaw, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let clientControl = RecordingMuxLink(wrapping: clientControlRaw)
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        let hostSide = HostSideBox()
        await host.setHostOpenHandler { open in
            Task {
                await host.sendOpenAck(open.channelID, accepted: true)
                hostSide.set(open.data)
            }
        }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(80))
        guard let hostData2 = hostSide.get() else { XCTFail("host never saw the open")
            return
        }

        // Host floods just under one window of threshold-crossing output (well past the
        // half-window grant threshold). The client demuxes + buffers it, but NOBODY consumes.
        let frame = Data(repeating: 0x61, count: 8 * 1024)
        for i in 1...6 { try await hostData2.send(.output(seq: Int64(i), bytes: frame)) } // 48KiB > threshold
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            clientControl.windowAdjustCount,
            0,
            "NO grant may be emitted before the consumer reports consumption (credit-at-consumption)",
        )

        // Now the consumer reports consumption → the grant fires (and rides CONTROL).
        var consumedWire = 0
        var received = 0
        for try await message in ch.data.inbound {
            consumedWire += message.wireByteCount
            await ch.data.noteConsumed(message.wireByteCount)
            received += 1
            if received == 6 { break }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(
            clientControl.windowAdjustCount,
            0,
            "consumption past the threshold emits the grant",
        )
        XCTAssertGreaterThan(consumedWire, MuxFlowControl.initialWindowBytes / 2)

        await client.close()
        await host.close()
    }

    /// A flooding sender parks at ~one window against a non-consuming receiver, and a
    /// consumer that then drains + credits lets the flood COMPLETE byte-identically. This
    /// is the end-to-end "slow renderer pauses the host PTY" semantic, headless.
    func testFloodParksAtOneWindowAndCompletesOnConsumption() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        let hostSide = HostSideBox()
        await host.setHostOpenHandler { open in
            Task {
                await host.sendOpenAck(open.channelID, accepted: true)
                hostSide.set(open.data)
            }
        }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(80))
        guard let sender = hostSide.get() else { XCTFail("host never saw the open")
            return
        }

        // Flood 4 windows' worth from the host. With no consumption the sender MUST park.
        let window = MuxFlowControl.initialWindowBytes
        let frameBody = Data(repeating: 0x62, count: 8 * 1024)
        let total = (4 * window) / (frameBody.count + 13) + 1
        let sentAll = BoolBox(false)
        let flood = Task {
            for i in 1...total { try? await sender.send(.output(seq: Int64(i), bytes: frameBody)) }
            sentAll.set(true)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(
            sentAll.get(),
            "the flood must PARK against a non-consuming receiver (bounded by ~one window)",
        )

        // Drain + credit: the flood completes and every byte arrives in order.
        var receivedFrames = 0
        for try await message in ch.data.inbound {
            guard case let .output(seq, bytes) = message else { continue }
            XCTAssertEqual(Int(seq), receivedFrames + 1, "frames arrive in exact send order")
            XCTAssertEqual(bytes, frameBody)
            receivedFrames += 1
            await ch.data.noteConsumed(message.wireByteCount)
            if receivedFrames == total { break }
        }
        XCTAssertEqual(receivedFrames, total, "the whole flood is delivered byte-identically after consumption resumes")
        _ = await flood.value
        XCTAssertTrue(sentAll.get())

        await client.close()
        await host.close()
    }

    /// noteConsumed after the channel closed must be a harmless no-op (accountant gone).
    func testNoteConsumedAfterCloseIsANoOp() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { open in
            Task { await host.sendOpenAck(open.channelID, accepted: true) }
        }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(50))
        await client.closeChannel(ch.data.channelID)
        await ch.data.noteConsumed(1_000_000) // accountant removed — must not crash or grant
        await client.close()
        await host.close()
    }

    /// `MuxClientTransport.sendInput` splits a large paste into frames of at most
    /// `maxDataMessagePayloadBytes` that reassemble byte-identically in order — the
    /// channel-killer (>16 MiB single frame) and the credit-at-consumption frame≥window
    /// deadlock are both de-fused at the source.
    func testSendInputSplitsLargePasteIntoBoundedFrames() async throws {
        final class FrameRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var decoder = FrameDecoder()
            private(set) var inputs: [Data] = []
            func ingest(_ inner: Data) {
                lock.lock()
                defer { lock.unlock() }
                decoder.append(inner)
                while let message = (try? decoder.nextMessage()) {
                    if case let .input(bytes) = message { inputs.append(bytes) }
                }
            }

            var payloads: [Data] { lock.lock()
                defer { lock.unlock() }
                return inputs
            }
        }
        let recorder = FrameRecorder()
        // Infinite send window: this test isolates the SPLIT (credit interplay is covered above).
        let dataCh = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: nil) { _, inner in
            recorder.ingest(inner)
        }
        let controlCh = MuxSubChannel(channelID: 1, channel: .control, sendWindowBytes: nil) { _, _ in }
        let transport = MuxClientTransport(
            acquire: { _, _, _, _ in MuxAcquisition(channelID: 1, data: dataCh, control: controlCh) },
            release: { _, _, _ in },
        )
        try await transport.connect(
            host: "h",
            port: 1,
            resume: WireMessage.newSessionID,
            lastReceivedSeq: 0,
            handshakeTimeout: .seconds(1),
        )

        var paste = Data()
        for i in 0..<(100 * 1024) { paste.append(UInt8(i % 251)) } // 100 KiB, non-repeating-ish
        try await transport.sendInput(paste)

        let frames = recorder.payloads
        XCTAssertGreaterThan(frames.count, 1, "a large paste splits into multiple .input frames")
        for frame in frames {
            XCTAssertLessThanOrEqual(
                frame.count,
                MuxFlowControl.maxDataMessagePayloadBytes,
                "every split frame stays within the payload cap",
            )
        }
        XCTAssertEqual(frames.reduce(Data(), +), paste, "split frames reassemble byte-identically in order")

        // A small keystroke stays ONE frame (the steady-state fast path).
        try await transport.sendInput(Data("a".utf8))
        XCTAssertEqual(recorder.payloads.last, Data("a".utf8))
        await transport.close()
    }

    // MARK: - Helpers

    private final class HostSideBox: @unchecked Sendable {
        private let lock = NSLock()
        private var channel: MuxSubChannel?
        func set(_ ch: MuxSubChannel) { lock.lock()
            channel = ch
            lock.unlock()
        }

        func get() -> MuxSubChannel? { lock.lock()
            defer { lock.unlock() }
            return channel
        }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { value = v }
        func get() -> Bool { lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ v: Bool) { lock.lock()
            value = v
            lock.unlock()
        }
    }
}
