import CSlopDeskFFI
import Foundation

// MARK: - Identity

/// Stable identity for a single pane (an item in the ``Canvas``, a leaf in the ``SplitNode`` tree).
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

// MARK: - Leaf intent (what a pane IS — never a live object)

/// What a pane *is*. The kind selects which proven per-session stack the live layer will
/// materialize for the leaf (docs/22 §7): a plain remote terminal or a PATH-2 video stream.
///
/// Claude Code is not a distinct kind: a `claude` session is just a `.terminal` pane. The host
/// watches its PTY foreground process / hooks and the client auto-detects it (wire types 26/27 →
/// the per-pane `ClaudeStatus`), opening the read-only inspector channel dynamically. There is no
/// dedicated "Claude Code pane".
///
/// `String`-raw + hand-stable so the persisted JSON discriminator is human-readable and
/// versionable. **Forward/back-tolerant decode** (below): an OLD persisted `"claudeCode"` raw
/// value maps to `.terminal` so a file predating the kind's removal never traps.
public enum PaneKind: String, Codable, Sendable, Equatable {
    /// A remote PTY terminal (PATH 1 byte pipeline). Also hosts an auto-detected `claude` session.
    case terminal
    /// A FULL-DESKTOP video pane (the full-desktop pivot, docs/DECISIONS.md 2026-07-14): streams a
    /// whole host display (`VideoEndpoint.displayID`, `0` = main) over the PATH-2 UDP media + cursor
    /// side-channel. The hello is display-targeted (`helloDisplay`); the target never goes stale the
    /// way CGWindowIDs do.
    case desktop

    /// The retired-but-tolerated legacy raw value of the removed "Claude Code" pane kind. A
    /// `.claudeCode` pane is just a `.terminal`; an OLD persisted file may still carry this
    /// discriminator. Kept ONLY as the migration/decode bridge below.
    static let legacyClaudeCodeRawValue = "claudeCode"

    /// The retired-but-tolerated legacy raw value of the removed LOCAL web pane kind (the app is a
    /// remote terminal + remote-GUI tool; a local browser is not core). An OLD persisted file may
    /// still carry a `"web"` leaf; it decodes to `.terminal` via the bridge below (same discipline
    /// as ``legacyClaudeCodeRawValue``) so a stale workspace never traps.
    static let legacyWebRawValue = "web"

    /// The retired-but-tolerated legacy raw value of the removed in-pane kind CHOOSER (the Stage
    /// re-scope made every new-pane gesture mint a terminal directly, so the transient chooser kind is
    /// gone). A persisted `.chooser` was always mid-gesture ephemera; folding it to `.terminal` is
    /// exactly what picking the default would have done.
    static let legacyChooserRawValue = "chooser"

    /// The retired-but-tolerated legacy raw value of the removed REMOTE-WINDOW pane kind (the
    /// dedicated-desktop-window re-scope, docs/DECISIONS.md 2026-07-22: full-desktop is the only
    /// remote-viewing mode). A persisted `"remoteGUI"` leaf folds to `.terminal` via the bridge below
    /// (same discipline as ``legacyClaudeCodeRawValue``) — the stream identity is deliberately
    /// dropped (no-backcompat rule), the pane itself survives as a blank terminal.
    static let legacyRemoteGUIRawValue = "remoteGUI"

    /// The retired-but-tolerated legacy raw value of the removed SYSTEM-DIALOG pane kind (the
    /// no-video-in-the-workspace re-scope, docs/DECISIONS.md 2026-07-23: the dedicated desktop
    /// window is the only video surface). A `.systemDialog` pane was ephemeral and never persisted,
    /// so this bridge is pure belt-and-braces (the ``legacyChooserRawValue`` discipline).
    static let legacySystemDialogRawValue = "systemDialog"

