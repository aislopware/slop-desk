import Foundation

/// The operation a ``WireMessage/metadataRequest(requestID:verb:payload:)`` selects — the host
/// metadata RPC. ONE generic request/response pair on the CONTROL channel backs every Details-Panel
/// surface that reads host-side metadata; the `verb` byte discriminates which of these operations the
/// host runs against the request's pane (carried by the mux channel envelope) and/or `payload`.
///
/// The wire carries the RAW `UInt8` (``WireMessage`` does not store this enum) so an unknown future
/// verb is forward-tolerantly carried across the wire; the HOST maps the byte back via the synthesized
/// `init(rawValue:)`, and an unrecognized value (`init(rawValue:)` returns `nil`) is answered with
/// ``MetadataStatus/unsupportedVerb`` — never a trap. `Sendable` so a decoded verb can cross actor /
/// task boundaries with its message.
///
/// **Read-only vs side-effecting.** Verbs `1...8` are PURE READS — the host runs a
/// git/lsof/proc/FileManager lookup and returns the data, mutating nothing; they are served by the pure
/// ``MetadataResponseBuilder``. Verbs `9` (``openPath``) and `10` (``revealPath``) are the ONLY
/// SIDE-EFFECTING verbs: they actuate on the HOST's own Finder / Launch Services (the file lives on the
/// host Mac, not the client) and return ONLY a status byte + empty payload — no host bytes ever cross the
/// wire, so they are not an exfiltration vector and accept an absolute path WITHOUT cwd-subtree
/// confinement (unlike the read verbs). The host routes them to a thin macOS shim BEFORE the read-only
/// builder (see `HostPathActionPerformer`).
///
/// **Agent-hooks verbs.** Verbs `11` (``installAgentHooks``) / `12` (``uninstallAgentHooks``)
/// are SIDE-EFFECTING like 9/10 — they write/strip the slopdesk Claude Code hook entries in the HOST's
/// `~/.claude/settings.json` (+ hook script) via `AgentInstaller`, returning ONLY a status byte + empty
/// payload (no host bytes cross the wire). Verb `13` (``agentHookStatus``) is a PURE READ that — unlike
/// the read verbs above — returns NO host file contents, only the 2-byte `[installed][listenerActive]`
/// flags (docs/20; byte 1 is the LIVE hook-listener bind state, kept separate from the install marker
/// because an installed-but-unbound hook must not render as active).
/// The host routes all three to a thin macOS shim BEFORE the read-only builder
/// (see `HostAgentActionPerformer`); they carry an EMPTY request payload (pane-agnostic — install/uninstall
/// act on the host regardless of which pane's channel carries the request).
public enum MetadataVerb: UInt8, Sendable, Equatable, CaseIterable {
    /// List the pane's foreground processes. Request payload: empty (the pane). Response: `ProcessList`.
    case processes = 1
    /// List the pane's listening ports. Request payload: empty (the pane). Response: `PortList`.
    case ports = 2
    /// The pane's current working directory. Request payload: empty (the pane). Response: UTF-8 path
    /// string (opaque — no nested codec).
    case cwd = 3
    /// The pane cwd's git status (branch + remote + ahead/behind + changed files — `gitBranch` is
    /// subsumed here). Request payload: empty (the pane cwd). Response: `GitStatus`.
    case gitStatus = 4
    /// A unified `git diff` of one file. Request payload: UTF-8 repo-relative file path. Response: raw
    /// `git diff` bytes (opaque — no nested codec).
    case gitDiff = 5
    /// One level of a host directory (lazy per-expand). Request payload: UTF-8 path (empty = pane cwd).
    /// Response: `DirListing` (leaf names only; the client joins with the request path).
    case listDirectory = 6
    /// Enumerate the agent (Claude/codex/opencode) session files for a project. Request payload: UTF-8
    /// project path (empty = pane cwd). Response: `AgentSessionList`.
    case listAgentSessions = 7
    /// Read one agent session's raw transcript. Request payload: UTF-8 session id/path. Response: raw
    /// JSONL/JSON bytes (opaque — the client parses it via `SlopDeskInspector.TranscriptParser`).
    case readAgentSession = 8
    /// **Side-effecting.** Open a host path in its default app / Finder (the ⌘click
    /// action). Request payload: raw UTF-8 ABSOLUTE host path. Response: empty payload — status `.ok` on
    /// a successful `NSWorkspace.open`, `.notFound` if the path no longer exists, `.error` on an
    /// empty/relative/un-openable path. The host actuates this on ITS OWN Finder / Launch Services; no
    /// host bytes cross the wire.
    case openPath = 9
    /// **Side-effecting.** Reveal a host path in the host's Finder (the ⌘⇧click action,
    /// `NSWorkspace.activateFileViewerSelecting`). Request payload: raw UTF-8 ABSOLUTE host path.
    /// Response: empty payload — status `.ok` when the path exists and the reveal was issued, `.notFound`
    /// if the path is gone, `.error` on an empty/relative path.
    case revealPath = 10
    /// **Side-effecting.** Install the slopdesk Claude Code hooks on the HOST: writes the
    /// hook script + merges our hook entries into `~/.claude/settings.json` (``AgentInstaller/install``).
    /// Request payload: empty (host-global — install acts on the host regardless of the carrying pane).
    /// Response: empty payload — status `.ok` on a successful write, `.error` if the install threw. Like
    /// 9/10 no host bytes cross the wire.
    case installAgentHooks = 11
    /// **Side-effecting.** Uninstall the slopdesk Claude Code hooks on the HOST: strips
    /// exactly our hook entries from `~/.claude/settings.json` (``AgentInstaller/uninstall``), leaving the
    /// user's own hooks intact. Request payload: empty. Response: empty payload — status `.ok` on success,
    /// `.error` if the uninstall threw.
    case uninstallAgentHooks = 12
    /// **Pure read.** Report the HOST's slopdesk Claude Code hooks state. Request payload:
    /// empty. Response: status `.ok` + the **2-byte** `[installed][listenerActive]` payload (docs/20) —
    /// byte 0 is the `settings.json` install marker
    /// (``AgentInstaller/isInstalled(settingsPath:fileManager:)``), byte 1 the LIVE hook-listener bind
    /// state, kept distinct because an installed-but-unbound hook must not render as a green check.
    /// NO host file CONTENTS cross the wire (unlike the read verbs 5...8), only the two flag bytes —
    /// so it needs no cwd confinement.
    case agentHookStatus = 13
    /// **Pure read.** The host's own hostname (`ProcessInfo.hostName`, e.g.
    /// "mac-studio.local") — the durable identity the client chrome speaks (titlebar monogram + label)
    /// when the user connected by IP. Request payload: empty (host-global, pane-agnostic). Response:
    /// status `.ok` + the raw UTF-8 hostname string (opaque — no nested codec); `.error` when the name
    /// is unresolvable. No cwd confinement needed — only the machine's name crosses the wire. An OLD
    /// host answers `.unsupportedVerb` (forward-tolerance) and the client falls back to reverse-DNS /
    /// the raw target host.
    case hostInfo = 14
    /// **Side-effecting.** Write the client's clipboard onto the HOST's general pasteboard —
    /// the push half of bidirectional clipboard sync (copy on the client → paste on the host, incl.
    /// Claude Code's Ctrl+V image paste and a plain ⌘V inside a remote-desktop pane). Host-global
    /// like 11/12 (the pasteboard is machine state, not pane state), so any connected pane's channel
    /// carries it. Request payload: `MetadataCodec.encodeClipboardSet` (`[UInt8 kind][content]`;
    /// kind 1 = UTF-8 text, 2 = PNG). Response: empty payload — status `.ok` on a successful
    /// pasteboard write, `.error` on a malformed/over-cap/unknown-kind payload. The host remembers
    /// the resulting pasteboard `changeCount` so ``readClipboard`` never echoes a client-pushed clip
    /// straight back (the loop-suppression half of the contract).
    case setClipboard = 15
    /// **Pure read.** The host's general-pasteboard content — the pull half of clipboard
    /// sync (copy on the host, e.g. ⌘C inside a remote-desktop pane → paste on the client). The
    /// client polls this alongside its local pasteboard watch. Request payload:
    /// `MetadataCodec.encodeClipboardReadRequest` (`Int64` last-seen host `changeCount`; `-1` =
    /// baseline probe — the host replies count-only so a fresh connection never overwrites the
    /// client clipboard with stale host state). Response:
    /// `MetadataCodec.encodeClipboardReadResponse` (`[Int64 changeCount][UInt8 kind][content]`;
    /// kind 0 = unchanged/empty/none — no content follows, also used when the current clip is the
    /// one the client itself pushed via ``setClipboard``). Ships host clipboard CONTENT to the
    /// client — deliberately unconfined like the mesh-trusted read verbs (both ends are the same
    /// user's machines; security = WireGuard, docs/DECISIONS).
    case readClipboard = 16
    /// **Pure read.** The host machine's own PULSE — all-core CPU busy percent, memory-in-use
    /// percent, and the kernel's memory-pressure level. Host-global and pane-agnostic like
    /// ``hostInfo`` (any connected pane's channel carries it); no path argument, no confinement —
    /// three aggregate numbers about the machine, never a byte of its content. Request payload:
    /// empty. Response: status `.ok` + ``MetadataCodec/encodeHostVitals`` (3 bytes).
    ///
    /// `.error` means "no reading yet", NOT a failure: the CPU percent is the delta between two tick
    /// snapshots, so the first request only primes the baseline (and a baseline older than the
    /// sampler's staleness window is discarded rather than smeared across a poll gap the client
    /// spent disconnected). The client simply keeps the previous reading — or nothing — until the
    /// next poll answers. An OLD host answers `.unsupportedVerb` and the footer stays one line.
    case hostVitals = 17
    /// **Side-effecting.** Ensure the HOST's code-server (VS Code web workbench) is running —
    /// the right sidebar's embedded editor. Request payload: raw UTF-8 ABSOLUTE host project-root
    /// path (the pane's `projectKey`) — VALIDATED (an endpoint is never reported for a path the
    /// host cannot see), though one shared instance serves every project (the workbench resolves
    /// its folder from the client URL's `?folder=` query). The host lazily spawns it
    /// (`CodeServerManager`) and replies IMMEDIATELY — it never waits out the multi-second cold
    /// start (the client registry's 5 s timeout must not race a boot):
    /// status `.ok` + ``MetadataCodec/CodeServerEndpoint`` (`[UInt8 state][UInt16 BE port]`,
    /// state `0` starting / `1` ready / `2` unavailable — no code-server binary on the host).
    /// The client polls this same verb until `ready`, then points its WKWebView at
    /// `http://<target-host>:<port>/?folder=<root>`. `.notFound` = the root is not a directory on
    /// the host; `.error` = a malformed (empty/relative/non-UTF-8) payload. Host-global like
    /// 11/12 (the one instance serves every pane and every client); no cwd
    /// confinement — the payload is a path the host itself published as `projectKey`, and only a
    /// state byte + port number cross back. NO auth token rides the URL: security = the WireGuard
    /// mesh, the same trust model as every other port hostd opens (docs/DECISIONS — no app-layer
    /// auth). An OLD host answers `.unsupportedVerb` and the sidebar shows its update hint.
    case ensureCodeServer = 18
}

/// The outcome of a ``WireMessage/metadataResponse(requestID:status:payload:)``. The host ALWAYS
/// replies (so the client's pending-request registry never hangs); the status discriminates whether the
/// `payload` carries the requested data.
///
/// The wire carries the RAW `UInt8`; an unknown future status (`init(rawValue:)` returns `nil`) is
/// treated as ``error`` client-side (forward-tolerant) — never a trap.
public enum MetadataStatus: UInt8, Sendable, Equatable, CaseIterable {
    /// The verb ran and the `payload` carries its result.
    case ok = 0
    /// The requested entity (file/session/path) does not exist; `payload` is empty.
    case notFound = 1
    /// The verb failed (query error, path-confinement rejection, cap exceeded); `payload` is empty.
    case error = 2
    /// The host does not recognize the request's `verb`; `payload` is empty.
    case unsupportedVerb = 3
}
