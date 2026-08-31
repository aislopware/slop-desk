import Foundation
import Observation

// De-SwiftUI'd — headless in `SlopDeskWorkspaceCore`. No `import SwiftUI` / `#if canImport(SwiftUI)`
// guard; `@MainActor` / `@Observable` come from Observation.
import SlopDeskVideoProtocol

// MARK: - PreferencesStore (what the settings MEAN, applied)

/// The four apply paths, and the two pieces of per-session state that ride along with them.
///
/// It used to own the settings as well — six `Codable` models persisted to `UserDefaults`, mutated
/// by a settings window, each with a `didSet` that re-applied. The settings are a FILE now
/// (``AppConfig``), so what is left is the half that was always the interesting one: turning a
/// resolved configuration into an effect on a running app.
///
/// FOUR apply paths (see `DECISIONS.md`):
///   1. **Client-readable video / agent flags → ``EnvConfig/overlay``.** They fold into the
///      process-wide overlay, overriding the compile-time default WITHOUT an env var. The `[env]`
///      table folds LAST, so a hand-written `SLOPDESK_*` beats the typed key that maps to it.
///   2. **Video / agent flags → the `video-prefs.json` SIDECAR (no live apply).** The host daemon
///      reads them at `static let` init and cannot live-reload, so a change reaches it at the next
///      launch. Applies on reconnect.
///   3. **Terminal keys → the live terminal reload.** Re-resolves what the file states and bumps
///      ``TerminalConfigBroadcaster``; every renderer re-applies through its typed doors. The config
///      TEXT this used to build is gone — it had no parser on the other end (docs/68).
///   4. **The `[keybind]` table → the registry overrides.** Publishes them to
///      ``WorkspaceBindingRegistry/activeOverrides`` so a chord resolves with the user override —
///      the registry stays the single binding TABLE; this only supplies overrides.
///
/// BEHAVIOR-PRESERVATION: a machine with no config file resolves the video and agent keys to
/// ABSENT — the table declares them without a default on purpose, because their numbers belong to
/// the daemon — so the overlay is empty, the sidecar carries no override, and the golden corpus is
/// byte-identical to an install that never had a settings system at all.
@preconcurrency
@MainActor
@Observable
public final class PreferencesStore {
    // MARK: The resolved reading

    /// The configuration every apply path below reads. Re-read by ``reapplyLiveSettings()``; never
    /// written, because nothing in this app writes a setting.
    public private(set) var config: AppConfig

    /// The terminal render preferences the config file resolves to — font, colours, cursor,
    /// scrollback. A projection, rebuilt on reload, not a stored model with a `didSet`.
    public var terminal: TerminalPreferences { TerminalPreferences(config) }

    /// The video / FEC / pacer / capture host flags, as the file resolves them. Every field is
    /// optional and an untouched install leaves all of them `nil`.
    public var video: VideoPreferences { VideoPreferences(config) }

    /// The agent detection gates, as the file resolves them.
    public var agent: AgentPreferences { AgentPreferences(config) }

    /// The user's `[keybind]` table, folded into binding overrides.
    ///
    /// Stored rather than computed because the fold resolves NAMED actions through the registry
    /// (`cmd+t = "new_tab"` → `tab.new`), which crosses an FFI door per entry — cheap, but not
    /// something to redo on every read. Rebuilt by ``reapplyLiveSettings()``, the only moment the
    /// table can change.
    public private(set) var keybindings: KeybindingPreferences

    /// Fold a `[keybind]` table into overrides, resolving named actions against the registry.
    ///
    /// The resolver is supplied HERE and not inside ``KeybindConfigLoader`` because the loader lives
    /// in `SlopDeskVideoProtocol`, which must not import this module — that layering is why the hook
    /// is a closure. An unknown name resolves to `nil` and the entry is dropped.
    private static func foldKeybinds(_ config: AppConfig) -> KeybindingPreferences {
        KeybindConfigLoader.apply(table: config.keybinds) { named in
            guard let bindingID = WorkspaceBindingRegistry.bindingID(
                forConfigName: named.id, arg: named.arg,
            ) else { return nil }
            return (bindingID: bindingID, chord: named.chord)
        }
    }

    // MARK: The runtime font-size delta (⌘+ / ⌘- / ⌘0)

    /// Point sizes ⌘± has moved the terminal from ``AppConfig``'s `terminal.font-size`.
    ///
    /// EPHEMERAL on purpose, and the one place this object holds a value at all. Zooming is a thing
    /// you do to read a stack trace, not a preference you are stating; persisting it would mean a
    /// font size that quietly disagrees with the file the user wrote, forever, with nothing on
    /// screen explaining why. ⌘0 puts it back and so does a relaunch — the same shape Ghostty's own
    /// runtime font size has.
    public private(set) var fontSizeDelta: Double = 0

