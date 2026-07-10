import Foundation

// MARK: - Identity

/// Stable identity for a single pane (a leaf in the ``PaneNode`` tree).
///
/// A `PaneID` is the join key between the two halves of the workspace architecture
/// (docs/22 §1.1): the **tree of intent** (this pure value tree) and the **table of liveness**
/// (the `[PaneID: any PaneSessionHandle]` registry in the later `WorkspaceStore`). It is minted
/// once when a leaf is created and is **stable for the lifetime of that pane's session** —
/// split / focus / zoom / resize re-renders never change it, only a true session swap does.
/// That stability is load-bearing: SwiftUI keys each leaf host view with `.id(PaneID)` so a
/// `GhosttySurface` / video pipeline / input `Coordinator` is never reused across panes
/// (docs/22 §7, the `.id(PaneID)` identity hazard).
public struct PaneID: Hashable, Codable, Sendable {
    public let raw: UUID
    /// Mints a fresh identity. The default is the common path (a brand-new pane); pass an
    /// explicit `UUID` only when reconstructing a known identity (e.g. decode, or a test that
    /// pins a value for assertions).
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// Stable identity for a ``PaneGroup`` — a named, ordered collection of panes on the single canvas
/// (the replacement for the retired tab concept, docs/31).
///
/// Mirrors ``PaneID``: minted once, stable across the group's lifetime, survives the persistence
/// round-trip (docs/22 §6) so a pane's `groupID` membership and the sidebar's group order stay valid
/// after restore.
public struct PaneGroupID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

// MARK: - Leaf intent (what a pane IS — never a live object)

/// What a pane *is*. The kind selects which proven per-session stack the live layer will
/// materialize for the leaf (docs/22 §7): a plain remote terminal or a remote-GUI video window.
///
/// **Claude Code is no longer a kind (docs/42 W11).** A `claude` session is just a `.terminal`
/// pane: the host watches its PTY foreground process / hooks and the client auto-detects it
/// (wire types 26/27 → the per-pane `ClaudeStatus`), opening the read-only inspector channel
/// dynamically. There is no dedicated "Claude Code pane".
///
/// `String`-raw + hand-stable so the persisted JSON discriminator is human-readable and
/// versionable. **Forward/back-tolerant decode** (below): an OLD persisted `"claudeCode"` raw
/// value maps to `.terminal` so a v9 / pre-W11-v10 file never traps now the case is gone.
public enum PaneKind: String, Codable, Sendable, Equatable {
    /// A remote PTY terminal (PATH 1 byte pipeline). Also hosts an auto-detected `claude` session.
    case terminal
    /// A remote-GUI video window (PATH 2 UDP media + cursor side-channel).
    case remoteGUI
    /// An EPHEMERAL pane auto-spawned by the client's system-dialog monitor to stream a host SYSTEM
    /// prompt (e.g. a SecurityAgent login/password dialog) in its own pane. Same video stack as
    /// ``remoteGUI``, but auto-managed (spawn/close follow the host poll), NOT persisted, and it skips
    /// the picker + stale-binding revalidation (its windowID is always fresh from the live poll).
    case systemDialog
    /// A TRANSIENT, just-created pane whose CONTENT is the pane-type CHOOSER (Terminal / Remote window).
    /// `WorkspaceBindingRegistry.route` mints this immediately on a split / new-tab / new-session
    /// gesture and FOCUSES it, so the user picks the kind INSIDE the pane (no modal popup). It materializes
    /// NO live session (the reconcile skips it); ``WorkspaceStore/choosePaneKind(_:kind:)`` flips it to a real
    /// kind, at which point reconcile materializes the terminal / remote-GUI session IN PLACE (same `PaneID`).
    case chooser

    /// The retired-but-tolerated legacy raw value of the removed "Claude Code" pane kind (docs/42 W11).
    /// A `.claudeCode` pane is now just a `.terminal`; an OLD persisted file (v9, or a v10 written before
    /// W11) may still carry this discriminator. Kept ONLY as the migration/decode bridge below.
    static let legacyClaudeCodeRawValue = "claudeCode"

