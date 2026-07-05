#if os(macOS)
import CoreGraphics
import Foundation

// C6 BUG C (2026-07-03): a daemon crash / SIGKILL used to leave VD-parked windows stranded — the
// clean-shutdown drain restores them, but nothing recovered after an unclean exit (the "next-launch
// hygiene" the shutdown comment promised did not exist). The fix: ``WindowParkingManager`` persists
// the parked set to this JSON sidecar on every park/unpark, and the next `slopdesk-videohostd`
// launch reads any leftover file, AX-restores the windows that are STILL stranded (validated by
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
    /// `<AppSupport>/SlopDesk/parked-windows.json` (beside `EnvBridge`'s `video-prefs.json`).
    /// `nil` only if the OS won't vend an Application-Support URL (never on macOS).
    public static func defaultSidecarURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("parked-windows.json", isDirectory: false)
    }
}

/// The PURE "should launch hygiene move this window" predicate. Restore ONLY a window that is
/// still demonstrably stranded: not already (near) its recorded original frame, AND intersecting
/// NO current display (it still sits in the dead VD's off-screen region). A window visible on any
/// real display was re-homed by WindowServer or moved by the user since the crash — moving it now
/// would yank it out from under them. An EMPTY display list (CG enumeration failure) fails SOFT:
/// never move a window on uncertainty.
public enum StrandedWindowRestorePolicy {
    /// `tolerance` absorbs sub-point AX/rounding drift when comparing against the original origin.
    public static func shouldRestore(
        currentFrame: CGRect,
        originalFrame: CGRect,
        displayBounds: [CGRect],
        tolerance: CGFloat = 2.0,
    ) -> Bool {
        // Already home (within drift) — nothing to fix.
        if abs(currentFrame.minX - originalFrame.minX) <= tolerance,
           abs(currentFrame.minY - originalFrame.minY) <= tolerance
        {
            return false
        }
        // No display info → fail soft.
        guard !displayBounds.isEmpty else { return false }
        // Stranded ⇔ reachable on no current display.
        return !displayBounds.contains { $0.intersects(currentFrame) }
    }
}
#endif
