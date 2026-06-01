#if canImport(Darwin)
import Darwin
#endif
import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// WF-3 PTY-level tests: deterministic, headless, no client networking. They drive the
/// `PTYProcess` master fd directly and assert on the bytes the shell produces.
final class PTYProcessTests: XCTestCase {

    // MARK: read helpers

    /// Reads from `fd` until `needle` appears in the accumulated output or `deadline`
    /// passes. Returns the full output read so far. Uses a background blocking read so
    /// the test has a hard timeout independent of the fd.
    private func readUntil(
        fd: Int32,
        needle: String,
        timeout: TimeInterval = 5.0
    ) -> String {
        let sink = ByteSink()
        let done = DispatchSemaphore(value: 0)
        let needleData = Data(needle.utf8)

        let queue = DispatchQueue(label: "test.pty.read")
        queue.async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    let hit = sink.append(buf[0..<n], contains: needleData)
                    if hit { done.signal(); return }
                } else {
                    done.signal(); return
                }
            }
        }

        _ = done.wait(timeout: .now() + timeout)
        return sink.string()
    }

    private func curatedEnv() -> [String: String] {
        // Force a deterministic TERM and locale for the tests.
        var env = HostEnvironment.curated()
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: Tests

    func testPTYRoundTripPrintf() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "printf rwork-ok"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.pid, 0)

        let output = readUntil(fd: pty.masterFD, needle: "rwork-ok")
        XCTAssertTrue(output.contains("rwork-ok"), "expected 'rwork-ok', got: \(output)")

        let exp = expectation(description: "exit")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testPTYInteractiveEcho() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv())

        // Cooked-mode line discipline echoes and the shell evaluates the command.
        let cmd = "echo HELLO_$((1+1))\n"
        PTYProcessTests.write(pty.masterFD, cmd)

        let output = readUntil(fd: pty.masterFD, needle: "HELLO_2")
        XCTAssertTrue(output.contains("HELLO_2"), "expected 'HELLO_2', got: \(output)")
        pty.terminate()
    }

    func testControllingTTY() throws {
        // 40 rows x 132 cols at spawn. We exercise the CONTROLLING-TERMINAL alias
        // `/dev/tty` (NOT fd 0/1/2): `/dev/tty` only opens if the slave is genuinely the
        // session's controlling terminal. `tty </dev/tty` / `stty size </dev/tty` operate
        // on that alias, so they prove POSIX_SPAWN_SETSID acquired the controlling tty —
        // running the same file-actions WITHOUT setsid yields "/dev/tty: Device not
        // configured" here (whereas plain `tty`/`stty size` on fd 0 would still pass,
        // making this the regression-meaningful form). Verified empirically.
        let pty = PTYProcess()
        try pty.spawn(
            "/bin/sh",
            arguments: ["-c", "tty </dev/tty; stty size </dev/tty"],
            environment: curatedEnv(),
            cols: 132, rows: 40
        )

        let output = readUntil(fd: pty.masterFD, needle: "40 132")
        // `tty </dev/tty` resolves and prints the controlling-terminal ALIAS `/dev/tty`
        // (verified empirically: WITH setsid -> "/dev/tty"; WITHOUT setsid ->
        // "/dev/tty: Device not configured"). The "Device not configured" check is what
        // makes this regression-meaningful for POSIX_SPAWN_SETSID — opening fd 0/1/2's
        // path would pass even with setsid broken, but /dev/tty would not.
        XCTAssertTrue(
            output.contains("/dev/tty"),
            "expected /dev/tty to resolve (controlling terminal), got: \(output)")
        XCTAssertFalse(
            output.lowercased().contains("device not configured"),
            "/dev/tty reported 'Device not configured' — slave is NOT the controlling terminal (setsid broken): \(output)")
        XCTAssertFalse(
            output.lowercased().contains("not a tty"),
            "tty reported 'not a tty' — slave is NOT the controlling terminal: \(output)")
        XCTAssertTrue(
            output.contains("40 132"),
            "expected 'stty size </dev/tty' = '40 132', got: \(output)")
    }

    func testResizeAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        pty.setWindowSize(cols: 80, rows: 24)
        PTYProcessTests.write(pty.masterFD, "stty size\n")
        let first = readUntil(fd: pty.masterFD, needle: "24 80")
        XCTAssertTrue(first.contains("24 80"), "expected '24 80', got: \(first)")

        pty.setWindowSize(cols: 120, rows: 40)
        PTYProcessTests.write(pty.masterFD, "stty size\n")
        let second = readUntil(fd: pty.masterFD, needle: "40 120")
        XCTAssertTrue(second.contains("40 120"), "expected '40 120' after resize, got: \(second)")

        pty.terminate()
    }

    func testExitCode() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 7"], environment: curatedEnv())

        let exp = expectation(description: "exit7")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 7, "expected exit code 7")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testSignalExitReportsShellConvention() throws {
        // WIFSIGNALED branch of the reaper: a child that signals itself reports
        // 128 + signal (shell convention). SIGTERM (15) -> 143. This exercises the
        // `(status & 0o177)` arithmetic that the normal-exit test never touches.
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: curatedEnv())

        let exp = expectation(description: "signal-exit-143")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 143, "expected 128 + SIGTERM(15) = 143 for a self-TERM child")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testMasterFDClosedOnShutdownNoFDLeak() throws {
        // FD-hygiene regression: each successful spawn opens one PTY master fd; before the
        // fix it was never closed (no deinit, terminate()/shutdown() did not close it), so
        // a long-running daemon leaked one fd per session and eventually hit EMFILE. Spawn
        // + drive a full HostSession relay + shutdown N times and assert the open-fd delta
        // is ~0 (we allow tiny slack for transient runtime fds, but a per-spawn leak would
        // show ~N).
        let n = 40
        let before = PTYProcessTests.openFDCount()
        for _ in 0..<n {
            let pty = PTYProcess()
            try pty.spawn("/bin/sh", arguments: ["-c", "printf hi; exit 0"], environment: curatedEnv())
            let transport = HostSessionTransport(sessionID: UUID())
            let session = HostSession(sessionID: transport.sessionID, pty: pty, transport: transport)
            session.startRelay()
            _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain to EOF
            session.shutdown()
            XCTAssertEqual(pty.masterFD, -1, "closeMaster() must mark the master fd -1 after shutdown")
        }
        // Give any in-flight teardown a beat to release fds.
        Thread.sleep(forTimeInterval: 0.2)
        let after = PTYProcessTests.openFDCount()
        let delta = after - before
        XCTAssertLessThan(
            delta, n / 2,
            "open-fd delta \(delta) over \(n) spawn+shutdown cycles indicates a per-session fd leak")
    }

    func testCloseMasterIsIdempotent() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        pty.closeMaster()
        XCTAssertEqual(pty.masterFD, -1)
        pty.closeMaster() // second call must be a harmless no-op (no double-close)
        XCTAssertEqual(pty.masterFD, -1)
    }

    func testMasterFDIsBlockingAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        let flags = fcntl(pty.masterFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & O_NONBLOCK, 0, "O_NONBLOCK must be cleared on the master fd")
        _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain until EOF
    }

    // MARK: util

    /// Counts the process's currently-open file descriptors by listing `/dev/fd`
    /// (macOS exposes one entry per open fd). Used by the fd-leak regression test.
    static func openFDCount() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev/fd") else { return -1 }
        return entries.count
    }

    static func write(_ fd: Int32, _ string: String) {
        let data = Array(string.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else { break }
        }
    }
}

/// Thread-safe accumulator for the background PTY read in tests.
final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    /// Appends `bytes` and returns whether `needle` now appears in the accumulation.
    func append(_ bytes: ArraySlice<UInt8>, contains needle: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        data.append(contentsOf: bytes)
        return data.range(of: needle) != nil
    }
    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