    /// The retired-but-tolerated legacy raw value of the removed LOCAL web pane kind (E18, since pruned —
    /// the app is a remote terminal + remote-GUI tool; a local browser is not core). An OLD persisted file
    /// may still carry a `"web"` leaf; it decodes to `.terminal` via the bridge below (same discipline as
    /// ``legacyClaudeCodeRawValue``) so a stale workspace never traps.
    static let legacyWebRawValue = "web"

    /// **Forward/back-tolerant decode (validate-then-repair, CLAUDE.md untrusted-persisted-data
    /// contract).** A persisted `"claudeCode"` raw value (the removed kind, W11) or `"web"` raw value (the
    /// removed local web pane) maps to `.terminal` so an old workspace file never traps now the cases are
    /// gone. Any OTHER unknown raw value still throws (it is genuine corruption the loader's reset path
    /// handles), preserving the strict behaviour for everything except the intentionally-retired values.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == Self.legacyClaudeCodeRawValue || raw == Self.legacyWebRawValue {
            self = .terminal
            return
        }
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown PaneKind raw value \"\(raw)\""),
            )
        }
        self = value
    }
}

public extension PaneKind {
    /// A video (PATH 2) pane — rides the shared UDP flow, counts against the live-video cap, renders the
    /// remote-GUI view. Both the user-picked ``remoteGUI`` and the auto ``systemDialog`` are video kinds.
    var isVideo: Bool { self == .remoteGUI || self == .systemDialog }
    /// An auto-managed, never-persisted overlay pane (the system-dialog surface).
    var isEphemeral: Bool { self == .systemDialog }
    /// Whether this pane has a shell input funnel that text can be typed into — the recipient set for
    /// broadcast/synchronized input (tmux `synchronize-panes`). Only the PTY-backed `.terminal` kind; the
    /// video kinds (`remoteGUI`/`systemDialog`) take input through the cursor/key side-channel, not a text bar.
    var canReceiveText: Bool { self == .terminal }
}

/// Which remote window a `.remoteGUI` (video) pane mirrors. The host + UDP ports are no longer here —
/// they live ONCE on the app-global ``ConnectionTarget`` (docs/31). All video panes ride the one shared
/// UDP flow at the app host; only the per-pane `windowID` selects which host-side window to stream.
/// Persisted with the tree so a restored video pane remembers its window + title; the actual UDP is
/// opened against the app target.
public struct VideoEndpoint: Codable, Sendable, Equatable {
    /// The host-side window being mirrored (ScreenCaptureKit window id).
    public var windowID: UInt32
    /// Human-readable window title (shown in pane chrome before the stream is live).
    public var title: String
    /// PANE REBIND (2026-06-12): the owning app's name at pick time (`WindowSummary.appName`).
    /// CGWindowIDs die with the window and get RECYCLED across host restarts, so `windowID` alone
    /// cannot be trusted on restore — app+title is what lets ``WindowRebind`` re-resolve the
    /// binding to the same app's window instead of streaming a dead/recycled id. Empty for
    /// legacy/manual-entry bindings (presence-of-id is then the only validity signal).
    public var appName: String
    public init(windowID: UInt32, title: String, appName: String = "") {
        self.windowID = windowID
        self.title = title
        self.appName = appName
    }
}

