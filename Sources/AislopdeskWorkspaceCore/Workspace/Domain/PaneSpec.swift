import CoreGraphics
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
    /// `WorkspaceBindingRegistry.route` mints this immediately on a split / new-tab / new-session / floating
    /// gesture and FOCUSES it, so the user picks the kind INSIDE the pane (no modal popup). It materializes
    /// NO live session (the reconcile skips it); ``WorkspaceStore/choosePaneKind(_:kind:)`` flips it to a real
    /// kind, at which point reconcile materializes the terminal / remote-GUI session IN PLACE (same `PaneID`).
    case chooser
    /// A LOCAL built-in web pane (a non-persistent `WKWebView`, E18) — NOT a video kind: it rides no remote
    /// stream and renders a browser surface entirely client-side. Like ``chooser`` it materializes NO live
    /// session (the reconcile SKIPS it), has no PTY input funnel, and is not agent-detectable; unlike
    /// ``chooser`` it PERSISTS — its current address survives the round-trip in the additive
    /// ``PaneSpec/webURL`` field, so a restored web pane reopens the same page. The `WKWebView` itself lives
    /// ONLY in the app target behind `WebRendererFactory`; the library never imports WebKit (hang-safety —
    /// no GUI/WebKit object is ever built in a headless or test context).
    case web

    /// The retired-but-tolerated legacy raw value of the removed "Claude Code" pane kind (docs/42 W11).
    /// A `.claudeCode` pane is now just a `.terminal`; an OLD persisted file (v9, or a v10 written before
    /// W11) may still carry this discriminator. Kept ONLY as the migration/decode bridge below.
    static let legacyClaudeCodeRawValue = "claudeCode"

    /// **Forward/back-tolerant decode (validate-then-repair, CLAUDE.md untrusted-persisted-data
    /// contract).** A persisted `"claudeCode"` raw value (the removed kind, W11) maps to `.terminal` so
    /// an old workspace file never traps now the case is gone — a Claude session is just a terminal. Any
    /// OTHER unknown raw value still throws (it is genuine corruption the loader's reset path handles),
    /// preserving the strict behaviour for everything except the one intentionally-retired value.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == Self.legacyClaudeCodeRawValue {
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

    // MARK: Floating overlay field (additive — schema v11)

    /// Non-`nil` marks this pane as a **floating** (scratch) pane that overlays the tiled layout instead
    /// of occupying a tree leaf rect (zellij-style floating panes). The rect is expressed in the
    /// `SplitTreeView` bounds coordinate space (top-left origin) and is the pane's last placed frame; the
    /// render model (``SplitTreeRenderModel/Layout/floatingLeaves``) clamps it into the live container on
    /// every layout, so a stale/oversized persisted rect can never escape the viewport. A pane that has
    /// never floated (or one that was embedded back into the tree) has `nil` here and tiles normally. The
    /// pane's membership in the floating layer is owned by ``Tab/floatingPanes``; this rect is just its
    /// geometry. Additive: a v10/v11 file written before this field decodes `nil` (tiled). `CGRect` is
    /// `Codable`/`Equatable`/`Sendable`, so the auto-synthesis on ``PaneSpec`` still holds.
    public var floatingFrame: CGRect?

    // MARK: Web-pane field (additive — E18, no schema bump)

    /// The current address of a ``PaneKind/web`` pane, as a raw string (the normalized URL most recently
    /// navigated to). Set ONLY for `.web` panes — `nil` for every other kind. Written back through the
    /// store on each navigation (``WorkspaceStore`` `setPaneWebURL`) so a restored web pane reopens the
    /// same page. Stored as a `String?` (not `URL`) so it survives an empty/relative draft without the
    /// `URL` Codable's strictness; the leaf view re-normalizes it through `WebURLNormalizer` before load.
    /// Additive: a v11 file written before this field decodes `nil` (a fresh/blank web pane), exactly the
    /// ``floatingFrame`` pattern — NO schema bump, never traps.
    public var webURL: String?

    public init(
        kind: PaneKind,
        title: String,
        video: VideoEndpoint? = nil,
        resumeSessionID: UUID? = nil,
        resumeLastReceivedSeq: Int64? = nil,
        lastKnownCwd: String? = nil,
        lastKnownTitle: String? = nil,
        floatingFrame: CGRect? = nil,
        webURL: String? = nil,
    ) {
        self.kind = kind
        self.title = title
        self.video = video
        self.resumeSessionID = resumeSessionID
        self.resumeLastReceivedSeq = resumeLastReceivedSeq
        self.lastKnownCwd = lastKnownCwd
        self.lastKnownTitle = lastKnownTitle
        self.floatingFrame = floatingFrame
        self.webURL = webURL
    }
}

// MARK: - PaneSpec Codable (additive — new keys are decodeIfPresent so v10 files still load)

extension PaneSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case video
        case resumeSessionID
        case resumeLastReceivedSeq
        case lastKnownCwd
        case lastKnownTitle
        case floatingFrame
        case webURL
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
        floatingFrame = try c.decodeIfPresent(CGRect.self, forKey: .floatingFrame)
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
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
        try c.encodeIfPresent(floatingFrame, forKey: .floatingFrame)
        try c.encodeIfPresent(webURL, forKey: .webURL)
    }
}

// MARK: - PaneSpec presentation derivations (E21 WI-5)

public extension PaneSpec {
    /// The sidebar-rail SECOND LINE for this pane (E21 WI-5) — the single, kind-generic source of truth the
    /// native rail row (``RailRowsBuilder`` in `AislopdeskClientUI`) and any other surface bind their subtitle
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
        if let app = Self.presentablePresence(video.appName) { return app }
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
