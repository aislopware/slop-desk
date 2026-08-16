#if os(macOS)
import Darwin
import Foundation
import SlopDeskProtocol

/// The THIN OS shim that backs the host metadata RPC for ONE pane (its PTY master fd + shell pid).
/// It conforms to ``MetadataQuerying`` so the PURE ``MetadataResponseBuilder`` can drive it;
/// **compiled + code-reviewed ONLY** — never instantiated in a unit test (the hang-safety rule,
/// exactly like ``PTYForegroundProbe``: real subprocess / `proc_*` work on a live PTY hangs / depends
/// on the host environment). The decision logic (verb mapping, path confinement, caps) lives in the
/// pure builder; this file is a straight, defensive translation of OS queries into the shared
/// ``MetadataCodec`` value types.
///
/// **What is left here is what needs the fd.** The five verbs that were subprocess and filesystem
/// work with no handle behind them — git status, git diff, directory listing, session listing,
/// session read — moved to `slopdesk-probe` and are forwarded through ``HostProbe`` below. What
/// stays is anchored to something a fork does not have: `tcgetpgrp`/`ptsname` on this pane's master
/// fd, `proc_pidinfo` over every live pid, and a CPU baseline that outlives the request.
///
/// **Validate-then-drop everywhere.** Every syscall return is checked (`> 0`, exact struct size); every
/// subprocess is best-effort (a missing binary / non-zero exit / unparseable line is SKIPPED, never a
/// trap); every parsed integer falls back to a default. The probe NEVER force-unwraps and NEVER traps on
/// the pane's environment — a non-git cwd, a permission error, a torn-down process all degrade to an
/// empty/`.noRepo`/`nil` result the builder maps to a clean status.
///
/// `#if os(macOS)` — it spawns `git`/`lsof` (`Foundation.Process`, unavailable on iOS) and reads Darwin
/// `proc_*`; it is NEVER compiled into the iOS slice (the shared codec/models are — see `check-ios.sh`).
struct HostMetadataProbe: MetadataQuerying {
    /// The pane's PTY master fd (the controlling-terminal anchor for the process / port scope).
    let masterFD: Int32
    /// The pane's shell pid (the cwd fallback when no foreground group resolves).
    let shellPID: pid_t

    // Caps (a second backstop under the builder's caps — a pathological host can't flood a frame).
    private static let maxProcesses = 256
    private static let maxPorts = 512
    /// The read budget for the ONE subprocess still spawned here. `lsof` scoped to a pane's pids
    /// prints kilobytes, so this is not a limit anyone reaches — it is the drain loop's stop
    /// condition, and a loop that appends until EOF with no ceiling is a loop a wedged `lsof` can
    /// grow without bound.
    private static let maxCaptureBytes = 15 * 1024 * 1024
    private static let lsofPath = "/usr/sbin/lsof"

    // MARK: - cwd (proc-vnode of the foreground process; OSC-7 is a clean future enhancement)

    func paneWorkingDirectory() -> String? {
        Self.cwd(of: foregroundPID()) ?? Self.cwd(of: shellPID)
    }

    /// The PTY's foreground process group leader pid, or the shell pid when none resolves.
    private func foregroundPID() -> pid_t {
        guard masterFD >= 0 else { return shellPID }
        let pgid = tcgetpgrp(masterFD)
        return pgid > 0 ? pgid : shellPID
    }