    /// **Forward/back-tolerant decode (validate-then-repair, CLAUDE.md untrusted-persisted-data
    /// contract).** A persisted `"claudeCode"` raw value (the removed kind), `"web"` raw value (the
    /// removed local web pane), `"chooser"` raw value (the removed in-pane kind chooser),
    /// `"remoteGUI"` raw value (the removed remote-window pane), or `"systemDialog"` raw value (the
    /// removed system-dialog pane) maps to `.terminal` so an old workspace file never traps now the
    /// cases are gone. Any OTHER unknown raw value still throws (it is genuine corruption the
    /// loader's reset path handles), preserving the strict behaviour for everything except the
    /// intentionally-retired values.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == Self.legacyClaudeCodeRawValue || raw == Self.legacyWebRawValue
            || raw == Self.legacyChooserRawValue || raw == Self.legacyRemoteGUIRawValue
            || raw == Self.legacySystemDialogRawValue
        {
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
    /// remote-GUI view. The full-desktop ``desktop`` is the only video kind, and it lives in a dedicated
    /// OS window (the detached set), never in the workspace tree.
    var isVideo: Bool { self == .desktop }
    /// Whether this pane has a shell input funnel that text can be typed into — the recipient set for
    /// broadcast/synchronized input (tmux `synchronize-panes`). Only the PTY-backed `.terminal` kind; the
    /// video `.desktop` takes input through the cursor/key side-channel, not a text bar.
    var canReceiveText: Bool { self == .terminal }
}

/// Which remote target a video pane streams. The host + UDP ports are no longer here — they live ONCE
/// on the app-global ``ConnectionTarget`` (docs/31). All video panes ride the one shared UDP flow at
/// the app host; the per-pane target is normally a whole display (``displayID``) — the window shape
/// (``windowID``) survives ONLY as the automation/E2E seam (`check-video.sh` serves one window) and
/// for decode of older files. Persisted with the tree so a restored video pane remembers its target +
/// title; the actual UDP is opened against the app target.
public struct VideoEndpoint: Codable, Sendable, Equatable {
    /// The host-side window being mirrored (ScreenCaptureKit window id — the automation seam's
    /// window-shaped target). `0` for a display target.
    public var windowID: UInt32
    /// Human-readable target title (shown in pane chrome before the stream is live).
    public var title: String
    /// The owning app's name at capture time (`WindowSummary.appName`) for a window-shaped endpoint.
    /// Persisted-shape compatible with retired remote-window endpoints; empty for manual/display
    /// bindings.
    public var appName: String
    /// FULL-DESKTOP TARGET (a ``PaneKind/desktop`` pane): non-nil ⇒ stream this whole host display
    /// (`0` = the main display) instead of a window. Additive (a missing key decodes to `nil` — an
    /// older file's window endpoints are unaffected).
    public var displayID: UInt32?

    /// The stable TARGET identity latched modes are keyed by (`DevicePreferences.videoModesByTarget`):
    /// a desktop pane keys by its DISPLAY; a window-shaped endpoint (the automation seam) keys by its
    /// owning APP (CGWindowIDs recycle across host restarts — the app is the stable identity), falling
    /// back to the raw window id when no app name is known.
    public var modesKey: String {
        if let displayID { return "display:\(displayID)" }
        return appName.isEmpty ? "window:\(windowID)" : "app:\(appName)"
    }

    public init(windowID: UInt32, title: String, appName: String = "", displayID: UInt32? = nil) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.displayID = displayID
    }

    private enum CodingKeys: String, CodingKey {
        case windowID
        case title
        case appName
        case displayID
    }

