import Foundation

/// The per-verb payload codecs for the host metadata RPC. Each ``MetadataVerb`` that returns a
/// STRUCTURED list rides one of these manual-binary sub-codecs INSIDE the opaque
/// ``WireMessage/metadataResponse(requestID:status:payload:)`` payload — the envelope only
/// length-prefixes the bytes; these codecs give them meaning. (The `cwd` / `gitDiff` /
/// `readAgentSession` verbs carry raw UTF-8 / raw bytes and have NO nested codec — the envelope's
/// length prefix already frames them.)
///
/// All encodings are **manual big-endian binary** (never JSON/`Codable`), matching the path-1 wire
/// contract: every multi-byte integer is big-endian, every string is length-prefixed UTF-8, every list
/// is `[UInt16 count]`-prefixed. The codecs live in this caseless `enum` namespace so the value type
/// ``MetadataCodec/ProcessInfo`` does NOT shadow `Foundation.ProcessInfo` at module scope (the host
/// reads `Foundation.ProcessInfo.processInfo` and imports this module — a top-level `ProcessInfo` would
/// make that reference ambiguous and break the build).
///
/// **Validate-then-drop on untrusted bytes (a metadata payload arrives over the same trusted mesh as
/// the rest of the wire, but is still treated as hostile input):**
/// - every list `count` is checked against the reader's remaining bytes BEFORE the per-entry loop and
///   before any `reserveCapacity` — a declared count larger than the body can hold throws
///   ``SlopDeskError/truncated`` with no allocation (count-before-alloc);
/// - every length-prefixed field is read via `BigEndianReader.readBytes`, which throws `truncated`
///   rather than over-reading a hostile body;
/// - every string field is STRICT UTF-8 (an invalid sequence throws
///   ``SlopDeskError/malformedBody(_:)`` — never a lossy/replacement decode);
/// - interop discriminator bytes (`isDir`, `hasRepo`) are read as `byte != 0`, never assumed `{0,1}`;
/// - there is NO force-unwrap (`!`) on any decoded field;
/// - on ENCODE every `UInt16` length field is clamped (string bytes clamped at a Unicode-scalar
///   boundary to ≤ 65535; list counts clamped to ≤ 65535) so an absurd >64 KiB field or >65535-entry
///   list can never WRAP the length/count and corrupt the trailer.
public enum MetadataCodec {
    // MARK: - Value types

    /// One foreground process of a pane (``MetadataVerb/processes`` → `ProcessList`).
    public struct ProcessInfo: Equatable, Sendable {
        /// The process id.
        public var pid: UInt32
        /// Seconds the process has been running (0 if unknown).
        public var uptimeSec: UInt32
        /// The process basename (e.g. `-zsh`, `claude`).
        public var name: String

        public init(pid: UInt32, uptimeSec: UInt32, name: String) {
            self.pid = pid
            self.uptimeSec = uptimeSec
            self.name = name
        }
    }

    /// One listening port of a pane (``MetadataVerb/ports`` → `PortList`).
    public struct PortInfo: Equatable, Sendable {
        /// The port number.
        public var port: UInt16
        /// The transport protocol as a RAW byte (0 = tcp, 1 = udp); carried forward-tolerantly so an
        /// unknown future value never drops the entry. See ``PortProtocol`` / ``portProtocol``.
        public var proto: UInt8
        /// The owning process basename.
        public var procName: String

        public init(port: UInt16, proto: UInt8, procName: String) {
            self.port = port
            self.proto = proto
            self.procName = procName
        }

        /// The transport protocol, or `nil` for an unknown future ``proto`` byte (forward-tolerant).
        public var portProtocol: PortProtocol? { PortProtocol(rawValue: proto) }
    }

    /// One entry of a single host directory level (``MetadataVerb/listDirectory`` → `DirListing`).
    /// Leaf names only — the client joins them with the request path (lazy per-expand).
    public struct DirEntry: Equatable, Sendable {
        /// Whether the entry is a directory (read as `byte != 0`).
        public var isDir: Bool
        /// The leaf name (no path components).
        public var name: String

        public init(isDir: Bool, name: String) {
            self.isDir = isDir
            self.name = name
        }
    }

    /// One changed file in a git working tree (a `GitStatus` entry).
    public struct GitFileChange: Equatable, Sendable {
        /// The porcelain `XY` status packed into one byte (high nibble = X / index, low nibble = Y /
        /// worktree, in a host-defined packing) — carried as a RAW byte (the client unpacks it).
        public var statusCode: UInt8
        /// The repo-relative path.
        public var path: String

        public init(statusCode: UInt8, path: String) {
            self.statusCode = statusCode
            self.path = path
        }
    }

