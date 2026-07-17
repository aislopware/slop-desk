import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the host→client app-audio datagrams (media channel tag 6): fixed 11-byte
/// big-endian header (`seq | hostSendTsMillis | flags | payloadLen`) + payload, flags bit0
/// selecting the config grammar. Pattern of StreamSettingsCodecTests: round-trip across
/// extremes + exact wire layout + truncation ladder + hostile-length and unknown-format
/// rejection. Reserved flag bits (1–7) must decode INERTLY — the forward-compatibility
/// contract for a future sender.
final class AudioWireCodecTests: XCTestCase {
    /// Builds a raw datagram byte-by-byte (independent of the encoder under test) so the
    /// hostile-input probes can express layouts `encode()` would never produce.
    private func rawDatagram(
        seq: UInt32 = 0, ts: UInt32 = 0, flags: UInt8, payloadLen: UInt16, payload: [UInt8],
    ) -> Data {
        var out = Data()
        out.appendBE(seq)
        out.appendBE(ts)
        out.append(flags)
        out.appendBE(payloadLen)
        out.append(contentsOf: payload)
        return out
    }

    // MARK: Round-trips

    func testFrameRoundTripAcrossExtremes() throws {
        let probes: [(UInt32, UInt32, Data)] = [
            (0, 0, Data()), // zero-length frame (degenerate but well-formed)
            (7, 250, Data([0xAA, 0xBB, 0xCC])), // typical small access unit
            (3, 1000, Data(repeating: 0x5A, count: 1920)), // one PCM frame: 480 samples × 2ch × 2B
            (UInt32.max, UInt32.max, Data(repeating: 0xFF, count: AudioChannelMessage.maxPayloadBytes)),
        ]
        for (seq, ts, payload) in probes {
            let msg = AudioChannelMessage.frame(seq: seq, hostSendTsMillis: ts, payload: payload)
            XCTAssertEqual(try AudioChannelMessage.decode(msg.encode()), msg)
        }
    }

    func testConfigRoundTripAcrossExtremes() throws {
        let probes: [AudioStreamConfig] = [
            AudioStreamConfig(format: .aacEld, sampleRate: 48000, channels: 2, cookie: Data([0xDE, 0xAD])),
            AudioStreamConfig(format: .pcmS16LE, sampleRate: 48000, channels: 2, cookie: Data()),
            AudioStreamConfig( // wire extremes — the codec carries them verbatim
                format: .aacEld, sampleRate: UInt32.max, channels: UInt8.max,
                cookie: Data(repeating: 0xC0, count: 64),
            ),
        ]
        for config in probes {
            let msg = AudioChannelMessage.config(seq: 9, hostSendTsMillis: 42, config: config)
            XCTAssertEqual(try AudioChannelMessage.decode(msg.encode()), msg)
        }
    }

    // MARK: Exact wire layout

    func testFrameWireLayoutIsSeqTsFlagsLenPayload() {
        XCTAssertEqual(AudioChannelMessage.headerSize, 11)
        let msg = AudioChannelMessage.frame(seq: 7, hostSendTsMillis: 0x0102_0304, payload: Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(
            msg.encode(),
            Data([
                0x00, 0x00, 0x00, 0x07, // UInt32 BE seq
                0x01, 0x02, 0x03, 0x04, // UInt32 BE hostSendTsMillis
                0x00, // flags: frame (bit0 clear, reserved bits encode 0)
                0x00, 0x03, // UInt16 BE payloadLen
                0xAA, 0xBB, 0xCC, // payload
            ]),
            "fixed 11-byte big-endian header, payload immediately after its length",
        )
    }

    func testConfigWireLayoutNestsFormatRateChannelsCookie() {
        let msg = AudioChannelMessage.config(
            seq: 1,
            hostSendTsMillis: 250,
            config: AudioStreamConfig(format: .aacEld, sampleRate: 48000, channels: 2, cookie: Data([0xDE, 0xAD])),
        )
        XCTAssertEqual(
            msg.encode(),
            Data([
                0x00, 0x00, 0x00, 0x01, // UInt32 BE seq
                0x00, 0x00, 0x00, 0xFA, // UInt32 BE hostSendTsMillis
                0x01, // flags: config (bit0)
                0x00, 0x0A, // UInt16 BE payloadLen (10-byte config payload)
                0x01, // formatID aacEld
                0x00, 0x00, 0xBB, 0x80, // UInt32 BE sampleRate 48000
                0x02, // channels
                0x00, 0x02, // UInt16 BE cookieLen
                0xDE, 0xAD, // cookie
            ]),
            "config payload = formatID | sampleRate | channels | cookieLen | cookie",
        )
    }

    // MARK: Truncation

    /// Every strict prefix of a valid datagram THROWS `.truncated` — bounds-checked decode,
    /// never an over-read or a crash (validate-then-drop).
    func testTruncationLadderThrowsTruncated() {
        for full in [
            AudioChannelMessage.frame(seq: 7, hostSendTsMillis: 0x0102_0304, payload: Data([0xAA, 0xBB, 0xCC]))
                .encode(),
            AudioChannelMessage.config(
                seq: 1, hostSendTsMillis: 250,
                config: AudioStreamConfig(format: .aacEld, sampleRate: 48000, channels: 2, cookie: Data([0xDE, 0xAD])),
            ).encode(),
        ] {
            for length in 0..<full.count {
                XCTAssertThrowsError(try AudioChannelMessage.decode(full.prefix(length))) { error in
                    guard case VideoProtocolError.truncated = error else {
                        return XCTFail("prefix \(length)/\(full.count) must throw .truncated, got \(error)")
                    }
                }
            }
        }
    }

    /// A cookie length pointing past the (consistent) payload end is a short CONFIG body —
    /// `.truncated` from the inner grammar, not an over-read.
    func testConfigCookieLenPastPayloadEndThrowsTruncated() {
        let payload: [UInt8] = [0x01, 0x00, 0x00, 0xBB, 0x80, 0x02, 0x00, 0x05, 0xDE, 0xAD] // cookieLen 5, 2 present
        let datagram = rawDatagram(flags: 0x01, payloadLen: UInt16(payload.count), payload: payload)
        XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
            guard case VideoProtocolError.truncated = error else {
                return XCTFail("short cookie must throw .truncated, got \(error)")
            }
        }
    }

