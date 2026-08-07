// AndroidScrcpySession — starting one device's `scrcpy-server` and handing back its two sockets.
//
// The dialect below was measured against `scrcpy-server` v4.1 on 2026-08-04, and the byte-level
// claims are what `docs/48-android-panel.md` records. `scrcpy` publishes no wire specification —
// its own documentation says the protocol is defined by the unit tests on both sides — so the
// version string is pinned and the jar is located rather than guessed at.
//
// ## The launch, in order
//
// ```
// adb -s S push <jar> /data/local/tmp/scrcpy-server.jar
// adb -s S forward tcp:0 localabstract:scrcpy_<scid>      → prints the allocated port
// adb -s S shell CLASSPATH=/data/local/tmp/scrcpy-server.jar \
//        app_process / com.genymobile.scrcpy.Server 4.1 scid=<scid> …
// connect 127.0.0.1:<port>  → read ONE byte   (the video socket)
// connect 127.0.0.1:<port>  →                 (the control socket)
// read 64 bytes off the video socket          (the device name)
// adb -s S forward --remove tcp:<port>
// ```
//
// ⚠️ **The 64-byte device name is written only after EVERY expected socket has connected.** Reading
// it straight after the dummy byte hangs forever against a healthy server — measured, and it looks
// exactly like a server that failed to start.
//
// ⚠️ **Push the jar every session.** It costs milliseconds over `adb` and it is the only defence
// against a stale optimised-dex cache in `/data/local/tmp/oat`, which makes `app_process` die with
// the single word `Aborted` — no stack, no scrcpy log line, nothing in `logcat`. Measured
// 2026-08-04: two hours of a working setup became an unexplained abort, and re-pushing fixed it.
//
// ## `clipboard_autosync=false` is load-bearing, not a preference
//
// The bridge gives the client ONE full-duplex connection: scrcpy's video stream flows down it and
// scrcpy's control messages flow up it. That works only because the control socket is, under these
// options, strictly client→device. scrcpy's server has exactly three device→client messages —
// clipboard, clipboard-ack and UHID output — and each is reachable only from a request this bridge
// never makes: autosync (disabled here), an explicit `GET_CLIPBOARD`, a `SET_CLIPBOARD` carrying a
// non-zero sequence, and UHID. Leave autosync on and the device will spontaneously write a clipboard
// message into a stream the client is parsing as H.264.

import Foundation

/// A running `scrcpy-server` and the two sockets it is speaking through.
final class AndroidScrcpySession: @unchecked Sendable {
    /// Frames down. Positioned at the codec id — the 64-byte device name has been consumed.
    let video: AndroidSocket
    /// Control messages up. Nothing ever comes back down it (see the file comment).
    let control: AndroidSocket
    /// The device's own name for itself, off the handshake.
    let deviceName: String
    private let process: Process
    private let lock = NSLock()
    private var isTornDown = false

    private init(video: AndroidSocket, control: AndroidSocket, deviceName: String, process: Process) {
        self.video = video
        self.control = control
        self.deviceName = deviceName
        self.process = process
    }

    /// Options the panel varies per session. Everything else is fixed by the invariants above.
    struct Options: Sendable {
        /// The longer edge, in pixels. **This flag genuinely bites**, unlike the simulator server's
        /// ignored `scale` — measured 1080×2400 → 460×1024, which also doubled the frame rate
        /// (13.7 → 25.3 fps) because an emulator has only SOFTWARE encoders and is encoder-bound.
        var maxSize: Int = 1024
        /// Encoder target. Measured ~2.4 Mbit/s under a continuous drag at 460×1024.
        var bitRate: Int = 4_000_000
        /// H.264 and nothing else, by default and on purpose. Measured on this emulator: H.265 at
        /// the same size ran at 11.3 fps against H.264's 25.3, because `c2.android.hevc.encoder` is
        /// software and costs more per frame than the bytes it saves are worth on a mesh. A physical
        /// device with a hardware HEVC encoder would flip that, which is why it is a field.
        var codec: String = "h264"
    }