    /// The git status of a pane's cwd (``MetadataVerb/gitStatus`` → `GitStatus`). `gitBranch` is
    /// SUBSUMED here (branch + remote + ahead/behind render together with the changed-file list).
    /// When ``hasRepo`` is `false` the remaining fields are at their canonical defaults (the wire
    /// carries only the `hasRepo` byte).
    public struct GitStatusPayload: Equatable, Sendable {
        /// Whether the cwd is inside a git repository (read as `byte != 0`).
        public var hasRepo: Bool
        /// The current branch name (empty when detached or no repo).
        public var branch: String
        /// The `origin` remote URL (empty when no remote or no repo).
        public var remoteURL: String
        /// The absolute git toplevel (`git rev-parse --show-toplevel`) — the precise By-Project grouping
        /// key. Empty when ``hasRepo`` is `false` (a no-repo payload is still only the single
        /// `0` byte) and may be empty even inside a repo if the host probe could not resolve it; the
        /// client falls back to the pane cwd in that case (never a hard dependency). Carried ONLY when
        /// ``hasRepo`` is `true`, length-prefixed UTF-8 right after ``remoteURL`` — same idiom as `branch`.
        public var repoRoot: String
        /// Commits the branch is ahead of its upstream (0 when no upstream).
        public var ahead: Int32
        /// Commits the branch is behind its upstream (0 when no upstream).
        public var behind: Int32
        /// The number of entries in the repo's stash (`git stash list`) — a repo-global count (0 when the
        /// stash is empty). Carried ONLY when ``hasRepo`` is `true`, as an `Int32` BE right after ``behind``
        /// (before the file list). Lets the sidebar surface `$N` without the client shelling out to git.
        public var stashCount: Int32
        /// The changed files.
        public var files: [GitFileChange]

        public init(
            hasRepo: Bool,
            branch: String,
            remoteURL: String,
            repoRoot: String = "",
            ahead: Int32,
            behind: Int32,
            stashCount: Int32 = 0,
            files: [GitFileChange],
        ) {
            self.hasRepo = hasRepo
            self.branch = branch
            self.remoteURL = remoteURL
            self.repoRoot = repoRoot
            self.ahead = ahead
            self.behind = behind
            self.stashCount = stashCount
            self.files = files
        }

        /// The canonical "not a git repo" payload (all fields at their wire-default).
        public static let noRepo = Self(
            hasRepo: false,
            branch: "",
            remoteURL: "",
            repoRoot: "",
            ahead: 0,
            behind: 0,
            stashCount: 0,
            files: [],
        )

        /// The porcelain breakdown folded from ``files``' packed `XY` status codes (high nibble = X /
        /// index, low = Y / worktree; space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9 — the host probe's
        /// packing). Each file counts INDEPENDENTLY per axis — an `MM` file is BOTH staged and
        /// modified; `??` is untracked; a `U` on either side (or `AA`/`DD`) is a conflict. The ONE
        /// fold shared by the client's `PaneGitSummary` and the host's type-35 push, so the two
        /// surfaces can never disagree on what "3 modified" means.
        public struct FoldedCounts: Equatable, Sendable {
            public var staged: Int
            public var modified: Int
            public var untracked: Int
            public var conflicted: Int

            public init(staged: Int = 0, modified: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
                self.staged = staged
                self.modified = modified
                self.untracked = untracked
                self.conflicted = conflicted
            }
        }

        /// See ``FoldedCounts``.
        public var foldedCounts: FoldedCounts {
            var counts = FoldedCounts()
            for file in files {
                let x = file.statusCode >> 4, y = file.statusCode & 0x0F
                if x == 7, y == 7 {
                    counts.untracked += 1 // ??
                } else if x == 6 || y == 6 || (x == 2 && y == 2) || (x == 3 && y == 3) {
                    counts.conflicted += 1 // unmerged: U on either side, or the AA / DD both-changed states
                } else {
                    if x != 0 { counts.staged += 1 } // index change (X not space)
                    if y != 0 { counts.modified += 1 } // worktree change (Y not space)
                }
            }
            return counts
        }
    }

    /// One agent (Claude/codex/opencode) session file for a project
    /// (``MetadataVerb/listAgentSessions`` → `AgentSessionList`).
    public struct AgentSessionInfo: Equatable, Sendable {
        /// The agent that owns the session as a RAW byte (0 = claude, 1 = codex, 2 = opencode);
        /// carried forward-tolerantly. See ``AgentKind`` / ``agentKind``.
        public var agentKindByte: UInt8
        /// The session id / path the client passes back to ``MetadataVerb/readAgentSession``.
        public var id: String
        /// A human-readable session title (may be empty).
        public var title: String
        /// The session's project cwd.
        public var cwd: String
        /// The file's last-modified time in milliseconds since the Unix epoch (newest first when sorted).
        public var mtimeMS: Int64

        public init(agentKindByte: UInt8, id: String, title: String, cwd: String, mtimeMS: Int64) {
            self.agentKindByte = agentKindByte
            self.id = id
            self.title = title
            self.cwd = cwd
            self.mtimeMS = mtimeMS
        }

        /// The owning agent, or `nil` for an unknown future ``agentKindByte`` (forward-tolerant).
        public var agentKind: AgentKind? { AgentKind(rawValue: agentKindByte) }
    }

