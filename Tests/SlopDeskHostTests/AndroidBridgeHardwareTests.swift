// AndroidBridgeHardwareTests — the Android path's dedicated gate (`scripts/check-android.sh`).
//
// These do NOT run under `make test`: they need a booted Android device or emulator, an `adb`, and a
// `scrcpy-server` jar. `docs/46-gates-env-paths.md` is where each path's gate is recorded; this one
// is `SLOPDESK_ANDROID_HW=1`. Without it every test here returns early, so a clean checkout stays
// green on a machine that has never seen the Android SDK.
//
// They are also the only place the bridge's SOCKETS are exercised — the parser tests beside them
// cover everything that is pure, and the hang-safety rule keeps real connections out of `make test`.

import Foundation
import XCTest
@testable import SlopDeskHost

final class AndroidBridgeHardwareTests: XCTestCase {
    /// The gate. Off ⇒ every test here is a no-op.
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SLOPDESK_ANDROID_HW"] == "1"
    }

    private func makeBridge() throws -> AndroidBridgeServer {
        guard let toolchain = AndroidToolchain.locate() else {
            throw XCTSkip("no adb on this host")
        }
        guard let bridge = AndroidBridgeServer(toolchain: toolchain) else {
            throw XCTSkip("could not bind a bridge port")
        }
        bridge.start()
        return bridge
    }

    /// One request/response round trip against the bridge, as a client would make it.
    private func request(_ payload: [String: Any], port: UInt16) throws -> [String: Any] {
        let socket = try XCTUnwrap(AndroidSocket.connectLoopback(port: port, timeout: 5))
        defer { socket.close() }
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(UInt8(ascii: "\n"))
        XCTAssertTrue(socket.writeAll(line))

        var response = Data()
        while let byte = socket.readExactly(1), let first = byte.first, first != UInt8(ascii: "\n") {
            response.append(first)
            if response.count > 1 << 20 { break }
        }
        let object = try JSONSerialization.jsonObject(with: response)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testListsTheHostsDevices() throws {
        try XCTSkipUnless(isEnabled, "SLOPDESK_ANDROID_HW=1 not set")
        let bridge = try makeBridge()
        defer { bridge.stop() }

        let reply = try request(["op": "list"], port: bridge.port)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let devices = try XCTUnwrap(reply["devices"] as? [[String: Any]])
        XCTAssertFalse(devices.isEmpty, "expected at least one AVD or attached device")

        // Every row must carry the two things the panel titles and selects on, whatever its state.
        for device in devices {
            XCTAssertNotNil(device["name"] as? String)
            XCTAssertNotNil(device["key"] as? String)
            XCTAssertNotNil(device["state"] as? String)
        }
        // An AVD on disk knows its own screen even when it has never booted — the fact the iOS panel
        // could not have. If this ever fails, the list has lost its subject for shut-down rows.
        if let avd = devices.first(where: { ($0["isEmulator"] as? Bool) == true }) {
            XCTAssertNotNil(avd["width"] as? Int)
            XCTAssertNotNil(avd["density"] as? Int)
        }
    }

    /// The whole mirror path: handshake, codec id, session header, then real H.264.
    func testOpensAMirrorAndReceivesDecodableFrames() throws {
        try XCTSkipUnless(isEnabled, "SLOPDESK_ANDROID_HW=1 not set")
        let bridge = try makeBridge()
        defer { bridge.stop() }

        let list = try request(["op": "list"], port: bridge.port)
        let devices = try XCTUnwrap(list["devices"] as? [[String: Any]])
        guard let running = devices.first(where: { ($0["state"] as? String) == "device" }),
              let serial = running["serial"] as? String
        else { throw XCTSkip("no booted device — `emulator -avd <name> -no-window` first") }

        let socket = try XCTUnwrap(AndroidSocket.connectLoopback(port: bridge.port, timeout: 5))
        defer { socket.close() }
        var line = try JSONSerialization.data(
            withJSONObject: ["op": "open", "serial": serial, "maxSize": 1024],
        )
        line.append(UInt8(ascii: "\n"))
        XCTAssertTrue(socket.writeAll(line))

        var ack = Data()
        while let byte = socket.readExactly(1), let first = byte.first, first != UInt8(ascii: "\n") {
            ack.append(first)
        }
        let acked = try XCTUnwrap(try JSONSerialization.jsonObject(with: ack) as? [String: Any])
        XCTAssertEqual(acked["ok"] as? Bool, true, "open failed: \(acked["error"] ?? "?")")

        // From here the connection is raw scrcpy. The codec id is four ASCII bytes.
        let codec = try XCTUnwrap(socket.readExactly(4))
        XCTAssertEqual(String(bytes: codec, encoding: .utf8), "h264")

        // Then exactly one session header: MSB set, width and height big-endian at 4 and 8.
        let session = try XCTUnwrap(socket.readExactly(12))
        XCTAssertEqual(session[0] & 0x80, 0x80, "expected a session header")
        let width = session[4...7].reduce(0) { $0 << 8 | Int($1) }
        let height = session[8...11].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
        // `max_size` genuinely bites here, unlike the simulator server's ignored `scale`.
        XCTAssertLessThanOrEqual(max(width, height), 1024)

        // The first media packet must be the config packet — SPS/PPS in Annex-B, which is what the
        // client's format description is built from. Its start code proves the framing is Annex-B
        // and NOT the AVCC the simulator panel receives.
        var sawConfig = false
        var sawKeyframe = false
        for _ in 0..<40 {
            guard let header = socket.readExactly(12) else { break }
            if header[0] & 0x80 != 0 { continue }
            let flags = header[0]
            let length = header[8...11].reduce(0) { $0 << 8 | Int($1) }
            XCTAssertGreaterThan(length, 0)
            let payload = try XCTUnwrap(socket.readExactly(length))
            if flags & 0x40 != 0 {
                sawConfig = true
                XCTAssertEqual(Array(payload.prefix(4)), [0, 0, 0, 1], "config must be Annex-B")
                XCTAssertEqual(payload[4] & 0x1F, 7, "first NAL of the config must be an SPS")
            }
            if flags & 0x20 != 0 { sawKeyframe = true }
            if sawConfig, sawKeyframe { break }
        }
        XCTAssertTrue(sawConfig, "no config packet — the client would have no format description")
        XCTAssertTrue(sawKeyframe, "no keyframe — the client would decode nothing")
    }

    /// The emulator console is the panel's route to GPS, battery and rotation. It answers only for
    /// emulators, which is why the panel offers those verbs on emulator rows alone.
    func testEmulatorConsoleAnswers() throws {
        try XCTSkipUnless(isEnabled, "SLOPDESK_ANDROID_HW=1 not set")
        let bridge = try makeBridge()
        defer { bridge.stop() }

        let list = try request(["op": "list"], port: bridge.port)
        let devices = try XCTUnwrap(list["devices"] as? [[String: Any]])
        guard let emulator = devices.first(where: {
            ($0["state"] as? String) == "device" && ($0["isEmulator"] as? Bool) == true
        }), let serial = emulator["serial"] as? String else {
            throw XCTSkip("no booted emulator")
        }

        let reply = try request(
            ["op": "console", "serial": serial, "command": "avd name"], port: bridge.port,
        )
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let output = try XCTUnwrap(reply["output"] as? String)
        XCTAssertTrue(output.contains("OK"), "console said: \(output)")
    }

    /// A malformed first line is answered and the connection closed — never a trap, never a hang.
    func testMalformedRequestIsAnswered() throws {
        try XCTSkipUnless(isEnabled, "SLOPDESK_ANDROID_HW=1 not set")
        let bridge = try makeBridge()
        defer { bridge.stop() }

        let socket = try XCTUnwrap(AndroidSocket.connectLoopback(port: bridge.port, timeout: 5))
        defer { socket.close() }
        XCTAssertTrue(socket.writeAll(Data("this is not json\n".utf8)))
        var response = Data()
        while let byte = socket.readExactly(1), let first = byte.first, first != UInt8(ascii: "\n") {
            response.append(first)
        }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response) as? [String: Any],
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertNotNil(object["error"] as? String)
    }
}
