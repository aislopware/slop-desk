// AndroidBridgeServer — the host end of the right panel's Android surface.
//
// ## Why there is a bridge at all
//
// `adb forward` binds `127.0.0.1` and has no option not to. The device's frames therefore land on a
// loopback socket ON THE HOST, and a SlopDesk client is somewhere else on the mesh. Something has to
// carry them across, and this is it.
//
// The alternative was considered and rejected: `adb` can be told to serve on all interfaces
// (`adb -a server -H 0.0.0.0`), which would let the client speak the adb protocol itself and reach
// `localabstract:scrcpy_…` directly, with no relay in the middle. It is rejected because it is a
// MACHINE-WIDE change to how the user's `adb` runs, it hands every peer on the mesh a shell on every
// attached device rather than a mirror of one, and it needs the user to restart their adb server
// with special flags before the panel works at all. That is the same class of machine-wide setting
// the simulator panel already declined to flip on the user's behalf (`baguette lifetime --detach`).
//
// ## The protocol
//
// One TCP connection, one request. The client writes a single JSON object followed by `\n`; what
// happens next depends on `op`:
//
// | `op` | then |
// | --- | --- |
// | `list` | one JSON line back, connection closes |
// | `boot` / `shutdown` / `console` | one JSON line back, connection closes |
// | `logcat` | one JSON line back, then `logcat` output until the client hangs up |
// | `open` | one JSON line back, then **raw scrcpy bytes**: the stream down, control up |
//
// `open` is the shape worth explaining. After the ack this connection stops being a message
// protocol: the host pumps the device's video socket into it verbatim — codec id, session header,
// 12-byte frame headers and all — and pumps whatever the client sends back into the device's control
// socket verbatim. The host never parses either direction. That is only sound because
// ``AndroidScrcpySession`` disables clipboard autosync, which is what makes the control socket
// strictly one-way and leaves the downstream direction free for video alone.
//
// **No credential.** Same invariant as every other port hostd opens: security is the WireGuard mesh
// (`docs/DECISIONS.md`).

import Foundation

/// The bridge. One listener, one thread per connection.
///
/// Threads rather than a queue because every path in here blocks by design (see
/// ``AndroidSocketIO``), and a blocking pump on a shared queue starves everything behind it.
/// A panel drives at most a handful of connections — a list poll, a stream, a logcat — so the thread
/// count is bounded by what the user has open.
final class AndroidBridgeServer: @unchecked Sendable {
    private let toolchain: AndroidToolchain
    private let listener: AndroidListener
    private let lock = NSLock()
    private var sessions: [AndroidScrcpySession] = []
    private var isStopped = false

    var port: UInt16 { listener.port }

    init?(toolchain: AndroidToolchain) {
        guard let listener = AndroidListener() else { return nil }
        self.toolchain = toolchain
        self.listener = listener
    }

    /// Starts accepting. Returns immediately.
    func start() {
        let thread = Thread { [weak self] in
            while let self, !stopped, let client = listener.accept() {
                let worker = Thread { [weak self] in self?.serve(client) }
                worker.stackSize = 512 * 1024
                worker.start()
            }
        }
        thread.name = "slopdesk.android.bridge"
        thread.start()
    }

