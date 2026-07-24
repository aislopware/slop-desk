import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol

/// W10 — host foreground-process watch (docs/41 §4.2 signal 1, docs/42 W10). The PRIMARY,
/// zero-config Claude-Code detection path (Decision #5: process-watch + manifest FIRST, the
/// hooks installer SECOND/opt-in). The host resolves each terminal pane/PTY's foreground
/// process basename and drives detection from it.
///
/// **Pure core / thin shim split (hang-safety).** This file is TWO pieces:
///
/// - ``ForegroundProcessDetector`` — the PURE core. Given a per-channel foreground-process
///   NAME from an INJECTED source, it (a) edge-detects basename changes to decide when to
///   emit a type-26 ``WireMessage/foregroundProcess(name:)``, and (b) folds a
///   `processPresent(claude?)` signal through the embedded ``ClaudeStatusMachine`` to decide
///   when a type-27 ``WireMessage/claudeStatus(state:kind:label:)`` status update changed.
///   It NEVER touches a PTY, syscall, or socket — it is a deterministic value-in/value-out
///   reducer, unit-tested by feeding process names directly (`ForegroundProcessWatcherTests`).
///
/// - ``PTYForegroundProbe`` — the THIN OS shim (compiled + code-reviewed only, NEVER spun in a
///   test per the hang-safety rule). It does the real PTY foreground-pgrp resolution
///   (`tcgetpgrp(masterFD)` → `proc_pidpath`/`proc_name`) on a low-rate poll. It feeds the
///   pure core; the core decides everything.
///
/// **Dedupe / debounce.** Type-26 is emitted only on a basename EDGE (the process actually
/// changed) — a 1 Hz poll that re-reads `"zsh"` ten times emits ONE message. Type-27 is
/// emitted only when the machine's rolled-up `(status, kind, label)` triple actually changed,
/// so an idle `claude` does not spam identical status frames down the CONTROL channel.
public struct ForegroundProcessDetector: Sendable {
    /// The matcher used to classify a basename as `claude` (exact basename match — no
    /// `claudefoo` false positive). Reused from W7 so there is one classifier, not two.
    private let matcher: ClaudeManifestMatcher

    /// The embedded per-pane state machine (W7). `processPresent(true/false)` is its FLOOR
    /// signal; the richer hook/manifest signals (other W10 components) feed the SAME machine
    /// instance when this detector is the one driving a pane, but the watcher only ever
    /// supplies presence — it never invents a working/blocked status from a process name.
    private var machine: ClaudeStatusMachine

    /// The last foreground basename we emitted a type-26 for (`nil` before the first sample).
    /// Edge-trigger anchor: a new sample emits type-26 iff its basename differs from this.
    private var lastEmittedName: String?

    /// The last `(state, kind, label)` triple we emitted a type-27 for. Dedupe anchor: a new
    /// machine verdict emits type-27 iff this triple changed. `nil` before the first emit.
    private var lastEmittedStatus: StatusTriple?

    /// The raw wire shape of a type-27 emission — the three fields the machine resolves,
    /// captured so dedupe compares the WIRE payload (not the richer `ClaudeStatus` enum).
    public struct StatusTriple: Sendable, Equatable {
        public let state: UInt8
        public let kind: UInt8
        public let label: String
        public init(state: UInt8, kind: UInt8, label: String) {
            self.state = state
            self.kind = kind
            self.label = label
        }
    }

    /// One decision: the (possibly empty) CONTROL messages to enqueue for this sample.
    public struct Emission: Sendable, Equatable {
        /// The type-26 `foregroundProcess(name:)` to send, or `nil` (no basename edge).
        public var foreground: WireMessage?
        /// The type-27 `claudeStatus(...)` to send, or `nil` (status unchanged).
        public var status: WireMessage?

        public var isEmpty: Bool { foreground == nil && status == nil }

        /// Flattened for the caller's `enqueueControl([WireMessage])` — foreground first
        /// (presence floor), then the richer status, mirroring the machine's precedence.
        public var messages: [WireMessage] {
            var out: [WireMessage] = []
            if let foreground { out.append(foreground) }
            if let status { out.append(status) }
            return out
        }
    }

    public init(doneToIdleTimeout: TimeInterval = 8) {
        matcher = ClaudeManifestMatcher()
        machine = ClaudeStatusMachine(doneToIdleTimeout: doneToIdleTimeout)
        lastEmittedName = nil
        lastEmittedStatus = nil
    }

    /// Fold one foreground-process sample at absolute time `now`, returning the CONTROL
    /// messages to enqueue. `name` is the resolved foreground basename (or path — the matcher
    /// takes the basename); `""` / a non-claude name clears the presence floor to `.none`.
    ///
    /// Pure + idempotent: re-feeding the SAME name yields an empty emission (the edge/dedupe
    /// anchors absorb it). Validate-then-drop: any string is tolerated (empty, huge, hostile)
    /// — never traps, never force-unwraps.
    public mutating func sample(name rawName: String, at now: TimeInterval) -> Emission {
        // Normalize to the basename for both the wire and the classifier — a path like
        // `/usr/local/bin/claude` emits `"claude"` on the wire (the client only needs the
        // basename) and classifies as present.
        let base = Self.basename(of: rawName)

        var emission = Emission()

        // (a) Type-26 edge: emit only when the basename actually changed from the last emit.
        if base != lastEmittedName {
            lastEmittedName = base
            emission.foreground = .foregroundProcess(name: base)
        }

        // (b) Drive the machine's presence FLOOR. `claude` present → at least `.idle`; any
        //     other (or empty) name → `.none` (presence absent forces termination, which the
        //     machine handles by clearing all state).
        let present = matcher.isClaudeRunning(processName: base)
        machine.reduce(.processPresent(present), at: now)

        if let status = statusEmissionIfChanged() {
            emission.status = status
        }
        return emission
    }