    /// The transport protocol of a ``PortInfo`` (the RAW ``PortInfo/proto`` byte's meaning).
    public enum PortProtocol: UInt8, Sendable, Equatable, CaseIterable {
        case tcp = 0
        case udp = 1
    }

    /// The agent that owns an ``AgentSessionInfo`` (the RAW ``AgentSessionInfo/agentKindByte`` byte).
    public enum AgentKind: UInt8, Sendable, Equatable, CaseIterable {
        case claude = 0
        case codex = 1
        case opencode = 2
    }

    // MARK: - ProcessList  ([UInt16 count] then [UInt32 pid][UInt32 uptimeSec][UInt16 nameLen][name])

    /// Fixed bytes per ``ProcessInfo`` entry (pid + uptime + nameLen; name may be empty).
    private static let processEntryFixedBytes = 4 + 4 + 2

    /// Encodes a process list. Count clamped to ≤ 65535; each name clamped to ≤ 65535 UTF-8 bytes.
    public static func encodeProcessList(_ items: [ProcessInfo]) -> Data {
        var out = Data()
        let count = clampedCount(items.count)
        out.appendBE(UInt16(count))
        for item in items.prefix(count) {
            out.appendBE(item.pid)
            out.appendBE(item.uptimeSec)
            appendString(item.name, to: &out)
        }
        return out
    }

