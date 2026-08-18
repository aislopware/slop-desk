#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// A daemon crash / SIGKILL leaves VD-parked windows stranded: the clean-shutdown drain restores
// them, but nothing else recovers an unclean exit. ``WindowParkingManager`` persists the parked set
// to this JSON sidecar on every park/unpark, and the next `slopdesk-videohostd` launch reads any
// leftover file, AX-restores the windows that are STILL stranded (validated by
// ``StrandedWindowRestorePolicy`` — never yank a window the user/OS already re-homed), then deletes
// the file. The codec + predicate are PURE and headlessly unit-tested; the AX/CGWindowList reads
// stay thin in the daemon.

/// The schema-versioned on-disk snapshot of the parked-window set. No-backcompat discipline
/// ([[rwork-no-backcompat]]): a version mismatch or any decode failure yields `nil` — stale data
/// decode-fails to "nothing to restore", never migrates.
public struct WindowParkingSnapshot: Codable, Equatable, Sendable {
    /// Bump on ANY shape change; old files then decode to `nil` and are ignored.
    public static let currentSchemaVersion = 1

    /// One DISTINCT parked window (refcount is a live-only concern — a crash restore puts each
    /// window back exactly once). The frame is stored as explicit fields (not `CGRect`'s nested
    /// array coding) so the file stays human-greppable and stable.
    public struct Entry: Codable, Equatable, Sendable {
        public var windowID: UInt32
        public var pid: Int32
        public var originalX: Double
        public var originalY: Double
        public var originalWidth: Double
        public var originalHeight: Double

        public init(windowID: UInt32, pid: Int32, originalFrame: CGRect) {
            self.windowID = windowID
            self.pid = pid
            originalX = originalFrame.origin.x
            originalY = originalFrame.origin.y
            originalWidth = originalFrame.width
            originalHeight = originalFrame.height
        }

        /// The recorded pre-park global frame to restore to.
        public var originalFrame: CGRect {
            CGRect(x: originalX, y: originalY, width: originalWidth, height: originalHeight)
        }
    }

    public var schemaVersion: Int
    public var entries: [Entry]

    public init(entries: [Entry]) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }

    /// Stable-key JSON bytes, or `nil` on an encoder failure (never throws into the park path —
    /// persistence is best-effort).
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    /// Validate-then-drop decode: `nil` on malformed JSON OR a schema-version mismatch.
    public static func decoded(from data: Data) -> Self? {
        guard let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.schemaVersion == currentSchemaVersion
        else { return nil }
        return snapshot
    }

    /// The default sidecar location under Application Support:
    /// `<AppSupport>/SlopDesk/parked-windows.json` (beside `EnvBridge`'s `video-prefs.json`), moved
    /// wholesale by ``SlopDeskAppSupport/directoryEnvKey``.
    /// `nil` only if the OS won't vend an Application-Support URL (never on macOS).
    ///
    /// The override matters more here than for a prefs file, because this path is WRITTEN and
    /// DELETED: an automation daemon that resolves the real one reads the developer's crash journal
    /// at launch and AX-moves the windows it names, then unlinks the file the moment its own parked
    /// set goes empty.
    public static func defaultSidecarURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        SlopDeskAppSupport.directory(environment: environment, fileManager: fileManager)?
            .appendingPathComponent("parked-windows.json", isDirectory: false)
    }
}

/// The "should launch hygiene move this window" predicate, asked of `slopdesk_video::window_restore`
/// — which window a crashed daemon left stranded, and every reason not to touch one, live there.
/// What is here is the marshalling: a `[CGRect]` of display bounds becomes the flat run of doubles
/// the door reads.
public enum StrandedWindowRestorePolicy {
    public static func shouldRestore(
        currentFrame: CGRect,
        originalFrame: CGRect,
        displayBounds: [CGRect],
    ) -> Bool {
        // The door reads extents as given, so standardize here — the negative-size form is a
        // near-side representation, never a rule.
        var scalars = [Double]()
        scalars.reserveCapacity(displayBounds.count * 4)
        for bounds in displayBounds.map(\.standardized) {
            scalars.append(contentsOf: [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height])
        }
        let current = currentFrame.standardized
        let original = originalFrame.standardized
        return scalars.withUnsafeBufferPointer { displays in
            slopdesk_window_should_restore(
                current.origin.x, current.origin.y, current.width, current.height,
                original.origin.x, original.origin.y,
                displays.baseAddress, displayBounds.count,
            )
        }
    }
}
#endif