    /// A bare clock tick — no new process sample, only time advance (drives the machine's
    /// `done → idle` decay). Emits type-27 iff the decay changed the status. Type-26 is never
    /// emitted on a tick (the foreground process did not change).
    public mutating func tick(at now: TimeInterval) -> Emission {
        machine.reduce(.tick, at: now)
        var emission = Emission()
        if let status = statusEmissionIfChanged() {
            emission.status = status
        }
        return emission
    }

    /// The current rolled-up status (diagnostics / the live wiring's per-pane rollup).
    public var status: ClaudeStatus { machine.status }

    // MARK: - Status dedupe

    /// Returns a type-27 `claudeStatus` message iff the machine's `(state, kind, label)`
    /// triple changed since the last emit; `nil` when unchanged (dedupe).
    private mutating func statusEmissionIfChanged() -> WireMessage? {
        // The watcher never sets a Notification kind (it only supplies presence), so the
        // wire `kind` is always `0` here; the richer kind arrives via the hook listener's
        // own machine. The label likewise stays empty for a presence-only transition.
        let triple = StatusTriple(
            state: UInt8(truncatingIfNeeded: machine.status.urgency),
            kind: 0,
            label: machine.displayLabel ?? "",
        )
        if triple == lastEmittedStatus { return nil }
        lastEmittedStatus = triple
        return .claudeStatus(state: triple.state, kind: triple.kind, label: triple.label)
    }

    /// The basename of a process path. `"/usr/local/bin/claude"` → `"claude"`; `"zsh"` → `"zsh"`;
    /// `""` → `""`. Pure string split (no `URL`, which would resolve `""` to the cwd).
    static func basename(of name: String) -> String {
        guard !name.isEmpty else { return "" }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    /// The CANONICAL process name of an executable path: the basename — except a VERSION-named
    /// executable, which resolves to the owning app directory. The Claude Code native installer
    /// lays the binary out as `…/.local/share/claude/versions/2.1.218` (the executable file IS
    /// the version string), so the raw basename defeats the exact-basename `claude` classifier
    /// AND reads as a meaningless `2.1.218` in the sidebar's shell-label slot. A pure version
    /// string names a release, not a program — walk up past it (and the layout components
    /// `versions`/`bin`/`current`/`libexec`) to the first real name. A non-version basename is
    /// returned untouched, so every other program keeps its exact-basename semantics.
    static func canonicalName(of path: String) -> String {
        let base = basename(of: path)
        guard isVersionShaped(base) else { return base }
        for component in path.split(separator: "/").dropLast().reversed() {
            let name = String(component)
            if isVersionShaped(name) { continue }
            if ["versions", "bin", "current", "libexec"].contains(name.lowercased()) { continue }
            return name
        }
        return base
    }

    /// True for a pure version string (`2.1.218`, `v1.0`) — digits and dots (an optional
    /// leading `v`), at least one dot so plain numerals (`7z`-style names, bare `2`) stay names.
    static func isVersionShaped(_ s: String) -> Bool {
        var t = Substring(s)
        if t.hasPrefix("v") || t.hasPrefix("V") { t = t.dropFirst() }
        guard t.contains("."), !t.isEmpty else { return false }
        return t.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// W10 — the THIN OS shim that resolves a PTY's foreground-process basename and feeds the
/// pure ``ForegroundProcessDetector``. **Compiled + code-reviewed ONLY** — never instantiated
/// in a unit test (the hang-safety rule: a real `tcgetpgrp`/poll on a live PTY hangs without a
/// child process). The pure decision logic is tested via the detector; this shim is a straight
/// translation of three Darwin syscalls into a basename string.
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
        let path = String(cString: buffer)
        // Canonical, not raw basename: the Claude Code native installer's executable is NAMED
        // by its version (`…/claude/versions/2.1.218`) — the raw basename would defeat the
        // claude classifier and label the pane "2.1.218".
        return ForegroundProcessDetector.canonicalName(of: path)
    }
}

/// The DEEP foreground-job probe (herdr's `foreground_job`, macOS): every process in the PTY's
/// foreground process GROUP with comm name + argv, feeding the pure ``AgentJobIdentifier``.
/// Used only when the cheap basename probe returns a generic runtime/shell (the npm-wrapped
/// `claude` case) — never on the steady path. **Compiled + code-reviewed ONLY** (hang-safety):
/// never instantiated in a unit test; the identification logic is tested via injected
/// ``ForegroundJob`` values.
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
