import Foundation
import SlopDeskWorkspaceModel

/// The workspace document's home on disk, and the DEFAULT document for a host that has none.
///
/// Two jobs that belong together because they are two answers to one question — "what workspace does
/// this host have?" — and because getting the second one wrong is unrecoverable: once client-side
/// tree persistence is gone, a host that cannot answer leaves every client staring at a blank window
/// with no way to create the first pane.
///
/// `workspace-state.json` is a SIBLING of the `scrollback/` directory, not a file inside it.
/// `ScrollbackJournalStore.sweep(maxAge:keepNewest:)` walks only `*.scrollback` in that directory, so
/// it would never see this file either way — but a workspace living inside a directory something
/// else prunes is the kind of arrangement that survives until the day it does not.
public actor HostWorkspaceStore {
    private let fileURL: URL
    private let hostDisplayName: String
    private let debounce: Duration
    private let onLog: (@Sendable (String) -> Void)?

    /// The freshest state waiting to be written. Depth-1 and COALESCING, like every other queue in
    /// this document: a save that has not happened yet is replaced, never queued, so a burst of
    /// intents costs one write.
    private var pending: HostWorkspaceState?
    private var saveTask: Task<Void, Never>?

    @preconcurrency
    public init(
        fileURL: URL,
        hostDisplayName: String,
        debounce: Duration = .milliseconds(600),
        onLog: (@Sendable (String) -> Void)? = nil,
    ) {
        self.fileURL = fileURL
        self.hostDisplayName = hostDisplayName
        self.debounce = debounce
        self.onLog = onLog
    }

    /// The store hostd uses, or `nil` when Application Support cannot be resolved.
    ///
    /// `SLOPDESK_WORKSPACE_STATE_DIR` overrides the location — the same escape hatch
    /// `SLOPDESK_SCROLLBACK_DIR` gives the journals, and what makes an end-to-end test able to run
    /// against a real store without touching the developer's own workspace.
    @preconcurrency
    public static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        hostDisplayName: String,
        onLog: (@Sendable (String) -> Void)? = nil,
    ) -> HostWorkspaceStore? {
        let directory: URL
        if let override = environment["SLOPDESK_WORKSPACE_STATE_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { return nil }
            directory = base.appendingPathComponent("SlopDesk", isDirectory: true)
        }
        return HostWorkspaceStore(
            fileURL: directory.appendingPathComponent("workspace-state.json"),
            hostDisplayName: hostDisplayName,
            onLog: onLog,
        )
    }

    // MARK: - Load

    /// Whether this host has ever written a workspace.
    ///
    /// The question `adoptWorkspace` asks — "has this host had a workspace of its own?" — and a file
    /// on disk answers it yes however plain its contents. Deliberately separate from ``load()``,
    /// which returns a usable document either way and so cannot say which it was.
    public var hasStoredWorkspace: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// The name this host publishes as its own.
    ///
    /// `Host.current().localizedName` is what a Mac calls itself in Sharing preferences — the name
    /// the user already recognises. It falls back to the POSIX hostname, then to a constant, because
    /// a workspace with no label is still a workspace.
    public static func hostDisplayName() -> String {
        if let localized = Host.current().localizedName, !localized.isEmpty { return localized }
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "SlopDesk" : name
    }

    /// The workspace this host starts with.
    ///
    /// Every failure lands on the same answer — a usable default — because a corrupt file must never
    /// brick the daemon for every client at once. This is a new class of host-side corruption: on the
    /// client a bad workspace file cost one device its layout, here it would cost all of them.
    ///
    /// The bad file is kept aside rather than overwritten. Losing a workspace to a decode bug is
    /// survivable if the bytes are still there to look at.
    public func load() -> HostWorkspaceState {
        guard let data = try? Data(contentsOf: fileURL) else { return defaultDocument() }
        do {
            let restored = try WorkspaceStateFile.decode(data)
            // Decoded, but is it a WORKSPACE? A file whose sessions all failed the structural checks
            // has no topology, and publishing it would hand every client an empty window.
            guard restored.topology != nil else {
                onLog?("workspace store: \(fileURL.lastPathComponent) holds no workspace — minting the default")
                setAside(reason: "empty")
                return defaultDocument()
            }
            return restored
        } catch {
            onLog?("workspace store: \(fileURL.lastPathComponent) did not decode (\(error)) — minting the default")
            setAside(reason: "corrupt")
            return defaultDocument()
        }
    }

    /// One session, one tab, one pane — the shape a first-run host publishes.
    ///
    /// It lives here rather than in the client's launch path because the host is now the only thing
    /// that can mint it. Without it, deleting client-side tree persistence dead-ends the cold start.
    public func defaultDocument() -> HostWorkspaceState {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(
            tree: .defaultWorkspace(),
            hostDisplayName: hostDisplayName,
        ))
        return state
    }

    private func setAside(reason: String) {
        // Seconds since the epoch rather than a formatted date: the name only has to be unique and
        // sortable, and a locale-formatted timestamp in a filename is a bug waiting for a traveller.
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("workspace-state.\(reason)-\(stamp).json")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: fileURL, to: aside)
            onLog?("workspace store: previous file kept as \(aside.lastPathComponent)")
        } catch {
            onLog?("workspace store: could not keep the previous file aside (\(error))")
        }
    }

    // MARK: - Save

    /// Offers the freshest document. Written after ``debounce``, or sooner if ``flush()`` is called.
    public func scheduleSave(_ state: HostWorkspaceState) {
        pending = WorkspaceStateFile.persisting(state)
        guard saveTask == nil else { return }
        saveTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            await self.writePending()
        }
    }

    /// Writes anything outstanding NOW — the daemon-shutdown path. A debounce that outlives the
    /// process is a debounce that loses the last thing the user did.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writePending()
    }

    private func writePending() {
        saveTask = nil
        guard let state = pending else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            // `.atomic` is write-to-temp-then-rename. A half-written workspace file is the one
            // outcome worse than no workspace file, because it decodes far enough to look real.
            try WorkspaceStateFile.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            onLog?("workspace store: save failed (\(error))")
        }
    }

    // MARK: - Test seams

    public var fileURLForTesting: URL { fileURL }
}
