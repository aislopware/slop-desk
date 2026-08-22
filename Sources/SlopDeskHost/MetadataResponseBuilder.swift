import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// The host's ONE answer to "is this path confined to this root", as Swift sees it.
///
/// Everything below this comment is argument marshalling. The rule itself is
/// `rust/slopdesk-probe/src/path_confine.rs`, reached through `slopdesk_path_confine` — see
/// `docs/55` §4 for the calling convention and `rust/slopdesk-ffi/src/path_confine.rs` for why it
/// is a door at all.
///
/// **The history is the reason this type exists.** The rule was written three times: component-wise
/// here, as a string `hasPrefix` in ``CodeBridgeServer``, and lexically-resolving inside the forked
/// probe. No two of the three agreed about `..`, about whether the root is inside itself, or about
/// `/`. The bridge's version answered TRUE for `contains(root: "/a", path: "/a/../../etc/passwd")`
/// and was safe only because a `standardizingPath` in a different file happened to run first —
/// which is a coincidence, not a guarantee, and it is the kind of coincidence that survives every
/// refactor until the one that removes it.
enum PathConfinement {
    /// Which spellings of the candidate argument are admissible. The raw values are the header's
    /// `SLOPDESK_PATH_SHAPE_*`; an undefined one refuses on the far side.
    enum Shape: UInt32 {
        /// Absolute, or relative and joined to the root — `listDirectory` / `listAgentSessions`.
        case either = 0
        /// Relative only. `gitDiff`'s argument is a repo-relative pathspec by wire contract, and an
        /// absolute one naming the same file would be a second spelling of an argument with one.
        case relativeOnly = 1
        /// Absolute only. A session id and an editor open target are absolute host paths by
        /// construction; joining a relative one to a root would invent a file nobody named.
        case absoluteOnly = 2
    }

    /// A candidate that survived the rule, in the two forms callers need out of one evaluation.
    struct Confined: Equatable {
        /// The normalised absolute path — leading `/`, no trailing one, no empty/`.`/`..` component.
        let absolute: String
        /// The part below the root, no leading `/`. EMPTY exactly when the candidate names the root
        /// itself, which is how a caller needing a file rather than a directory tells them apart.
        let relative: String
    }

    /// The first buffer the door is offered. A host path longer than this exists in principle
    /// (`PATH_MAX` is 1024 on Darwin and a client may send more), so the retry below is real rather
    /// than ceremonial — but it is not travelled by any path a filesystem will accept.
    private static let firstGuess = 1024

    /// Confines `candidate` to `root`, or `nil` for everything the rule refuses.
    static func confine(root: String, _ candidate: String, _ shape: Shape) -> Confined? {
        Array(root.utf8).withUnsafeBufferPointer { rootBytes in
            Array(candidate.utf8).withUnsafeBufferPointer { candidateBytes -> Confined? in
                var offset = 0
                var room = [UInt8](repeating: 0, count: firstGuess)
                var needed = room.withUnsafeMutableBufferPointer { out in
                    slopdesk_path_confine(
                        rootBytes.baseAddress, rootBytes.count,
                        candidateBytes.baseAddress, candidateBytes.count,
                        shape.rawValue, &offset, out.baseAddress, out.count,
                    )
                }
                if needed > room.count {
                    room = [UInt8](repeating: 0, count: needed)
                    needed = room.withUnsafeMutableBufferPointer { out in
                        slopdesk_path_confine(
                            rootBytes.baseAddress, rootBytes.count,
                            candidateBytes.baseAddress, candidateBytes.count,
                            shape.rawValue, &offset, out.baseAddress, out.count,
                        )
                    }
                }
                // `needed == 0` is the refusal. The two bounds after it are not defensive noise:
                // this is the one seam where a garbled answer would be read as a PATH, so an offset
                // the door could not have produced fails the whole call rather than half of it.
                guard needed > 0, needed <= room.count, offset <= needed,
                      let absolute = String(bytes: room[0..<needed], encoding: .utf8),
                      let relative = String(bytes: room[offset..<needed], encoding: .utf8)
                else { return nil }
                return Confined(absolute: absolute, relative: relative)
            }
        }
    }

