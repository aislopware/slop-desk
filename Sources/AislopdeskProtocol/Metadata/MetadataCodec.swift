import Foundation

/// The per-verb payload codecs for the host metadata RPC (E4). Each ``MetadataVerb`` that returns a
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
///   ``AislopdeskError/truncated`` with no allocation (count-before-alloc);
/// - every length-prefixed field is read via `BigEndianReader.readBytes`, which throws `truncated`
///   rather than over-reading a hostile body;
/// - every string field is STRICT UTF-8 (an invalid sequence throws
///   ``AislopdeskError/malformedBody(_:)`` — never a lossy/replacement decode);
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
        /// key (E6 WI-7). Empty when ``hasRepo`` is `false` (a no-repo payload is still only the single
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
        guard reader.bytesRemaining >= count * processEntryFixedBytes else { throw AislopdeskError.truncated }
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
        guard reader.bytesRemaining >= count * portEntryFixedBytes else { throw AislopdeskError.truncated }
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
        guard reader.bytesRemaining >= count * dirEntryFixedBytes else { throw AislopdeskError.truncated }
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
        guard reader.bytesRemaining >= count * gitFileFixedBytes else { throw AislopdeskError.truncated }
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
        guard reader.bytesRemaining >= count * agentSessionFixedBytes else { throw AislopdeskError.truncated }
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
    /// `readBytes` (throws ``AislopdeskError/truncated`` rather than over-reading a hostile body) and
    /// requires STRICT UTF-8 (throws ``AislopdeskError/malformedBody(_:)`` on an invalid sequence).
    private static func readString(_ reader: inout BigEndianReader, _ context: String) throws -> String {
        let length = try Int(reader.readUInt16())
        let bytes = try reader.readBytes(length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw AislopdeskError.malformedBody("\(context): invalid UTF-8")
        }
        return string
    }
}
