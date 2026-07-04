import AislopdeskProtocol
import Foundation

/// E4 — the host's query seam for the metadata RPC. The set of OS lookups a
/// ``WireMessage/metadataRequest(requestID:verb:payload:)`` may need, abstracted behind a protocol
/// so ``MetadataResponseBuilder`` is a PURE value-in/value-out reducer (unit-tested with an injected
/// fake — `MetadataResponseBuilderTests`). The real ``HostMetadataProbe`` (`#if os(macOS)`) does the
/// git/lsof/proc syscalls; it is compiled + code-reviewed only, never spun in a unit test (the
/// hang-safety rule, exactly like ``PTYForegroundProbe`` splitting from ``ForegroundProcessDetector``).
///
/// **Confinement contract:** the builder NEVER calls a path/id-parameterized query method until it has
/// validated and confined the request's argument against the pane's cwd subtree (or rejected an unsafe
/// session id). So a fake can assert "rejected → query untouched" — the revert-to-confirm-fail anchor
/// for each path-confinement guard (a hostile `listDirectory("/etc")` / `gitDiff("../x")` /
/// `readAgentSession("../../secrets")` must reach status `.error` WITHOUT a syscall).
protocol MetadataQuerying {
    /// The pane's current working directory — the `cwd` verb's answer AND the confinement root for
    /// `listDirectory`/`gitDiff`/`listAgentSessions`. `nil` when unresolvable (the verb replies `.error`).
    func paneWorkingDirectory() -> String?
    /// The pane's processes (controlling-terminal scoped). Empty list is valid.
    func processes() -> [MetadataCodec.ProcessInfo]
    /// The pane's listening ports. Empty list ("No listening ports") is valid.
    func ports() -> [MetadataCodec.PortInfo]
    /// The git status of `cwd` (branch + remote + ahead/behind + changed files; `gitBranch` subsumed).
    func gitStatus(cwd: String) -> MetadataCodec.GitStatusPayload
    /// A unified `git diff` of `file` (already confined repo-relative) in `cwd`. `nil` → `.notFound`.
    func gitDiff(cwd: String, file: String) -> Data?
    /// One level of `absolutePath` (already confined within the pane cwd subtree). `nil` → `.notFound`.
    func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]?
    /// The agent (Claude/codex/opencode) session files for `project` (already confined). Empty is valid.
    func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo]
    /// The raw transcript bytes for session `id` (the id was checked free of `..` traversal; the probe
    /// additionally confines the resolved file to the known session roots). `nil` → `.notFound`.
    func readAgentSession(id: String) -> Data?
    /// The host machine's own hostname (`hostInfo` verb; e.g. "mac-studio.local") — the client chrome's
    /// durable host identity. `nil`/empty when unresolvable (the verb replies `.error`).
    func hostName() -> String?
}

/// E4 — the PURE host responder for the metadata RPC. Maps a request `(verb, payload)` to a
/// ``WireMessage/metadataResponse(requestID:status:payload:)`` over an injected ``MetadataQuerying``,
/// doing NO syscalls itself: it decodes the request's UTF-8 path/id argument, CONFINES it against the
/// pane cwd subtree, enforces the count/byte CAPS, calls the (fakeable) query, and encodes the result
/// via the shared ``MetadataCodec``. It ALWAYS produces a response (an unknown verb →
/// ``MetadataStatus/unsupportedVerb``; a confinement rejection / missing cwd → ``MetadataStatus/error``;
/// a query that returns `nil` → ``MetadataStatus/notFound``) so the client's pending-request registry
/// never hangs — never throws, never traps, never force-unwraps.
struct MetadataResponseBuilder {
    /// The directory-listing entry cap (a hostile / pathological dir can't flood a frame). The shared
    /// codec also clamps the `UInt16` count, but the builder caps to this much smaller production limit.
    static let defaultMaxDirEntries = 4096
    /// The opaque-payload (gitDiff / readAgentSession) byte cap. Held well under
    /// ``Aislopdesk/maxFramePayloadLength`` (16 MiB) so the response — plus its envelope/header — can
    /// never exceed the frame cap and get dropped by the peer's ``FrameDecoder``.
    static let defaultMaxOpaquePayloadBytes = 15 * 1024 * 1024

    private let query: MetadataQuerying
    private let maxDirEntries: Int
    private let maxOpaquePayloadBytes: Int

