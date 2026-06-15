import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Pins the Rust-backed video wire codecs (cursor / window-geometry / input-event) to their exact
/// on-wire byte layout. The Rust core is the single source of truth — there is no native Swift
/// codec to diff against any more — so these hand-computed vectors independently verify the Swift
/// FFI marshaling (field order + endianness) in BOTH directions. A round-trip test alone could miss
/// a *symmetric* marshaling bug (a field swapped on both encode and decode); a known vector cannot.
///
/// The `f64` constants are chosen to be power-of-two-exact so their big-endian IEEE-754 bytes are
/// transparent: 2.0=0x4000…, 1.0=0x3FF0…, 0.5=0x3FE0…, 0.25=0x3FD0….
final class RustCodecWireVectorTests: XCTestCase {
    // MARK: cursor

    func testCursorWireVector() throws {
        let update = CursorUpdate(
            position: VideoPoint(x: 2.0, y: 1.0),
            shapeID: 42,
            hotspot: VideoPoint(x: 0.5, y: 0.25),
            visible: true,
        )
        let expected: [UInt8] = [
            0x01, // type = cursorUpdate
            0x00, 0x2A, // shapeID 42 (u16 BE)
            0x01, // visible
            0x40, 0, 0, 0, 0, 0, 0, 0, // x = 2.0
            0x3F, 0xF0, 0, 0, 0, 0, 0, 0, // y = 1.0
            0x3F, 0xE0, 0, 0, 0, 0, 0, 0, // hotspotX = 0.5
            0x3F, 0xD0, 0, 0, 0, 0, 0, 0, // hotspotY = 0.25
        ]
        XCTAssertEqual(Array(update.encode()), expected)
        XCTAssertEqual(try CursorUpdate.decode(Data(expected)), update)
    }

    // MARK: window_geometry