/// The full value-typed description of a leaf: its kind, its display title, and (for `.remoteGUI`) the
/// window it mirrors. The connection host is NOT here — terminals/Claude open a channel on the app-global
/// ``ConnectionTarget`` and `.remoteGUI` opens a lane on the same host's UDP flow, selecting its window
/// via ``video``.
///
/// A `PaneSpec` is pure intent: it is what the pane *should* be, not a handle to anything live.
/// The store reads it to materialize a session; mutating it (e.g. rename) is done through
/// ``PaneNode/updatingSpec(_:_:)`` and triggers a reconcile downstream.
///
/// ### Additive persistence fields (Stage 1 — schema v11)
/// Four optional fields are persisted when a pane has been connected at least once. They are ADDITIVE:
/// a v10 file that does not carry these keys decodes with all four `nil` (never traps). Only
/// `lastKnownTitle` feeds the load-time auto-title promotion (see ``WorkspacePersistence/loadTree()``);
/// the resume fields are reserved for Stage 2 (host-side detach/reattach) and are NOT fed into
/// `connect()` yet.
public struct PaneSpec: Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    /// Set for `remoteGUI` panes (which host-side window to mirror).
    public var video: VideoEndpoint?

    // MARK: Stage-1 additive persistence fields (schema v11)

    /// The session ID assigned by the host on the most-recent successful connection. Reserved for Stage 2
    /// (host-side detach/reattach). NOT fed into `connect()` in Stage 1.
    public var resumeSessionID: UUID?
    /// The last sequence number successfully received from the host (used to resume from a mid-stream
    /// disconnect in Stage 2). NOT fed into `connect()` in Stage 1.
    public var resumeLastReceivedSeq: Int64?
    /// The working directory reported by the host shell at last-seen time. Used as the display subtitle
    /// and as a hint for Stage 2 cwd-restore. Read-only from the client perspective.
    public var lastKnownCwd: String?
    /// The shell title (e.g. the running process or tab title) as last reported by the host. Written into
    /// ``title`` on load only when the user has not renamed the pane (see
    /// ``WorkspacePersistence/loadTree()``). Read-only from the client perspective.
    public var lastKnownTitle: String?

    /// The HOST-computed By-Project sidebar key (wire type 34): the git worktree toplevel containing the
    /// pane's cwd, else the cwd itself. Persisted so a cold relaunch renders the FINAL sections from disk
    /// (no cwd-fallback → toplevel re-bucketing flash). Written only through the guarded
    /// ``WorkspaceStore/setProjectKey(_:for:)`` sink; an absent key decodes `nil`
    /// (``WorkspaceStore/paneProjectKey(_:)`` then falls back to ``lastKnownCwd``).
    public var projectKey: String?

    /// True when the user has EXPLICITLY renamed this pane (⌘R / the palette / the inline rail field →
    /// ``WorkspaceStore/renamePane(_:to:)``). The single, unambiguous signal that ``title`` is a custom
    /// user identity that must win over the cwd-folder / shell-title auto-derivations.
    ///
    /// B2 (host-authoritative-metadata audit): the rail's OLD "is this a rename?" heuristic —
    /// `title != defaultTitle && title != lastKnownTitle` — MISFIRES the moment a shell emits a SECOND OSC
    /// title: the load-time promotion set `title == lastKnownTitle₀`, then `lastKnownTitle` advances to
    /// `title₁` while `title` stays `title₀`, so `title != lastKnownTitle` flips true and the stale promoted
    /// title latches as if the user had renamed it. An explicit flag removes the ambiguity (only a real
    /// rename sets it). Additive persisted field (encoded only when `true`); an older file without it decodes
    /// to `false` (no-backcompat: a pane renamed before B2 falls back to its cwd-folder title until re-named).
    public var userRenamed: Bool = false

    /// The title to surface in a command-completion notification/toast — the live OSC 0/2 shell title
    /// (``lastKnownTitle``, often the running command line) when the shell has reported one, else the
    /// host cwd's FOLDER NAME (``cwdDisplayName(_:)`` of ``lastKnownCwd`` — the same identity the
    /// sidebar/tab/window title show), else the static ``title`` (e.g. "Terminal"). Distinct from
    /// ``title`` itself, which stays the pane's persisted/renamable identity — this is only for the
    /// completion sink, which historically read `title` directly and so always showed the generic default.
    ///
    /// B1 (host-authoritative-metadata audit): the cwd fallback keeps the banner consistent with the
    /// visible pane title for a shell that emits NO OSC-0/2 title (Starship / hookless) — without it the
    /// banner said "Terminal" while every other surface showed the folder name.
    public var completionNotificationTitle: String {
        lastKnownTitle ?? Self.cwdDisplayName(lastKnownCwd) ?? title
    }

    /// The display FOLDER NAME of a working directory: its last path component (`/a/b/repo` → `repo`,
    /// trailing-slash tolerant), the root as `/`, a bare `~` kept as-is. `nil` for `nil`/blank so a caller
    /// falls back cleanly — never an empty title. Lifted into ``PaneSpec`` (WorkspaceCore) as the single
    /// source of truth so BOTH the pure completion title above and the client-UI rail row
    /// (``RailRowsBuilder`` delegates here) derive the same folder name from a cwd.
    public static func cwdDisplayName(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        var path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { return "/" }
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return leaf.isEmpty ? nil : leaf
    }

    /// True when `path` is almost certainly a plugin-manager's TRANSIENT cache dir — not a directory the
    /// user navigated to — so it must never become a pane's ``lastKnownCwd`` (the inherit source for new
    /// panes + the sidebar/title label).
    ///
    /// On a shell WITHOUT an OSC-7 chpwd hook, `lastKnownCwd` is fed only by the host `cwd` RPC
    /// (`proc_pidinfo` of the shell), which reads the KERNEL cwd and so observes every transient `chdir`
    /// the shell makes internally. A zsh plugin manager in TURBO / deferred mode (zinit `wait lucid`,
    /// antidote, …) `builtin cd`s into a plugin's cache dir to SOURCE it — synchronously inside a precmd,
    /// or async via `zsh/sched` while the shell sits idle at the prompt. `WorkspaceStore.refreshCwd` fires
    /// the RPC on every command completion (OSC 133;D); racing that transient `cd` returns e.g.
    /// `…/plugins/zsh-users---zsh-autosuggestions`, poisoning the inherit source so a later new-tab /
    /// split / relaunch spawns its PTY THERE (the "cwd sometimes becomes zsh-users---zsh-autosuggestions"
    /// bug). OSC 7 itself is immune — zinit uses `cd -q`, which suppresses the chpwd hooks OSC 7 rides —
    /// but a hookless shell has ONLY the RPC, so the guard lives at the cwd sink instead.
    ///
    /// Signature: a `/`-component of the form `owner---repo` — zinit's `user/repo → user---repo`
    /// flattening. A triple-dash component is vanishingly unlikely in a real project path, so this is a
    /// tight, low-false-positive drop. Applied at BOTH the write sink (``WorkspaceStore/setLastKnownCwd``,
    /// blocks new poison) and the spawn seed (`LivePaneSession`'s `initialCwd`, so a persisted poison
    /// self-heals to the host default on the next launch).
    public static func looksLikeTransientPluginCwd(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.contains("---") }
    }

    public init(
        kind: PaneKind,
        title: String,
        video: VideoEndpoint? = nil,
        resumeSessionID: UUID? = nil,
        resumeLastReceivedSeq: Int64? = nil,
        lastKnownCwd: String? = nil,
        lastKnownTitle: String? = nil,
        projectKey: String? = nil,
        userRenamed: Bool = false,
    ) {
        self.kind = kind
        self.title = title
        self.video = video
        self.resumeSessionID = resumeSessionID
        self.resumeLastReceivedSeq = resumeLastReceivedSeq
        self.lastKnownCwd = lastKnownCwd
        self.lastKnownTitle = lastKnownTitle
        self.projectKey = projectKey
        self.userRenamed = userRenamed
    }
}

