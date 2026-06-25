import Foundation

/// The operation a ``WireMessage/metadataRequest(requestID:verb:payload:)`` selects (E4, the host
/// metadata RPC). ONE generic request/response pair on the CONTROL channel backs every Details-Panel
/// surface that reads host-side metadata; the `verb` byte discriminates which of these operations the
/// host runs against the request's pane (carried by the mux channel envelope) and/or `payload`.
///
/// The wire carries the RAW `UInt8` (``WireMessage`` does not store this enum) so an unknown future
/// verb is forward-tolerantly carried across the wire; the HOST maps the byte back via the synthesized
/// `init(rawValue:)`, and an unrecognized value (`init(rawValue:)` returns `nil`) is answered with
/// ``MetadataStatus/unsupportedVerb`` — never a trap. `Sendable` so a decoded verb can cross actor /
/// task boundaries with its message.
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
    /// JSONL/JSON bytes (opaque — the client parses it via `AislopdeskInspector.TranscriptParser`).
    case readAgentSession = 8
}

/// The outcome of a ``WireMessage/metadataResponse(requestID:status:payload:)`` (E4). The host ALWAYS
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
