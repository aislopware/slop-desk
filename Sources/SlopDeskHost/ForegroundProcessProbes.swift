import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect

/// W10 — WHO holds a pane's PTY foreground (docs/41 §4.2 signal 1, docs/42 W10). The primary,
/// zero-config agent-detection input: a low-rate poll asks per terminal pane and the host folds the
/// answer into that pane's detector.
///
/// ## A face over two doors, and nothing else
/// Both questions used to be answered HERE, in Swift, out of six Darwin syscalls — `tcgetpgrp`,
/// `proc_pidpath`, `proc_listpids`, `proc_pidinfo`, `sysctl(KERN_PROCARGS2)` — plus a hand-rolled
/// `argv` walk, and then the deep answer was staged back across the FFI boundary one field at a
/// time so `rust/slopdesk-agent` could identify it. The syscalls are `rust/slopdesk-posix::proc`
/// now and the two halves meet in `rust/slopdesk-ffi::foreground`, so each question is one call.
///
/// That is also what retired the old hang-safety caveat. There is nothing here to unit-test around
/// — no buffer arithmetic, no length validation, no `withUnsafeBytes` over a kernel struct — and the
/// probes themselves are tested in Rust, where a fixture is a value rather than a live PTY.
public enum PTYForegroundProbe {
    /// The CANONICAL name of the program holding the PTY's foreground group, or `""` on any failure
    /// — no foreground group, the process exited mid-read, a permission error. All three clear
    /// presence rather than trap (validate-then-drop).
    ///
    /// Canonical, not raw: the Claude Code native installer NAMES its executable by version
    /// (`…/claude/versions/2.1.218`), so a raw basename would defeat the `claude` classifier and
    /// print a version string in the sidebar's program slot.
    public static func foregroundName(masterFD: Int32) -> String {
        guard masterFD >= 0 else { return "" }
        var out = [UInt8](repeating: 0, count: 256)
        var needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_pty_foreground_name(masterFD, buffer.baseAddress, buffer.count)
        }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_pty_foreground_name(masterFD, buffer.baseAddress, buffer.count)
            }
        }
        guard needed > 0, needed <= out.count else { return "" }
        return String(bytes: out[0..<needed], encoding: .utf8) ?? ""
    }

    /// The DEEP probe: which agent holds the foreground group, read from every process in it with
    /// its `comm` name and argv. `nil` when there is no foreground group or nobody in it is an
    /// agent.
    ///
    /// It answers the npm-wrapped case, where the group leader is `node` and the agent's name is
    /// only in someone's argv — so a caller reaches for it exactly when ``foregroundName(masterFD:)``
    /// returned a generic runtime or shell. It costs a process-group enumeration, never on the
    /// steady path.
    public static func agent(masterFD: Int32) -> AgentKind? {
        guard masterFD >= 0 else { return nil }
        return AgentKind.at(index: Int(slopdesk_pty_foreground_agent(masterFD)))
    }
}