    /// Closes the listener and every live mirror session.
    ///
    /// Booted DEVICES are deliberately left running, for ``SimulatorServerManager/shutdown()``'s
    /// reason: an emulator the user started is their machine's state and outlives any one hostd run.
    func stop() {
        lock.lock()
        isStopped = true
        let live = sessions
        sessions.removeAll()
        lock.unlock()
        listener.close()
        for session in live { session.stop() }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    // MARK: - One connection

    private func serve(_ client: AndroidSocket) {
        guard let line = readRequestLine(client),
              let request = AndroidBridgeRequest.decode(line)
        else {
            reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
            client.close()
            return
        }

        switch request.op {
        case "list":
            reply(client, ["ok": true, "devices": deviceListPayload()])
            client.close()
        case "boot":
            let error = boot(avd: request.string("avd"))
            reply(client, error.map { ["ok": false, "error": $0.rawValue] } ?? ["ok": true])
            client.close()
        case "shutdown":
            let error = shutdown(serial: request.string("serial"))
            reply(client, error.map { ["ok": false, "error": $0.rawValue] } ?? ["ok": true])
            client.close()
        case "console":
            guard let serial = request.string("serial"), let command = request.string("command") else {
                reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
                client.close()
                return
            }
            let output = AndroidEmulatorConsole.run(command, serial: serial)
            reply(
                client,
                output.map { ["ok": true, "output": $0] }
                    ?? ["ok": false, "error": "The emulator console did not answer."],
            )
            client.close()
        case "screenshot":
            screenshot(client, request: request)
        case "logcat":
            streamLogcat(client, request: request)
        case "open":
            openMirror(client, request: request)
        default:
            reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
            client.close()
        }
    }

    /// Reads the request line byte by byte up to a hard cap.
    ///
    /// Byte-at-a-time because the very next bytes after the newline may be the client's first
    /// control messages, and a buffered read would swallow them into a buffer this function is about
    /// to discard. The cap makes a peer that never sends a newline a bounded mistake rather than an
    /// unbounded allocation.
    private func readRequestLine(_ client: AndroidSocket, limit: Int = 8192) -> Data? {
        var line = Data()
        while line.count < limit {
            guard let byte = client.readExactly(1), let first = byte.first else { return nil }
            if first == UInt8(ascii: "\n") { return line }
            line.append(first)
        }
        return nil
    }

    private func reply(_ client: AndroidSocket, _ payload: [String: Any]) {
        // `isValidJSONObject` first: `data(withJSONObject:)` raises an Objective-C exception rather
        // than throwing on a value it cannot encode, so `try?` alone would not save the bridge thread
        // from a field this server built wrong.
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        data.append(UInt8(ascii: "\n"))
        client.writeAll(data)
    }

    // MARK: - Device list

    /// The whole catalogue: attached targets folded with the AVDs on disk.
    private func deviceListPayload() -> [[String: Any]] {
        let listing = AndroidToolchain.adb(toolchain, ["devices", "-l"], timeout: 5) ?? ""
        var running: [AndroidDevice] = []
        for entry in AndroidDeviceCatalog.parseDevices(listing) {
            // A target that is `offline` or `unauthorized` cannot answer a shell, so it is recorded
            // from what `adb devices` alone said. Probing it would cost the poll its timeout.
            guard entry.state == "device" else {
                running.append(AndroidDevice(serial: entry.serial, state: entry.state))
                continue
            }
            let probe = AndroidToolchain.adb(
                toolchain, serial: entry.serial,
                ["shell", "getprop; echo \(Self.probeMarker); wm size; wm density"], timeout: 5,
            ) ?? ""
            let halves = probe.components(separatedBy: Self.probeMarker)
            let properties = AndroidDeviceCatalog.parseProperties(halves.first ?? "")
            let metrics = halves.count > 1 ? halves[1] : ""
            running.append(AndroidDeviceCatalog.device(
                serial: entry.serial, state: entry.state, properties: properties,
                size: AndroidDeviceCatalog.parseDisplaySize(metrics),
                density: AndroidDeviceCatalog.parseDensity(metrics),
            ))
        }
        return AndroidDeviceCatalog.merge(running: running, avds: availableAVDs())
            .map(Self.encode)
    }

    /// One `adb shell` round trip carries both halves; the marker splits them. Eight `getprop <key>`
    /// calls would be eight process spawns per device per poll.
    static let probeMarker = "--slopdesk-wm--"

    /// Every AVD on disk, read from its own `config.ini`. A host with no emulator binary simply has
    /// none — attached devices still list.
    private func availableAVDs() -> [AndroidDevice] {
        guard let emulator = toolchain.emulator,
              let output = AndroidToolchain.run(emulator, ["-list-avds"], timeout: 10)
        else { return [] }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return AndroidDeviceCatalog.parseAVDNames(output).compactMap { name in
            let path = home + "/.android/avd/" + name + ".avd/config.ini"
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(bytes: data, encoding: .utf8)
            else {
                // An AVD whose config cannot be read still exists and can still be booted; it just
                // has nothing but its name to show.
                return AndroidDevice(avdName: name, state: "offline")
            }
            let config = AndroidDeviceCatalog.parseConfig(text)
            return AndroidDeviceCatalog.device(avdName: name, config: config)
        }
    }

    static func encode(_ device: AndroidDevice) -> [String: Any] {
        var payload: [String: Any] = [
            "state": device.state,
            "key": device.key,
            "name": device.displayName,
            "isEmulator": device.isEmulator,
        ]
        if let serial = device.serial { payload["serial"] = serial }
        if let avdName = device.avdName { payload["avd"] = avdName }
        if let manufacturer = device.manufacturer { payload["manufacturer"] = manufacturer }
        if let model = device.model { payload["model"] = model }
        if let release = device.release { payload["release"] = release }
        if let apiLevel = device.apiLevel { payload["api"] = apiLevel }
        if let abi = device.abi { payload["abi"] = abi }
        if let width = device.width { payload["width"] = width }
        if let height = device.height { payload["height"] = height }
        if let density = device.density { payload["density"] = density }
        if let formFactor = device.formFactor { payload["formFactor"] = formFactor }
        return payload
    }

    // MARK: - Lifecycle verbs

    /// Boots an AVD **headless**. A SlopDesk host is a machine nobody is sitting at, so an emulator
    /// window there is a window the user will never see that steals focus from whoever is. The panel
    /// mirrors it instead. `SLOPDESK_ANDROID_EMULATOR_ARGS` appends flags for the host whose GPU
    /// needs `-gpu swiftshader_indirect` to run windowless.
    private func boot(avd: String?) -> AndroidBridgeError? {
        guard let avd, !avd.isEmpty else { return .badRequest }
        guard let emulator = toolchain.emulator else { return .emulatorMissing }
        let extra = ProcessInfo.processInfo.environment["SLOPDESK_ANDROID_EMULATOR_ARGS"]?
            .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulator)
        process.arguments = ["-avd", avd, "-no-window", "-no-boot-anim"] + extra
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Deliberately NOT waited on and deliberately not tracked: an emulator outlives the panel
        // that started it, and hostd restarting must not take the user's device down with it.
        do { try process.run() } catch { return .launchFailed }
        return nil
    }