    /// Launches the server and completes the handshake, or returns `nil` with a reason.
    ///
    /// Runs entirely on the calling thread and blocks — call it from the bridge's per-connection
    /// thread, never from a queue that answers anything.
    static func start(
        toolchain: AndroidToolchain, serial: String, options: Options,
    ) -> Result<AndroidScrcpySession, AndroidBridgeError> {
        guard let jar = toolchain.scrcpyServerJar else { return .failure(.scrcpyServerMissing) }

        // A random id per session so two clients driving two devices cannot collide on the abstract
        // socket name, and so a previous session's orphaned server is never mistaken for this one.
        //
        // ⚠️ The top bit must be CLEAR. The server reads this with `Integer.parseInt(s, 16)`, which
        // is SIGNED, so anything from `80000000` up dies with `NumberFormatException: For input
        // string: "…" under radix 16` — on the device, into a log this bridge discards, leaving a
        // launch that simply never answers. Measured 2026-08-04: a full-width `UInt32` fails for
        // half of all sessions, which reads as a flaky panel rather than a bug.
        let scid = String(format: "%08x", UInt32.random(in: 0...0x7FFF_FFFF))

        guard AndroidToolchain.adb(
            toolchain, serial: serial, ["push", jar, deviceJarPath], timeout: 60,
        ) != nil else { return .failure(.pushFailed) }

        guard let forwardOutput = AndroidToolchain.adb(
            toolchain, serial: serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"],
        ), let port = UInt16(forwardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.forwardFailed)
        }
        // The tunnel exists only to get two sockets across; it is removed as soon as they are open,
        // exactly as scrcpy does, so a panel opened thirty times does not leave thirty forwards.
        defer {
            AndroidToolchain.adb(toolchain, serial: serial, ["forward", "--remove", "tcp:\(port)"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolchain.adb)
        process.arguments = [
            "-s",
            serial,
            "shell",
            "CLASSPATH=\(deviceJarPath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            serverVersion,
        ]
            + serverArguments(scid: scid, options: options)
        // The server's log is its own diagnostic channel and nothing here reads it; discarding it
        // keeps a long session from filling a pipe nobody drains.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.launchFailed) }

        guard let video = dialUntilServerAnswers(port: port) else {
            process.terminate()
            return .failure(.serverDidNotStart)
        }
        guard let control = AndroidSocket.connectLoopback(port: port) else {
            video.close()
            process.terminate()
            return .failure(.serverDidNotStart)
        }
        control.setNoDelay()

        guard let nameBytes = video.readExactly(deviceNameLength) else {
            video.close()
            control.close()
            process.terminate()
            return .failure(.serverDidNotStart)
        }
        // The field is a fixed 64 bytes, NUL-padded; a device whose name fills it has no terminator.
        let name = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Handshake done: from here the stream is quiet for as long as the screen is still (measured
        // idle floor 547 B/s), so the dial-time receive timeout has to go or the pump reads that as
        // a dead peer.
        video.clearReceiveTimeout()

        return .success(AndroidScrcpySession(
            video: video, control: control, deviceName: name, process: process,
        ))
    }

    /// Ends the session. Closing the sockets is what actually stops the device-side server (it exits
    /// when its stream socket breaks); terminating the `adb shell` is the belt to that braces.
    func stop() {
        lock.lock()
        let alreadyDone = isTornDown
        isTornDown = true
        lock.unlock()
        guard !alreadyDone else { return }
        video.close()
        control.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - Details

    /// Pinned to the jar this build expects. `scrcpy`'s server refuses to run unless the client
    /// version string matches it EXACTLY, which is a feature: a Homebrew upgrade that moves the jar
    /// under us fails loudly at launch instead of decoding as garbage.
    static let serverVersion = "4.1"
    static let deviceJarPath = "/data/local/tmp/scrcpy-server.jar"
    /// scrcpy's `SC_DEVICE_NAME_FIELD_LENGTH`.
    static let deviceNameLength = 64

    static func serverArguments(scid: String, options: Options) -> [String] {
        [
            "scid=\(scid)",
            "log_level=error",
            // The panel is a screen. Audio would be a second socket, a second decoder and a second
            // set of sync questions for something nobody debugs an app by listening to.
            "audio=false",
            "video_codec=\(options.codec)",
            "max_size=\(options.maxSize)",
            "video_bit_rate=\(options.bitRate)",
            // The client dials in; the device listens. The alternative (`adb reverse`) needs the
            // device to reach back to the host, which an emulator on a shared machine cannot always
            // do and a device on someone's desk certainly cannot.
            "tunnel_forward=true",
            // See the file comment — this one is not a preference.
            "clipboard_autosync=false",
            // A device that sleeps mid-session leaves a black rectangle and no explanation; the
            // server restores the setting on a clean exit.
            "stay_awake=true",
        ]
    }

    /// Connects, then proves the far side is really the server by reading its dummy byte.
    ///
    /// The `adb forward` tunnel completes a TCP handshake whether or not anything is listening on
    /// the device, so a successful `connect` proves nothing at all. The device-side server takes
    /// roughly a fifth of a second to come up (measured: first socket at 0.23 s, first keyframe at
    /// 0.60 s), and the retry budget below is ~5 s — long enough for a loaded host, short enough
    /// that a genuinely broken launch reports rather than hangs.
    private static func dialUntilServerAnswers(port: UInt16) -> AndroidSocket? {
        for _ in 0..<100 {
            if let socket = AndroidSocket.connectLoopback(port: port) {
                if let byte = socket.readExactly(1), !byte.isEmpty { return socket }
                socket.close()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

/// Why a bridge request could not be served. Each case names the piece that is missing, because the
/// panel renders the message and "Android unavailable" tells nobody what to install.
enum AndroidBridgeError: String, Error, Sendable {
    case adbMissing = "No adb on this host. Install the Android SDK platform-tools."
    case emulatorMissing = "No emulator binary on this host — only attached devices can be listed."
    // The jar is committed at `ThirdParty/tools/vendor/scrcpy-server`, so reaching this now means
    // hostd is running from outside a checkout — naming the checkout is the actionable part.
    case scrcpyServerMissing = "No scrcpy-server jar reachable. Run hostd from a SlopDesk checkout, or set SLOPDESK_ANDROID_SERVER_JAR."
    case pushFailed = "Could not copy the mirror server onto the device."
    case forwardFailed = "adb refused to open a tunnel to the device."
    case launchFailed = "Could not start the mirror server on the device."
    case serverDidNotStart = "The device accepted the connection but never answered."
    case unknownDevice = "That device is no longer attached."
    case deviceStarting = "The device is still starting up."
    case deviceUnauthorized = "Debugging has not been allowed on the device yet."
    case badRequest = "The bridge did not understand that request."
}
