// AndroidToolchain — finding the three host binaries the Android panel stands on, and running the
// one of them that answers questions.
//
// **Why locating is harder here than for `baguette`.** ``HostServiceProcess/locate(_:overrideVariable:)``
// walks `PATH` plus the Homebrew prefixes, which is the whole story for a Homebrew formula. The
// Android SDK is not a Homebrew formula: it is a directory tree that Android Studio, `sdkmanager`,
// `mise`, `asdf` and Nix each put somewhere different, and whose `platform-tools` end up on `PATH`
// only if the user edited a shell profile — which hostd, launched outside a login shell, never reads
// anyway. So the search walks the SDK roots as well, in the order of how authoritative each is.
//
// **`scrcpy-server` is a jar, not an executable**, so it cannot go through the same locator at all:
// `isExecutableFile` is false for it. It is looked up as a readable file under Homebrew's
// `share/scrcpy`, which is where the formula installs it.
//
// Hang-safety: every `run` here spawns a real process. Unit tests exercise the PARSERS
// (``AndroidDeviceCatalog``) against captured output and never reach this file.

import Foundation

/// Where the host's Android tooling lives. `nil` for any member means the panel reports unavailable
/// and names the missing piece — an install hint that says "adb" when adb is what is missing beats
/// one generic "Android unavailable".
struct AndroidToolchain: Sendable {
    /// `platform-tools/adb` — the device channel. Everything else is optional; without this there is
    /// no Android panel at all.
    var adb: String
    /// `emulator/emulator` — only needed to LIST and BOOT AVDs. A host with a physical device
    /// plugged in and no emulator installed is a perfectly good Android host.
    var emulator: String?
    /// `share/scrcpy/scrcpy-server` — the jar pushed to the device. Without it devices still list
    /// and boot, but nothing mirrors.
    var scrcpyServerJar: String?

    /// Resolve the toolchain, or `nil` when `adb` itself is missing.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> Self? {
        guard let adb = locateSDKTool(
            "adb", subdirectory: "platform-tools", overrideVariable: "SLOPDESK_ADB_BIN",
            environment: environment, fileManager: fileManager,
        ) else { return nil }
        return Self(
            adb: adb,
            emulator: locateSDKTool(
                "emulator", subdirectory: "emulator", overrideVariable: "SLOPDESK_ANDROID_EMULATOR_BIN",
                environment: environment, fileManager: fileManager,
            ),
            scrcpyServerJar: locateScrcpyServerJar(environment: environment, fileManager: fileManager),
        )
    }

    /// `PATH` first (an operator who put the SDK on the path meant that one), then every SDK root
    /// this host might have, each probed at `<root>/<subdirectory>/<name>`.
    static func locateSDKTool(
        _ name: String, subdirectory: String, overrideVariable: String,
        environment: [String: String], fileManager: FileManager,
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty {
            // Same contract as ``HostServiceProcess/locate``: a named-but-broken override is an
            // error, not a reason to go looking for a different binary.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let candidate = directory + "/" + name
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        for root in sdkRoots(environment: environment, fileManager: fileManager) {
            let candidate = root + "/" + subdirectory + "/" + name
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Candidate SDK roots, most authoritative first: the two environment variables Google
    /// documents, then Android Studio's default, then the version-manager trees. `mise`/`asdf`
    /// install one directory per version, so those are enumerated rather than guessed — a hard-coded
    /// version number would rot on the user's next upgrade.
    static func sdkRoots(environment: [String: String], fileManager: FileManager) -> [String] {
        var roots: [String] = []
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[variable], !value.isEmpty { roots.append(value) }
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        roots.append(home + "/Library/Android/sdk")
        for managed in ["/.local/share/mise/installs/android-sdk", "/.asdf/installs/android-sdk"] {
            let parent = home + managed
            let versions = (try? fileManager.contentsOfDirectory(atPath: parent)) ?? []
            // Newest-looking first, so a host with several SDKs installed does not answer with the
            // oldest one purely because its name sorts first.
            for version in versions.sorted(by: >) { roots.append(parent + "/" + version) }
        }
        return roots
    }

    /// The `scrcpy-server` jar. Not an executable and not on `PATH` — it ships in the formula's
    /// `share/scrcpy`, and `SLOPDESK_ANDROID_SERVER_JAR` overrides for anyone running scrcpy from a
    /// build tree.
    static func locateScrcpyServerJar(
        environment: [String: String], fileManager: FileManager,
    ) -> String? {
        if let override = environment["SLOPDESK_ANDROID_SERVER_JAR"], !override.isEmpty {
            return fileManager.isReadableFile(atPath: override) ? override : nil
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let candidate = prefix + "/share/scrcpy/scrcpy-server"
            if fileManager.isReadableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Running

    /// Runs a tool and returns its merged stdout/stderr, or `nil` when the exec failed or the
    /// deadline passed.
    ///
    /// **The timeout is not optional.** `adb` blocks indefinitely on a device that has wedged (a
    /// half-booted emulator answers the transport and never the shell), and every caller here sits
    /// on a queue that is answering something. A timed-out probe reports "cannot say" and the panel
    /// keeps its last-known list, which is the same choice the simulator panel makes for a failed
    /// poll.
    @discardableResult
    static func run(
        _ binary: String, _ arguments: [String], timeout: TimeInterval = 10,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String? {
        capture(binary, arguments, timeout: timeout, environment: environment)
            // Lossy: `adb` and `emulator` print whatever a device handed them, and a command whose
            // output has one bad byte still has to report the rest.
            // swiftlint:disable:next optional_data_string_conversion
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The same run, as BYTES.
    ///
    /// Separate from ``run(_:_:timeout:environment:)`` for one operation — `screencap`, whose output
    /// is a PNG. Decoding that as UTF-8 and re-encoding it would not round-trip: every byte that is
    /// not valid UTF-8 becomes a replacement character, which is most of a compressed image.
    ///
    /// `mergesStandardError` is false here for the same reason. `run` folds stderr into stdout so a
    /// tool's complaint is not lost, and that is right for text; folded into a PNG it is a corrupt
    /// file with a warning spliced through it.
    static func capture(
        _ binary: String, _ arguments: [String], timeout: TimeInterval = 10,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mergesStandardError: Bool = true,
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergesStandardError ? pipe : FileHandle.nullDevice
        // stdin must not be the caller's terminal: `adb` inherits it and a stray tool that reads a
        // line would take the host's own input.
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain on a thread rather than after `waitUntilExit`: a tool that fills the 64 KiB pipe
        // buffer blocks in `write` forever if nobody is reading, and `list_apps` on a real device
        // clears that easily.
        let collected = Collector()
        let reader = Thread { collected.set(pipe.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        // The drain thread ends when the child's last writer closes; the terminate above guarantees
        // it, and this bounded join keeps a wedged descriptor from stranding the caller.
        let joinDeadline = Date().addingTimeInterval(2)
        while collected.value == nil, Date() < joinDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return collected.value
    }

    /// Runs `adb -s <serial> <arguments…>`, or host-scoped `adb <arguments…>` with no serial.
    static func adb(
        _ toolchain: Self, serial: String? = nil, _ arguments: [String],
        timeout: TimeInterval = 10,
    ) -> String? {
        let prefix = serial.map { ["-s", $0] } ?? []
        return run(toolchain.adb, prefix + arguments, timeout: timeout)
    }

    /// A `Data?` cell one thread writes and another reads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Data?

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        var value: Data? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