    // MARK: Dependencies (injectable for tests)

    private let defaults: UserDefaults
    private let sidecarURL: URL?

    // MARK: UserDefaults keys — per-session STATE, never a setting

    enum Key {
        /// The starred command blocks, `sessionUUID → [block index]`.
        static let blockBookmarks = "state.blockBookmarks.v1"
        /// The completion counters this DEVICE has already read, scoped to the document epoch they
        /// were recorded under (``SeenCompletionEpochs``). Device-local by design: the host holds no
        /// per-client acknowledgement state, so every viewer answers "is this finish unread" for
        /// itself.
        static let seenCompletionEpochs = "state.seenCompletionEpochs.v1"
    }

    // MARK: Init / apply

    /// Reads the resolved configuration and applies it. `sidecarURL` defaults to the shared
    /// `video-prefs.json` location; tests inject a temp URL (or `nil` to skip the sidecar write).
    /// `applyOnInit` runs the apply paths once after load (default ON; a test that must not mutate
    /// the process overlay passes `false`).
    public init(
        defaults: UserDefaults = SettingsKey.store,
        sidecarURL: URL? = EnvBridge.defaultSidecarURL(),
        applyOnInit: Bool = true,
        config: AppConfig = AppConfig.current,
    ) {
        self.defaults = defaults
        self.sidecarURL = sidecarURL
        self.config = config
        keybindings = Self.foldKeybinds(config)
        if applyOnInit {
            applyTerminal()
            applyVideoAndAgent()
            applyKeybindings()
        }
    }

    // MARK: Apply paths

    /// Resolve the terminal keys and bump the broadcaster so every live renderer re-applies them
    /// through its typed doors — see ``TerminalConfigBroadcaster``.
    private func applyTerminal() {
        // The app's one terminal profile pins the CELL bg/fg (flat design) — `resolveTerminalColors`
        // reads `SlateTheme.app` (GUI only; `nil` headless ⇒ the config's own colours stand).
        let themeColors = AppearanceApplier.resolveTerminalColors?()
        var prefs = TerminalPreferences(config)
        prefs.fontSize = PreferenceRules.effectiveFontSize(configured: prefs.fontSize, delta: fontSizeDelta)
        // `prefs` already carries the EFFECTIVE size — the ⌘± delta was folded in above — so the
        // renderer measures its grid from the same number that was published.
        TerminalConfigBroadcaster.shared.publish(
            fontFamily: prefs.fontFamily,
            fontSize: prefs.fontSize,
            // The FALLBACK is the point, and it is what keeps `terminal.background` /
            // `terminal.foreground` honest: with the hook installed (every GUI build) the one flat
            // profile wins, and without it the file's own two colours are what the cells wear. A
            // `nil` here would leave the surface at the ENGINE's defaults, so a headless render would
            // ignore both the theme and the file.
            themeWords: themeColors ?? ResolvedTerminalTheme(preferences: prefs),
            scrollbackLines: prefs.scrollbackLines,
            cursorStyle: prefs.cursorStyle.surfaceCode,
            cursorBlink: prefs.cursorBlink.surfaceCode,
            cursorColor: prefs.cursorColorWord,
            cursorTextColor: prefs.cursorTextColorWord,
            cursorOpacity: prefs.cursorOpacity,
        )
    }

    /// Re-resolve + publish the terminal settings from the current reading. The seam a surface calls
    /// when it needs them re-derived without a reload.
    public func refreshTerminalControls() {
        applyTerminal()
    }

    // MARK: Font-size zoom (⌘+ / ⌘- / ⌘0)

    /// ⌘+ / ⌘= — one step bigger. A font-SIZE change DOES reflow the remote PTY grid (the cell box
    /// resizes → SIGWINCH); that is correct, not a bug — only font FAMILY/STYLE rebuilds are
    /// grid-preserving.
    public func increaseFontSize() { applyZoom(.increase) }

    /// ⌘- — one step smaller.
    public func decreaseFontSize() { applyZoom(.decrease) }

    /// ⌘0 — back to the size the config file states.
    public func resetFontSize() { applyZoom(.reset) }

    /// The size the terminal is drawing at right now: the file's answer plus whatever ⌘± has moved
    /// it by, held inside the zoom band.
    public var effectiveFontSize: Double {
        PreferenceRules.effectiveFontSize(
            configured: TerminalPreferences(config).fontSize, delta: fontSizeDelta,
        )
    }

