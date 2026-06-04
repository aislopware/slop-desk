import Foundation

/// The `RWORK_VIDEO_STATICIDR` env-gate for the static-window forced-IDR heartbeat
/// (VIDEO-HOST-1). Default OFF.
///
/// ## Why this gate exists
/// SCStream delivers only `.idle` status frames (no new IOSurface) for a completely
/// static window (WWDC22 s10156; Apple docs `SCFrameStatus.idle`). In `WindowCapturer`
/// the `guard status == .complete` early-return means the forced-keyframe latch AND the
/// ~1s heartbeat IDR — both below that guard — never run on a static window, so a client
/// that joins or requests loss-recovery while the host window is unchanging freezes on
/// the last good frame. The fix (gated ON) retains the last `.complete` pixel buffer and,
/// on a timer serialized on the capture `frameQueue`, re-encodes it as a forced IDR.
///
/// ## OFF is byte-identical
/// An UNSET (or non-truthy) `RWORK_VIDEO_STATICIDR` returns `false`. The OFF path never
/// starts the timer, never copies a buffer, and never branches on it on the hot path —
/// `WindowCapturer` executes the exact `.complete`/`.idle` callback that ships today. The
/// gate is read ONCE at the `WindowCapturer` construction site and stored as a `let`.
public enum StaticIDRGate {
    /// The `RWORK_VIDEO_STATICIDR` gate value from `env` (ON iff `"1"`/`"true"`/`"yes"`/`"on"`,
    /// case-insensitive). Default OFF. Same truthiness vocabulary as ``VideoMuxGate``.
    public static func enabledFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env["RWORK_VIDEO_STATICIDR"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }
}