    /// Shuts a device down. `adb emu kill` is the emulator's own clean exit; a physical device is
    /// not something this panel may power off, so it is refused rather than approximated with
    /// `reboot -p`.
    private func shutdown(serial: String?) -> AndroidBridgeError? {
        guard let serial, !serial.isEmpty else { return .badRequest }
        guard AndroidEmulatorConsole.port(forSerial: serial) != nil else { return .unknownDevice }
        guard AndroidToolchain.adb(toolchain, serial: serial, ["emu", "kill"], timeout: 10) != nil
        else { return .unknownDevice }
        return nil
    }

    // MARK: - Screenshot

    /// One capture of the device's screen, as a PNG.
    ///
    /// ON DEMAND ONLY, and the measurement is why. `adb exec-out screencap -p` against this host's
    /// emulator, 2026-08-04: **300 KB in ~250 ms**, three times over. There is no scale or quality
    /// argument — `screencap` renders the framebuffer at native size and PNG-encodes it ON THE DEVICE
    /// — so the 250 ms is the device's CPU, not the link's. The simulator panel polls its server's
    /// `screenshot.jpg?scale=6&quality=0.5` at 13.5 KB in 22 ms and can afford a card that refreshes
    /// every two seconds; the same cadence here would be 150 KB/s and an eighth of a phone's core per
    /// listed device, for a thumbnail. So the Android list draws facts instead — which it has, and the
    /// simulator list did not — and a picture is taken when somebody asks for one.
    ///
    /// The reply names the byte count and the bytes follow it, rather than riding the JSON as base64:
    /// a 4K tablet's capture is several megabytes, and base64 would add a third to that and force the
    /// client to buffer the whole line before it could see the length.
    private func screenshot(_ client: AndroidSocket, request: AndroidBridgeRequest) {
        guard let serial = request.string("serial") else {
            reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
            client.close()
            return
        }
        // `exec-out` rather than `shell`: `shell` allocates a pty on some transports and translates
        // `\n` to `\r\n`, which rewrites every 0x0A byte inside the PNG.
        let png = AndroidToolchain.capture(
            toolchain.adb, ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 20, mergesStandardError: false,
        )
        guard let png, png.count > 8, png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else {
            reply(client, ["ok": false, "error": "The device did not return a screenshot."])
            client.close()
            return
        }
        reply(client, ["ok": true, "bytes": png.count])
        client.writeAll(png)
        client.close()
    }

    // MARK: - logcat

