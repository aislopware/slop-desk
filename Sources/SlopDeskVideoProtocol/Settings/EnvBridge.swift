import Foundation

/// The bridge between the settings MODELS and the `SLOPDESK_*` flags they override (W12).
///
/// Two directions, both pure:
///  1. ``toEnv()`` — a settings model → its `[String: String]` env-overlay (keyed 1:1 to `SLOPDESK_*`),
///     ready to fold into ``EnvConfig/overlay``. An UNSET field emits NO entry, so a default-constructed
///     model yields an EMPTY overlay ⇒ byte-identical to today's compile-time defaults (W12 invariant).
///  2. The `video-prefs.json` SIDECAR — host-daemon prefs (video + agent) serialised to a file the
///     daemon reads at launch (``loadSidecar(at:into:)``) and folds into ``EnvConfig/overlay`` BEFORE any
///     consumer's `static let` is forced (decision #10: no live reload — "applies on reconnect").
///
/// SYMMETRIC keys (``symmetricKeys``) must be set IDENTICALLY on host AND client (`SLOPDESK_FEC_M` /
/// `_FEC_K`, the mux window) or the two ends disagree — the UI surfaces a "set on both ends" warning.
public enum EnvBridge {
    /// Keys that MUST match on host and client (CLAUDE.md "set identically on host and client"). The
    /// Settings UI flags these "set on both ends."
    public static let symmetricKeys: Set<String> = [
        "SLOPDESK_FEC_M", "SLOPDESK_FEC_K", "SLOPDESK_MUX_WINDOW",
    ]

    // MARK: VideoPreferences → env

    /// Map a ``VideoPreferences`` to its `SLOPDESK_*` overlay. Booleans use the SAME literal a user
    /// would type at the read site so the polarity is preserved exactly:
    ///   • `virtualDisplay` → `SLOPDESK_VD` (`!= "0"` default-ON): emit `"0"` only when OFF.
    ///   • `qpDecouple`     → `SLOPDESK_QP_DECOUPLE`: this site is default-ON (`!= "0"`) too.
    /// An UNSET (`nil`) field emits nothing.
    public static func toEnv(_ prefs: VideoPreferences) -> [String: String] {
        var env: [String: String] = [:]
        if let v = prefs.qpSharp { env["SLOPDESK_QP_SHARP"] = String(v) }
        if let v = prefs.qpCoarse { env["SLOPDESK_QP_COARSE"] = String(v) }
        if let v = prefs.qpDecouple { env["SLOPDESK_QP_DECOUPLE"] = v ? "1" : "0" }
        if let v = prefs.fecM { env["SLOPDESK_FEC_M"] = String(v) }
        if let v = prefs.fecK { env["SLOPDESK_FEC_K"] = String(v) }
        if let v = prefs.pacer { env["SLOPDESK_PACER"] = v.rawValue }
        if let v = prefs.playoutMs { env["SLOPDESK_PLAYOUT_MS"] = formatDouble(v) }
        if let v = prefs.captureScale { env["SLOPDESK_CAPTURE_SCALE"] = formatDouble(v) }
        if let v = prefs.displayCapture { env["SLOPDESK_DISPLAY_CAPTURE"] = v.rawValue }
        if let v = prefs.virtualDisplay { env["SLOPDESK_VD"] = v ? "1" : "0" }
        if let v = prefs.sharpen { env["SLOPDESK_SHARPEN"] = formatDouble(v) }
        return env
    }

    // MARK: AgentPreferences → env

    /// Map an ``AgentPreferences`` to its `SLOPDESK_*` overlay. An explicit ON writes `"1"`, an explicit
    /// OFF writes `"0"`; an unset (`nil`) field emits nothing. The host READ idiom differs per gate
    /// (`agentDetect`/`resumeOnRecovery` are default-ON `!= "0"`; `agentHooks`/`preventSleep` are default-OFF
    /// `== "1"`), but the WRITE is symmetric — a present field always pins the exact `"1"`/`"0"` the read site
    /// resolves, so the polarity is preserved on both ends.
    public static func toEnv(_ prefs: AgentPreferences) -> [String: String] {
        var env: [String: String] = [:]
        if let v = prefs.agentDetect { env["SLOPDESK_AGENT_DETECT"] = v ? "1" : "0" }
        if let v = prefs.agentHooks { env["SLOPDESK_AGENT_HOOKS"] = v ? "1" : "0" }
        if let v = prefs.preventSleep { env["SLOPDESK_AGENT_PREVENT_SLEEP"] = v ? "1" : "0" }
        if let v = prefs.resumeOnRecovery { env["SLOPDESK_AGENT_RESUME_ON_RECOVERY"] = v ? "1" : "0" }
        return env
    }