    /// The current working directory of `pid` via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`; `nil` on any
    /// failure (process gone / not permitted / short read).
    private static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, Int32(PROC_PIDVNODEPATHINFO), 0, $0, size)
        }
        guard got == size else { return nil }
        let path = cString(&info.pvi_cdir.vip_path, capacity: Int(MAXPATHLEN))
        return path.isEmpty ? nil : path
    }

    // MARK: - processes (controlling-terminal scoped)

    func processes() -> [MetadataCodec.ProcessInfo] {
        guard let ttyDev = paneTTYDev() else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [MetadataCodec.ProcessInfo] = []
        for pid in Self.allPIDs() {
            guard let bsd = Self.bsdInfo(pid), bsd.e_tdev == ttyDev else { continue }
            let startSec = TimeInterval(bsd.pbi_start_tvsec)
            let uptime = startSec > 0 ? max(0, now - startSec) : 0
            out.append(MetadataCodec.ProcessInfo(
                pid: UInt32(bitPattern: pid),
                uptimeSec: UInt32(min(uptime, TimeInterval(UInt32.max))),
                name: Self.processName(pid),
            ))
            if out.count >= Self.maxProcesses { break }
        }
        return out
    }

    /// The pids whose controlling terminal is this pane's PTY (the pane's process set).
    private func paneProcessIDs() -> [pid_t] {
        guard let ttyDev = paneTTYDev() else { return [] }
        return Self.allPIDs().filter { Self.bsdInfo($0)?.e_tdev == ttyDev }
    }

    /// The PTY slave device number (the controlling tty of the pane's processes) as the `proc_bsdinfo`
    /// `e_tdev` field's `UInt32`, or `nil`.
    private func paneTTYDev() -> UInt32? {
        guard masterFD >= 0, let slave = ptsname(masterFD) else { return nil }
        var st = stat()
        guard stat(slave, &st) == 0 else { return nil }
        return UInt32(bitPattern: Int32(truncatingIfNeeded: st.st_rdev))
    }

    // MARK: - ports (lsof scoped to the pane's pids)

    func ports() -> [MetadataCodec.PortInfo] {
        let pids = paneProcessIDs()
        guard !pids.isEmpty else { return [] }
        let pidArg = pids.map(String.init).joined(separator: ",")
        var out = Self.lsofPorts(pidArg: pidArg, proto: .tcp)
        out.append(contentsOf: Self.lsofPorts(pidArg: pidArg, proto: .udp))
        return Array(out.prefix(Self.maxPorts))
    }

    private static func lsofPorts(pidArg: String, proto: MetadataCodec.PortProtocol) -> [MetadataCodec.PortInfo] {
        var args = ["-nP", "-w", "-a", "-p", pidArg, "-F", "cn"]
        switch proto {
        case .tcp: args += ["-iTCP", "-sTCP:LISTEN"]
        case .udp: args += ["-iUDP"]
        }
        guard let output = runProcessString(lsofPath, args) else { return [] }
        return parseLsof(output, proto: proto)
    }

    /// Parses `lsof -F cn` field output: `c<command>` sets the current command, `n<address>` yields one
    /// listening port (the integer after the LAST `:` of the address — handles `*:8080`, `127.0.0.1:80`,
    /// `[::1]:443`). A malformed line is SKIPPED (validate-then-drop) — `lsof` output is hostile input.
    static func parseLsof(_ output: String, proto: MetadataCodec.PortProtocol) -> [MetadataCodec.PortInfo] {
        var out: [MetadataCodec.PortInfo] = []
        var command = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "c":
                command = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":") else { continue }
                let portText = value[value.index(after: colon)...]
                guard let port = UInt16(portText) else { continue }
                out.append(MetadataCodec.PortInfo(port: port, proto: proto.rawValue, procName: command))
                if out.count >= maxPorts { return out }
            default:
                continue
            }
        }
        return out
    }

    // MARK: - forwarded to `slopdesk-probe` (git, directories, sessions)

    func gitStatus(cwd: String) -> MetadataCodec.GitStatusPayload { HostProbe.gitStatus(cwd: cwd) }

    func gitDiff(cwd: String, file: String) -> Data? { HostProbe.gitDiff(cwd: cwd, file: file) }

    func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]? {
        HostProbe.listDirectory(absolutePath: absolutePath)
    }

    /// Claude Code and OpenCode only. Codex auto-enumeration is intentionally DEFERRED (the
    /// Claude-first scope reduction), not removed: the probe still lists `~/.codex/sessions` as a
    /// read root, so an EXPLICIT absolute codex session id stays readable while auto-discovery is the
    /// deferred half — see `docs/DECISIONS.md`.
    func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        HostProbe.listAgentSessions(project: project)
    }

    func readAgentSession(id: String) -> Data? { HostProbe.readAgentSession(id: id) }

    // MARK: - host identity + vitals

    func hostName() -> String? {
        // The machine's own name ("mac-studio.local") — the `hostInfo` verb's answer. Pane-agnostic,
        // no file access; `ProcessInfo` resolves it without a DNS round-trip.
        ProcessInfo.processInfo.hostName
    }

    func hostVitals() -> MetadataCodec.HostVitals? {
        // The machine's pulse — the `hostVitals` verb's answer. Pane-agnostic, so it reads the
        // PROCESS-WIDE sampler rather than any state of this per-request probe: the CPU percent is a
        // delta between polls and would never exist if the baseline died with the probe.
        HostVitalsSampler.shared.sample()
    }

    // MARK: - Darwin proc helpers

    /// All live pids (`proc_listpids(PROC_ALL_PIDS)`), `> 0` filtered; empty on failure.
    private static func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 16
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size),
        )
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return buffer.prefix(count).filter { $0 > 0 }
    }

    /// The BSD info (`PROC_PIDTBSDINFO`) of `pid`, or `nil` on a short read (process gone / not permitted).
    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, $0, size)
        }
        return got == size ? info : nil
    }

    /// The basename of `pid`'s executable (`proc_pidpath`), falling back to `proc_name`; `""` on failure.
    private static func processName(_ pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            return ForegroundProcessDetector.basename(of: string(fromCString: pathBuffer))
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        return string(fromCString: nameBuffer)
    }

    /// Decode a NUL-terminated `[CChar]` buffer as UTF-8 (the non-deprecated `String(cString:)` shape).
    private static func string(fromCString buffer: [CChar]) -> String {
        String(bytes: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), encoding: .utf8) ?? ""
    }

    /// Reads a fixed-size C char tuple (e.g. `vnode_info_path.vip_path`) as a String.
    private static func cString(_ tuple: inout some Any, capacity: Int) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    // MARK: - subprocess helpers (best-effort; a missing binary / non-zero exit → nil, never a trap)

    private static func runProcessString(_ path: String, _ arguments: [String]) -> String? {
        guard let data = runProcessData(path, arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `accumulated` captured bytes have exceeded ``maxCaptureBytes``. A PURE predicate (no
    /// I/O) so the drain loop's stop condition is unit-pinned WITHOUT spinning a `Process` in a test
    /// (the hang-safety rule keeps that compiled-and-reviewed only).
    static func captureBudgetExceeded(_ accumulated: Int) -> Bool {
        accumulated > maxCaptureBytes
    }

    /// Runs `path arguments`, returning captured stdout bytes (stderr discarded). `nil` if the binary
    /// is missing / not executable / cannot spawn. stdout is drained in CHUNKS before `waitUntilExit`
    /// so a child can neither deadlock on a full pipe buffer nor grow this side without bound: once
    /// the accumulated bytes exceed ``captureBudgetExceeded`` the child is `terminate()`d and reading
    /// stops.
    private static func runProcessData(_ path: String, _ arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let reader = stdout.fileHandleForReading
        var data = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break } // EOF — the child closed its stdout (the normal, small-diff case).
            data.append(chunk)
            if captureBudgetExceeded(data.count) {
                // Past the budget: kill the child (a blocked `write` is interrupted by SIGTERM, so
                // `waitUntilExit` can't wedge) and stop reading. The bounded buffer is returned as-is.
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        return data
    }
}
#endif