// MARK: - PaneSpec Codable (additive — new keys are decodeIfPresent so v10 files still load)

extension PaneSpec: Codable {
    /// A stale `floatingFrame` key (floating-pane feature removed 2026-07-03) is simply not in
    /// ``CodingKeys`` → decode-ignored.
    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case video
        case resumeSessionID
        case resumeLastReceivedSeq
        case lastKnownCwd
        case lastKnownTitle
        case projectKey
        case userRenamed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PaneKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        video = try c.decodeIfPresent(VideoEndpoint.self, forKey: .video)
        resumeSessionID = try c.decodeIfPresent(UUID.self, forKey: .resumeSessionID)
        resumeLastReceivedSeq = try c.decodeIfPresent(Int64.self, forKey: .resumeLastReceivedSeq)
        lastKnownCwd = try c.decodeIfPresent(String.self, forKey: .lastKnownCwd)
        lastKnownTitle = try c.decodeIfPresent(String.self, forKey: .lastKnownTitle)
        // Additive: a file written before the host-pushed key decodes to `nil` (cwd fallback).
        projectKey = try c.decodeIfPresent(String.self, forKey: .projectKey)
        // Additive (B2): an older file without the key decodes to `false` (validate-then-default).
        userRenamed = try c.decodeIfPresent(Bool.self, forKey: .userRenamed) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(video, forKey: .video)
        try c.encodeIfPresent(resumeSessionID, forKey: .resumeSessionID)
        try c.encodeIfPresent(resumeLastReceivedSeq, forKey: .resumeLastReceivedSeq)
        try c.encodeIfPresent(lastKnownCwd, forKey: .lastKnownCwd)
        try c.encodeIfPresent(lastKnownTitle, forKey: .lastKnownTitle)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        // Encoded only when set, so a never-renamed pane's JSON is unchanged (additive-minimal).
        if userRenamed { try c.encode(userRenamed, forKey: .userRenamed) }
    }
}

