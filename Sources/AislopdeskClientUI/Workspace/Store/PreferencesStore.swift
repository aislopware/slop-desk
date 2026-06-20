#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import Foundation
import Observation
import SwiftUI

// MARK: - PreferencesStore (the one live settings owner)

/// The single live source of truth for the GUI Settings system (W13). A `@MainActor @Observable`
/// store that owns the four W12 `Codable` models — ``VideoPreferences``, ``TerminalPreferences``,
/// ``AgentPreferences``, ``KeybindingPreferences`` — and persists each to `UserDefaults` (the
/// `@AppStorage`-style bridge for client/terminal prefs) PLUS the `video-prefs.json` sidecar (the
/// daemon-at-launch bridge for the video/agent host flags).
///
/// FOUR apply paths (decision #6 / #10):
///   1. **Live client/agent prefs → ``EnvConfig/overlay``.** `sharpen` and the agent gates that the
///      CLIENT process reads are folded into the process-wide overlay so a live setting overrides the
///      compile-time default WITHOUT an env var.
///   2. **Video prefs → the `video-prefs.json` SIDECAR (no live apply).** The ~80 video flags are read
///      at `static let` init and CANNOT live-reload, so a change is written to the sidecar the HOST
///      daemon reads at next launch — the UI marks these **"applies on reconnect."**
///   3. **Terminal prefs → the live terminal reload.** A change rebuilds the libghostty config string
///      (``TerminalConfigBuilder``) and bumps ``TerminalConfigBroadcaster`` so the (Xcode-app-target-
///      only) `GhosttyTerminalView` re-applies it via `ghostty_config_load_string` + a PTY grid resize.
///   4. **Keybinding prefs → the W6 registry overrides.** The store publishes the current
///      ``KeybindingPreferences`` to ``WorkspaceBindingRegistry`` (via
///      ``WorkspaceBindingRegistry/activeOverrides``) so a chord resolves with the user override when one
///      is present — the registry stays the single binding TABLE; this only supplies the overrides.
///
/// BEHAVIOR-PRESERVATION: a fresh install (no persisted prefs) loads the model DEFAULTS — for video /
/// agent that is the all-`nil` model ⇒ an EMPTY ``EnvConfig`` overlay ⇒ no sidecar override ⇒
/// byte-identical to today (the golden corpus is unaffected). Terminal prefs DO have real defaults
/// (they are render prefs), but the libghostty apply is compile-only and the headless build / golden
/// never sees it.
@preconcurrency
@MainActor
@Observable
public final class PreferencesStore {
    // MARK: Persisted models (the live source the UI binds)

    /// Live, client-side terminal-render prefs (font / theme / cursor / scrollback). A `didSet` reloads.
    public var terminal: TerminalPreferences {
        didSet { if terminal != oldValue { persistTerminal()
            applyTerminal()
        } }
    }

    /// The video / FEC / pacer / capture host flags. A `didSet` writes the sidecar + folds the
    /// client-readable subset into the overlay. "Applies on reconnect" for the host-read flags.
    public var video: VideoPreferences {
        didSet { if video != oldValue { persistVideo()
            applyVideoAndAgent()
        } }
    }

    /// Agent (Claude) detection gates (foreground watch / hooks). A `didSet` writes the sidecar.
    public var agent: AgentPreferences {
        didSet { if agent != oldValue { persistAgent()
            applyVideoAndAgent()
        } }
    }

    /// User keybinding overrides (`bindingID → chord`). A `didSet` republishes them to the W6 registry.
    public var keybindings: KeybindingPreferences {
        didSet { if keybindings != oldValue { persistKeybindings()
            applyKeybindings()
        } }
    }

    /// Raw `AISLOPDESK_*` overrides for power users (the Advanced panel). A sparse `[key: value]` that is
    /// folded LAST into the ``EnvConfig`` overlay so an explicit raw override wins over the typed prefs.
    /// Persisted separately; an empty map (the default) contributes nothing (behavior-preserving).
    public var rawOverrides: [String: String] {
        didSet { if rawOverrides != oldValue { persistRawOverrides()
            applyVideoAndAgent()
        } }
    }

    // MARK: Dependencies (injectable for tests)

    private let defaults: UserDefaults
    private let sidecarURL: URL?

    // MARK: UserDefaults keys

    enum Key {
        static let terminal = "settings.terminal.v1"
        static let video = "settings.video.v1"
        static let agent = "settings.agent.v1"
        static let keybindings = "settings.keybindings.v1"
        static let rawOverrides = "settings.rawOverrides.v1"
    }

    // MARK: Init / load