    /// Take the new delta ``PreferenceRules/zoom(configured:delta:_:)`` lands on and re-apply.
    ///
    /// A press the rule refuses — either edge of the band, or ⌘0 with nothing zoomed — leaves the
    /// delta alone and never reaches ``applyTerminal()``, which is what keeps a ⌘± held down against
    /// the edge from churning the broadcaster: its generation bumps unconditionally, so a re-publish
    /// of an identical string still rebuilds every live terminal's config and re-measures its grid.
    private func applyZoom(_ press: PreferenceRules.Zoom) {
        guard let moved = PreferenceRules.zoom(
            configured: TerminalPreferences(config).fontSize, delta: fontSizeDelta, press,
        ) else { return }
        fontSizeDelta = moved
        applyTerminal()
    }

    /// Fold the video + agent keys and the `[env]` table into the process-wide ``EnvConfig`` overlay
    /// for the CLIENT-readable flags, and write the `video-prefs.json` SIDECAR for the host daemon.
    ///
    /// WITHIN the overlay: the typed keys first, then `[env]` on top, so a hand-written
    /// `SLOPDESK_*` line wins over the typed key that maps to it. ACROSS tiers: a real `ProcessInfo`
    /// env var STILL wins over the whole overlay (see `DECISIONS.md`, `env → overlay → default`) —
    /// ``EnvConfig/string(_:)`` checks the real env var FIRST, so a deliberate `launchctl` / `--args`
    /// env on the CLIENT is never clobbered by a configured value.
    private func applyVideoAndAgent() {
        var overlay = EnvBridge.toEnv(video).merging(EnvBridge.toEnv(agent)) { _, new in new }
        for (key, value) in config.env where !key.isEmpty { overlay[key] = value }
        EnvConfig.overlay = overlay
        writeSidecar()
    }

    /// Serialise the video + agent keys to the `video-prefs.json` sidecar the HOST daemon reads at
    /// launch. A nil `sidecarURL` (tests) skips the write. Failure is swallowed — a write that
    /// cannot reach disk must not crash the UI, and the compiled-in answers still hold.
    private func writeSidecar() {
        guard let url = sidecarURL else { return }
        let sidecar = EnvBridge.VideoSidecar(video: video, agent: agent, rawOverrides: config.env)
        try? EnvBridge.writeSidecar(sidecar, to: url)
    }

    /// Publish the keybinding overrides to the registry so a chord resolves with the user override
    /// when present (the registry stays the single binding TABLE; this supplies the overrides).
    private func applyKeybindings() {
        WorkspaceBindingRegistry.activeOverrides = keybindings
    }

    /// Re-read ``AppConfig/current`` and re-fire the LIVE client apply paths — the effect behind
    /// `slopdesk config reload`.
    ///
    /// Deliberately SKIPS ``applyVideoAndAgent()``: those host flags are "applies on reconnect", and
    /// that path rewrites the process-wide ``EnvConfig/overlay`` (a `nonisolated(unsafe)` static the
    /// realtime pipeline reads), so a reload must not race-rewrite it.
    public func reapplyLiveSettings() {
        config = AppConfig.current
        keybindings = Self.foldKeybinds(config)
        applyTerminal()
        applyKeybindings()
    }

    // MARK: Block bookmarks (per-session starred command blocks)

    /// The persisted per-session block bookmarks: `sessionUUID → [block index]`. STATE, not a
    /// setting — never folded into the env overlay or the sidecar. An absent key reads as empty.
    private func loadBlockBookmarkMap() -> [String: [UInt32]] {
        Self.decode([String: [UInt32]].self, defaults, Key.blockBookmarks) ?? [:]
    }

    /// The bookmarked block indices for `sessionUUID` (empty if none / unknown). The wiring layer
    /// seeds a pane's ``TerminalBlockModel`` from this on attach.
    public func blockBookmarks(for sessionUUID: String) -> [UInt32] {
        loadBlockBookmarkMap()[sessionUUID] ?? []
    }

    /// Persists `indices` as `sessionUUID`'s bookmarks (an EMPTY set removes the entry, keeping the
    /// map tidy). The wiring layer calls this from the model's `onBookmarksChanged`.
    public func setBlockBookmarks(_ indices: [UInt32], for sessionUUID: String) {
        var map = loadBlockBookmarkMap()
        if indices.isEmpty { map.removeValue(forKey: sessionUUID) } else { map[sessionUUID] = indices }
        Self.encode(map, defaults, Key.blockBookmarks)
    }

    // MARK: Seen completion counters (the unread-finish marker's device half)

    /// The persisted ``SeenCompletionEpochs``, or `nil` on a fresh install.
    public func seenCompletionEpochs() -> SeenCompletionEpochs? {
        Self.decode(SeenCompletionEpochs.self, defaults, Key.seenCompletionEpochs)
    }