    /// Format a `Double` env value without a spurious exponent / trailing noise. Integral values print
    /// without a decimal point (`60.0` → `"60"`), matching what a user types and what `Double(_:)` /
    /// `Int(_:)` parse back at the read site.
    static func formatDouble(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e15 {
            return String(Int(v))
        }
        return String(v)
    }

    // MARK: video-prefs.json sidecar (host daemon)

    /// What the host daemon serialises to / reads from `video-prefs.json`: the launch-time prefs
    /// (video + agent) the daemon cannot live-reload. Versioned for forward tolerance.
    public struct VideoSidecar: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var video: VideoPreferences
        public var agent: AgentPreferences
        /// The free-text `SLOPDESK_*` overrides a user types in the Settings "Raw overrides" box. These
        /// reach the HOST daemon through the sidecar (not only the client's in-process ``EnvConfig/overlay``),
        /// so a HOST-only knob typed here actually lands. They fold LAST — a raw override beats the typed
        /// video/agent field for the SAME key (last-wins), mirroring ``PreferencesStore``'s live overlay.
        public var rawOverrides: [String: String]

        public init(
            video: VideoPreferences = .init(), agent: AgentPreferences = .init(),
            rawOverrides: [String: String] = [:], schemaVersion: Int = 1,
        ) {
            self.schemaVersion = schemaVersion
            self.video = video
            self.agent = agent
            self.rawOverrides = rawOverrides
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case video
            case agent
            case rawOverrides
        }

        /// Decode with `rawOverrides` OPTIONAL so a stale sidecar written before the field existed still
        /// loads (→ empty) instead of decode-failing the whole file ([[rwork-no-backcompat]]: new optional
        /// field, no migration). The other fields stay required (a truly corrupt file drops via `readSidecar`).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            video = try c.decode(VideoPreferences.self, forKey: .video)
            agent = try c.decode(AgentPreferences.self, forKey: .agent)
            rawOverrides = try c.decodeIfPresent([String: String].self, forKey: .rawOverrides) ?? [:]
        }

        /// The combined `SLOPDESK_*` overlay this sidecar contributes (video ∪ agent ∪ raw overrides,
        /// raw LAST-WINS over the typed fields for a shared key).
        public func toEnv() -> [String: String] {
            var env = EnvBridge.toEnv(video).merging(EnvBridge.toEnv(agent)) { _, new in new }
            for (key, value) in rawOverrides where !key.isEmpty { env[key] = value }
            return env
        }
    }

    /// The default sidecar location under Application Support: `<AppSupport>/SlopDesk/video-prefs.json`.
    /// `nil` only if the OS won't vend an Application-Support URL (never on macOS).
    public static func defaultSidecarURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("video-prefs.json", isDirectory: false)
    }

    /// Serialise the sidecar to `url` (creating the parent dir). Pretty-printed, stable key order.
    public static func writeSidecar(_ sidecar: VideoSidecar, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    /// Decode the sidecar at `url`. Returns `nil` (validate-then-drop) when the file is missing or the
    /// JSON is malformed — a corrupt prefs file MUST NOT brick the daemon; it falls back to env/defaults.
    public static func readSidecar(at url: URL) -> VideoSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VideoSidecar.self, from: data)
    }

    /// Daemon launch hook: read the sidecar (if present + valid) and fold its overlay into
    /// `EnvConfig.overlay`, WITHOUT clobbering an entry already there (a real `SLOPDESK_*` env var,
    /// or an earlier overlay write, wins — the sidecar only fills gaps so a deliberate env override is
    /// honoured). Returns the keys it actually applied (for a launch-time debug line). Call this in
    /// `main()` BEFORE the video pipeline / any consumer `static let` is touched.
    @discardableResult
    public static func loadSidecar(at url: URL, into overlay: inout [String: String]) -> [String] {
        guard let sidecar = readSidecar(at: url) else { return [] }
        let env = ProcessInfo.processInfo.environment
        var applied: [String] = []
        for (key, value) in sidecar.toEnv() {
            // A real env var, or an existing overlay entry, always wins over the sidecar.
            if env[key] != nil || overlay[key] != nil { continue }
            overlay[key] = value
            applied.append(key)
        }
        return applied
    }

    /// Convenience: fold the default-location sidecar into the process-wide ``EnvConfig/overlay``.
    /// The one-liner a daemon `main()` calls.
    @discardableResult
    public static func loadDefaultSidecarIntoEnvConfig(fileManager: FileManager = .default) -> [String] {
        guard let url = defaultSidecarURL(fileManager: fileManager) else { return [] }
        return loadSidecar(at: url, into: &EnvConfig.overlay)
    }
}
