#if canImport(Darwin)
import Darwin
#endif
import Foundation
import ObjectiveC
import XCTest
@testable import SlopDeskHost

/// The fork-to-exec window, held two ways.
///
/// Between `fork()` and `execve()` in a multi-threaded process only async-signal-safe raw syscalls
/// are legal, because the child inherits every lock the parent's other threads happened to hold and
/// none of the threads that would release them. The Swift runtime's type/witness/conformance caches
/// are behind `os_unfair_lock`, and `os_unfair_lock_lock` answers a lock owned by a thread that does
/// not exist by ABORTING — pre-`execve`, so the pane's shell dies at birth while the host has already
/// logged `attached for pane`.
///
/// A doc comment already said all of that, two lines above a `for sig in 1...31` that asked the
/// runtime to build `ClosedRange<Int32>` metadata from a mangled name. Ten `.ips` reports in one day
/// is what the comment was worth. So this file pins the window instead:
///
/// 1. ``testForkToExecWindowCallsNothingButRawSyscalls`` DISASSEMBLES the window and fails on any
///    call target that is not one of seven syscalls — deterministic, and it catches the next
///    innocent-looking line before it ever runs.
/// 2. ``testEveryForkedChildReachesExecUnderRuntimeCacheContention`` runs the real thing: 64 real
///    `PTYProcess` spawns from a process whose other threads are hammering one of the two caches the
///    crash reports name, and asserts every child got far enough to print a token. With the shipped
///    `for sig in 1...31` put back it loses a handful of them; a window that touches no runtime
///    cannot lose any.
final class ForkExecWindowContractTests: XCTestCase {
    // MARK: 1 — the window's contents, by disassembly

    /// Every call the forked child can make, and nothing else. `login_tty` is libutil (`setsid` +
    /// `ioctl(TIOCSCTTY)` + `dup2` + `close`, all raw syscalls); the rest are libc syscall wrappers.
    private static let permittedCallees: Set<String> = [
        "_sigprocmask",
        "_signal",
        "_login_tty",
        "_chdir",
        "_close",
        "_execve",
        "__exit",
    ]

    func testForkToExecWindowCallsNothingButRawSyscalls() throws {
        let binary = try testBinaryPath()
        let symbol = try mangledSymbol(containing: "execInForkedChild", in: binary)
        let window = try disassembly(of: symbol, in: binary)

        // Anchor: if the slice is empty or does not end in the exec, the parse is wrong and every
        // assertion below would pass vacuously.
        XCTAssertTrue(
            window.contains { $0.contains("_execve") },
            "the disassembly slice for \(symbol) does not contain the exec — the parse is wrong, "
                + "not the code:\n\(window.prefix(20).joined(separator: "\n"))",
        )

        let callees = calleesIn(window)
        let forbidden = callees.subtracting(Self.permittedCallees).sorted()
        XCTAssertTrue(
            forbidden.isEmpty,
            "the fork-to-exec window calls \(forbidden.joined(separator: ", ")) — between fork() and "
                + "execve() only async-signal-safe raw syscalls are legal, and anything reached through "
                + "the Swift runtime (metadata from a mangled name, a witness table, a conformance "
                + "lookup, ARC, an allocation, a `swift_once`) takes an os_unfair_lock that a forked "
                + "child can only abort on. Permitted: "
                + Self.permittedCallees.sorted().joined(separator: ", "),
        )

        // An indirect call has no name to whitelist, so the check above cannot see through it.
        XCTAssertFalse(
            window.contains { instruction(in: $0) == "blr" },
            "the fork-to-exec window makes an INDIRECT call — its target cannot be audited, so it is "
                + "not allowed here at all",
        )
    }

