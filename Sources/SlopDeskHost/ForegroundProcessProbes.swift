import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol

/// W10 — the two OS shims that answer WHO holds a pane's PTY foreground (docs/41 §4.2 signal 1,
/// docs/42 W10). The primary, zero-config agent-detection input: a low-rate poll resolves the
/// foreground process for each terminal pane and the host folds it into that pane's detector.
///
/// **Shims only, and that is the hang-safety rule.** Both types here are compiled + code-reviewed,
/// never spun in a unit test — a real `tcgetpgrp`/poll on a live PTY hangs without a child process.
/// Nothing here DECIDES anything: the fold, the edge-detection and the dedupe all live in
/// ``ClaudePaneDetector``, whose inputs are injected values and which is tested that way.
///
/// ## Why there is no reducer beside them any more
/// There was: a `ForegroundProcessDetector` holding its own ``ClaudeStatusMachine``, its own
/// basename edge anchor and its own status dedupe anchor. ``ClaudePaneDetector`` exists because two
/// machines per pane fight — both emit type-27 with no reconciliation, and neither owns the
/// `.done → .idle` decay — so detection was fused into ONE machine and this one stopped being
/// constructed anywhere in the host. What kept it compiling was its own test file, which is the
/// shape the one-implementation rule names outright: a second implementation surviving as a test
/// fake. Its `StatusTriple` was the one live part and is now ``ClaudeStatusTriple``, in the module
/// that owns the vocabulary; its `basename`/`canonicalName` were forwarding faces over
/// ``ForegroundProcessName``, which callers now ask directly.

/// The cheap probe: a PTY's foreground-process name, resolved from three Darwin syscalls and
/// nothing else. Feeds ``ClaudePaneDetector/sample(name:at:)``.
///
/// ## Resolution (docs/42 W10)
/// 1. `tcgetpgrp(masterFD)` → the PTY's foreground process GROUP id (the pgid the kernel
///    routes signals/input to — the leaf the user is interacting with).
/// 2. `proc_pidpath(pgid, …)` → the executable path of that process; basename = the last
///    path component.
/// 3. On any failure (no foreground group, the process exited mid-read, a permission error)
///    → `""` (validate-then-drop: clears presence, never traps).
public enum PTYForegroundProbe {
    /// Resolves the foreground-process basename for a PTY master fd, or `""` on any failure.
    ///
    /// SAFETY: `tcgetpgrp` / `proc_pidpath` are plain Darwin syscalls over an fd the caller
    /// owns; the path buffer is a fixed `MAXPATHLEN` stack array, and the returned length is
    /// validated (`> 0`) before constructing a String — never over-reads.
    public static func foregroundName(masterFD: Int32) -> String {
        guard masterFD >= 0 else { return "" }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return "" }
        // `proc_pidpath` fills the executable path; a returned length ≤ 0 means the lookup
        // failed (process gone / not permitted) → clear presence.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pgid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        let path = String(bytes: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), encoding: .utf8) ?? ""
        // Canonical, not raw basename: the Claude Code native installer's executable is NAMED
        // by its version (`…/claude/versions/2.1.218`) — the raw basename would defeat the
        // claude classifier and label the pane "2.1.218".
        return ForegroundProcessName.canonicalName(of: path)
    }
}

/// The DEEP probe (herdr's `foreground_job`, macOS): every process in the PTY's foreground process
/// GROUP with comm name + argv, feeding the pure ``AgentJobIdentifier``. Used only when the cheap
/// probe above returns a generic runtime/shell (the npm-wrapped `claude` case) — never on the steady
/// path. The identification logic is tested via injected ``ForegroundJob`` values.
public enum ForegroundJobProbe {
    /// Collects the foreground job for a PTY master fd, or `nil` when there is no foreground
    /// group / it cannot be enumerated. Bounded work: one `proc_listpids` over the pgid (buffer
    /// grown geometrically, ≤ 8 tries) + per-pid `proc_pidinfo`/`sysctl` — all plain syscalls,
    /// every length validated before reads (validate-then-drop).
    public static func job(masterFD: Int32) -> ForegroundJob? {
        guard masterFD >= 0 else { return nil }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return nil }
        let pids = processGroupPIDs(pgid)
        guard !pids.isEmpty else { return nil }
        var processes: [ForegroundJobProcess] = []
        for pid in pids {
            guard var info = bsdInfo(pid), info.pbi_pgid == UInt32(pgid) else { continue }
            let comm = withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
                String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            let args = processArgs(pid)
            processes.append(ForegroundJobProcess(
                pid: pid,
                name: comm,
                argv0: args?.first.map(normalizeArgv0),
                argv: args,
            ))
        }
        guard !processes.isEmpty else { return nil }
        return ForegroundJob(processGroupID: pgid, processes: processes)
    }

    /// A login shell's argv0 carries a leading `-` — strip it (herdr does the same).
    private static func normalizeArgv0(_ argv0: String) -> String {
        argv0.hasPrefix("-") ? String(argv0.dropFirst()) : argv0
    }

    private static func processGroupPIDs(_ pgid: pid_t) -> [pid_t] {
        var capacity = 64
        for _ in 0..<8 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteCount = buffer.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), raw.baseAddress, Int32(raw.count))
            }
            guard byteCount > 0 else { return [] }
            let count = Int(byteCount) / MemoryLayout<pid_t>.size
            if count < capacity {
                return Array(buffer.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard got == size else { return nil }
        return info
    }

    /// argv via `sysctl(KERN_PROCARGS2)` (two-call size-then-fill): the buffer holds
    /// `argc`, the exec path, padding NULs, then the NUL-separated argv (env follows —
    /// deliberately not read past `argc` strings).
    private static func processArgs(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        // Skip the exec path…
        while index < size, buffer[index] != 0 { index += 1 }
        // …and its padding NULs.
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        var current: [UInt8] = []
        while index < size, argv.count < Int(argc) {
            let byte = buffer[index]
            index += 1
            if byte == 0 {
                argv.append(String(bytes: current, encoding: .utf8) ?? "")
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        guard !argv.isEmpty else { return nil }
        return argv
    }
}
