import Foundation
import SlopDeskWorkspaceModel

// MARK: - DevicePreferences (the facts that belong to THIS device, not to the workspace)

/// The device-local half of the client's persisted state (docs/45 §7.3): everything the workspace
/// document deliberately does not carry, because it describes THIS machine rather than THE LAYOUT.
///
/// The layout is host-owned and identical on every attached client. These five are not: a 27″ Studio
/// and an iPhone must not share an immersive-mode latch, "which host am I talking to" is definitionally
/// a client concept, and the preset library is a per-device convenience. They live here, in
/// `<Application Support>/SlopDesk/device-prefs.json`, so a projected tree can never regenerate them
/// away.
///
/// ### Decode-failure rule
/// A corrupt or stale file becomes a FRESH default — it is never migrated (the no-backcompat directive).
/// The `Codable` conformance is synthesized, so a file written by a build with a different field set
/// fails to decode and the whole value resets. That is the intended behaviour: a preset library is
/// re-creatable, a half-migrated one is a bug with no failing test.
public struct DevicePreferences: Codable, Sendable, Equatable {
    /// Whether this device follows the host's session focus (docs/45 §8.2): ON for macOS, OFF for iOS.
    /// A phone attaches to LOOK at one session; a desktop attaches to WORK, and expects the host's
    /// focus to lead. Resolved at compile time — there is no runtime platform check.
    public static var platformDefaultFollowSessionFocus: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    /// The identity a connection target is filed under: `"host:port"`.
    ///
    /// This is the ONLY host identity known BEFORE connecting. The document's `root/hostDisplayName`
    /// arrives WITH the snapshot, so it cannot gate a read that happens on the way to the connect gate,
    /// and `host:port` is already what ``AppConnection/recentTargets`` dedupes on — the two MRUs
    /// therefore agree on what "the same host" means.
    public static func hostKey(for target: ConnectionTarget) -> String {
        "\(target.host):\(target.port)"
    }

    /// Named launch configurations — a title + a command that spawn a terminal pane running it.
    /// Seeded with ``LaunchPreset/builtIns`` on a fresh device.
    public var launchPresets: [LaunchPreset]
    /// Named session templates / project profiles — a layout + per-pane cwd/command that spawn a whole
    /// named session. Seeded with ``SessionTemplate/builtIns`` on a fresh device.
    public var sessionTemplates: [SessionTemplate]
    /// The latched video-pane modes (immersive / audio / viewport lock / stream overrides), keyed by the
    /// stream TARGET (``VideoEndpoint/modesKey`` — a display, or a window's owning app) and NOT by pane.
    /// Keying by target is what lets a latch survive close-tab → reopen (the reopened target mints a
    /// brand-new ``PaneID``/spec) as well as a relaunch.
    public var videoModesByTarget: [String: VideoPaneModes]
    /// The last committed ``ConnectionTarget`` per host, keyed by ``hostKey(for:)``. The connect gate's
    /// per-host port memory, read back by ``connectionTarget(seededBy:)``: re-dialling a known host
    /// restores the video ports it was reached on.
    public var connectionByHostKey: [String: ConnectionTarget]
    /// Whether the client's selection follows the host's session focus. Defaults per platform — see
    /// ``platformDefaultFollowSessionFocus``.
    public var followSessionFocus: Bool

    public init(
        launchPresets: [LaunchPreset] = LaunchPreset.builtIns,
        sessionTemplates: [SessionTemplate] = SessionTemplate.builtIns,
        videoModesByTarget: [String: VideoPaneModes] = [:],
        connectionByHostKey: [String: ConnectionTarget] = [:],
        followSessionFocus: Bool = Self.platformDefaultFollowSessionFocus,
    ) {
        self.launchPresets = launchPresets
        self.sessionTemplates = sessionTemplates
        self.videoModesByTarget = videoModesByTarget
        self.connectionByHostKey = connectionByHostKey
        self.followSessionFocus = followSessionFocus
    }

    /// The target the connect gate prefills, given the host `seed` names.
    ///
    /// ``AppConnection/launchSeedTarget()`` remembers the TERMINAL address and nothing else, so
    /// re-dialling a host reached on non-default video ports would silently offer the defaults for
    /// them. This is what closes that: the whole target, filed under the same `host:port` the MRU
    /// dedupes on. An unknown host answers `seed` unchanged.
    public func connectionTarget(seededBy seed: ConnectionTarget) -> ConnectionTarget {
        connectionByHostKey[Self.hostKey(for: seed)] ?? seed
    }
}

// MARK: - DevicePreferencesStore (the value ↔ disk seam)

/// Loads + saves ``DevicePreferences`` at `<Application Support>/SlopDesk/device-prefs.json`.
///
/// Injectable exactly like ``WorkspacePersistence``: a `nil` store never touches disk, which is what the
/// unit-test seam and the automation path need (a throwaway shape must not clobber the real file). IO-thin
/// — the only stored properties are a `URL` and a thread-safe `FileManager`, so a value crosses actor
/// boundaries safely.
public struct DevicePreferencesStore: @unchecked Sendable {
    /// Cap on any loaded collection. A file claiming ten thousand presets is corrupt, not ambitious;
    /// the whole value resets rather than being allocated. Mirrors ``WorkspacePersistence/maxItems``.
    public static let maxItems = 1024

    /// The file preferences are read from / written to.
    public let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)``.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(using: fileManager)
    }

    /// `<Application Support>/SlopDesk/device-prefs.json` — sibling of the workspace cache. Falls back to
    /// a temporary directory when Application Support can't resolve (sandboxed edge cases); the data is
    /// non-critical, a fresh default is always recoverable.
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("device-prefs.json", isDirectory: false)
    }

    /// Reads + decodes. Never throws — launch must always get a usable value:
    /// - missing file → a fresh ``DevicePreferences`` (first launch on this device)
    /// - corrupt / stale / over-`maxItems` → a fresh ``DevicePreferences`` (NO migration)
    public func load() -> DevicePreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DevicePreferences.self, from: data),
              decoded.launchPresets.count <= Self.maxItems,
              decoded.sessionTemplates.count <= Self.maxItems,
              decoded.videoModesByTarget.count <= Self.maxItems,
              decoded.connectionByHostKey.count <= Self.maxItems
        else {
            return DevicePreferences()
        }
        return decoded
    }

    /// Encodes `preferences` and writes it atomically, creating the parent dir if needed. Throws on
    /// IO/encode failure — callers are best-effort, and a failed write just keeps the previous good file.
    public func save(_ preferences: DevicePreferences) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try SidecarJSON.encoder().encode(preferences).write(to: fileURL, options: [.atomic])
    }
}