    /// Hand-written because the SYNTHESIZED decode faulted on three of these four keys, and
    /// `slopdesk_workspace::persist::decode_video` repairs all three. **Rust had it right**; this is
    /// that function transcribed field for field:
    ///
    /// - `windowID` — `.and_then(Json::integer).and_then(|raw| u32::try_from(raw).ok()).unwrap_or(0)`:
    ///   absent, non-numeric, negative or past `u32` all read as `0`, the value that already MEANS
    ///   "not a window-shaped target" (see ``modesKey``). Synthesized Swift required the key and
    ///   threw on any of them.
    /// - `title` — `text(value, "title")?` is a fault in Rust, so it stays a fault here. It is the
    ///   only thing a window-shaped endpoint says about itself that a repair cannot invent; an
    ///   endpoint with no title describes no target, and `decode_spec` refuses that whole spec.
    /// - `appName` — `.and_then(Json::string).unwrap_or_default()`: absent or non-string is `""`,
    ///   which the doc comment above already calls the manual/display binding.
    /// - `displayID` — the same integer chain, answering `None`. An unreadable display target
    ///   therefore falls back to the window shape rather than failing, which is what Rust does.
    ///
    /// The trap being closed is `decodeIfPresent`/required-key decode on a key that is PRESENT with
    /// a value its type refuses: it does not answer `nil`, it THROWS, and here the throw did not
    /// stop at the endpoint. It unwound the `PaneSpec`, the `Session`, the whole `TreeWorkspace`, so
    /// `WorkspacePersistence.load()` fell back to the default workspace and filed the user's
    /// arrangement away as `.corrupt` — every session and tab lost to one edited window id.
    ///
    /// `encode(to:)` stays synthesized: it already writes what `encode_video` writes, `displayID`
    /// included only when set (`encodeIfPresent`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowID = (try? c.decode(UInt32.self, forKey: .windowID)) ?? 0
        title = try c.decode(String.self, forKey: .title)
        appName = (try? c.decode(String.self, forKey: .appName)) ?? ""
        // No `??` needed: `try?` on a non-optional decode already collapses "absent" and
        // "unreadable" into the `nil` this field spells as "not a display target".
        displayID = try? c.decode(UInt32.self, forKey: .displayID)
    }
}

/// The user's LATCHED video-pane modes (a `.desktop` pane): immersive system-key
/// capture, host audio, the viewport position lock, and the stream-quality overrides. DEVICE-LOCAL —
/// persisted in the client's `device-prefs.json` keyed by the stream TARGET
/// (`DevicePreferences.videoModesByTarget` / ``VideoEndpoint/modesKey``), deliberately NOT per pane, so
/// close-tab → reopen-the-same-target restores them (a reopened target mints a brand-new pane) as well
/// as a relaunch. The runtime source of truth is ``RemoteWindowModel``
/// (which re-asserts each wish into every freshly-published sink on a detach/reattach remount); this
/// struct is only the persisted snapshot of the user's last EXPLICIT toggles for a target.
///
/// Additive per field: an older file without the key — or a newer file with fields this build
/// doesn't know — decodes to the defaults, never traps.
public struct VideoPaneModes: Codable, Sendable, Equatable {
    /// Immersive system-key capture (⌘Tab/⌘Space… → host). macOS-only at runtime; the flag itself is
    /// platform-neutral so a shared workspace file round-trips losslessly.
    public var immersive: Bool
    /// Host app-audio streaming into this pane (the footer speaker).
    public var audioEnabled: Bool
    /// The viewport position lock (edge-hover auto-pan frozen, ⌥⌘L).
    public var viewportLocked: Bool
    /// Live stream-quality overrides (`0` = auto): host encode fps cap + bitrate ceiling.
    public var fpsCap: Int
    public var bitrateCeilingBps: Int

    public init(
        immersive: Bool = false,
        audioEnabled: Bool = false,
        viewportLocked: Bool = false,
        fpsCap: Int = 0,
        bitrateCeilingBps: Int = 0,
    ) {
        self.immersive = immersive
        self.audioEnabled = audioEnabled
        self.viewportLocked = viewportLocked
        self.fpsCap = fpsCap
        self.bitrateCeilingBps = bitrateCeilingBps
    }

    /// Every mode at its default — the spec then stores `nil` instead (additive-minimal JSON, like
    /// ``PaneSpec/userRenamed``'s encode-only-when-true discipline).
    public var isDefault: Bool { self == Self() }

    private enum CodingKeys: String, CodingKey {
        case immersive
        case audioEnabled
        case viewportLocked
        case fpsCap
        case bitrateCeilingBps
    }

