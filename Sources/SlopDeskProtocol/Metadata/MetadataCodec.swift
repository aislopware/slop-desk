import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// The per-verb payload codecs for the host metadata RPC. Each ``MetadataVerb`` that returns a
/// STRUCTURED list rides one of these sub-codecs INSIDE the opaque
/// ``WireMessage/metadataResponse(requestID:status:payload:)`` payload — the envelope only
/// length-prefixes the bytes; these codecs give them meaning. (The `cwd` / `gitDiff` /
/// `readAgentSession` verbs carry raw UTF-8 / raw bytes and have NO nested codec — the envelope's
/// length prefix already frames them.)
///
/// Every layout, every clamp and every validation lives in `rust/slopdesk-wire`'s `metadata::codec`.
/// This type is the Swift face of it: the value types below and the calls that flatten them across
/// the boundary. The codecs live in this caseless `enum` namespace so the value type
/// ``MetadataCodec/ProcessInfo`` does NOT shadow `Foundation.ProcessInfo` at module scope (the host
/// reads `Foundation.ProcessInfo.processInfo` and imports this module — a top-level `ProcessInfo`
/// would make that reference ambiguous and break the build).
///
/// **How a payload crosses.** A record — a LIST of them where the payload is a list — plus one
/// ARENA holding every text field, each named by an `(offset, length)` pair into it. The same shape
/// the wire codec (`rust/slopdesk-wire/src/codec.rs`) uses, for the same reason.
///
/// **A decode takes no probing call.** The payload bounds both buffers: no arena can exceed the
/// payload's own length, and no list can hold more entries than `payload.count / fixedBytesPerEntry`
/// — the divisor being ``slopdesk_metadata_constant(_:)``'s, never respelled here. So the sizes come
/// off the bytes already in hand and the call happens ONCE. An encode is the §4 convention: size,
/// then fill.
///
/// **The one payload that elides.** A clipboard clip runs to ``maxClipboardContentBytes`` (12 MiB),
/// so its decode answers WHERE the content sits in the payload rather than copying it out — and its
/// encode reads the content out of the caller's buffer rather than being handed a copy of it. Every
/// other payload here is kilobytes and crosses whole.
///
/// **Validate-then-drop on untrusted bytes** (a metadata payload arrives over the same trusted mesh
/// as the rest of the wire, but is still treated as hostile input) is unchanged and is enforced in
/// the crate that owns the layout: a declared count larger than the body can hold is rejected before
/// any allocation, every length-prefixed field throws rather than over-reading, every string field
/// is STRICT UTF-8, interop discriminator bytes are read as `byte != 0`, and on ENCODE every length
/// and count is clamped so an absurd field can never WRAP and corrupt the trailer.
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
        /// surfaces can never disagree on what "3 modified" means — which is why the fold itself
        /// rides the boundary rather than being spelled on both sides of it.
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
            var counts = SlopDeskMetadataGitCounts()
            // Only the status codes decide the fold, so only they cross — one byte per file, out
            // of a scratch buffer, because a summary re-folds on every render.
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Swift.max(files.count, 1)) { codes in
                for slot in 0..<files.count { codes[slot] = files[slot].statusCode }
                slopdesk_metadata_fold_git_codes(codes.baseAddress, files.count, &counts)
            }
            return FoldedCounts(
                staged: Int(counts.staged), modified: Int(counts.modified),
                untracked: Int(counts.untracked), conflicted: Int(counts.conflicted),
            )
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

    /// Encodes a process list. Count clamped to ≤ 65535; each name clamped to ≤ 65535 UTF-8 bytes.
    public static func encodeProcessList(_ items: [ProcessInfo]) -> Data {
        var pool: [UInt8] = []
        let records = items.map {
            SlopDeskMetadataProcess(pid: $0.pid, uptime_sec: $0.uptimeSec, name: intern($0.name, &pool))
        }
        return encode(records, pool, slopdesk_metadata_encode_processes)
    }

    /// Decodes a process list, validating the declared count before allocating and dropping a truncated
    /// or non-UTF-8 body (throws), never trapping.
    public static func decodeProcessList(_ data: Data) throws -> [ProcessInfo] {
        try decode(data, entryBytes: 3, "processList", slopdesk_metadata_decode_processes) { record, pool in
            ProcessInfo(pid: record.pid, uptimeSec: record.uptime_sec, name: text(pool, record.name))
        }
    }

    // MARK: - PortList  ([UInt16 count] then [UInt16 port][UInt8 proto][UInt16 nameLen][procName])

    /// Encodes a port list. An empty list ("No listening ports") encodes as `[UInt16 0]`.
    public static func encodePortList(_ items: [PortInfo]) -> Data {
        var pool: [UInt8] = []
        let records = items.map {
            SlopDeskMetadataPort(proc_name: intern($0.procName, &pool), port: $0.port, proto: $0.proto)
        }
        return encode(records, pool, slopdesk_metadata_encode_ports)
    }

    /// Decodes a port list (validate-then-drop, count-before-alloc).
    public static func decodePortList(_ data: Data) throws -> [PortInfo] {
        try decode(data, entryBytes: 4, "portList", slopdesk_metadata_decode_ports) { record, pool in
            PortInfo(port: record.port, proto: record.proto, procName: text(pool, record.proc_name))
        }
    }

    // MARK: - DirListing  ([UInt16 count] then [UInt8 isDir][UInt16 nameLen][leafName])

    /// Encodes a one-level directory listing (leaf names only). Count clamped to ≤ 65535.
    public static func encodeDirListing(_ items: [DirEntry]) -> Data {
        var pool: [UInt8] = []
        let records = items.map {
            SlopDeskMetadataDirEntry(name: intern($0.name, &pool), is_dir: $0.isDir)
        }
        return encode(records, pool, slopdesk_metadata_encode_dir_listing)
    }

    /// Decodes a one-level directory listing (validate-then-drop, count-before-alloc). The `isDir`
    /// discriminator is read as `byte != 0` (never assumed `{0,1}`).
    public static func decodeDirListing(_ data: Data) throws -> [DirEntry] {
        try decode(data, entryBytes: 5, "dirListing", slopdesk_metadata_decode_dir_listing) { record, pool in
            DirEntry(isDir: record.is_dir, name: text(pool, record.name))
        }
    }

    // MARK: - GitStatus  ([UInt8 hasRepo]; if repo: branch, remote, repoRoot, [Int32 ahead][Int32 behind][Int32 stash], files)

    /// Encodes a git status. When `hasRepo` is `false` only the single `0` byte is written (the
    /// remaining fields are not on the wire); otherwise branch + remote + repoRoot + ahead/behind + the
    /// changed-file list follow. Strings clamped to ≤ 65535 bytes, file count clamped to ≤ 65535.
    public static func encodeGitStatus(_ status: GitStatusPayload) -> Data {
        var pool: [UInt8] = []
        // The head's three strings intern FIRST so a long file list cannot move their offsets.
        var head = SlopDeskMetadataGitStatus(
            branch: intern(status.branch, &pool),
            remote_url: intern(status.remoteURL, &pool),
            repo_root: intern(status.repoRoot, &pool),
            ahead: status.ahead,
            behind: status.behind,
            stash_count: status.stashCount,
            file_count: UInt32(clamping: status.files.count),
            has_repo: status.hasRepo,
        )
        let records = status.files.map {
            SlopDeskMetadataGitFile(path: intern($0.path, &pool), status_code: $0.statusCode)
        }
        return records.withUnsafeBufferPointer { list in
            pool.withUnsafeBufferPointer { arena in
                sized { out, cap in
                    slopdesk_metadata_encode_git_status(
                        &head, list.baseAddress, list.count, arena.baseAddress, arena.count, out,
                        cap,
                    )
                }
            }
        }
    }

    /// Decodes a git status (validate-then-drop, count-before-alloc). `hasRepo` is read as `byte != 0`;
    /// `hasRepo == false` returns ``GitStatusPayload/noRepo`` regardless of any trailing bytes.
    public static func decodeGitStatus(_ data: Data) throws -> GitStatusPayload {
        var head = SlopDeskMetadataGitStatus()
        let (files, strings) = try decode(
            data, entryBytes: 6, "gitStatus",
            { payload, length, records, cap, arena, arenaCap, count in
                slopdesk_metadata_decode_git_status(
                    payload, length, &head, records, cap, arena, arenaCap, count,
                )
            },
            { record, pool in
                GitFileChange(statusCode: record.status_code, path: text(pool, record.path))
            },
        ) { pool in
            // The head's strings live in the same arena, and are read before it is released.
            (text(pool, head.branch), text(pool, head.remote_url), text(pool, head.repo_root))
        }
        guard head.has_repo else { return .noRepo }
        return GitStatusPayload(
            hasRepo: true,
            branch: strings.0,
            remoteURL: strings.1,
            repoRoot: strings.2,
            ahead: head.ahead,
            behind: head.behind,
            stashCount: head.stash_count,
            files: files,
        )
    }

    // MARK: - AgentSessionList  ([UInt16 count] then kind, id, title, cwd, [Int64 mtimeMS])

    /// Encodes an agent-session list. Count clamped to ≤ 65535; each string clamped to ≤ 65535 bytes.
    public static func encodeAgentSessionList(_ items: [AgentSessionInfo]) -> Data {
        var pool: [UInt8] = []
        let records = items.map {
            SlopDeskMetadataAgentSession(
                mtime_ms: $0.mtimeMS,
                id: intern($0.id, &pool),
                title: intern($0.title, &pool),
                cwd: intern($0.cwd, &pool),
                agent_kind: $0.agentKindByte,
            )
        }
        return encode(records, pool, slopdesk_metadata_encode_agent_sessions)
    }

    /// Decodes an agent-session list (validate-then-drop, count-before-alloc).
    public static func decodeAgentSessionList(_ data: Data) throws -> [AgentSessionInfo] {
        try decode(
            data, entryBytes: 7, "agentSessionList", slopdesk_metadata_decode_agent_sessions,
        ) { record, pool in
            AgentSessionInfo(
                agentKindByte: record.agent_kind,
                id: text(pool, record.id),
                title: text(pool, record.title),
                cwd: text(pool, record.cwd),
                mtimeMS: record.mtime_ms,
            )
        }
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
    public static let maxClipboardContentBytes = Int(slopdesk_metadata_constant(0))

    /// The ``MetadataVerb/readClipboard`` request value meaning "baseline probe": the host replies
    /// with its current `changeCount` and NO content, so a fresh connection learns where the host
    /// clipboard stands without pulling (and applying) stale pre-connection state.
    public static let clipboardBaselineProbe = slopdesk_metadata_constant(1)

    /// Encodes a ``MetadataVerb/setClipboard`` request payload: `[UInt8 kind][content]` (the content
    /// runs to the end of the payload — the RPC envelope already frames it).
    public static func encodeClipboardSet(_ clip: ClipboardClip) -> Data {
        clip.lent { flat, content, contentLength in
            sized { out, cap in
                slopdesk_metadata_encode_clipboard_set(flat, content, contentLength, out, cap)
            }
        }
    }

    /// Decodes a ``MetadataVerb/setClipboard`` request payload (validate-then-drop): an empty payload
    /// throws `truncated`, an over-cap content throws `malformedBody`. The kind byte is carried RAW
    /// (an unknown future kind decodes fine; the applier refuses it with `.error`).
    public static func decodeClipboardSet(_ data: Data) throws -> ClipboardClip {
        var flat = SlopDeskMetadataClip()
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_clipboard_set(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &flat,
                )
            },
            "clipboardSet",
        )
        return ClipboardClip(kindByte: flat.kind, bytes: content(flat, in: data))
    }

    /// Encodes a ``MetadataVerb/readClipboard`` request payload: the `Int64` (BE) host `changeCount`
    /// the client last saw (``clipboardBaselineProbe`` = none yet — baseline probe).
    public static func encodeClipboardReadRequest(lastSeenChangeCount: Int64) -> Data {
        sized { out, cap in
            slopdesk_metadata_encode_clipboard_read_request(lastSeenChangeCount, out, cap)
        }
    }

    /// Decodes a ``MetadataVerb/readClipboard`` request payload (throws `truncated` on a short body).
    public static func decodeClipboardReadRequest(_ data: Data) throws -> Int64 {
        var count: Int64 = 0
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_clipboard_read_request(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &count,
                )
            },
            "clipboardReadRequest",
        )
        return count
    }

    /// Encodes a ``MetadataVerb/readClipboard`` response payload:
    /// `[Int64 changeCount][UInt8 kind][content]`, where a `nil` clip writes kind `0` ("unchanged /
    /// empty / client's own push") and no content.
    public static func encodeClipboardReadResponse(changeCount: Int64, clip: ClipboardClip?) -> Data {
        let carried = clip ?? ClipboardClip(kindByte: 0, bytes: Data())
        return carried.lent(present: clip != nil) { flat, content, contentLength in
            sized { out, cap in
                slopdesk_metadata_encode_clipboard_read_response(
                    changeCount, flat, content, contentLength, out, cap,
                )
            }
        }
    }

    /// Decodes a ``MetadataVerb/readClipboard`` response payload (validate-then-drop): kind `0`
    /// returns a `nil` clip (any trailing bytes after a kind-0 marker are malformed), an over-cap
    /// content throws `malformedBody`.
    public static func decodeClipboardReadResponse(
        _ data: Data,
    ) throws -> (changeCount: Int64, clip: ClipboardClip?) {
        var flat = SlopDeskMetadataClip()
        var changeCount: Int64 = 0
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_clipboard_read_response(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &changeCount, &flat,
                )
            },
            "clipboardRead",
        )
        guard flat.present else { return (changeCount, nil) }
        return (changeCount, ClipboardClip(kindByte: flat.kind, bytes: content(flat, in: data)))
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
        ///
        /// WHICH byte is which level, and what an unrecognised one means, is
        /// `slopdesk_wire`'s `HostVitals::memory_pressure`. It used to be spelled here as well, and
        /// the two spellings agreed only because nobody had touched either — the pair had no
        /// differential, no vocabulary pin and no gate of any kind, which is the shape docs/55 §8
        /// says every cross-language defect this project has found came in.
        ///
        /// The `??` below is not that rule a second time: the door answers a byte its own table
        /// names, for every input, and the fallback is the tax Swift charges for a failable
        /// `RawRepresentable` init. It cannot fire without the two case lists having diverged, which
        /// is a different fault from the one this reading is about.
        public var memoryPressure: MemoryPressure {
            MemoryPressure(rawValue: slopdesk_metadata_memory_pressure(pressureByte)) ?? .normal
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
    public static let diskFreeUnknown = UInt32(truncatingIfNeeded: slopdesk_metadata_constant(2))

    /// Encodes a ``MetadataVerb/hostVitals`` response payload: `[UInt8 cpu%][UInt8 mem%][UInt8
    /// pressure][UInt32 disk free MiB]`. Both percents are clamped to `0...100` at the SOURCE; a nil
    /// disk reading goes out as ``diskFreeUnknown``.
    public static func encodeHostVitals(_ vitals: HostVitals) -> Data {
        var flat = SlopDeskMetadataVitals(
            disk_free_mib: vitals.diskFreeMiB ?? 0,
            cpu_percent: vitals.cpuPercent,
            memory_percent: vitals.memoryPercent,
            pressure: vitals.pressureByte,
            has_disk: vitals.diskFreeMiB != nil,
        )
        return sized { out, cap in slopdesk_metadata_encode_host_vitals(&flat, out, cap) }
    }

    /// Decodes a ``MetadataVerb/hostVitals`` response payload (validate-then-drop): a body shorter
    /// than 7 bytes throws ``SlopDeskError/truncated``; an out-of-range percent is CLAMPED (not
    /// thrown — the reading is still usable and a status row must not vanish over one wild byte); a
    /// longer body is tolerated, its trailer ignored, so a future field can be appended without
    /// breaking this reader.
    public static func decodeHostVitals(_ data: Data) throws -> HostVitals {
        var flat = SlopDeskMetadataVitals()
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_host_vitals(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &flat,
                )
            },
            "hostVitals",
        )
        return HostVitals(
            cpuPercent: flat.cpu_percent, memoryPercent: flat.memory_percent,
            pressureByte: flat.pressure, diskFreeMiB: flat.has_disk ? flat.disk_free_mib : nil,
        )
    }

    // MARK: - Host service endpoint  (ensureCodeServer = 18, ensureSimulatorServer = 21)

    /// The host's answer to an ENSURE verb: where (and whether) a lazily-spawned host-side HTTP
    /// service is listening. Two verbs share the shape because they share the lifecycle exactly —
    /// the right panel's surfaces are each a web UI the host supervises for them (verb 18's
    /// code-server, verb 21's simulator server), reached through the client's loopback relay.
    ///
    /// The `port` is meaningful ONLY when ``state`` is ``ServiceState/ready`` — a starting instance
    /// may not have bound its socket yet (the host spawns with port `0` and learns the real port
    /// from the child's own log line), and an unavailable one has no port at all; both carry `0`.
    public struct ServiceEndpoint: Equatable, Sendable {
        /// The lifecycle state as a RAW byte (forward-tolerant carry, like
        /// ``HostVitals/pressureByte``); see ``state``.
        public var stateByte: UInt8
        /// The TCP port the instance listens on — `0` unless ``state`` is ``ServiceState/ready``.
        public var port: UInt16

        public init(stateByte: UInt8, port: UInt16) {
            self.stateByte = stateByte
            self.port = port
        }

        public init(state: ServiceState, port: UInt16) {
            self.init(stateByte: state.rawValue, port: port)
        }

        /// The typed state. An unknown future byte reads ``ServiceState/starting`` — "keep
        /// polling" is the benign fallback; a state this build cannot interpret must never render
        /// the install-hint error surface it cannot justify.
        ///
        /// The reading is `slopdesk_wire`'s `ServiceEndpoint::state`, asked rather than restated —
        /// see ``HostVitals/memoryPressure`` for why the `??` that remains is not the rule again.
        /// This half of the pair was the live one: `slopdesk_devicepanel::phase` folds the same
        /// method into the panel's phase, so an unknown byte was already being read twice per poll,
        /// once in each language, with nothing comparing the two answers.
        public var state: ServiceState {
            ServiceState(rawValue: slopdesk_metadata_service_state(stateByte)) ?? .starting
        }
    }

    /// The meaning of ``ServiceEndpoint/stateByte``.
    public enum ServiceState: UInt8, Sendable, Equatable, CaseIterable {
        /// Spawned but not confirmed listening — the client polls the verb again.
        case starting = 0
        /// Listening; ``ServiceEndpoint/port`` is live and the WKWebView can load.
        case ready = 1
        /// The service's binary is not installed on the host — the panel shows the install hint
        /// for whichever verb asked (`code-server` for 18, `baguette` for 21).
        case unavailable = 2
    }

    /// Encodes an ensure-verb response payload: `[UInt8 state][UInt16 BE port]`.
    public static func encodeServiceEndpoint(_ endpoint: ServiceEndpoint) -> Data {
        var flat = SlopDeskMetadataEndpoint(port: endpoint.port, state: endpoint.stateByte)
        return sized { out, cap in slopdesk_metadata_encode_service_endpoint(&flat, out, cap) }
    }

    /// Decodes an ensure-verb response payload (validate-then-drop): a body
    /// shorter than 3 bytes throws ``SlopDeskError/truncated``; a longer body is tolerated, its
    /// trailer ignored, so a future field can be appended without breaking this reader.
    public static func decodeServiceEndpoint(_ data: Data) throws -> ServiceEndpoint {
        var flat = SlopDeskMetadataEndpoint()
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_service_endpoint(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &flat,
                )
            },
            "serviceEndpoint",
        )
        return ServiceEndpoint(stateByte: flat.state, port: flat.port)
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
        sized { out, cap in
            slopdesk_metadata_encode_code_open_disposition(disposition.rawValue, out, cap)
        }
    }

    /// Decodes a ``MetadataVerb/openInCodeServer`` response payload (validate-then-drop): an empty
    /// body throws ``SlopDeskError/truncated``; a longer body is tolerated (trailer ignored); an
    /// unknown future byte reads ``CodeOpenDisposition/workbench`` — revealing the panel is the
    /// benign fallback (worst case an expanded panel, never a silently invisible open).
    ///
    /// That last reading happens INSIDE the door: `slopdesk_metadata_decode_code_open_disposition`
    /// writes `disposition.as_byte()`, so what comes back is already one of the two this build
    /// names. The `??` at the end is Swift's failable-init tax, not a second opinion about the
    /// wire — unlike ``HostVitals/pressureByte`` and ``ServiceEndpoint/stateByte``, which cross RAW
    /// because a re-encode has to put back what it was given, and so ask their own doors.
    public static func decodeCodeOpenDisposition(_ data: Data) throws -> CodeOpenDisposition {
        var byte: UInt8 = 0
        try throwIfFaulted(
            data.spanning { payload, length in
                slopdesk_metadata_decode_code_open_disposition(
                    payload?.assumingMemoryBound(to: UInt8.self), length, &byte,
                )
            },
            "codeOpenDisposition",
        )
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
        var pool: [UInt8] = []
        var flat = SlopDeskMetadataFontSpec(
            size_bits: spec.size.bitPattern,
            line_height_bits: spec.lineHeight.bitPattern,
            family: intern(spec.family, &pool),
        )
        return pool.withUnsafeBufferPointer { arena in
            sized { out, cap in
                slopdesk_metadata_encode_code_font_spec(
                    &flat, arena.baseAddress, arena.count, out, cap,
                )
            }
        }
    }

    /// Decodes a ``MetadataVerb/syncCodeFont`` request payload (validate-then-drop): truncated bodies
    /// and invalid UTF-8 throw, and so do out-of-range values — an empty family, a size outside
    /// `4…128` pt, or a ratio outside `0.5…4` (NaN fails every comparison → throws). The host writes
    /// these into a file the workbench trusts; hostile bytes must die here, not there. A longer body
    /// is tolerated (trailer ignored) so a future field can be appended.
    public static func decodeCodeFontSpec(_ data: Data) throws -> CodeFontSpec {
        var flat = SlopDeskMetadataFontSpec()
        // The family cannot outgrow the payload that carried it length-prefixed.
        let room = Swift.max(data.count, 1)
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: room) { arena in
            try throwIfFaulted(
                data.spanning { payload, length in
                    slopdesk_metadata_decode_code_font_spec(
                        payload?.assumingMemoryBound(to: UInt8.self), length, &flat,
                        arena.baseAddress, arena.count,
                    )
                },
                "codeFontSpec",
            )
            return CodeFontSpec(
                family: text(UnsafeRawBufferPointer(arena), flat.family),
                size: Double(bitPattern: flat.size_bits),
                lineHeight: Double(bitPattern: flat.line_height_bits),
            )
        }
    }

    // MARK: - Crossing the boundary

    /// Appends `string`'s UTF-8 to `pool` and answers where it landed.
    ///
    /// The arena is a `[UInt8]` and not a `Data` on purpose: this runs once per text field of every
    /// entry, and `Data.append` carries a per-call cost that `Array.append(contentsOf:)` over a
    /// `String.UTF8View` does not.
    private static func intern(_ string: String, _ pool: inout [UInt8]) -> SlopDeskMetadataText {
        let offset = UInt32(clamping: pool.count)
        pool.append(contentsOf: string.utf8)
        return SlopDeskMetadataText(offset: offset, length: UInt32(clamping: pool.count) - offset)
    }

    /// Reads a text field out of an arena a decode filled.
    private static func text(_ arena: UnsafeRawBufferPointer, _ field: SlopDeskMetadataText) -> String {
        ArenaText.text(arena, field.offset, field.length)
    }

    /// The clip content an eliding decode left in `payload`, as its own `Data`.
    private static func content(_ flat: SlopDeskMetadataClip, in payload: Data) -> Data {
        guard flat.content.length > 0 else { return Data() }
        let start = payload.startIndex + Int(flat.content.offset)
        return Data(payload[start..<start + Int(flat.content.length)])
    }

    /// Size, then fill — the §4 convention. `call` answers the bytes NEEDED and writes only when the
    /// room it is given is enough, so the first call measures with no buffer at all.
    private static func sized(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
        let needed = call(nil, 0)
        return WireBuffer.filled(needed) { out in
            let written = call(out?.assumingMemoryBound(to: UInt8.self), needed)
            precondition(
                written == needed, "the metadata codec sized a payload differently than it wrote it",
            )
        }
    }

    /// Encodes a list of records plus the arena their text fields live in.
    private static func encode<Record>(
        _ records: [Record],
        _ pool: [UInt8],
        _ call: (
            UnsafePointer<Record>?, Int, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int,
        ) -> Int,
    ) -> Data {
        records.withUnsafeBufferPointer { list in
            pool.withUnsafeBufferPointer { arena in
                sized { out, cap in
                    call(list.baseAddress, list.count, arena.baseAddress, arena.count, out, cap)
                }
            }
        }
    }

    /// Decodes a list of records, sizing both buffers off the payload rather than probing for them.
    ///
    /// `entryBytes` is the ``slopdesk_metadata_constant(_:)`` INDEX of the per-entry fixed size, not
    /// the size — the number itself stays in the crate that owns the layout.
    private static func decode<Record, Item, Head>(
        _ payload: Data,
        entryBytes: UInt32,
        _ context: String,
        _ call: (
            UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Record>?, Int,
            UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?,
        ) -> UInt32,
        _ build: (Record, UnsafeRawBufferPointer) -> Item,
        _ readHead: (UnsafeRawBufferPointer) -> Head,
    ) throws -> ([Item], Head) {
        let fixed = Int(slopdesk_metadata_constant(entryBytes))
        let room = Swift.max(payload.count / Swift.max(fixed, 1), 1)
        let arenaRoom = Swift.max(payload.count, 1)
        return try payload.spanning { bytes, length in
            try withUnsafeTemporaryAllocation(of: Record.self, capacity: room) { records in
                try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: arenaRoom) { arena in
                    var count = 0
                    let verdict = call(
                        bytes?.assumingMemoryBound(to: UInt8.self), length,
                        records.baseAddress, records.count,
                        arena.baseAddress, arena.count, &count,
                    )
                    try throwIfFaulted(verdict, context)
                    let pool = UnsafeRawBufferPointer(arena)
                    return ((0..<count).map { build(records[$0], pool) }, readHead(pool))
                }
            }
        }
    }

    /// The list decode for a payload with no head fields.
    private static func decode<Record, Item>(
        _ payload: Data,
        entryBytes: UInt32,
        _ context: String,
        _ call: (
            UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Record>?, Int,
            UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?,
        ) -> UInt32,
        _ build: (Record, UnsafeRawBufferPointer) -> Item,
    ) throws -> [Item] {
        try decode(payload, entryBytes: entryBytes, context, call, build) { _ in () }.0
    }

    /// Throws the error a non-OK verdict names.
    ///
    /// `AGAIN` cannot reach a caller here: every buffer is sized off the payload that bounds it, so
    /// a short one would be a boundary bug rather than a hostile body — and is trapped as one.
    private static func throwIfFaulted(_ verdict: UInt32, _ context: String) throws {
        switch verdict {
        case SLOPDESK_WIRE_DECODE_OK: return
        case SLOPDESK_WIRE_DECODE_TRUNCATED: throw SlopDeskError.truncated
        case SLOPDESK_WIRE_DECODE_AGAIN:
            preconditionFailure("\(context): a payload out-grew the buffers it bounds")
        default: throw SlopDeskError.malformedBody("\(context): rejected by the metadata codec")
        }
    }
}

private extension MetadataCodec.ClipboardClip {
    /// Lends the clip's content to `body` without copying it, alongside the flat record that names
    /// it — a clip runs to 12 MiB, and an encode must not begin by duplicating them.
    func lent<R>(
        present: Bool = true,
        _ body: (UnsafePointer<SlopDeskMetadataClip>, UnsafePointer<UInt8>?, Int) -> R,
    ) -> R {
        bytes.spanning { content, contentLength in
            var flat = SlopDeskMetadataClip(
                content: SlopDeskMetadataText(offset: 0, length: UInt32(clamping: contentLength)),
                kind: kindByte,
                present: present,
            )
            return body(&flat, content?.assumingMemoryBound(to: UInt8.self), contentLength)
        }
    }
}