    /// - Parameters are injectable so a unit test can drive the caps with tiny values (asserting the
    ///   truncation guards without allocating 15 MiB). Production uses the static defaults.
    init(
        query: MetadataQuerying,
        maxDirEntries: Int = Self.defaultMaxDirEntries,
        maxOpaquePayloadBytes: Int = Self.defaultMaxOpaquePayloadBytes,
    ) {
        self.query = query
        self.maxDirEntries = max(0, maxDirEntries)
        self.maxOpaquePayloadBytes = max(0, maxOpaquePayloadBytes)
    }

    /// Builds the response for one request. `verbByte` is the raw wire byte (forward-tolerant — an
    /// unrecognized value is answered `.unsupportedVerb`, never a trap). `payload` is the request's
    /// opaque argument (raw UTF-8 path/id for the parameterized verbs; empty for the pane verbs).
    func response(requestID: UInt32, verb verbByte: UInt8, payload: Data) -> WireMessage {
        guard let verb = MetadataVerb(rawValue: verbByte) else {
            return reply(requestID, .unsupportedVerb, Data())
        }
        switch verb {
        case .processes:
            return reply(requestID, .ok, MetadataCodec.encodeProcessList(query.processes()))

        case .ports:
            return reply(requestID, .ok, MetadataCodec.encodePortList(query.ports()))

        case .cwd:
            guard let cwd = query.paneWorkingDirectory(), !cwd.isEmpty else {
                return reply(requestID, .error, Data())
            }
            return reply(requestID, .ok, Data(cwd.utf8))

        case .gitStatus:
            guard let cwd = query.paneWorkingDirectory(), !cwd.isEmpty else {
                return reply(requestID, .error, Data())
            }
            return reply(requestID, .ok, MetadataCodec.encodeGitStatus(query.gitStatus(cwd: cwd)))

        case .gitDiff:
            // A repo-relative file: reject an empty arg, an absolute path, or any `..` escape BEFORE
            // touching the query (confinement → no read). The probe runs `git -C <cwd> diff -- <file>`.
            guard let cwd = query.paneWorkingDirectory(), !cwd.isEmpty,
                  let file = Self.utf8Arg(payload), !file.isEmpty,
                  let confined = Self.confinedRelativePath(file, root: cwd)
            else { return reply(requestID, .error, Data()) }
            guard let diff = query.gitDiff(cwd: cwd, file: confined) else {
                return reply(requestID, .notFound, Data())
            }
            return reply(requestID, .ok, cappedOpaque(diff))

        case .listDirectory:
            // Empty arg = the pane cwd. A non-empty arg (relative OR absolute) must resolve WITHIN the
            // pane cwd subtree (reject `..` traversal and an absolute path that escapes the root).
            guard let cwd = query.paneWorkingDirectory(), !cwd.isEmpty,
                  let path = Self.utf8Arg(payload)
            else { return reply(requestID, .error, Data()) }
            let target: String
            if path.isEmpty {
                target = cwd
            } else if let confined = Self.confinedAbsolutePath(path, root: cwd) {
                target = confined
            } else {
                return reply(requestID, .error, Data())
            }
            guard let entries = query.listDirectory(absolutePath: target) else {
                return reply(requestID, .notFound, Data())
            }
            return reply(requestID, .ok, MetadataCodec.encodeDirListing(Array(entries.prefix(maxDirEntries))))

        case .listAgentSessions:
            guard let cwd = query.paneWorkingDirectory(), !cwd.isEmpty,
                  let project = Self.utf8Arg(payload)
            else { return reply(requestID, .error, Data()) }
            let projectPath: String
            if project.isEmpty {
                projectPath = cwd
            } else if let confined = Self.confinedAbsolutePath(project, root: cwd) {
                projectPath = confined
            } else {
                return reply(requestID, .error, Data())
            }
            let sessions = query.listAgentSessions(project: projectPath)
            return reply(requestID, .ok, MetadataCodec.encodeAgentSessionList(sessions))

        case .readAgentSession:
            guard let id = Self.utf8Arg(payload), Self.isSafeSessionID(id) else {
                return reply(requestID, .error, Data())
            }
            guard let bytes = query.readAgentSession(id: id) else {
                return reply(requestID, .notFound, Data())
            }
            return reply(requestID, .ok, cappedOpaque(bytes))

        case .hostInfo:
            // Pane-agnostic pure read: the machine's own name (no path argument, no confinement — only
            // the hostname string crosses the wire).
            guard let name = query.hostName(), !name.isEmpty else {
                return reply(requestID, .error, Data())
            }
            return reply(requestID, .ok, Data(name.utf8))

        case .openPath,
             .revealPath:
            // E10 WI-7: the side-effecting path verbs are NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostPathActionPerformer` BEFORE the
            // builder, so they never reach here in production. Reaching this case is a routing bug;
            // answer `.error` defensively (this pure reducer must NEVER perform a host side effect).
            return reply(requestID, .error, Data())

        case .installAgentHooks,
             .uninstallAgentHooks,
             .agentHookStatus:
            // E13 WI-1: the agent-hooks verbs are likewise NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostAgentActionPerformer` BEFORE the
            // builder (install/uninstall touch the host's `~/.claude/settings.json`; status reads the
            // marker), so they never reach here in production. Reaching this case is a routing bug;
            // answer `.error` defensively (this pure reducer must NEVER perform a host side effect).
            return reply(requestID, .error, Data())
        }
    }