// MARK: - PaneSpec presentation derivations (E21 WI-5)

public extension PaneSpec {
    /// The sidebar-rail SECOND LINE for this pane (E21 WI-5) — the single, kind-generic source of truth the
    /// native rail row (``RailRowsBuilder`` in `SlopDeskClientUI`) and any other surface bind their subtitle
    /// to, so a `.remoteGUI` window is a first-class peer of a terminal in the rail (carry-overs §0).
    ///
    /// - A `.terminal` pane shows its last-known working directory (``lastKnownCwd``), or NOTHING when the cwd
    ///   is unknown — a single-line row, never a blank second line.
    /// - A VIDEO pane (`.remoteGUI`/`.systemDialog`) has no shell cwd, so the host-side window's owning APP
    ///   name (``VideoEndpoint/appName``) stands in — falling back to the window ``VideoEndpoint/title`` when
    ///   the app name is empty (a manual-id binding). A remote-window row then reads as a *labelled window*
    ///   (its window title on line 1, the host app on line 2) rather than a bare single line.
    /// - A real cwd, if ever present, always wins (the subtitle never silently drops a working directory).
    ///
    /// Pure + total — NO kind is dropped (the `default`/non-video arm just yields the cwd-or-nil a terminal
    /// already used), so the builder stays kind-generic and never branches the whole row. Mirrors the
    /// Open-Quickly subtitle discipline (``OpenQuicklyModel`` `paneRowSubtitle`), which carries the leaner
    /// window-title fold; the rail gets this richer host-app line. A non-empty trimmed-presence check keeps an
    /// empty field from rendering a blank line (the ``OpenQuicklyModel`` `nonEmpty` discipline).
    var railSubtitle: String? {
        if let cwd = Self.presentablePresence(lastKnownCwd) { return cwd }
        guard kind.isVideo, let video else { return nil }
        if let app = Self.presentablePresence(video.appName) {
            // EMPTY HOST-TITLE PARITY: when the streamed window has NO title, the `newRemoteWindowTab` /
            // `addSystemDialogPane` LABEL collapses to the app name — so the display title (line 1) AND the
            // streamed window title are BOTH just the app name. Printing the host app on line 2 then shows it
            // on both lines. Suppress to a single line ONLY in that all-collapsed case; a window WITH a real
            // title keeps line 1 distinct, so the host-app subtitle still shows (a labelled window).
            let line1 = Self.presentablePresence(lastKnownTitle) ?? Self.presentablePresence(title)
            if line1 == app, Self.presentablePresence(video.title) == app { return nil }
            return app
        }
        return Self.presentablePresence(video.title)
    }

    /// A trimmed-presence helper: `nil` for `nil`/blank, the trimmed string otherwise — so an empty/whitespace
    /// field becomes "no subtitle", never a blank second line.
    private static func presentablePresence(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Focus intent

/// A focus-movement intent, resolved geometrically against the solved layout (docs/22 §2.1).
///
/// The four cardinal directions move to the nearest pane in that direction *as the user sees it*
/// (``FocusResolver/neighbor(of:_:in:)`` works on the same rects the layout renders, never on
/// abstract tree position). `next` / `previous` cycle through the pre-order leaf list with wrap
/// (``FocusResolver/cycle(_:from:forward:)``), which is what `⌘]` / `⌘[` and a compact swipe map
/// to.
public enum FocusDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
    /// Cycle forward through the leaves (wraps past the end).
    case next
    /// Cycle backward through the leaves (wraps past the start).
    case previous
}
