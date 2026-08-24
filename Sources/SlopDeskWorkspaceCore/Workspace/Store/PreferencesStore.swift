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
///   3. **Terminal keys → the live terminal reload.** Rebuilds the libghostty config string
///      (``TerminalConfigBuilder``) and bumps ``TerminalConfigBroadcaster`` so the (Xcode-app-target-
///      only) `GhosttyTerminalView` re-applies it via `ghostty_config_load_string` + a PTY grid resize.
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

    /// Rebuild the libghostty config string from the resolved terminal keys and the fire-time
    /// Controls bundle, and bump the broadcaster so the (Xcode-only) `GhosttyTerminalView`
    /// re-applies it live.
    private func applyTerminal() {
        // The app's one terminal profile pins the CELL bg/fg (flat design) — `resolveTerminalColors`
        // reads `SlateTheme.app` (GUI only; `nil` headless ⇒ the config's own colours stand).
        let themeColors = AppearanceApplier.resolveTerminalColors?()
        var prefs = TerminalPreferences(config)
        prefs.fontSize = Self.clampedFontSize(prefs.fontSize + fontSizeDelta)
        let config = TerminalConfigBuilder.string(
            for: prefs,
            backgroundOverride: themeColors?.background,
            foregroundOverride: themeColors?.foreground,
            // The active theme's ANSI palette + selection colour reach the terminal cells. Both are
            // optional and validate-then-drop in the builder, so a `nil` themeColors (headless / no
            // GUI hook) or a theme with no palette is byte-identical.
            paletteOverride: themeColors?.palette,
            selectionBackgroundOverride: themeColors?.selectionBackground,
            controls: Self.controlsConfig(from: TerminalControls.from(config: config)),
        )
        TerminalConfigBroadcaster.shared.publish(config)
    }

    /// Rebuild + publish the libghostty config from the current reading. The seam a surface calls
    /// when it needs the terminal string re-derived without a reload.
    public func refreshTerminalControls() {
        applyTerminal()
    }

    // MARK: Font-size zoom (⌘+ / ⌘- / ⌘0)

    /// The point-size step ⌘± moves by, and the band it stays inside.
    static let fontSizeStep: Double = 1
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// ⌘+ / ⌘= — one step bigger. A font-SIZE change DOES reflow the remote PTY grid (the cell box
    /// resizes → SIGWINCH); that is correct, not a bug — only font FAMILY/STYLE rebuilds are
    /// grid-preserving.
    public func increaseFontSize() { setFontSize(effectiveFontSize + Self.fontSizeStep) }

    /// ⌘- — one step smaller.
    public func decreaseFontSize() { setFontSize(effectiveFontSize - Self.fontSizeStep) }

    /// ⌘0 — back to the size the config file states.
    public func resetFontSize() {
        guard fontSizeDelta != 0 else { return }
        fontSizeDelta = 0
        applyTerminal()
    }

    /// The size the terminal is drawing at right now: the file's answer plus whatever ⌘± has moved
    /// it by.
    public var effectiveFontSize: Double {
        Self.clampedFontSize(TerminalPreferences(config).fontSize + fontSizeDelta)
    }

    /// Move the runtime size to `size`, clamped, and re-apply. A no-op at the clamp boundary, so a
    /// ⌘± held down against the edge does not churn the broadcaster.
    private func setFontSize(_ size: Double) {
        let clamped = Self.clampedFontSize(size)
        guard clamped != effectiveFontSize else { return }
        fontSizeDelta = clamped - TerminalPreferences(config).fontSize
        applyTerminal()
    }

    /// NaN-faithfully clamped to ``fontSizeRange`` (``Double/maximum(_:_:)`` /
    /// ``Double/minimum(_:_:)``, never a bare ternary).
    private static func clampedFontSize(_ size: Double) -> Double {
        Double.maximum(fontSizeRange.lowerBound, Double.minimum(fontSizeRange.upperBound, size))
    }

    /// Map the fire-time ``TerminalControls`` bundle to the leaf ``TerminalControlsConfig`` the
    /// (VideoProtocol) ``TerminalConfigBuilder`` consumes: boolean knobs pass straight through,
    /// multi-state enums resolve to their libghostty token. The mapping lives HERE (not the leaf) so
    /// the builder never imports WorkspaceCore — the one-way module graph is preserved.
    private static func controlsConfig(from controls: TerminalControls) -> TerminalControlsConfig {
        TerminalControlsConfig(
            copyOnSelect: controls.copyOnSelect,
            trimTrailing: controls.trimTrailing,
            clearOnTyping: controls.clearOnTyping,
            clearOnCopy: controls.clearOnCopy,
            pasteProtection: controls.pasteProtection,
            bracketedSafe: controls.bracketedSafe,
            clipboardReadToken: controls.clipboardRead.rawValue,
            clipboardWriteToken: controls.clipboardWrite.rawValue,
            hideMouseWhileTyping: controls.hideMouseWhileTyping,
            mouseShiftCaptureToken: controls.allowShiftClick.configValue,
            clickToMove: controls.clickToMove,
            allowMouseCapture: controls.allowMouseCapture,
            rightClickActionToken: controls.rightClickAction.rawValue,
            shiftArrowSelect: controls.shiftArrowSelect,
            scrollMultiplier: controls.scrollMultiplier,
            macosOptionAsAltToken: controls.optionAsAlt.configValue,
        )
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

/// The process-wide bridge carrying the current libghostty config STRING from ``PreferencesStore`` to the
/// (Xcode-app-target-only) `GhosttyTerminalView`, which re-applies it via `ghostty_config_load_string`
/// and re-measures + resizes the PTY grid.
///
/// A tiny `@Observable` holder (not the model) so the gated renderer can `@Observe` it without importing
/// the whole store; the HEADLESS build keeps a no-op consumer. The `generation` bumps on each publish so
/// an idempotent re-publish of the SAME string still triggers a reload (e.g. a ⌘± that lands back where
/// it started).
@preconcurrency
@MainActor
@Observable
public final class TerminalConfigBroadcaster {
    public static let shared = TerminalConfigBroadcaster()

    /// The current libghostty config string (built by ``TerminalConfigBuilder``). Empty until the first
    /// publish (the renderer then keeps libghostty's compiled-in defaults).
    public private(set) var configString = ""
    /// Monotonic publish counter — the renderer keys its "apply on change" off this, so re-publishing the
    /// same string still reloads.
    public private(set) var generation = 0

    public init() {}

    /// Publish a new config string (bumps ``generation`` even if unchanged).
    public func publish(_ config: String) {
        configString = config
        generation &+= 1
    }
}