    /// Loads the persisted prefs (or the model defaults on a fresh install) and applies them. The
    /// `sidecarURL` defaults to the shared `video-prefs.json` location; tests inject a temp URL (or
    /// `nil` to skip the sidecar write). `applyOnInit` runs the apply paths once after load (default
    /// ON; a test that only wants round-trip can pass `false` to avoid mutating the process overlay).
    public init(
        defaults: UserDefaults = .standard,
        sidecarURL: URL? = EnvBridge.defaultSidecarURL(),
        applyOnInit: Bool = true,
    ) {
        self.defaults = defaults
        self.sidecarURL = sidecarURL
        terminal = Self.decode(TerminalPreferences.self, defaults, Key.terminal) ?? TerminalPreferences()
        video = Self.decode(VideoPreferences.self, defaults, Key.video) ?? VideoPreferences()
        agent = Self.decode(AgentPreferences.self, defaults, Key.agent) ?? AgentPreferences()
        keybindings = Self.decode(KeybindingPreferences.self, defaults, Key.keybindings) ?? KeybindingPreferences()
        rawOverrides = (defaults.dictionary(forKey: Key.rawOverrides) as? [String: String]) ?? [:]
        if applyOnInit {
            applyTerminal()
            applyVideoAndAgent()
            applyKeybindings()
        }
    }

    // MARK: Persist (model → UserDefaults)

    private func persistTerminal() { Self.encode(terminal, defaults, Key.terminal) }
    private func persistVideo() { Self.encode(video, defaults, Key.video) }
    private func persistAgent() { Self.encode(agent, defaults, Key.agent) }
    private func persistKeybindings() { Self.encode(keybindings, defaults, Key.keybindings) }
    private func persistRawOverrides() { defaults.set(rawOverrides, forKey: Key.rawOverrides) }

    private static func encode(_ value: some Encodable, _ defaults: UserDefaults, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Apply paths

    /// Rebuild the libghostty config string from the live terminal prefs (+ any terminal keybind lines)
    /// and bump the broadcaster so the (Xcode-only) `GhosttyTerminalView` re-applies it live.
    private func applyTerminal() {
        let config = TerminalConfigBuilder.string(for: terminal)
        TerminalConfigBroadcaster.shared.publish(config)
    }

    /// Fold the video + agent prefs (and the raw overrides) into the process-wide ``EnvConfig`` overlay
    /// for the CLIENT-readable flags, and write the `video-prefs.json` SIDECAR for the host daemon.
    ///
    /// WITHIN the overlay, precedence is typed-prefs (video ∪ agent) THEN the raw power-user overrides on
    /// top, so an explicit `AISLOPDESK_*` typed by hand in the Settings raw-overrides box wins over the
    /// matching toggle. ACROSS tiers, a real `ProcessInfo` env var STILL wins over the whole overlay
    /// (decision #16, `env → overlay → default`): ``EnvConfig/string(_:)`` checks the real env var FIRST
    /// and only falls back to the overlay, so a deliberate `launchctl`/`--args` env on the CLIENT is never
    /// clobbered by a persisted setting — consistent with the host sidecar's gap-fill.
    private func applyVideoAndAgent() {
        var overlay = EnvBridge.toEnv(video).merging(EnvBridge.toEnv(agent)) { _, new in new }
        for (key, value) in rawOverrides where !key.isEmpty { overlay[key] = value }
        EnvConfig.overlay = overlay
        writeSidecar()
    }

    /// Serialise the video + agent prefs to the `video-prefs.json` sidecar the HOST daemon reads at
    /// launch. A nil `sidecarURL` (tests) skips the write. Failure is swallowed — a prefs write that
    /// can't reach disk must not crash the UI (the typed defaults still hold).
    private func writeSidecar() {
        guard let url = sidecarURL else { return }
        let sidecar = EnvBridge.VideoSidecar(video: video, agent: agent)
        try? EnvBridge.writeSidecar(sidecar, to: url)
    }

    /// Publish the live keybinding overrides to the W6 registry so a chord resolves with the user
    /// override when present (the registry stays the single binding TABLE; this supplies the overrides).
    private func applyKeybindings() {
        WorkspaceBindingRegistry.activeOverrides = keybindings
    }

    // MARK: Convenience for the UI

    /// Reset EVERY pref to its model default (the "Restore Defaults" affordance). The `didSet`s persist
    /// + re-apply each, so the process returns to behavior-preserving defaults (empty overlay, no
    /// sidecar override) exactly as a fresh install.
    public func resetAll() {
        terminal = TerminalPreferences()
        video = VideoPreferences()
        agent = AgentPreferences()
        keybindings = KeybindingPreferences()
        rawOverrides = [:]
    }

    /// The keybinding conflicts the UI highlights — DISTINCT ids resolving to the same chord (W12
    /// ``KeybindingPreferences/conflicts()``). Only explicit overrides collide here; the registry
    /// defaults are conflict-free by construction (pinned by `TreeCommandRoutingTests`).
    public func keybindingConflicts() -> [String: [String]] { keybindings.conflicts() }
}

// MARK: - TerminalConfigBroadcaster (the live terminal-reload seam)

/// The process-wide bridge that carries the current libghostty config STRING from the
/// ``PreferencesStore`` to the (Xcode-app-target-only) `GhosttyTerminalView`, which re-applies it via
/// `ghostty_config_load_string` and re-measures + resizes the PTY grid.
///
/// It is a tiny `@Observable` holder (not the model) so the gated renderer can `@Observe` it without
/// importing the whole store, and the HEADLESS build keeps a no-op consumer (the placeholder ignores
/// it). The `generation` bumps on each publish so an idempotent re-publish of the SAME string still
/// triggers a reload (e.g. the user toggles a value back and forth).
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
#endif
