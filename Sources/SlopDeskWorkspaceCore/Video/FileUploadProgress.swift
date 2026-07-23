import Foundation

/// One drag-drop upload's progress, as the desktop pane renders it. A headless value type: the
/// app-layer coordinator (which owns the PATH-4 reliable-channel client) maps its wire events onto
/// this and hands it to ``RemoteWindowModel/upsertUpload(_:)``; the pane overlay reads the list.
public struct FileUploadProgress: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case sending
        case completed
        case failed
    }

    /// Stable per-file id (a fresh UUID per dropped file), so re-drops never collide and an update
    /// finds its row regardless of ordering.
    public let id: UUID
    public var name: String
    public var sentBytes: UInt64
    public var totalBytes: UInt64
    public var phase: Phase
    /// A short failure reason for the row (nil unless `phase == .failed`).
    public var reason: String?

    public init(
        id: UUID,
        name: String,
        sentBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        phase: Phase = .sending,
        reason: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
        self.phase = phase
        self.reason = reason
    }

    /// Completion fraction in `0...1` for a progress bar. A finished upload reads full even when the
    /// size was unknown (0 bytes / never reported); an in-flight one with no known size reads empty.
    public var fraction: Double {
        if phase == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(sentBytes) / Double(totalBytes))
    }

    /// Whether the upload has settled (completed or failed) — the coordinator schedules its dismissal.
    public var isSettled: Bool { phase != .sending }
}