    /// Nothing at all runs between `fork()` returning 0 in the child and the window function — the
    /// child's very first instruction after the fork must be argument shuffling and a branch.
    ///
    /// This is the gap the whitelist above cannot see: `spawn` is full of Swift, and a single
    /// statement placed on the child's side of the `if` would run there with no test noticing.
    func testNothingRunsBetweenForkAndTheWindow() throws {
        let binary = try testBinaryPath()
        let spawnSymbol = try mangledSymbol(containing: "PTYProcessC5spawn", in: binary)
        let body = try disassembly(of: spawnSymbol, in: binary)

        let forkIndex = try XCTUnwrap(
            body.firstIndex { $0.contains("rawFork") },
            "no call to rawFork in \(spawnSymbol) — the fork moved, so this test no longer proves anything",
        )
        let windowIndex = try XCTUnwrap(
            body.firstIndex { $0.contains("execInForkedChild") },
            "no call to execInForkedChild in \(spawnSymbol) — the child window moved out of spawn",
        )
        XCTAssertGreaterThan(windowIndex, forkIndex, "the child window is emitted BEFORE the fork")

        let between = Array(body[(forkIndex + 1)..<windowIndex])
        let callsBetween = calleesIn(between)
        XCTAssertTrue(
            callsBetween.isEmpty,
            "\(callsBetween.sorted().joined(separator: ", ")) runs between fork() and the child "
                + "window — in the child that is Swift-runtime work with no thread to unlock behind it",
        )
        XCTAssertFalse(
            between.contains { instruction(in: $0) == "blr" },
            "an indirect call runs between fork() and the child window",
        )
    }

    // MARK: 2 — the window's behaviour, under real contention

    /// N real PTY spawns while other threads hammer the Swift runtime's conformance cache.
    ///
    /// The churn is not decoration. The ten crash reports die on two runtime caches — nine in the
    /// generic-metadata one, one in `ConformanceState::cacheResult` — and both are only LOCKED while a
    /// miss is being recorded. So the churn threads generate nothing but misses: each registers a
    /// brand-new class and asks whether it conforms to sixteen protocols, which is sixteen
    /// (type, protocol) pairs the cache has never seen. `K` classes × 16 protocols is a combinatorial
    /// key space, so the miss rate stays high while the memory the churn costs stays in the
    /// single-digit megabytes — a plain class-per-miss churn spends 380 MB in three seconds.
    ///
    /// Measured, on this machine, with the shipped `for sig in 1...31` put back: 2, 4, 6 and 2 lost
    /// out of 64 over four runs — ~5.5% per fork, so 64 spawns detect the regression ~97% of the time.
    /// The deterministic half of that job belongs to the disassembly test above; this one is here
    /// because the whole point is that the real path really does survive. With the window holding, the
    /// loss is 0 — there is no runtime call left to race, so this test cannot flake, it just stops
    /// being interesting.
    func testEveryForkedChildReachesExecUnderRuntimeCacheContention() throws {
        let churn = RuntimeConformanceCacheChurn(threads: 8)
        churn.start()
        defer { churn.stop() }

        let home = try sandboxHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = HostEnvironment.curated(parent: ["PATH": "/usr/bin:/bin"])
        environment["HOME"] = home.path

        let spawnCount = 64
        var lost: [Int] = []
        for index in 0..<spawnCount {
            let token = "FORKWINDOW-\(index)-REACHED-EXEC"
            let pty = PTYProcess()
            defer {
                pty.forceTerminate()
                _ = pty.waitUntilExited(timeout: 1.0)
                pty.closeMaster()
            }
            // Non-interactive `/bin/sh -c`: it prints the token and exits, so no shell ever reads or
            // writes a history file even though HOME is sandboxed anyway.
            try pty.spawn(
                "/bin/sh",
                arguments: ["-c", "printf '%s\\n' '\(token)'"],
                environment: environment,
            )
            // A child that aborted pre-`execve` never opens the slave, so this returns on EOF in
            // milliseconds rather than sitting out the timeout.
            if !readUntil(fd: pty.masterFD, needle: token, timeout: 5.0).contains(token) {
                lost.append(index)
            }
        }

        XCTAssertTrue(
            lost.isEmpty,
            "\(lost.count)/\(spawnCount) forked children never reached execve (spawns \(lost)) — the "
                + "fork-to-exec window touched the Swift runtime and aborted on a lock whose owner "
                + "thread does not exist in the child. Check "
                + "~/Library/Logs/DiagnosticReports for reports whose `asi` says "
                + "\"crashed on child side of fork pre-exec\"",
        )
    }

    // MARK: disassembly helpers