    public func setSeenCompletionEpochs(_ record: SeenCompletionEpochs) {
        Self.encode(record, defaults, Key.seenCompletionEpochs)
    }

    private static func encode(_ value: some Encodable, _ defaults: UserDefaults, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - TerminalConfigBroadcaster (the live terminal-reload seam)

/// The process-wide bridge carrying the current terminal settings from ``PreferencesStore`` to the
/// live renderer.
///
/// It used to carry a config STRING to the deleted fork's `GhosttyTerminalView`, which re-applied it
/// via `ghostty_config_load_string` and re-measured + resized the PTY grid. That string outlived its
/// only parser and is gone: the renderer takes typed doors, so what crosses here is the VALUES those
/// doors take. `docs/68` argues the boundary; the practical difference is that a `scrollback-limit`
/// of 10 000 now means ten thousand ROWS rather than whatever a 256-byte-per-line estimate bought.
///
/// Everything here is a setting ``PreferencesStore`` had to RESOLVE — the ⌘± delta folded into the
/// size, the theme's palette, a colour parsed out of its hex. A setting the driver can read straight
/// off `SettingsKey` does not travel this way; it is read where it is applied.
///
/// A tiny `@Observable` holder (not the model) so the gated renderer can `@Observe` it without importing
/// the whole store; the HEADLESS build keeps a no-op consumer. The `generation` bumps on each publish so
/// an idempotent re-publish of the SAME values still triggers a reload (e.g. a ⌘± that lands back where
/// it started).
@preconcurrency
@MainActor
@Observable
public final class TerminalConfigBroadcaster {
    public static let shared = TerminalConfigBroadcaster()

    /// The monospace family the terminal draws with, as the renderer's `slopdesk_term_surface_new`
    /// takes it. Empty until the first publish, which the renderer reads as "the engine's default".
    public private(set) var fontFamily = ""

    /// Monotonic publish counter — the renderer keys its "apply on change" off this, so re-publishing
    /// the same values still reloads.
    public private(set) var generation = 0

    public init() {}

    /// The EFFECTIVE point size — the file's `terminal.font-size` plus whatever ⌘± has moved it by.
    /// `0` until the first publish, for ``fontFamily``'s reason.
    ///
    /// Effective rather than configured, because the renderer measures a grid from it: handing over
    /// the configured size would draw at one size and lay out at another the moment ⌘+ was pressed.
    public private(set) var fontSize: Double = 0

    /// The cell colours as the renderer's doors take them, or `nil` where no GUI filled the seam
    /// (headless, pre-launch) and the engine's own defaults stand.
    public private(set) var themeWords: ResolvedTerminalTheme?

    /// How many ROWS of scrollback to retain.
    public private(set) var scrollbackLines = 0

    /// The caret's shape, blink and colour as their doors take them — see
    /// ``TerminalPreferences/CursorStyle/surfaceCode``.
    ///
    /// All three set the engine's DEFAULT, which is what makes them safe to publish: a program's
    /// `DECSCUSR` or `OSC 12` still wins, so a user who prefers a bar keeps it in the shell and still
    /// sees vim's block in insert mode.
    public private(set) var cursorStyle: UInt8 = 0
    /// See ``cursorStyle``. `0` defers to DEC mode 12.
    public private(set) var cursorBlink: UInt8 = 0
    /// See ``cursorStyle``. `nil` follows the foreground.
    public private(set) var cursorColor: UInt32?

    /// The glyph colour under a filled caret; `nil` keeps the cell's own background.
    ///
    /// Apart from ``cursorColor`` because it is not an engine default at all: no escape sequence
    /// names this colour, so there is nothing for a program to override and the renderer decides it
    /// outright.
    public private(set) var cursorTextColor: UInt32?

    /// How opaque the caret is drawn, `0`–`1`. Zero is a real way to turn it off.
    public private(set) var cursorOpacity: Double = 1

    /// Publish the resolved terminal settings (bumps ``generation`` even if nothing moved).
    public func publish(
        fontFamily: String = "",
        fontSize: Double = 0,
        themeWords: ResolvedTerminalTheme? = nil,
        scrollbackLines: Int = 0,
        cursorStyle: UInt8 = 0,
        cursorBlink: UInt8 = 0,
        cursorColor: UInt32? = nil,
        cursorTextColor: UInt32? = nil,
        cursorOpacity: Double = 1,
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.themeWords = themeWords
        self.scrollbackLines = scrollbackLines
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor
        self.cursorOpacity = cursorOpacity
        generation &+= 1
    }
}