    /// Decodes a process list, validating the declared count before allocating and dropping a truncated
    /// or non-UTF-8 body (throws), never trapping.
    public static func decodeProcessList(_ data: Data) throws -> [ProcessInfo] {
        var reader = BigEndianReader(data)
        let count = try Int(reader.readUInt16())
        // count-before-alloc: a count the body cannot possibly hold is rejected before reserveCapacity.
        guard reader.bytesRemaining >= count * processEntryFixedBytes else { throw SlopDeskError.truncated }
        var items: [ProcessInfo] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let pid = try reader.readUInt32()
            let uptimeSec = try reader.readUInt32()
            let name = try readString(&reader, "processList.name")
            items.append(ProcessInfo(pid: pid, uptimeSec: uptimeSec, name: name))
        }
        return items
    }

    // MARK: - PortList  ([UInt16 count] then [UInt16 port][UInt8 proto][UInt16 nameLen][procName])

    /// Fixed bytes per ``PortInfo`` entry (port + proto + nameLen; procName may be empty).
    private static let portEntryFixedBytes = 2 + 1 + 2

    /// Encodes a port list. An empty list ("No listening ports") encodes as `[UInt16 0]`.
    public static func encodePortList(_ items: [PortInfo]) -> Data {
        var out = Data()
        let count = clampedCount(items.count)
        out.appendBE(UInt16(count))
        for item in items.prefix(count) {
            out.appendBE(item.port)
            out.append(item.proto)
            appendString(item.procName, to: &out)
        }
        return out
    }

    /// Decodes a port list (validate-then-drop, count-before-alloc).
    public static func decodePortList(_ data: Data) throws -> [PortInfo] {
        var reader = BigEndianReader(data)
        let count = try Int(reader.readUInt16())
        guard reader.bytesRemaining >= count * portEntryFixedBytes else { throw SlopDeskError.truncated }
        var items: [PortInfo] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let port = try reader.readUInt16()
            let proto = try reader.readUInt8()
            let procName = try readString(&reader, "portList.procName")
            items.append(PortInfo(port: port, proto: proto, procName: procName))
        }
        return items
    }

    // MARK: - DirListing  ([UInt16 count] then [UInt8 isDir][UInt16 nameLen][leafName])

    /// Fixed bytes per ``DirEntry`` (isDir + nameLen; name may be empty).
    private static let dirEntryFixedBytes = 1 + 2

    /// Encodes a one-level directory listing (leaf names only). Count clamped to ≤ 65535.
    public static func encodeDirListing(_ items: [DirEntry]) -> Data {
        var out = Data()
        let count = clampedCount(items.count)
        out.appendBE(UInt16(count))
        for item in items.prefix(count) {
            out.append(item.isDir ? 1 : 0)
            appendString(item.name, to: &out)
        }
        return out
    }

    /// Decodes a one-level directory listing (validate-then-drop, count-before-alloc). The `isDir`
    /// discriminator is read as `byte != 0` (never assumed `{0,1}`).
    public static func decodeDirListing(_ data: Data) throws -> [DirEntry] {
        var reader = BigEndianReader(data)
        let count = try Int(reader.readUInt16())
        guard reader.bytesRemaining >= count * dirEntryFixedBytes else { throw SlopDeskError.truncated }
        var items: [DirEntry] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let isDir = try reader.readUInt8() != 0
            let name = try readString(&reader, "dirListing.name")
            items.append(DirEntry(isDir: isDir, name: name))
        }
        return items
    }

    // MARK: - GitStatus  ([UInt8 hasRepo]; if repo: branch, remote, repoRoot, [Int32 ahead][Int32 behind][Int32 stash], files)

    /// Fixed bytes per ``GitFileChange`` (statusCode + pathLen; path may be empty).
    private static let gitFileFixedBytes = 1 + 2

    /// Encodes a git status. When `hasRepo` is `false` only the single `0` byte is written (the
    /// remaining fields are not on the wire); otherwise branch + remote + repoRoot + ahead/behind + the
    /// changed-file list follow. Strings clamped to ≤ 65535 bytes, file count clamped to ≤ 65535.
    public static func encodeGitStatus(_ status: GitStatusPayload) -> Data {
        var out = Data()
        guard status.hasRepo else {
            out.append(0)
            return out
        }
        out.append(1)
        appendString(status.branch, to: &out)
        appendString(status.remoteURL, to: &out)
        appendString(status.repoRoot, to: &out)
        out.appendBE(status.ahead)
        out.appendBE(status.behind)
        out.appendBE(status.stashCount)
        let count = clampedCount(status.files.count)
        out.appendBE(UInt16(count))
        for file in status.files.prefix(count) {
            out.append(file.statusCode)
            appendString(file.path, to: &out)
        }
        return out
    }

    /// Decodes a git status (validate-then-drop, count-before-alloc). `hasRepo` is read as `byte != 0`;
    /// `hasRepo == false` returns ``GitStatusPayload/noRepo`` regardless of any trailing bytes.
    public static func decodeGitStatus(_ data: Data) throws -> GitStatusPayload {
        var reader = BigEndianReader(data)
        let hasRepo = try reader.readUInt8() != 0
        guard hasRepo else { return .noRepo }
        let branch = try readString(&reader, "gitStatus.branch")
        let remoteURL = try readString(&reader, "gitStatus.remoteURL")
        let repoRoot = try readString(&reader, "gitStatus.repoRoot")
        let ahead = try reader.readInt32()
        let behind = try reader.readInt32()
        let stashCount = try reader.readInt32()
        let count = try Int(reader.readUInt16())
        guard reader.bytesRemaining >= count * gitFileFixedBytes else { throw SlopDeskError.truncated }
        var files: [GitFileChange] = []
        files.reserveCapacity(count)
        for _ in 0..<count {
            let statusCode = try reader.readUInt8()
            let path = try readString(&reader, "gitStatus.file.path")
            files.append(GitFileChange(statusCode: statusCode, path: path))
        }
        return GitStatusPayload(
            hasRepo: true,
            branch: branch,
            remoteURL: remoteURL,
            repoRoot: repoRoot,
            ahead: ahead,
            behind: behind,
            stashCount: stashCount,
            files: files,
        )
    }

    // MARK: - AgentSessionList  ([UInt16 count] then kind, id, title, cwd, [Int64 mtimeMS])

    /// Fixed bytes per ``AgentSessionInfo`` (kind + idLen + titleLen + cwdLen + mtimeMS; strings empty).
    private static let agentSessionFixedBytes = 1 + 2 + 2 + 2 + 8

    /// Encodes an agent-session list. Count clamped to ≤ 65535; each string clamped to ≤ 65535 bytes.
    public static func encodeAgentSessionList(_ items: [AgentSessionInfo]) -> Data {
        var out = Data()
        let count = clampedCount(items.count)
        out.appendBE(UInt16(count))
        for item in items.prefix(count) {
            out.append(item.agentKindByte)
            appendString(item.id, to: &out)
            appendString(item.title, to: &out)
            appendString(item.cwd, to: &out)
            out.appendBE(item.mtimeMS)
        }
        return out
    }

    /// Decodes an agent-session list (validate-then-drop, count-before-alloc).
    public static func decodeAgentSessionList(_ data: Data) throws -> [AgentSessionInfo] {
        var reader = BigEndianReader(data)
        let count = try Int(reader.readUInt16())
        guard reader.bytesRemaining >= count * agentSessionFixedBytes else { throw SlopDeskError.truncated }
        var items: [AgentSessionInfo] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let kind = try reader.readUInt8()
            let id = try readString(&reader, "agentSession.id")
            let title = try readString(&reader, "agentSession.title")
            let cwd = try readString(&reader, "agentSession.cwd")
            let mtimeMS = try reader.readInt64()
            items.append(AgentSessionInfo(agentKindByte: kind, id: id, title: title, cwd: cwd, mtimeMS: mtimeMS))
        }
        return items
    }

    // MARK: - Clipboard sync  (setClipboard = 15 / readClipboard = 16)

    /// One synced clipboard clip: a raw kind byte (forward-tolerant carry, like ``PortInfo/proto``)
    /// plus the content bytes (UTF-8 text or a PNG image — see ``ClipboardKind``).
    public struct ClipboardClip: Equatable, Sendable {
        /// The content kind as a RAW byte; see ``ClipboardKind`` / ``kind``.
        public var kindByte: UInt8
        /// The content: UTF-8 text bytes for ``ClipboardKind/text``, PNG bytes for
        /// ``ClipboardKind/imagePNG``. Opaque at the codec layer (PNG is not UTF-8); the APPLIER
        /// validates text strictly before use.
        public var bytes: Data

        public init(kindByte: UInt8, bytes: Data) {
            self.kindByte = kindByte
            self.bytes = bytes
        }

        public init(kind: ClipboardKind, bytes: Data) {
            self.init(kindByte: kind.rawValue, bytes: bytes)
        }

        /// The typed kind, or `nil` for an unknown future ``kindByte`` (forward-tolerant — the
        /// receiver drops the clip, never traps).
        public var kind: ClipboardKind? { ClipboardKind(rawValue: kindByte) }
    }

    /// The meaning of ``ClipboardClip/kindByte``. `0` is RESERVED for the read-response's
    /// "unchanged / empty" arm and is never a clip kind.
    public enum ClipboardKind: UInt8, Sendable, Equatable, CaseIterable {
        case text = 1
        case imagePNG = 2
    }

    /// The per-clip content cap (12 MiB) — well under the 16 MiB wire frame cap with envelope
    /// headroom. Both ends enforce it: the sender SKIPS an over-cap clip (the clipboard stays
    /// local, sync silently lags), the decoder rejects one as malformed.
    public static let maxClipboardContentBytes = 12 * 1024 * 1024

    /// The ``MetadataVerb/readClipboard`` request value meaning "baseline probe": the host replies
    /// with its current `changeCount` and NO content, so a fresh connection learns where the host
    /// clipboard stands without pulling (and applying) stale pre-connection state.
    public static let clipboardBaselineProbe: Int64 = -1

    /// Encodes a ``MetadataVerb/setClipboard`` request payload: `[UInt8 kind][content]` (the content
    /// runs to the end of the payload — the RPC envelope already frames it).
    public static func encodeClipboardSet(_ clip: ClipboardClip) -> Data {
        var out = Data(capacity: 1 + clip.bytes.count)
        out.append(clip.kindByte)
        out.append(clip.bytes)
        return out
    }

    /// Decodes a ``MetadataVerb/setClipboard`` request payload (validate-then-drop): an empty payload
    /// throws `truncated`, an over-cap content throws `malformedBody`. The kind byte is carried RAW
    /// (an unknown future kind decodes fine; the applier refuses it with `.error`).
    public static func decodeClipboardSet(_ data: Data) throws -> ClipboardClip {
        guard let kindByte = data.first else { throw SlopDeskError.truncated }
        let bytes = data.dropFirst()
        guard bytes.count <= maxClipboardContentBytes else {
            throw SlopDeskError.malformedBody("clipboardSet: content exceeds cap")
        }
        return ClipboardClip(kindByte: kindByte, bytes: Data(bytes))
    }

    /// Encodes a ``MetadataVerb/readClipboard`` request payload: the `Int64` (BE) host `changeCount`
    /// the client last saw (``clipboardBaselineProbe`` = none yet — baseline probe).
    public static func encodeClipboardReadRequest(lastSeenChangeCount: Int64) -> Data {
        var out = Data(capacity: 8)
        out.appendBE(lastSeenChangeCount)
        return out
    }

    /// Decodes a ``MetadataVerb/readClipboard`` request payload (throws `truncated` on a short body).
    public static func decodeClipboardReadRequest(_ data: Data) throws -> Int64 {
        var reader = BigEndianReader(data)
        return try reader.readInt64()
    }

    /// Encodes a ``MetadataVerb/readClipboard`` response payload:
    /// `[Int64 changeCount][UInt8 kind][content]`, where a `nil` clip writes kind `0` ("unchanged /
    /// empty / client's own push") and no content.
    public static func encodeClipboardReadResponse(changeCount: Int64, clip: ClipboardClip?) -> Data {
        var out = Data(capacity: 8 + 1 + (clip?.bytes.count ?? 0))
        out.appendBE(changeCount)
        guard let clip else {
            out.append(0)
            return out
        }
        out.append(clip.kindByte)
        out.append(clip.bytes)
        return out
    }

    /// Decodes a ``MetadataVerb/readClipboard`` response payload (validate-then-drop): kind `0`
    /// returns a `nil` clip (any trailing bytes after a kind-0 marker are malformed), an over-cap
    /// content throws `malformedBody`.
    public static func decodeClipboardReadResponse(
        _ data: Data,
    ) throws -> (changeCount: Int64, clip: ClipboardClip?) {
        var reader = BigEndianReader(data)
        let changeCount = try reader.readInt64()
        let kindByte = try reader.readUInt8()
        let bytes = try reader.readBytes(reader.bytesRemaining)
        guard kindByte != 0 else {
            guard bytes.isEmpty else {
                throw SlopDeskError.malformedBody("clipboardRead: content after kind-0 marker")
            }
            return (changeCount, nil)
        }
        guard bytes.count <= maxClipboardContentBytes else {
            throw SlopDeskError.malformedBody("clipboardRead: content exceeds cap")
        }
        return (changeCount, ClipboardClip(kindByte: kindByte, bytes: bytes))
    }

    // MARK: - Host vitals  (hostVitals = 17)

    /// The host machine's pulse (``MetadataVerb/hostVitals``): how hard the Mac on the other end is
    /// working right now. Three aggregate bytes — nothing about WHAT it runs, only how much of it.
    ///
    /// Percentages are pre-rounded by the HOST (it owns the sampling window; the client renders what
    /// it is told and never re-derives a rate from two readings). Both are clamped to `0...100` on
    /// encode AND decode, so a wrong/hostile byte can never render "197%".
    public struct HostVitals: Equatable, Sendable {
        /// All-core CPU busy percent (`0...100`) across the sampler's window — `100 - idle`, so a
        /// 10-core Mac pegged on one core reads ~10, not 100 (the Activity Monitor "% CPU LOAD"
        /// reading, not its per-process column, which sums past 100).
        public var cpuPercent: UInt8
        /// Physical memory in use percent (`0...100`): wired + app-internal (minus purgeable) +
        /// compressed over the installed RAM — the Activity Monitor "Memory Used" reading, with the
        /// file cache excluded (macOS parks the whole free pool in cache; counting it would pin
        /// every Mac at 99% and say nothing).
        public var memoryPercent: UInt8
        /// The kernel's memory-pressure level as a RAW byte (forward-tolerant carry, like
        /// ``PortInfo/proto``); see ``MemoryPressure`` / ``memoryPressure``.
        public var pressureByte: UInt8
        /// Free space in MiB on the volume the user's work lives on (the home directory's), or `nil`
        /// when the host could not read it. An ABSOLUTE figure, not a percent: a 4 TB disk at 2%
        /// free still builds, a 128 GB disk at 8% does not — only the bytes left answer "can I
        /// still work here". MiB granularity keeps the field 4 bytes and still spans 4 PiB.
        public var diskFreeMiB: UInt32?

        public init(
            cpuPercent: UInt8, memoryPercent: UInt8, pressureByte: UInt8, diskFreeMiB: UInt32? = nil,
        ) {
            self.cpuPercent = cpuPercent
            self.memoryPercent = memoryPercent
            self.pressureByte = pressureByte
            self.diskFreeMiB = diskFreeMiB
        }

        public init(
            cpuPercent: UInt8, memoryPercent: UInt8, pressure: MemoryPressure,
            diskFreeMiB: UInt32? = nil,
        ) {
            self.init(
                cpuPercent: cpuPercent, memoryPercent: memoryPercent,
                pressureByte: pressure.rawValue, diskFreeMiB: diskFreeMiB,
            )
        }

        /// The typed pressure level. An unknown future byte reads ``MemoryPressure/normal`` — a level
        /// this build cannot interpret must never light an alarm ink it cannot justify.
        public var memoryPressure: MemoryPressure {
            MemoryPressure(rawValue: pressureByte) ?? .normal
        }
    }

    /// The meaning of ``HostVitals/pressureByte`` — the kernel's own memory-pressure verdict, which
    /// is the reading that actually predicts a miserable session (a high memory PERCENT is normal on
    /// a healthy Mac; pressure is what says the machine is thrashing).
    public enum MemoryPressure: UInt8, Sendable, Equatable, CaseIterable {
        case normal = 0
        case warn = 1
        case critical = 2
    }

    /// The wire value for "the host could not read the disk". Free space is a real `0` when a volume
    /// is genuinely full, so the unreadable case needs its own value rather than borrowing zero —
    /// the client hides the metric on ``diskFreeUnknown`` and would otherwise draw a full-disk alarm
    /// for a failed syscall.
    public static let diskFreeUnknown = UInt32.max

    /// Encodes a ``MetadataVerb/hostVitals`` response payload: `[UInt8 cpu%][UInt8 mem%][UInt8
    /// pressure][UInt32 disk free MiB]`. Both percents are clamped to `0...100` at the SOURCE; a nil
    /// disk reading goes out as ``diskFreeUnknown``.
    public static func encodeHostVitals(_ vitals: HostVitals) -> Data {
        var data = Data([
            min(vitals.cpuPercent, 100),
            min(vitals.memoryPercent, 100),
            vitals.pressureByte,
        ])
        data.appendBE(vitals.diskFreeMiB ?? diskFreeUnknown)
        return data
    }

    /// Decodes a ``MetadataVerb/hostVitals`` response payload (validate-then-drop): a body shorter
    /// than 7 bytes throws ``SlopDeskError/truncated``; an out-of-range percent is CLAMPED (not
    /// thrown — the reading is still usable and a status row must not vanish over one wild byte); a
    /// longer body is tolerated, its trailer ignored, so a future field can be appended without
    /// breaking this reader.
    public static func decodeHostVitals(_ data: Data) throws -> HostVitals {
        var reader = BigEndianReader(data)
        let cpu = try reader.readUInt8()
        let mem = try reader.readUInt8()
        let pressure = try reader.readUInt8()
        let disk = try reader.readUInt32()
        return HostVitals(
            cpuPercent: min(cpu, 100), memoryPercent: min(mem, 100), pressureByte: pressure,
            diskFreeMiB: disk == diskFreeUnknown ? nil : disk,
        )
    }

    // MARK: - Code-server endpoint  (ensureCodeServer = 18)

    /// The host's answer to ``MetadataVerb/ensureCodeServer``: where (and whether) the project's
    /// code-server instance is. The `port` is meaningful ONLY when ``state`` is
    /// ``CodeServerState/ready`` — a starting instance may not have bound its socket yet (the host
    /// spawns with port `0` and learns the real port from the child's own log line), and an
    /// unavailable one has no port at all; both carry `0`.
    public struct CodeServerEndpoint: Equatable, Sendable {
        /// The lifecycle state as a RAW byte (forward-tolerant carry, like
        /// ``HostVitals/pressureByte``); see ``state``.
        public var stateByte: UInt8
        /// The TCP port the instance listens on — `0` unless ``state`` is ``CodeServerState/ready``.
        public var port: UInt16

        public init(stateByte: UInt8, port: UInt16) {
            self.stateByte = stateByte
            self.port = port
        }

        public init(state: CodeServerState, port: UInt16) {
            self.init(stateByte: state.rawValue, port: port)
        }

        /// The typed state. An unknown future byte reads ``CodeServerState/starting`` — "keep
        /// polling" is the benign fallback; a state this build cannot interpret must never render
        /// the install-hint error surface it cannot justify.
        public var state: CodeServerState {
            CodeServerState(rawValue: stateByte) ?? .starting
        }
    }

    /// The meaning of ``CodeServerEndpoint/stateByte``.
    public enum CodeServerState: UInt8, Sendable, Equatable, CaseIterable {
        /// Spawned but not confirmed listening — the client polls the verb again.
        case starting = 0
        /// Listening; ``CodeServerEndpoint/port`` is live and the WKWebView can load.
        case ready = 1
        /// No code-server binary on the host — the sidebar shows the install hint.
        case unavailable = 2
    }

    /// Encodes a ``MetadataVerb/ensureCodeServer`` response payload: `[UInt8 state][UInt16 BE port]`.
    public static func encodeCodeServerEndpoint(_ endpoint: CodeServerEndpoint) -> Data {
        var data = Data([endpoint.stateByte])
        data.appendBE(endpoint.port)
        return data
    }

    /// Decodes a ``MetadataVerb/ensureCodeServer`` response payload (validate-then-drop): a body
    /// shorter than 3 bytes throws ``SlopDeskError/truncated``; a longer body is tolerated, its
    /// trailer ignored, so a future field can be appended without breaking this reader.
    public static func decodeCodeServerEndpoint(_ data: Data) throws -> CodeServerEndpoint {
        var reader = BigEndianReader(data)
        let state = try reader.readUInt8()
        let port = try reader.readUInt16()
        return CodeServerEndpoint(stateByte: state, port: port)
    }

    // MARK: - Code-open disposition  (openInCodeServer = 19)

    /// Where the host routed a ``MetadataVerb/openInCodeServer`` request — the 1-byte response
    /// payload. The client reveals its code panel ONLY for ``workbench``; a ``hostDefault`` open
    /// (a directory, or a host without code-server) happened on the host's own screen.
    public enum CodeOpenDisposition: UInt8, Sendable, Equatable, CaseIterable {
        /// Dispatched to the embedded VS Code workbench (`code-server -r`).
        case workbench = 0
        /// Opened in the host's default app / Finder (the verb-9 behavior).
        case hostDefault = 1
    }

    /// Encodes a ``MetadataVerb/openInCodeServer`` response payload: `[UInt8 disposition]`.
    public static func encodeCodeOpenDisposition(_ disposition: CodeOpenDisposition) -> Data {
        Data([disposition.rawValue])
    }

    /// Decodes a ``MetadataVerb/openInCodeServer`` response payload (validate-then-drop): an empty
    /// body throws ``SlopDeskError/truncated``; a longer body is tolerated (trailer ignored); an
    /// unknown future byte reads ``CodeOpenDisposition/workbench`` — revealing the panel is the
    /// benign fallback (worst case an expanded panel, never a silently invisible open).
    public static func decodeCodeOpenDisposition(_ data: Data) throws -> CodeOpenDisposition {
        var reader = BigEndianReader(data)
        let byte = try reader.readUInt8()
        return CodeOpenDisposition(rawValue: byte) ?? .workbench
    }

    // MARK: - Code font spec  (syncCodeFont = 20)

    /// The client's terminal-font truth for the embedded workbench — the ``MetadataVerb/syncCodeFont``
    /// REQUEST payload. The terminal face/size/rhythm are CLIENT state (libghostty renders on the
    /// client; the prefs never otherwise cross the wire), while the editor reads the host-side shared
    /// `settings.json` — so the client pushes the three values and the host folds them into the seeded
    /// editor keys (`CodeServerManager.syncEditorFont`). `lineHeight` is the EFFECTIVE cell-height
    /// RATIO (family metrics × the adjust-cell-height mode), not the raw preference.
    public struct CodeFontSpec: Equatable, Sendable {
        /// The terminal font family name (the preference string, e.g. "JetBrains Mono").
        public var family: String
        /// The terminal font size in points.
        public var size: Double
        /// The effective line-height ratio (editor `lineHeight` semantics — a multiple of `size`).
        public var lineHeight: Double

        public init(family: String, size: Double, lineHeight: Double) {
            self.family = family
            self.size = size
            self.lineHeight = lineHeight
        }
    }

    /// Encodes a ``MetadataVerb/syncCodeFont`` request payload:
    /// `[UInt16 len][family UTF-8][UInt64 BE size bitPattern][UInt64 BE lineHeight bitPattern]`.
    /// Doubles ride as IEEE-754 bit patterns (bit-exact floats invariant — no textual round-trip).
    public static func encodeCodeFontSpec(_ spec: CodeFontSpec) -> Data {
        var data = Data()
        appendString(spec.family, to: &data)
        data.appendBE(spec.size.bitPattern)
        data.appendBE(spec.lineHeight.bitPattern)
        return data
    }

    /// Decodes a ``MetadataVerb/syncCodeFont`` request payload (validate-then-drop): truncated bodies
    /// and invalid UTF-8 throw, and so do out-of-range values — an empty family, a size outside
    /// `4…128` pt, or a ratio outside `0.5…4` (NaN fails every comparison → throws). The host writes
    /// these into a file the workbench trusts; hostile bytes must die here, not there. A longer body
    /// is tolerated (trailer ignored) so a future field can be appended.
    public static func decodeCodeFontSpec(_ data: Data) throws -> CodeFontSpec {
        var reader = BigEndianReader(data)
        let family = try readString(&reader, "codeFontSpec.family")
        let size = try Double(bitPattern: reader.readUInt64())
        let lineHeight = try Double(bitPattern: reader.readUInt64())
        guard !family.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SlopDeskError.malformedBody("codeFontSpec.family: empty")
        }
        guard size >= 4, size <= 128 else {
            throw SlopDeskError.malformedBody("codeFontSpec.size: out of range")
        }
        guard lineHeight >= 0.5, lineHeight <= 4 else {
            throw SlopDeskError.malformedBody("codeFontSpec.lineHeight: out of range")
        }
        return CodeFontSpec(family: family, size: size, lineHeight: lineHeight)
    }

    // MARK: - Shared encode/decode helpers

    /// A list count clamped to the `[0, 65535]` the `UInt16` count field can hold, so a >65535-entry
    /// list can never WRAP the count and desync the decoder (the encoder writes only the first 65535
    /// entries — unreachable in production; the host caps every list well under this).
    private static func clampedCount(_ count: Int) -> Int {
        min(max(count, 0), Int(UInt16.max))
    }

    /// Appends a `[UInt16 len][UTF-8 bytes]` length-prefixed string, clamping the UTF-8 to ≤ 65535
    /// bytes at a Unicode-scalar boundary so the length field can never WRAP and corrupt the trailer.
    private static func appendString(_ string: String, to data: inout Data) {
        let bytes = clampedUTF8(string)
        data.appendBE(UInt16(bytes.count))
        data.append(bytes)
    }

    /// The UTF-8 of `string` clamped to ≤ 65535 bytes at a Unicode-scalar boundary (so it stays valid
    /// UTF-8). Identity for any sane field (the host caps these well under 64 KiB); only an absurd
    /// >64 KiB value is shortened. Mirrors `WireMessage.clamped*` so the convention is uniform.
    private static func clampedUTF8(_ string: String) -> Data {
        let full = Data(string.utf8)
        guard full.count > Int(UInt16.max) else { return full }
        var clamped = Data()
        for scalar in string.unicodeScalars {
            let scalarBytes = Array(String(scalar).utf8)
            if clamped.count + scalarBytes.count > Int(UInt16.max) { break }
            clamped.append(contentsOf: scalarBytes)
        }
        return clamped
    }

    /// Reads a `[UInt16 len][UTF-8 bytes]` length-prefixed string: validates the declared length via
    /// `readBytes` (throws ``SlopDeskError/truncated`` rather than over-reading a hostile body) and
    /// requires STRICT UTF-8 (throws ``SlopDeskError/malformedBody(_:)`` on an invalid sequence).
    private static func readString(_ reader: inout BigEndianReader, _ context: String) throws -> String {
        let length = try Int(reader.readUInt16())
        let bytes = try reader.readBytes(length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw SlopDeskError.malformedBody("\(context): invalid UTF-8")
        }
        return string
    }
}