    /// This test bundle's own executable — `SlopDeskHost` is linked into it statically, so the code
    /// under test and the code being disassembled are the same bytes.
    private func testBinaryPath() throws -> String {
        let bundle = Bundle(for: ForkExecWindowContractTests.self)
        return try XCTUnwrap(bundle.executableURL?.path, "the test bundle has no executable")
    }

    /// The one defined symbol whose name contains `fragment`.
    ///
    /// The `grep` runs in the shell rather than in Swift because this bundle's symbol table is ~1M
    /// lines: splitting that into Swift `String`s costs seconds, and grepping it costs milliseconds.
    /// Both the binary path and the fragment travel as ENV, so neither can be read as shell syntax.
    private func mangledSymbol(containing fragment: String, in binary: String) throws -> String {
        let listing = try runTool(
            "/bin/sh",
            ["-c", #"/usr/bin/nm -U "$SLOPDESK_BIN" | /usr/bin/grep -- "$SLOPDESK_FRAGMENT""#],
            environment: ["SLOPDESK_BIN": binary, "SLOPDESK_FRAGMENT": fragment],
        )
        let matches = listing
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let name = line.split(separator: " ").last.map(String.init),
                      name.contains(fragment) else { return nil }
                return name
            }
            // A `$defer`/closure/thunk carries the parent's name; the window itself is the shortest.
            .sorted { $0.count < $1.count }
        return try XCTUnwrap(matches.first, "no symbol containing \(fragment) in \(binary)")
    }

    /// The instruction lines of `symbol`, from its label to the next symbol label.
    private func disassembly(of symbol: String, in binary: String) throws -> [String] {
        // `otool -p` starts the disassembly AT the symbol; awk stops it at the next one, which also
        // closes otool's pipe rather than disassembling the rest of a 90 MB text section.
        let program = "/^_/ { if (seen) exit; seen = 1; next } seen { print }"
        let text = try runTool(
            "/bin/sh",
            ["-c", #"/usr/bin/otool -tvV -p "$SLOPDESK_SYMBOL" "$SLOPDESK_BIN" | /usr/bin/awk "$SLOPDESK_AWK""#],
            environment: ["SLOPDESK_BIN": binary, "SLOPDESK_SYMBOL": symbol, "SLOPDESK_AWK": program],
        )
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The mnemonic of a disassembly line (`0x…\tbl\t…` → `bl`).
    private func instruction(in line: String) -> String {
        let fields = line.split(separator: "\t")
        return fields.count > 1 ? String(fields[1]) : ""
    }

    /// Every named call target in `lines`. `otool` renders a stub call as
    /// `bl 0x… ; symbol stub for: _foo` and a direct one as `bl _$s…`.
    private func calleesIn(_ lines: [String]) -> Set<String> {
        var callees: Set<String> = []
        for line in lines where instruction(in: line) == "bl" {
            if let range = line.range(of: "symbol stub for: ") {
                callees.insert(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            } else if let target = line.split(separator: "\t").last, target.hasPrefix("_") {
                callees.insert(String(target))
            }
        }
        return callees
    }

    // MARK: spawn helpers

    private func sandboxHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-forkwindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Reads `fd` until `needle` appears, EOF, or `timeout`. `poll()`-gated on this thread so it can
    /// never block past the deadline and never abandons a thread inside `read()`.
    private func readUntil(fd: Int32, needle: String, timeout: TimeInterval) -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
            if remainingMs <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, min(remainingMs, 100))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
            if text(collected).contains(needle) { break }
        }
        return text(collected)
    }