    // MARK: - Response helpers

    private func reply(_ requestID: UInt32, _ status: MetadataStatus, _ payload: Data) -> WireMessage {
        .metadataResponse(requestID: requestID, status: status.rawValue, payload: payload)
    }

    /// Truncates an opaque payload to ``maxOpaquePayloadBytes`` (a safety backstop — a real diff /
    /// transcript is far smaller; a truncated tail is still valid opaque bytes the client renders
    /// best-effort, and can never exceed the frame cap).
    private func cappedOpaque(_ data: Data) -> Data {
        data.count > maxOpaquePayloadBytes ? Data(data.prefix(maxOpaquePayloadBytes)) : data
    }

    // MARK: - Argument decode + path confinement (pure; the security-critical core)

    /// Decodes a request payload as a UTF-8 argument; `nil` on invalid UTF-8 (→ `.error`). An empty
    /// payload decodes to `""` (valid — the "no argument" / "pane cwd" case).
    static func utf8Arg(_ payload: Data) -> String? {
        String(data: payload, encoding: .utf8)
    }

    /// The non-empty path components of `path` (collapses `//`, drops a trailing slash).
    static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether `path` contains a `..` component (parent-directory traversal — always rejected; we never
    /// rely on resolving `..`, so a single token is enough to reject the whole arg).
    static func containsTraversal(_ path: String) -> Bool {
        pathComponents(path).contains("..")
    }

    /// Component-wise "is `candidate` at or under `root`" — a COMPONENT prefix match, never a string
    /// `hasPrefix` (which would treat `/a/repo-evil` as under `/a/repo`). An empty `root` (the FS root)
    /// is never a valid confinement base → `false`.
    static func isWithin(_ candidate: [String], root: [String]) -> Bool {
        guard !root.isEmpty, candidate.count >= root.count else { return false }
        return Array(candidate.prefix(root.count)) == root
    }

    /// Confines a RELATIVE arg (gitDiff's repo-relative file) within `root`: rejects an absolute path
    /// and any `..` traversal, then re-confirms the joined path stays under `root`. Returns the original
    /// relative path on success (the probe runs `git -C <root> diff -- <path>`); `nil` rejects.
    static func confinedRelativePath(_ path: String, root: String) -> String? {
        guard !path.hasPrefix("/"), !containsTraversal(path) else { return nil }
        let rootC = pathComponents(root)
        guard isWithin(rootC + pathComponents(path), root: rootC) else { return nil }
        return path
    }

    /// Confines an arg that may be RELATIVE or ABSOLUTE within `root`, returning the normalized absolute
    /// path. Rejects any `..` traversal and any absolute path that escapes the `root` subtree; `nil`
    /// rejects. An absolute path that IS under `root` (e.g. `listDirectory("/repo/src")`) is allowed.
    static func confinedAbsolutePath(_ path: String, root: String) -> String? {
        guard !containsTraversal(path) else { return nil }
        let rootC = pathComponents(root)
        let candidate = path.hasPrefix("/") ? pathComponents(path) : rootC + pathComponents(path)
        guard isWithin(candidate, root: rootC) else { return nil }
        return "/" + candidate.joined(separator: "/")
    }

    /// A session id is safe when it is non-empty and carries no `..` traversal. The probe additionally
    /// confines the resolved file to the known agent-session roots — this builder guard blocks the
    /// obvious `readAgentSession("../../secrets")` escape WITHOUT a syscall (revert-to-confirm-fail).
    static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && !containsTraversal(id)
    }
}
