// AndroidEmulatorConsole — the emulator's own telnet control channel.
//
// Every running AVD listens on `127.0.0.1:<console port>`, where the port is the number in its
// `adb` serial (`emulator-5554` → 5554). It is a line protocol: a greeting, then `auth <token>`
// with the token from `~/.emulator_console_auth_token`, then commands, each answered by output and
// a bare `OK` or `KO: …`.
//
// **Why this and not the emulator's gRPC service.** The emulator also exposes `-grpc <port>`, whose
// `EmulatorController` covers the same ground. It was rejected for the video path first — its
// `streamScreenshot` returns PNG or raw RGB888 frames, which at 1080×2400 is megabytes per frame,
// and the WebRTC alternative needs a `goldfish-webrtc-bridge` binary that ships only in Google's
// container images, not in the public SDK. Having chosen `scrcpy` for frames, gRPC's remaining value
// is control — and paying for grpc-swift plus SwiftProtobuf to reach a feature set this text
// protocol already covers would put two large dependencies into a project whose clean checkout
// builds headless with none.
//
// What it buys the panel, verified against a live AVD on 2026-08-04: `geo fix <lon> <lat>`,
// `rotate`, `power capacity <n>`, `sms send`, `gsm`, `network` (speed/latency shaping), `fold` /
// `unfold`, `sensor set`, `finger touch`. It answers only for EMULATORS — a physical device has no
// console, which is why the panel offers these verbs on emulator rows alone.

import Foundation

enum AndroidEmulatorConsole {
    /// The console port carried by an emulator's serial, or `nil` for a physical device's serial.
    static func port(forSerial serial: String) -> UInt16? {
        guard serial.hasPrefix("emulator-") else { return nil }
        return UInt16(serial.dropFirst("emulator-".count))
    }

    /// The shared auth token. Read fresh per session rather than cached: the emulator rewrites it,
    /// and a cached token survives into a run where it is wrong.
    static func authToken(
        home: String = NSHomeDirectory(), fileManager: FileManager = .default,
    ) -> String? {
        let path = home + "/.emulator_console_auth_token"
        guard let data = fileManager.contents(atPath: path),
              let text = String(bytes: data, encoding: .utf8)
        else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Runs one command and returns everything the console said before its verdict line.
    ///
    /// Blocking, like the rest of the bridge. `nil` means the console could not be reached or
    /// refused the token; a `KO: …` verdict is returned as text, because the console's own
    /// complaint ("KO: unknown command") is a better message than any this layer could invent.
    static func run(_ command: String, serial: String, timeout: TimeInterval = 3) -> String? {
        guard let port = port(forSerial: serial), let token = authToken(),
              let socket = AndroidSocket.connectLoopback(port: port, timeout: timeout)
        else { return nil }
        defer { socket.close() }

        // The greeting arrives unprompted and has no fixed length, so it is drained by reading until
        // the console falls quiet rather than by counting bytes.
        _ = drain(socket)
        guard socket.writeAll(Data("auth \(token)\n".utf8)) else { return nil }
        guard let authReply = drain(socket), authReply.contains("OK") else { return nil }

        guard socket.writeAll(Data((command + "\n").utf8)) else { return nil }
        return drain(socket)
    }

    /// Reads until the console stops talking. The socket carries a receive timeout from
    /// ``AndroidSocket/connectLoopback(port:timeout:)``, so a console that says nothing more ends
    /// this loop instead of parking the thread — which is the whole reason the reply is not parsed
    /// for a terminator: `help` ends with a bare command name, and `sensor status` ends with a line
    /// that has no verdict at all.
    private static func drain(_ socket: AndroidSocket) -> String? {
        var collected = Data()
        while let chunk = socket.read(upTo: chunkSize) {
            collected.append(chunk)
            if collected.count > 256 * 1024 { break }
            // A verdict line ends a well-formed reply; the timeout ends every other kind. Matched on
            // BYTES rather than on a decoded string: the tail of a chunk can split a multi-byte
            // sequence, and re-decoding the whole buffer per chunk is quadratic in a reply that can
            // run to a quarter of a megabyte.
            if endsWithVerdict(collected) { break }
        }
        guard !collected.isEmpty else { return nil }
        // Lossy: the console echoes whatever a command printed, and a reply that survived the
        // handshake must reach the caller even if one byte of it is not UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: collected, as: UTF8.self)
    }

    /// Whether the reply has reached its verdict. `KO` is looked for over the NEWEST bytes only: the
    /// verdict is the last thing the console says, so a window covering the chunk just appended plus
    /// the boundary it may straddle sees everything a whole-buffer scan would.
    private static func endsWithVerdict(_ data: Data) -> Bool {
        let tail = data.suffix(chunkSize + 4)
        if tail.suffix(4).elementsEqual(Data("OK\r\n".utf8)) { return true }
        if tail.suffix(3).elementsEqual(Data("OK\n".utf8)) { return true }
        return tail.contains(Data("\nKO".utf8))
    }

    private static let chunkSize = 8192
}