    func testWindowGeometryWireVectors() throws {
        let cases: [(WindowGeometryMessage, [UInt8])] = [
            (
                .move(VideoPoint(x: 2.0, y: 1.0)),
                [0x01, 0x40, 0, 0, 0, 0, 0, 0, 0, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .resize(VideoSize(width: 0.5, height: 0.25)),
                [0x02, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0x3F, 0xD0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .bounds(VideoRect(x: 1.0, y: 2.0, width: 0.5, height: 0.25)),
                [
                    0x03,
                    0x3F,
                    0xF0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x40,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ],
            ),
            (.title("Hi"), [0x04, 0x48, 0x69]),
            (.title(""), [0x04]),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(Array(message.encode()), expected, "encode \(message)")
            XCTAssertEqual(try WindowGeometryMessage.decode(Data(expected)), message, "decode \(message)")
        }
    }

    // MARK: input_event

    func testInputEventWireVectors() throws {
        let cases: [(InputEvent, [UInt8])] = [
            (
                .mouseMove(normalized: VideoPoint(x: 0.5, y: 0.25), tag: 1),
                [0x01, 0, 0, 0, 1, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0x3F, 0xD0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .mouseDown(
                    button: .right,
                    normalized: VideoPoint(x: 0.5, y: 0.25),
                    clickCount: 2,
                    modifiers: [.shift, .command],
                    tag: 9,
                ),
                [
                    0x02,
                    0,
                    0,
                    0,
                    9,
                    0x01,
                    0x02,
                    0x09,
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ],
            ),
            (
                .scroll(
                    dx: 2.0,
                    dy: 1.0,
                    normalized: VideoPoint(x: 0.5, y: 0.25),
                    scrollPhase: 2,
                    momentumPhase: 0,
                    continuous: true,
                    tag: 7,
                ),
                [
                    0x04,
                    0,
                    0,
                    0,
                    7,
                    0x40,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // dx = 2.0
                    0x3F,
                    0xF0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // dy = 1.0
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // x = 0.5
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // y = 0.25
                    0x02,
                    0x00,
                    0x01,
                ],
            ), // scrollPhase, momentumPhase, continuous
            (
                .key(keyCode: 0x0035, down: true, modifiers: .option, tag: 4),
                [0x05, 0, 0, 0, 4, 0x00, 0x35, 0x01, 0x04],
            ),
            (.text("Hi", tag: 3), [0x06, 0, 0, 0, 3, 0x48, 0x69]),
        ]
        for (event, expected) in cases {
            XCTAssertEqual(Array(event.encode()), expected, "encode \(event)")
            XCTAssertEqual(try InputEvent.decode(Data(expected)), event, "decode \(event)")
        }
    }

    // MARK: video_control

    /// Pins the scalar video-control variants to their exact wire bytes — including the field order
    /// the FFI flattens (`hello` viewport `f64`s, `resizeAck` u16+u32, `streamCadence` u16).
    func testVideoControlScalarWireVectors() throws {
        let cases: [(VideoControlMessage, [UInt8])] = [
            // hello: type | protocolVersion u16 | requestedWindowID u32 | viewport.w f64 | .h f64
            (
                .hello(
                    protocolVersion: 0x0102,
                    requestedWindowID: 0x0304_0506,
                    viewport: VideoSize(width: 2.0, height: 0.5),
                ),
                [
                    0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
                    0x40, 0, 0, 0, 0, 0, 0, 0, // 2.0
                    0x3F, 0xE0, 0, 0, 0, 0, 0, 0, // 0.5
                ],
            ),
            // resizeAck: type | captureWidth u16 | captureHeight u16 | epoch u32
            (
                .resizeAck(captureWidth: 0x0102, captureHeight: 0x0304, epoch: 0x0506_0708),
                [0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
            ),
            // streamCadence: type | fps u16
            (.streamCadence(fps: 60), [0x0A, 0x00, 0x3C]),
            (.keepalive, [0x06]),
            (.bye, [0x03]),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(Array(message.encode()), expected, "encode \(message)")
            XCTAssertEqual(try VideoControlMessage.decode(Data(expected)), message, "decode \(message)")
        }
    }

    /// Pins the nested-array `windowList` / `systemDialogList` layout: `u16 count` then per record
    /// `u32 id | u16 w | u16 h | (u8 isSecure | u8 keystrokesBlocked) | lp name | lp title`. A known
    /// vector independently verifies the FFI record-array marshaling (field order across the
    /// boundary), which a round-trip alone could not catch if a field were swapped symmetrically —
    /// here especially the TWO adjacent dialog flag bytes (`isSecure` then `keystrokesBlocked`),
    /// pinned to DIFFERENT values so a swap would change the bytes.
    func testVideoControlListWireVectors() throws {
        let windowList = VideoControlMessage.windowList([
            WindowSummary(windowID: 1, appName: "Hi", title: "", width: 0x0102, height: 0x0304),
        ])
        let windowExpected: [UInt8] = [
            0x08, // type = windowList
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x01, // windowID
            0x01, 0x02, // width
            0x03, 0x04, // height
            0x00, 0x02, 0x48, 0x69, // appName len 2 + "Hi"
            0x00, 0x00, // title len 0
        ]
        XCTAssertEqual(Array(windowList.encode()), windowExpected)
        XCTAssertEqual(try VideoControlMessage.decode(Data(windowExpected)), windowList)

        // A secure-CLASS prompt that is still TYPABLE (isSecure=true, keystrokesBlocked=false) — the
        // `do shell script with administrator privileges` case. The two flag bytes differ (0x01 then
        // 0x00), so the vector catches a symmetric swap of the two.
        let dialogList = VideoControlMessage.systemDialogList([
            SystemDialogSummary(
                windowID: 1, owner: "Hi", title: "", width: 0x0102, height: 0x0304,
                isSecure: true, keystrokesBlocked: false,
            ),
        ])
        let dialogExpected: [UInt8] = [
            0x0C, // type = systemDialogList
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x01, // windowID
            0x01, 0x02, // width
            0x03, 0x04, // height
            0x01, // isSecure
            0x00, // keystrokesBlocked
            0x00, 0x02, 0x48, 0x69, // owner len 2 + "Hi"
            0x00, 0x00, // title len 0
        ]
        XCTAssertEqual(Array(dialogList.encode()), dialogExpected)
        XCTAssertEqual(try VideoControlMessage.decode(Data(dialogExpected)), dialogList)
    }

    // MARK: fuzz — arbitrary bytes must never crash the Rust-backed decoders.

    func testDecodersNeverCrashOnRandomBytes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let len = Int.random(in: 0...48, using: &rng)
            let data = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? CursorUpdate.decode(data)
            _ = try? WindowGeometryMessage.decode(data)
            _ = try? InputEvent.decode(data)
            _ = try? VideoControlMessage.decode(data)
        }
    }
}