    /// Every field FILLS, because the doc comment above already promised it would ("never traps")
    /// and `decodeIfPresent(…) ?? default` does not keep that promise: on a key present with a value
    /// its type refuses it THROWS rather than answering `nil`, past the default written beside it.
    /// Here the throw unwinds `DevicePreferences`, so one hand-edited `"immersive": "yes"` in
    /// `device-prefs.json` resets every latched mode for every target rather than that one flag.
    ///
    /// No Rust counterpart — this struct is device-local and has never been persisted by
    /// `slopdesk-workspace`. Swift is the only implementation of the answer; a future Rust decoder
    /// has to agree that each of these five is independently repairable, which is exactly what
    /// makes them safe to fill: every one is a toggle or a `0`-means-auto override that the user can
    /// re-assert in one click, and none of them names a pane.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        immersive = (try? c.decode(Bool.self, forKey: .immersive)) ?? false
        audioEnabled = (try? c.decode(Bool.self, forKey: .audioEnabled)) ?? false
        viewportLocked = (try? c.decode(Bool.self, forKey: .viewportLocked)) ?? false
        // Validate-then-default (untrusted persisted data): a negative override is nonsense — auto.
        fpsCap = Swift.max(0, (try? c.decode(Int.self, forKey: .fpsCap)) ?? 0)
        bitrateCeilingBps = Swift.max(0, (try? c.decode(Int.self, forKey: .bitrateCeilingBps)) ?? 0)
    }
}

