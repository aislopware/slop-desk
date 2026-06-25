import AislopdeskProtocol
import Foundation

/// The `@Observable` per-pane Details-Panel model (E4): it holds the decoded host metadata the inspector's
/// Info / Git / Files tabs bind to, and drives the ``MetadataClient`` façade to (re)fetch it. One per pane
/// (the metadata is pane-scoped — it rides the pane's mux channel). The view layer (WI-5/WI-6) renders
/// these projections; this model owns the fetch + state, kept free of SwiftUI so it stays headlessly
/// testable.
///
/// `@MainActor @Observable` like ``TerminalBlockModel`` / ``TerminalViewModel``: the fetch awaits the
/// façade (which suspends, never blocks, the main actor) and the SwiftUI reads are on the main actor. A
/// `nil` client (the pane is disconnected) makes every fetch a no-op, so the panel renders its empty state
/// without hanging.
@preconcurrency
@MainActor
@Observable
public final class PaneMetadataModel {
    /// The pane's foreground processes (Info tab). Newest fetch wins.
    public private(set) var processes: [MetadataCodec.ProcessInfo] = []
    /// The pane's listening ports (Info tab). Empty == "No listening ports".
    public private(set) var ports: [MetadataCodec.PortInfo] = []
    /// The pane cwd's git status (Git tab), or `nil` until fetched / on a query failure.
    public private(set) var gitStatus: MetadataCodec.GitStatusPayload?
    /// The pane's current working directory (Info tab header / `lastKnownCwd` source), or `nil` until fetched.
    public private(set) var cwd: String?
    /// The pane project's agent session files (Info tab "View Session History"), newest first.
    public private(set) var agentSessions: [MetadataCodec.AgentSessionInfo] = []

    // MARK: Files tab — lazy directory tree state

    /// The top-level directory listing (pane cwd) — the Files tree roots (one level).
    public private(set) var rootEntries: [MetadataCodec.DirEntry] = []
    /// Children of an expanded directory keyed by its JOINED path (so a re-expand reads from here). A
    /// collapse keeps the cached children so re-expanding is instant.
    public private(set) var childrenByPath: [String: [MetadataCodec.DirEntry]] = [:]
    /// The currently expanded directory paths (drives the disclosure triangles).
    public private(set) var expandedPaths: Set<String> = []

    /// True while ``refresh()`` is in flight (the panel shows a subtle loading affordance).
    public private(set) var isRefreshing = false

    /// The pane's metadata façade, or `nil` while the pane is disconnected (every fetch then no-ops). Held
    /// `@ObservationIgnored` — it is a collaborator, not view state.
    @ObservationIgnored private var client: MetadataClient?

    public init(client: MetadataClient? = nil) {
        self.client = client
    }

    /// Rebinds (or clears) the metadata façade — called when the pane (re)connects or drops. Clears the
    /// rendered state on a clear so the panel doesn't show a dead session's data.
    public func setClient(_ client: MetadataClient?) {
        self.client = client
        if client == nil { clear() }
    }

    /// Whether a live metadata façade is bound (the panel gates its refresh on this).
    public var isConnected: Bool { client != nil }

    /// Re-fetches the Info + Git data for the pane: processes, ports, cwd, git status, and the agent
    /// session list, plus the Files root. Awaited SEQUENTIALLY — each verb is an independent round-trip
    /// with its own correlation id, and a Details-Panel refresh is a low-frequency, user-triggered action
    /// where serialization is imperceptible and keeps the model trivially main-actor-safe. Every façade
    /// call swallows its own failure to empty/`nil`, so one slow/failed verb never strands the others.
    public func refresh() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Drop the directory cache so the Files tree re-reads the host after a refresh.
        client.invalidateDirectoryCache()
        processes = await client.processes()
        ports = await client.ports()
        cwd = await client.cwd()
        gitStatus = await client.gitStatus()
        agentSessions = await client.listAgentSessions()
        rootEntries = await client.listDirectory(path: "", useCache: false)
        // A refresh re-roots the tree: collapse everything (cached children are stale post-refresh).
        expandedPaths.removeAll()
        childrenByPath.removeAll()
    }

    // MARK: Files tab — expand / collapse

    /// Toggles a directory node: expands (fetching its children if not cached) or collapses it.
    public func toggleExpand(path: String) async {
        if expandedPaths.contains(path) {
            collapse(path: path)
        } else {
            await expand(path: path)
        }
    }

    /// Expands `path`, fetching its one-level children (served from the façade cache when available) and
    /// marking it expanded. A no-op if already expanded.
    public func expand(path: String) async {
        guard let client, !expandedPaths.contains(path) else { return }
        let children = await client.listDirectory(path: path)
        childrenByPath[path] = children
        expandedPaths.insert(path)
    }

    /// Collapses `path` (keeps the cached children so a re-expand is instant).
    public func collapse(path: String) {
        expandedPaths.remove(path)
    }

    // MARK: On-demand verbs (Git diff / agent transcript)

    /// Fetches the unified `git diff` for a changed `file` (raw bytes), for the Git-tab diff overlay.
    public func gitDiff(file: String) async -> Data? {
        await client?.gitDiff(file: file)
    }

    /// Reads one agent session's raw transcript bytes, for the "View Session History" viewer.
    public func readAgentSession(id: String) async -> Data? {
        await client?.readAgentSession(id: id)
    }

    // MARK: Reset

    /// Clears every rendered projection (a disconnect / pane reset). Pure — no fetch.
    public func clear() {
        processes = []
        ports = []
        gitStatus = nil
        cwd = nil
        agentSessions = []
        rootEntries = []
        childrenByPath.removeAll()
        expandedPaths.removeAll()
        isRefreshing = false
    }
}