    /// Streams `logcat` until the client hangs up.
    ///
    /// A separate connection from the mirror, for the reason `docs/47` gives for keeping the
    /// simulator's log socket separate from its stream: the console opens and closes while the
    /// stream stays up, and a log subscription that died with a video reconnect would lose the
    /// output covering the moment being investigated.
    private func streamLogcat(_ client: AndroidSocket, request: AndroidBridgeRequest) {
        guard let serial = request.string("serial") else {
            reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
            client.close()
            return
        }
        // `*:<level>` is logcat's own filter spec. The level is validated against a closed set
        // rather than interpolated: this string reaches an argument vector.
        let requested = request.string("level") ?? ""
        let level = Self.logcatLevels.contains(requested) ? requested : "I"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolchain.adb)
        // `-v time` gives each line its own timestamp; `-T 200` starts with the last 200 lines so a
        // console opened after the interesting moment still shows it.
        process.arguments = ["-s", serial, "logcat", "-v", "time", "-T", "200", "*:\(level)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            reply(client, ["ok": false, "error": "Could not start logcat."])
            client.close()
            return
        }
        reply(client, ["ok": true])

        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard client.writeAll(chunk) else { break }
        }
        if process.isRunning { process.terminate() }
        client.close()
    }

    /// logcat's priority letters, least severe first. A level outside this set would be interpolated
    /// into an argument vector, and `logcat` treats an unparsable filter spec as a fatal error.
    static let logcatLevels: Set<String> = ["V", "D", "I", "W", "E", "F"]

    // MARK: - The mirror

    /// Starts a mirror session and becomes its byte pump.
    private func openMirror(_ client: AndroidSocket, request: AndroidBridgeRequest) {
        guard let serial = request.string("serial") else {
            reply(client, ["ok": false, "error": AndroidBridgeError.badRequest.rawValue])
            client.close()
            return
        }
        var options = AndroidScrcpySession.Options()
        if let maxSize = request.int("maxSize"), maxSize >= 320, maxSize <= 4096 {
            options.maxSize = maxSize
        }
        if let bitRate = request.int("bitRate"), bitRate >= 200_000, bitRate <= 50_000_000 {
            options.bitRate = bitRate
        }
        if let codec = request.string("codec"), ["h264", "h265", "av1"].contains(codec) {
            options.codec = codec
        }

        let started = AndroidScrcpySession.start(
            toolchain: toolchain, serial: serial, options: options,
        )
        guard case let .success(session) = started else {
            let error: AndroidBridgeError =
                if case let .failure(failure) = started { failure }
                else { .serverDidNotStart }
            reply(client, ["ok": false, "error": error.rawValue])
            client.close()
            return
        }

        lock.lock()
        sessions.append(session)
        lock.unlock()

        reply(client, ["ok": true, "device": session.deviceName])

        // Upstream on its own thread; downstream on this one. Whichever direction ends first closes
        // the sockets, which unblocks the other out of its `read` — no cancellation flag to poll.
        let upstream = Thread { [weak self] in
            while let chunk = client.read(upTo: 64 * 1024) {
                guard session.control.writeAll(chunk) else { break }
            }
            self?.finish(session, client: client)
        }
        upstream.name = "slopdesk.android.control"
        upstream.start()

        while let chunk = session.video.read(upTo: 256 * 1024) {
            guard client.writeAll(chunk) else { break }
        }
        finish(session, client: client)
    }

    private func finish(_ session: AndroidScrcpySession, client: AndroidSocket) {
        session.stop()
        client.close()
        lock.lock()
        sessions.removeAll { $0 === session }
        lock.unlock()
    }
}

/// One decoded bridge request. Deliberately untyped past `op`: the fields differ per operation, and
/// a `Codable` union over six shapes is more ceremony than three accessors.
///
/// Validate-then-drop, like every other decoder in the project that reads bytes it did not write:
/// a malformed request yields `nil` and the connection is answered with an error, never a trap.
struct AndroidBridgeRequest {
    let op: String
    private let fields: [String: Any]

    static func decode(_ line: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let fields = object as? [String: Any],
              let op = fields["op"] as? String, !op.isEmpty
        else { return nil }
        return Self(op: op, fields: fields)
    }

    func string(_ key: String) -> String? {
        (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Both spellings, because `JSONSerialization` decides between them from the literal's own
    /// syntax: `5` arrives as an integer and `5.0` as a double, and a client that wrote a coordinate
    /// out with a trailing zero should not lose it.
    func int(_ key: String) -> Int? {
        if let value = fields[key] as? Int { return value }
        guard let value = fields[key] as? Double, value.isFinite,
              value >= Double(Int32.min), value <= Double(Int32.max)
        else { return nil }
        return Int(value)
    }
}