/// The full value-typed description of a leaf: its kind, its display title, and (for a video kind) the
/// target it streams. The connection host is NOT here — terminals/Claude open a channel on the app-global
/// ``ConnectionTarget`` and a video pane opens a lane on the same host's UDP flow, selecting its display
/// or window via ``video``.
///
/// A `PaneSpec` is pure intent: it is what the pane *should* be, not a handle to anything live.
/// The store reads it to materialize a session; mutating it (e.g. rename) is done through the tree's
/// spec side table (`WorkspaceStore.updateSpecLive`) and triggers a reconcile downstream.
///
/// ### What a spec does NOT carry
/// The pane's live FACTS — its working directory, its By-Project key, the shell title it last asserted,
/// and the host session it resumes — are not here. They are per-pane state the workspace document owns
/// (`pane/cwd`, `pane/projectKey`, `pane/liveTitle`, `pane/spawnCwd`; docs/45 §5.3), read through
/// ``HostWorkspaceMirror``. The spec is what ``WorkspaceTopology/spec(_:from:)`` can rebuild from the
/// document and nothing more, so there is exactly one place each fact lives. The pane's resume identity
/// is its own ``PaneID``: the client proposes object ids (DECISIONS, Multi-client Phase 5 ruling 1), so
/// the id the host keys its liveness records by IS the id the layout uses.
public struct PaneSpec: Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    /// Set for video panes (which host-side display or window to stream).
    public var video: VideoEndpoint?

    /// True when the user has EXPLICITLY renamed this pane (⌘R / the palette / the inline rail field →
    /// ``WorkspaceStore/renamePane(_:to:)``). The single, unambiguous signal that ``title`` is a custom
    /// user identity that must win over the cwd-folder / shell-title auto-derivations.
    ///
    /// A heuristic like `title != defaultTitle && title != liveTitle` MISFIRES the moment a shell emits
    /// a SECOND OSC title: `title` stays at `title₀` while the live one advances to `title₁`, so the
    /// comparison flips true and a stale title latches as if the user had renamed it. An explicit flag
    /// removes the ambiguity — only a real rename sets it. Encoded only when `true`, so a never-renamed
    /// pane's JSON stays minimal.
    public var userRenamed: Bool = false

    /// The display FOLDER NAME of a working directory: its last path component (`/a/b/repo` → `repo`,
    /// trailing-slash tolerant), the root as `/`, a bare `~` kept as-is. `nil` for `nil`/blank so a caller
    /// falls back cleanly — never an empty title. Lifted into ``PaneSpec`` (WorkspaceCore) as the single
    /// source of truth so BOTH the pure completion title above and the client-UI rail row
    /// (``RailRowsBuilder`` delegates here) derive the same folder name from a cwd.
    ///
    /// A face over `slopdesk-workspace`'s `PaneSpec::cwd_display_name`, which `tab_ordering` already
    /// reads on the Rust side: the same rule written twice is the shape where a sidebar row and the
    /// project section it sorts into disagree about what one directory is called.
    public static func cwdDisplayName(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let bytes = Array(cwd.utf8)
        return bytes.withUnsafeBufferPointer { input -> String? in
            let needed = slopdesk_ws_cwd_display_name(input.baseAddress, input.count, nil, 0)
            // Zero is "no name to show", not "did not fit": a real name is never empty.
            guard needed > 0 else { return nil }
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_cwd_display_name(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            guard written == needed else { return nil }
            // Non-failable on purpose: the door slices a leaf out of a `str` it already validated,
            // so what comes back is UTF-8 by construction and a failable initialiser would only add
            // an arm no input can reach.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: room, as: UTF8.self)
        }
    }

    /// The same directory as a BADGE prints it — the whole path rather than its leaf, with a
    /// `/Users/<name>` or `/home/<name>` prefix collapsed to `~` and a trailing `/` marking it a
    /// directory (`/Users/abner/Workplace/myproject` → `~/Workplace/myproject/`).
    ///
    /// The command palette's WORKING DIRECTORY pill is what asks. An empty path answers empty — a
    /// badge that prints the whole path has nothing to fall back to, unlike ``cwdDisplayName(_:)``.
    ///
    /// ⚠️ The home is matched by SHAPE, never against this client's own `$HOME`: the path arrives
    /// from the REMOTE host over the `cwd()` metadata RPC, so the local home is an answer to a
    /// different question. `slopdesk-workspace`'s `PaneSpec::cwd_badge_path` holds the rule.
    public static func cwdBadgePath(_ cwd: String) -> String {
        var cwd = cwd
        let answer = wsAnswerBytes { out, cap in
            cwd.withUTF8 { input in
                slopdesk_ws_cwd_badge_path(input.baseAddress, input.count, out, cap)
            }
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: answer, as: UTF8.self)
    }

    /// True when `path` is almost certainly a plugin-manager's TRANSIENT cache dir — not a directory the
    /// user navigated to — so it must never become a pane's `pane/cwd` (the inherit source for new
    /// panes + the sidebar/title label).
    ///
    /// On a shell WITHOUT an OSC-7 chpwd hook, `pane/cwd` is fed only by the host `cwd` RPC
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
    ///
    /// A face over `slopdesk-workspace`'s `PaneSpec::looks_like_transient_plugin_cwd`, which
    /// `tab_ordering` already reads on the Rust side. Fourteen Swift call sites guard the pane
    /// directory with this; a second copy of the signature means the sinks and the ordering can
    /// disagree about which of them is poison.
    public static func looksLikeTransientPluginCwd(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        return bytes.withUnsafeBufferPointer { input in
            slopdesk_ws_transient_plugin_cwd(input.baseAddress, input.count)
        }
    }

    public init(
        kind: PaneKind,
        title: String,
        video: VideoEndpoint? = nil,
        userRenamed: Bool = false,
    ) {
        self.kind = kind
        self.title = title
        self.video = video
        self.userRenamed = userRenamed
    }
}

// MARK: - PaneSpec Codable

extension PaneSpec: Codable {
    /// A key this build does not know (a retired field, a hand edit) is simply not in ``CodingKeys``
    /// → decode-ignored.
    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case video
        case userRenamed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PaneKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        // STRICT on purpose, and it agrees with Rust: `decode_spec` matches `Some(Json::Null) | None
        // => None` and propagates anything `decode_video` refuses. A `video` object that is present
        // but malformed is a fault on both sides — a video pane whose target silently became `nil`
        // would come back as a blank surface pointed at nothing.
        video = try c.decodeIfPresent(VideoEndpoint.self, forKey: .video)
        // Absent OR unreadable ⇒ `false`. `decode_spec` asks exactly one question here —
        // `matches!(value.get("userRenamed"), Some(Json::Bool(true)))` — so `"userRenamed": "yes"`
        // is not true, and is not a fault either. **Rust had it right.**
        //
        // `decodeIfPresent(Bool.self, …) ?? false` was the trap: on a key present with a value the
        // type refuses it THROWS instead of answering `nil`, so the `?? false` beside it never ran
        // and the throw unwound the entire `TreeWorkspace` decode — `WorkspacePersistence.load()`
        // then replaced the user's whole arrangement with the default and wrote a `.corrupt`
        // sidecar. The field it was guarding decides one thing: whether a later host title may
        // overwrite this pane's name. That is not worth a workspace.
        userRenamed = (try? c.decode(Bool.self, forKey: .userRenamed)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(video, forKey: .video)
        // Encoded only when set, so a never-renamed pane's JSON stays minimal.
        if userRenamed { try c.encode(userRenamed, forKey: .userRenamed) }
    }
}