    /// PTY bytes as text. UTF-8 first, latin-1 second — a `read()` can land mid-sequence, and a
    /// decoder that answers nil for that would hide an ASCII token that IS in the buffer.
    private func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - The churn

// Sixteen protocols nothing conforms to. Each one asked about a never-before-seen class is one
// conformance-cache MISS, and a miss is the only thing that takes `ConformanceState`'s
// `os_unfair_lock` — one of the two locks the ten crash reports died on.
private protocol ForkChurnProbe00 {}
private protocol ForkChurnProbe01 {}
private protocol ForkChurnProbe02 {}
private protocol ForkChurnProbe03 {}
private protocol ForkChurnProbe04 {}
private protocol ForkChurnProbe05 {}
private protocol ForkChurnProbe06 {}
private protocol ForkChurnProbe07 {}
private protocol ForkChurnProbe08 {}
private protocol ForkChurnProbe09 {}
private protocol ForkChurnProbe10 {}
private protocol ForkChurnProbe11 {}
private protocol ForkChurnProbe12 {}
private protocol ForkChurnProbe13 {}
private protocol ForkChurnProbe14 {}
private protocol ForkChurnProbe15 {}

/// Keeps the Swift runtime's conformance cache under continuous WRITE pressure, so that a fork taken
/// at a random instant has a real chance of catching the cache's `os_unfair_lock` held.
///
/// Registering a class is the cheap half of the key space and the only half that costs memory; the
/// sixteen protocol questions multiply it for free. At six threads this is a few thousand classes and
/// a few megabytes for the length of a spawn loop.
private final class RuntimeConformanceCacheChurn: @unchecked Sendable {
    private let running = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let finished = DispatchGroup()
    private let threads: Int
    /// Whether the churn threads still hold `running`.
    ///
    /// They dereference it on every iteration, so the storage is only this object's to free once each
    /// of them has LEFT the group — `start()` hands it over, `stop()` takes it back by joining. In
    /// between, `deinit` leaks the four bytes instead: a live thread reading freed memory is a crash
    /// with no connection to the code that caused it, and the next test in the bundle wears it.
    private var threadsHoldRunning = false

    init(threads: Int) {
        self.threads = threads
        running.initialize(to: 0)
    }

    deinit {
        guard !threadsHoldRunning else { return }
        running.deallocate()
    }

    func start() {
        running.pointee = 1
        threadsHoldRunning = true
        for thread in 0..<threads {
            finished.enter()
            let running = running
            let finished = finished
            Thread.detachNewThread {
                var serial = 0
                while running.pointee != 0 {
                    autoreleasepool {
                        let name = "SlopDeskForkChurn_\(thread)_\(serial)"
                        serial += 1
                        guard let created = objc_allocateClassPair(NSObject.self, name, 0) else { return }
                        objc_registerClassPair(created)
                        guard let type = created as? NSObject.Type else { return }
                        askEveryProbe(type.init())
                    }
                }
                finished.leave()
            }
        }
    }

    /// Stops the churn and JOINS it. The join is the load-bearing half: each thread reads `running`
    /// until it observes the store, so the flag is unsafe to free until every one of them is gone.
    /// The timeout only keeps a wedged thread from hanging the bundle — it hands the flag to that
    /// thread for good rather than freeing it underneath.
    func stop() {
        running.pointee = 0
        let joined = finished.wait(timeout: .now() + 30) == .success
        threadsHoldRunning = !joined
        XCTAssertTrue(
            joined,
            "the runtime-cache churn threads did not stop within 30s of being told to — the fork "
                + "contention test's teardown is wedged, and its `running` flag is leaked deliberately "
                + "so the threads still reading it do not read freed memory",
        )
    }
}

/// Sixteen conformance questions about one object. Written out rather than driven from a table: a
/// table of closures is a table of existentials, and the point is the sixteen distinct
/// `swift_conformsToProtocol` calls.
private func askEveryProbe(_ object: NSObject) {
    _ = object is ForkChurnProbe00
    _ = object is ForkChurnProbe01
    _ = object is ForkChurnProbe02
    _ = object is ForkChurnProbe03
    _ = object is ForkChurnProbe04
    _ = object is ForkChurnProbe05
    _ = object is ForkChurnProbe06
    _ = object is ForkChurnProbe07
    _ = object is ForkChurnProbe08
    _ = object is ForkChurnProbe09
    _ = object is ForkChurnProbe10
    _ = object is ForkChurnProbe11
    _ = object is ForkChurnProbe12
    _ = object is ForkChurnProbe13
    _ = object is ForkChurnProbe14
    _ = object is ForkChurnProbe15
}

/// Runs `tool` and returns its stdout.
private func runTool(
    _ tool: String,
    _ arguments: [String],
    environment: [String: String] = [:],
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if !environment.isEmpty { process.environment = environment }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(bytes: data, encoding: .utf8) ?? ""
}