    /// Whether `path` lives at or under `root` — the containment verdict alone.
    ///
    /// Asks with `(NULL, 0)`, which `docs/55` §4 documents as the way to get a length without a
    /// buffer: the answer here is a bool, so there is nothing to copy and nothing to allocate.
    static func isWithin(root: String, path: String) -> Bool {
        Array(root.utf8).withUnsafeBufferPointer { rootBytes in
            Array(path.utf8).withUnsafeBufferPointer { pathBytes in
                slopdesk_path_confine(
                    rootBytes.baseAddress, rootBytes.count,
                    pathBytes.baseAddress, pathBytes.count,
                    Shape.absoluteOnly.rawValue, nil, nil, 0,
                ) > 0
            }
        }
    }

    /// Whether `path` is a path the rule could ever confine — absolute, naming at least one
    /// component, free of `..` and of an interior NUL. The question a caller asks when it holds no
    /// root; see ``MetadataResponseBuilder/isSafeSessionID(_:)`` for the only one that does.
    static func isConfinableAbsolute(_ path: String) -> Bool {
        Array(path.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_path_is_confinable_absolute(bytes.baseAddress, bytes.count)
        }
    }
}

/// The host's query seam for the metadata RPC. The set of OS lookups a
/// ``WireMessage/metadataRequest(requestID:verb:payload:)`` may need, abstracted behind a protocol
/// so ``MetadataResponseBuilder`` is a PURE value-in/value-out reducer (unit-tested with an injected
/// fake — `MetadataResponseBuilderTests`). The real ``HostMetadataProbe`` (`#if os(macOS)`) does the
/// git/lsof/proc syscalls; it is compiled + code-reviewed only, never spun in a unit test (the
/// hang-safety rule, exactly like ``PTYForegroundProbe`` holding no decision of its own).
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
    /// The pane's processes (controlling-terminal scoped), ALREADY ENCODED as the reply payload.
    /// An empty list is valid and encodes as a zero count; there is no `nil`.
    ///
    /// Encoded rather than as values because this responder holds no opinion about either list — it
    /// forwards them verbatim. A `[ProcessInfo]` here would mean records crossing the FFI boundary
    /// to be re-encoded one line later, which is the shape ``gitStatus(cwd:)`` already rejected.
    func processes() -> Data
    /// The pane's listening ports, ALREADY ENCODED. Empty ("No listening ports") is valid — see
    /// ``processes()`` for why both cross encoded.
    func ports() -> Data
    /// The git status of `cwd` (branch + remote + ahead/behind + changed files; `gitBranch` subsumed).
    func gitStatus(cwd: String) -> MetadataCodec.GitStatusPayload
    /// A unified `git diff` of `file` (already confined repo-relative) in `cwd`. `nil` → `.notFound`.
    func gitDiff(cwd: String, file: String) -> Data?
    /// One level of `absolutePath` (already confined within the pane cwd subtree). `nil` → `.notFound`.
    func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]?
    /// The agent (Claude/codex/opencode) session files for `project` (already confined). Empty is valid.
    func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo]
    /// The raw transcript bytes for session `id` (the id was checked to be a well-formed absolute path
    /// with no `..` in it; the probe then confines it to the known session roots with the SAME rule —
    /// see ``PathConfinement``). `nil` → `.notFound`.
    func readAgentSession(id: String) -> Data?
    /// The host machine's own hostname (`hostInfo` verb; e.g. "mac-studio.local") — the client chrome's
    /// durable host identity. `nil`/empty when unresolvable (the verb replies `.error`).
    func hostName() -> String?
    /// The host machine's pulse (`hostVitals` verb: CPU / memory / pressure). `nil` = NO READING YET
    /// (the CPU percent needs two tick snapshots, so the first call only primes the baseline) or the
    /// sampling syscall failed — either way the verb replies `.error` and the client keeps whatever
    /// it last had.
    func hostVitals() -> MetadataCodec.HostVitals?
}

