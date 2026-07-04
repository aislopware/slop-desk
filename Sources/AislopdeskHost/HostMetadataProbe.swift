#if os(macOS)
import AislopdeskProtocol
import Darwin
import Foundation

/// E4 — the THIN OS shim that backs the host metadata RPC by running the real git/lsof/proc/FileManager
/// queries for ONE pane (its PTY master fd + shell pid). It conforms to ``MetadataQuerying`` so the PURE
/// ``MetadataResponseBuilder`` can drive it; **compiled + code-reviewed ONLY** — never instantiated in a
/// unit test (the hang-safety rule, exactly like ``PTYForegroundProbe``: real subprocess / `proc_*` work
/// on a live PTY hangs / depends on the host environment). The decision logic (verb mapping, path
/// confinement, caps) lives in the pure builder; this file is a straight, defensive translation of OS
/// queries into the shared ``MetadataCodec`` value types.
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
    private static let maxGitFiles = 4096
    private static let maxDirEntries = 4096
    private static let maxSessions = 512
    /// The opaque-read budget for the source-side bounded reads (`readAgentSession` / `gitDiff`). It
    /// MIRRORS ``MetadataResponseBuilder/defaultMaxOpaquePayloadBytes`` (15 MiB) so an opaque read is
    /// bounded at the SOURCE — we pull at most `cap + 1` bytes so the builder's `cappedOpaque()` still
    /// trims an already-bounded tail (and its "was truncated" signal survives) instead of letting a
    /// pathological session file / huge `git diff` spike per-request RAM before the cap is applied.
    private static let maxOpaqueReadBytes = 15 * 1024 * 1024
    private static let gitPath = "/usr/bin/git"
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

    // MARK: - git status (porcelain v1 -b) + diff

    func gitStatus(cwd: String) -> MetadataCodec.GitStatusPayload {
        // `-c core.quotepath=false` disables git's default octal-escaping/quoting of non-ASCII paths
        // (`"b\303\241o..."`) so accented/CJK filenames flow through verbatim as UTF-8 — both for display
        // and as the `gitDiff` pathspec, which would otherwise match nothing against the quoted literal.
        guard let output = Self.runProcessString(
            Self.gitPath, ["-c", "core.quotepath=false", "-C", cwd, "status", "--porcelain", "-b"],
        ) else {
            return .noRepo
        }
        var hasRepo = false
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        var files: [MetadataCodec.GitFileChange] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            hasRepo = true
            if line.hasPrefix("## ") {
                Self.parseBranchHeader(line.dropFirst(3), branch: &branch, ahead: &ahead, behind: &behind)
            } else if line.count >= 3 {
                if let change = Self.parseStatusLine(line), files.count < Self.maxGitFiles {
                    files.append(change)
                }
            }
        }
        guard hasRepo else { return .noRepo }
        let remote = Self.runProcessString(Self.gitPath, ["-C", cwd, "remote", "get-url", "origin"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // E6 WI-7: the precise By-Project grouping key — the repo's absolute toplevel. Best-effort like
        // every other probe (a missing binary / non-repo / detached state → empty; the client then falls
        // back to the pane cwd).
        let toplevel = Self.gitToplevel(cwd: cwd) ?? ""
        return MetadataCodec.GitStatusPayload(
            hasRepo: true, branch: branch, remoteURL: remote, repoRoot: toplevel,
            ahead: ahead, behind: behind, files: files,
        )
    }

    func gitDiff(cwd: String, file: String) -> Data? {
        Self.resolveGitDiff(cwd: cwd, file: file) { Self.runProcessData(Self.gitPath, $0) }
    }

    /// The repo's absolute toplevel for `cwd` (`git -C cwd rev-parse --show-toplevel`), trimmed of the
    /// trailing newline; `nil` when `cwd` is not inside a repo / git is missing (the best-effort fallback).
    static func gitToplevel(cwd: String) -> String? {
        let top = runProcessString(gitPath, ["-C", cwd, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return top.isEmpty ? nil : top
    }

    /// The ORDERED `git diff` invocations the resolver tries for a repo-ROOT-relative `file`, all rooted
    /// at the repo `repoRoot` (NEVER the pane cwd — porcelain status paths are repo-root-relative, so a
    /// subdir-cwd diff of a root-relative pathspec matches nothing). The bases, in order:
    ///  1. `diff HEAD` — the combined change vs the last commit, so a STAGED/index-only change shows just
    ///     like an unstaged worktree change (the medium finding: `git diff` alone is empty for a staged file).
    ///  2. `diff` — the plain unstaged worktree diff (the fallback for a repo with no commits, where
    ///     `diff HEAD` errors, but a tracked file is modified in the worktree).
    ///  3. `diff --cached` — the staged index-vs-HEAD diff (the no-HEAD repo where a freshly-staged add
    ///     lives ONLY in the index and neither of the above shows it).
    /// A PURE arg-builder (no I/O) so the base ordering is unit-pinned without spinning a `git` Process.
    static func gitDiffArgumentPlan(repoRoot: String, file: String) -> [[String]] {
        [
            ["-C", repoRoot, "diff", "HEAD", "--", file],
            ["-C", repoRoot, "diff", "--", file],
            ["-C", repoRoot, "diff", "--cached", "--", file],
        ]
    }

    /// Resolves the `git diff` for a repo-ROOT-relative `file` whose pane cwd is `cwd`, returning the
    /// FIRST non-empty diff across the ``gitDiffArgumentPlan`` bases. `run` is the injected git arg-runner
    /// (path-relative argv → captured stdout bytes, or `nil` on a spawn failure) — injected so the
    /// subdir-relativity + staged-base logic is unit-pinned WITHOUT a real `Process` (the hang-safety rule).
    ///
    /// **The subdir fix:** the diff is rooted at the repo toplevel (`git rev-parse --show-toplevel`), not
    /// the possibly-subdir `cwd`, so a root-relative pathspec from `git status` resolves. When the toplevel
    /// can't be resolved (non-repo / git missing) it falls back to `cwd` (best-effort — the empty diff the
    /// builder maps to `.notFound`/`.ok`). A nil/empty result from one base falls through to the next; an
    /// all-empty chain returns the last result (empty `Data` → `.ok` empty, or `nil` → `.notFound`), the
    /// SAME mapping the single-command path produced for an unchanged/untracked file.
    static func resolveGitDiff(cwd: String, file: String, run: ([String]) -> Data?) -> Data? {
        let topRaw = run(["-C", cwd, "rev-parse", "--show-toplevel"])
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = topRaw.isEmpty ? cwd : topRaw
        var last: Data?
        for args in gitDiffArgumentPlan(repoRoot: root, file: file) {
            let data = run(args)
            if let data, !data.isEmpty { return data }
            last = data ?? last
        }
        return last
    }

    /// Parses a porcelain v1 `-b` branch header: `<branch>...<upstream> [ahead N, behind M]`, or a bare
    /// `<branch>`, or `HEAD (no branch)` (detached → empty branch). Defensive: a missing field defaults.
    static func parseBranchHeader(
        _ rest: Substring, branch: inout String, ahead: inout Int32, behind: inout Int32,
    ) {
        var head = String(rest)
        if let open = head.firstIndex(of: "["), let close = head.firstIndex(of: "]"), open < close {
            let inside = head[head.index(after: open)..<close]
            for token in inside.split(separator: ",") {
                let trimmed = String(token).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead ") {
                    ahead = Int32(trimmed.dropFirst("ahead ".count)) ?? 0
                } else if trimmed.hasPrefix("behind ") {
                    behind = Int32(trimmed.dropFirst("behind ".count)) ?? 0
                }
            }
            head = String(head[..<open])
        }
        let name = head.components(separatedBy: "...").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        branch = name.hasPrefix("HEAD") ? "" : name
    }

    /// Parses a porcelain v1 status line `XY <path>` (rename `XY old -> new` keeps the new path); the
    /// `XY` chars are packed via ``packStatus``. `nil` for a malformed line.
    static func parseStatusLine(_ line: Substring) -> MetadataCodec.GitFileChange? {
        guard line.count >= 3 else { return nil }
        let x = line[line.startIndex]
        let y = line[line.index(after: line.startIndex)]
        // The path starts at index 3 (the `XY` pair + one space separator).
        let pathStart = line.index(line.startIndex, offsetBy: 3)
        var path = String(line[pathStart...])
        if let range = path.range(of: " -> ") {
            // A rename `old -> new`: keep the NEW path (what the worktree now holds).
            path = String(path[range.upperBound...])
        }
        guard !path.isEmpty else { return nil }
        return MetadataCodec.GitFileChange(statusCode: packStatus(x, y), path: path)
    }

    /// Maps a porcelain status char to a 4-bit code. **The client (WI-5) MUST mirror this inverse** to
    /// render the change category. Convention: space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9 (other=15).
    static func statusNibble(_ char: Character) -> UInt8 {
        switch char {
        case " ": 0
        case "M": 1
        case "A": 2
        case "D": 3
        case "R": 4
        case "C": 5
        case "U": 6
        case "?": 7
        case "!": 8
        case "T": 9
        default: 15
        }
    }

    /// Packs the porcelain `X` (index) and `Y` (worktree) status chars into one byte (high nibble = X,
    /// low nibble = Y) — the ``MetadataCodec/GitFileChange/statusCode`` host-defined packing.
    static func packStatus(_ x: Character, _ y: Character) -> UInt8 {
        (statusNibble(x) << 4) | statusNibble(y)
    }

    // MARK: - directory listing (one level, lazy)

    func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absolutePath, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let names = try? fm.contentsOfDirectory(atPath: absolutePath) else { return nil }
        var out: [MetadataCodec.DirEntry] = []
        for name in names.sorted() {
            var entryIsDir: ObjCBool = false
            // swiftlint:disable:next legacy_objc_type
            let full = (absolutePath as NSString).appendingPathComponent(name)
            _ = fm.fileExists(atPath: full, isDirectory: &entryIsDir)
            out.append(MetadataCodec.DirEntry(isDir: entryIsDir.boolValue, name: name))
            if out.count >= Self.maxDirEntries { break }
        }
        return out
    }

    // MARK: - agent sessions (Claude / codex / opencode)

    /// Auto-enumerates the agent sessions discoverable for `project` — Claude Code + OpenCode ONLY.
    ///
    /// **Codex auto-enumeration is intentionally DEFERRED (Claude-first scope reduction), NOT removed.**
    /// There is deliberately no `codexSessions` enumerator here, so a `~/.codex/sessions` transcript is never
    /// auto-discovered into this list. The codex scaffolding is kept intact ON PURPOSE — ``AgentKind`` still
    /// carries `.codex`, ``sessionRoots()`` still lists the codex root, and ``readAgentSession(id:)`` still
    /// serves an EXPLICIT absolute codex session id (the shipped E4 on-disk read capability). So only the
    /// auto-discovery half is deferred; the explicit-id read path stays live. E9 surfaces only Claude as the
    /// first-class agent. (E9 carry-over #3 — see `docs/DECISIONS.md`.)
    func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        var out = Self.claudeSessions(project: project)
        out.append(contentsOf: Self.opencodeSessions(project: project))
        out.sort { $0.mtimeMS > $1.mtimeMS }
        return Array(out.prefix(Self.maxSessions))
    }

    func hostName() -> String? {
        // The machine's own name ("mac-studio.local") — the `hostInfo` verb's answer. Pane-agnostic,
        // no file access; `ProcessInfo` resolves it without a DNS round-trip.
        ProcessInfo.processInfo.hostName
    }

    func readAgentSession(id: String) -> Data? {
        // Defense in depth (the builder already rejected `..`): confine the resolved file to the known
        // session roots so an absolute id outside them can't exfiltrate an arbitrary host file.
        guard id.hasPrefix("/") else { return nil }
        // swiftlint:disable:next legacy_objc_type
        let path = (id as NSString).standardizingPath
        let pathC = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let withinRoot = Self.sessionRoots().contains { root in
            let rootC = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return !rootC.isEmpty && pathC.count > rootC.count && Array(pathC.prefix(rootC.count)) == rootC
        }
        guard withinRoot, FileManager.default.isReadableFile(atPath: path) else { return nil }
        // Bound the read at the SOURCE: pull at most `maxOpaqueReadBytes + 1` (NOT the whole file via
        // `Data(contentsOf:)`) so the builder's `cappedOpaque()` only trims an already-bounded tail and a
        // pathological session file can't spike per-request RAM. Validate-then-drop: any open/read failure
        // → `nil` (never a trap), with the handle closed on every exit.
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Self.maxOpaqueReadBytes + 1)
    }

    /// The known agent-session roots (expanded against the host's home dir). The `~/.codex/sessions` root is
    /// listed for the READ path (``readAgentSession(id:)`` confines an explicit absolute id to a known root)
    /// even though ``listAgentSessions(project:)`` does NOT auto-enumerate codex — codex auto-enumeration is
    /// intentionally deferred (Claude-first scope reduction), so the codex root stays here BY DESIGN, not by
    /// oversight: it keeps an explicit codex session id readable while auto-discovery is the deferred half.
    private static func sessionRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.claude/projects",
            "\(home)/.codex/sessions",
            "\(home)/.local/share/opencode/storage/session",
        ]
    }

    /// Claude Code's on-disk project-slug convention: every non-alphanumeric character (not just `/`)
    /// becomes `-`, one dash per character (no collapsing of runs). Verified empirically against a real
    /// `~/.claude/projects` listing — e.g. `/Users/me/.config/nvim` stores as `-Users-me--config-nvim`
    /// (the leading `.` of `.config` becomes its OWN dash, adjacent to the `/`'s dash).
    static func claudeProjectSlug(_ project: String) -> String {
        String(project.map { $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber ? $0 : "-" })
    }

    /// Claude Code: `~/.claude/projects/<slug>/*.jsonl` where the slug is ``claudeProjectSlug(_:)``.
    /// Title is best-effort (filled by the viewer epic).
    private static func claudeSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude/projects/\(claudeProjectSlug(project))"
        return jsonlSessions(inDirectory: dir, kind: .claude, project: project, ext: "jsonl")
    }

    /// OpenCode: `~/.local/share/opencode/storage/session/<slug>/*.json`.
    private static func opencodeSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let slug = project.replacingOccurrences(of: "/", with: "-")
        let dir = "\(home)/.local/share/opencode/storage/session/\(slug)"
        return jsonlSessions(inDirectory: dir, kind: .opencode, project: project, ext: "json")
    }

    /// Enumerates `<dir>/*.<ext>` into ``MetadataCodec/AgentSessionInfo`` (id = absolute file path,
    /// mtime from the file attrs). Missing dir → empty (validate-then-drop).
    private static func jsonlSessions(
        inDirectory dir: String, kind: MetadataCodec.AgentKind, project: String, ext: String,
    ) -> [MetadataCodec.AgentSessionInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [MetadataCodec.AgentSessionInfo] = []
        for name in names where name.hasSuffix(".\(ext)") {
            // swiftlint:disable:next legacy_objc_type
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(MetadataCodec.AgentSessionInfo(
                agentKindByte: kind.rawValue,
                id: path,
                title: "",
                cwd: project,
                mtimeMS: Int64(mtime * 1000),
            ))
            if out.count >= maxSessions { break }
        }
        return out
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
            return ForegroundProcessDetector.basename(of: String(cString: pathBuffer))
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        return String(cString: nameBuffer)
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

    /// Whether `accumulated` captured opaque bytes have exceeded the source-side read budget
    /// (``maxOpaqueReadBytes``, mirroring the builder's 15 MiB opaque cap). A PURE predicate (no I/O) so
    /// the byte-budgeted drain loop's stop condition is unit-pinned WITHOUT spinning a `Process` /
    /// `FileHandle` in a test (the hang-safety rule keeps those compiled-and-reviewed only). `cap` → false,
    /// `cap + 1` → true, so the loop stops once the captured buffer is one byte past the cap and the
    /// builder's `cappedOpaque()` still trims an already-bounded tail.
    static func opaqueBudgetExceeded(_ accumulated: Int) -> Bool {
        accumulated > maxOpaqueReadBytes
    }

    /// Runs `path arguments`, returning captured stdout bytes (stderr discarded). `nil` if the binary
    /// is missing / not executable / cannot spawn. stdout is drained in CHUNKS before `waitUntilExit` so
    /// a large `git diff` can neither deadlock on a full pipe buffer nor spike per-request RAM: once the
    /// accumulated bytes exceed the opaque budget (``opaqueBudgetExceeded``, i.e. one past the cap so the
    /// builder still sees a truncation) the child is `terminate()`d and reading stops — bounding the read
    /// at the SOURCE while still draining-before-wait.
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
            if opaqueBudgetExceeded(data.count) {
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