// MARK: - Pane presentation derivations

/// The pane-label rules that combine a pane's SPEC (kind, title, video target) with the live FACTS the
/// workspace document owns (its cwd, the shell title it last asserted).
///
/// Free functions rather than ``PaneSpec`` properties because the two halves have different owners: the
/// spec is layout the document rebuilds verbatim, the facts are per-pane state read from the mirror. A
/// property on the spec would have to pretend the spec knows both, which is precisely the cache that
/// went stale.
public enum PaneLabel {
    /// The title to surface in a command-completion notification/toast — the live OSC 0/2 shell title
    /// (`liveTitle`, often the running command line) when the shell has reported one, else the host
    /// cwd's FOLDER NAME (``PaneSpec/cwdDisplayName(_:)`` — the same identity the sidebar/tab/window
    /// title show), else the static spec `title` (e.g. "Terminal"). Distinct from the spec title itself,
    /// which stays the pane's persisted/renamable identity — this is only for the completion sink, which
    /// would otherwise read `title` directly and always show the generic default.
    ///
    /// The cwd fallback keeps the banner consistent with the visible pane title for a shell that emits
    /// NO OSC-0/2 title (Starship / hookless) — without it the banner says "Terminal" while every other
    /// surface shows the folder name.
    public static func completionNotificationTitle(
        title: String, cwd: String?, liveTitle: String?,
    ) -> String {
        liveTitle ?? PaneSpec.cwdDisplayName(cwd) ?? title
    }

    /// A pane's SECOND LINE — the single, kind-generic source of truth every surface that draws one
    /// binds to, so a video pane is a first-class peer of a terminal in the rail (carry-overs §0).
    /// `slopdesk_workspace::rail_title::pane_subtitle`, which is where the rule is decided and
    /// documented: what a terminal says depends on how much of its location the surface has already
    /// said, and what a video pane says depends on whether line one already said it.
    ///
    /// - Parameter projectKey: the section this pane is drawn under, supplied by a surface that
    ///   DRAWS section headers so the line can shrink to what the header does not already cover. A
    ///   surface without headers passes `nil` and gets the whole path.
    public static func railSubtitle(
        kind: PaneKind, title: String, video: VideoEndpoint?, cwd: String?, liveTitle: String?,
        projectKey: String?,
    ) -> String? {
        var strings = WsStrings()
        let inputs = SlopDeskWsSubtitle(
            kind: kind.ffiByte,
            spec_title: strings.span(title),
            video_present: video != nil,
            video_app_name: strings.span(video?.appName),
            video_title: strings.span(video?.title),
            cwd: strings.span(cwd),
            live_title: strings.span(liveTitle),
            project_key: strings.span(projectKey),
        )
        var blob = strings.bytes
        return blob.withUnsafeMutableBufferPointer { text in
            wsAnswer { out, cap in
                slopdesk_ws_pane_subtitle(inputs, text.baseAddress, text.count, out, cap)
            }
        }
    }
}

public extension PaneSpec {
    /// ``PaneLabel/railSubtitle(kind:title:video:cwd:liveTitle:projectKey:)`` for THIS spec — the
    /// caller supplies the three facts the spec does not carry.
    func railSubtitle(cwd: String?, liveTitle: String?, projectKey: String?) -> String? {
        PaneLabel.railSubtitle(
            kind: kind, title: title, video: video, cwd: cwd, liveTitle: liveTitle,
            projectKey: projectKey,
        )
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