    // MARK: Hostile lengths

    func testOversizePayloadLenThrowsMalformed() {
        let over = AudioChannelMessage.maxPayloadBytes + 1
        let datagram = rawDatagram(flags: 0, payloadLen: UInt16(over), payload: [UInt8](repeating: 0, count: over))
        XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("payloadLen past the 8192 cap must throw .malformed, got \(error)")
            }
        }
    }

    func testPayloadLenShortOfDatagramEndThrowsMalformed() {
        // payloadLen must consume the datagram EXACTLY — trailing bytes are corruption/hostile.
        let datagram = rawDatagram(flags: 0, payloadLen: 3, payload: [1, 2, 3, 4, 5])
        XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("trailing bytes must throw .malformed, got \(error)")
            }
        }
    }

    func testConfigCookieLenShortOfPayloadEndThrowsMalformed() {
        // cookieLen must consume the config payload EXACTLY (the outer length already matches).
        let payload: [UInt8] = [0x01, 0x00, 0x00, 0xBB, 0x80, 0x02, 0x00, 0x01, 0xDE, 0xAD] // cookieLen 1, 2 present
        let datagram = rawDatagram(flags: 0x01, payloadLen: UInt16(payload.count), payload: payload)
        XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("trailing cookie bytes must throw .malformed, got \(error)")
            }
        }
    }

    // MARK: Config grammar rejection

    func testUnknownFormatIDThrowsMalformed() {
        let payload: [UInt8] = [0x03, 0x00, 0x00, 0xBB, 0x80, 0x02, 0x00, 0x00] // formatID 3 undefined
        let datagram = rawDatagram(flags: 0x01, payloadLen: UInt16(payload.count), payload: payload)
        XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown formatID must throw .malformed, got \(error)")
            }
        }
    }

    func testZeroSampleRateOrChannelsThrowsMalformed() {
        let zeroRate: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00]
        let zeroChannels: [UInt8] = [0x01, 0x00, 0x00, 0xBB, 0x80, 0x00, 0x00, 0x00]
        for payload in [zeroRate, zeroChannels] {
            let datagram = rawDatagram(flags: 0x01, payloadLen: UInt16(payload.count), payload: payload)
            XCTAssertThrowsError(try AudioChannelMessage.decode(datagram)) { error in
                guard case VideoProtocolError.malformed = error else {
                    return XCTFail("degenerate config must throw .malformed, got \(error)")
                }
            }
        }
    }

    // MARK: Reserved-flags tolerance

    /// Bits 1–7 of the flags byte are reserved: a future sender may set them and THIS decoder
    /// must ignore them — only bit0 selects the payload grammar.
    func testReservedFlagBitsDecodeInertly() throws {
        let frameBits = rawDatagram(seq: 7, ts: 9, flags: 0b1111_1110, payloadLen: 2, payload: [0xAA, 0xBB])
        XCTAssertEqual(
            try AudioChannelMessage.decode(frameBits),
            .frame(seq: 7, hostSendTsMillis: 9, payload: Data([0xAA, 0xBB])),
            "bit0 clear ⇒ frame, regardless of reserved bits",
        )
        let configPayload: [UInt8] = [0x02, 0x00, 0x00, 0xBB, 0x80, 0x02, 0x00, 0x00]
        let configBits = rawDatagram(
            seq: 8, ts: 10, flags: 0b1111_1111, payloadLen: UInt16(configPayload.count), payload: configPayload,
        )
        XCTAssertEqual(
            try AudioChannelMessage.decode(configBits),
            .config(
                seq: 8, hostSendTsMillis: 10,
                config: AudioStreamConfig(format: .pcmS16LE, sampleRate: 48000, channels: 2, cookie: Data()),
            ),
            "bit0 set ⇒ config, regardless of reserved bits",
        )
    }
}
