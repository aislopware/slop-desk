import CSlopDeskFFI
import Foundation

/// The capture path's whole `SLOPDESK_*` operating point, resolved once through
/// `rust/slopdesk-video`'s `capture_gates`.
///
/// ## What moved, and what did not
///
/// `WindowCapturer` used to hold twenty-eight `static let`s, each hand-writing its own environment
/// read, its own parse, its own clamp and its own default. The DEFAULTS and the CLAMPS are rules,
/// so they are Rust's now; the prose recording the hardware measurement behind each one stays
/// exactly where it was, beside the field that acts on it. So do the three CONJUNCTIONS — the
/// pacer and freshest-wins need the decoupled encode queue, idle-skip needs the adaptive-QP
/// measurement it reuses — each of which used to be a sentence inside the static that implemented
/// it, where nothing could check it.
///
/// ## Why this port is not just tidier
///
/// Twenty-five of those statics read `ProcessInfo.processInfo.environment` DIRECTLY rather than
/// through ``EnvConfig``, so the settings overlay never reached them: with no settings GUI
/// (`docs/58`), they were knobs only an exported shell variable could move, and a `video-prefs.json`
/// entry for any of them did nothing at all. Every one of the twenty-eight now goes through
/// ``EnvConfig/string(_:)`` — env, then overlay — and the family cannot drift back out, because the
/// caller can only resolve the keys the far side names.
///
/// ## Order
///
/// The key list comes from the same table that reads the values, so the two cannot disagree about
/// what position a key occupies. An unset key crosses as an ABSENT blob rather than an empty one:
/// `SLOPDESK_VIDEO_DEBUG` tests PRESENCE, so `=0` turns it ON, and absent and empty are opposite
/// answers for it.
public enum CaptureGateTable {
    /// Resolves the capture operating point.
    ///
    /// - Parameters:
    ///   - maxAllowedFrameQP: the encoder's own static drop-avoidance ceiling — the default the
    ///     adaptive motion cap falls back to when its key says nothing usable.
    ///   - encodeEWMAAlpha: the encode-load pacer's EWMA weight, which is the pacer's own constant
    ///     rather than anything this table reads.
    public static func resolve(
        maxAllowedFrameQP: Int32,
        encodeEWMAAlpha: Double,
    ) -> SlopDeskVideoCaptureGates {
        let values: [Data?] = keys.map { key in EnvConfig.string(key).map { Data($0.utf8) } }
        let blob = FECBlobList.encode(values)
        var gates = SlopDeskVideoCaptureGates()
        let resolved = blob.withUnsafeBufferPointer { bytes in
            slopdesk_video_capture_gates(
                bytes.baseAddress, bytes.count, maxAllowedFrameQP, encodeEWMAAlpha, &gates,
            )
        }
        // The only input is a list this file built from a list the same crate handed it, so a
        // refusal means the two sides no longer agree about the shape — a state the capturer must
        // not come up in, because the answer it would come up with is every gate off.
        precondition(resolved, "the capture gate table refused a list it dictated the shape of")
        return gates
    }

    /// The environment key names, in the order the values must be handed back.
    ///
    /// Read once, for the reason its sibling gives: one call is one place the split can be wrong,
    /// rather than twenty-eight.
    private static let keys: [String] = {
        let needed = Int(slopdesk_video_capture_gate_keys(nil, 0))
        guard needed > 0 else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            Int(slopdesk_video_capture_gate_keys($0.baseAddress, $0.count))
        }
        guard written == needed, let text = String(bytes: blob, encoding: .utf8) else { return [] }
        return text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }()
}