/// The PURE host responder for the metadata RPC. Maps a request `(verb, payload)` to a
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
    /// ``SlopDesk/maxFramePayloadLength`` (16 MiB) so the response — plus its envelope/header — can
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
            return reply(requestID, .ok, query.processes())

        case .ports:
            return reply(requestID, .ok, query.ports())

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

        case .hostVitals:
            // Pane-agnostic pure read like `hostInfo`: three aggregate numbers about the machine, no
            // path argument to confine. A `nil` reading (baseline still priming / syscall refused)
            // is `.error`, NOT `.notFound` — the client treats it as "ask again next poll".
            guard let vitals = query.hostVitals() else { return reply(requestID, .error, Data()) }
            return reply(requestID, .ok, MetadataCodec.encodeHostVitals(vitals))

        case .openPath,
             .revealPath:
            // The side-effecting path verbs are NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostPathActionPerformer` BEFORE the
            // builder, so they never reach here in production. Reaching this case is a routing bug;
            // answer `.error` defensively (this pure reducer must NEVER perform a host side effect).
            return reply(requestID, .error, Data())

        case .installAgentHooks,
             .uninstallAgentHooks,
             .agentHookStatus:
            // The agent-hooks verbs are likewise NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostAgentActionPerformer` BEFORE the
            // builder (install/uninstall touch the host's `~/.claude/settings.json`; status reads the
            // marker), so they never reach here in production. Reaching this case is a routing bug;
            // answer `.error` defensively (this pure reducer must NEVER perform a host side effect).
            return reply(requestID, .error, Data())

        case .setClipboard,
             .readClipboard:
            // The clipboard-sync verbs are likewise NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostClipboardPerformer` BEFORE the
            // builder (both touch the host's general pasteboard), so they never reach here in
            // production. Reaching this case is a routing bug; answer `.error` defensively (this
            // pure reducer must NEVER perform a host side effect).
            return reply(requestID, .error, Data())

        case .ensureCodeServer,
             .ensureSimulatorServer,
             .ensureAndroidBridge,
             .openInCodeServer,
             .syncCodeFont:
            // The right-panel service verbs are likewise NOT this READ-ONLY builder's job —
            // `MuxChannelSession.serveMetadata` routes them to `HostCodeServerPerformer` /
            // `HostSimulatorPerformer` / `HostAndroidPerformer` BEFORE the
            // builder (they spawn a child process or bind a socket), so they never reach here in
            // production. Reaching this case is a routing bug; answer `.error` defensively (this
            // pure reducer must NEVER perform a host side effect).
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

    // MARK: - Argument decode + path confinement (the security-critical core)

    // Still pure — the door below performs no I/O and holds no state — but no longer a rule of its
    // own. Every judgement about a path is ``PathConfinement``'s, which is Rust's, which is also
    // what the forked probe runs.

    /// Decodes a request payload as a UTF-8 argument; `nil` on invalid UTF-8 (→ `.error`). An empty
    /// payload decodes to `""` (valid — the "no argument" / "pane cwd" case).
    static func utf8Arg(_ payload: Data) -> String? {
        String(data: payload, encoding: .utf8)
    }

    /// Confines a RELATIVE arg (gitDiff's repo-relative file) within `root`, answering the
    /// normalized path below the root — the probe runs `git -C <root> diff -- <answer>`. An
    /// absolute path is refused rather than confined: the wire contract for this argument is a
    /// repo-relative pathspec, and accepting a second spelling of it would be a loosening with
    /// nothing asking for it.
    ///
    /// The answer is NORMALIZED where the deleted version echoed the argument back verbatim, so
    /// `src//./main.swift` reaches git as `src/main.swift`. Same file, one spelling.
    static func confinedRelativePath(_ path: String, root: String) -> String? {
        PathConfinement.confine(root: root, path, .relativeOnly)?.relative
    }

    /// Confines an arg that may be RELATIVE or ABSOLUTE within `root`, returning the normalized
    /// absolute path. An absolute path that IS under `root` (e.g. `listDirectory("/repo/src")`) is
    /// allowed; the root itself is allowed, because a pane listing its own cwd is the ordinary case.
    static func confinedAbsolutePath(_ path: String, root: String) -> String? {
        PathConfinement.confine(root: root, path, .either)?.absolute
    }

    /// Whether a session id is one this builder will pass on: a well-formed ABSOLUTE path with no
    /// `..` in it and no interior NUL.
    ///
    /// This is the one confinement question the builder cannot finish, because the roots it would
    /// confine against live under the host's `$HOME` — the forked probe's business, not a pure
    /// reducer's — and `read_session` there confines against them with the same rule. What is
    /// checked here is the argument's SHAPE, which is enough to stop the obvious
    /// `readAgentSession("../../secrets")` without a syscall (the revert-to-confirm-fail anchor in
    /// the type documentation above).
    ///
    /// Stricter than the guard it replaces in two ways, both deliberate: a RELATIVE id is now
    /// refused here rather than downstream, and `/` is refused. Every id a client can hold came out
    /// of `listAgentSessions`, whose rows are absolute paths built from `read_dir` entries, so
    /// neither refusal can reach a legitimate request — and both were already refused by the probe,
    /// one fork later, as `.notFound`.
    static func isSafeSessionID(_ id: String) -> Bool {
        PathConfinement.isConfinableAbsolute(id)
    }
}
