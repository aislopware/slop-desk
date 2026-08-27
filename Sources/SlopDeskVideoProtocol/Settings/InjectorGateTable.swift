#if os(macOS)
import CSlopDeskFFI
import Foundation

/// The input injector's `SLOPDESK_*` operating point, resolved once through
/// `rust/slopdesk-ffi`'s `injector` handle.
///
/// ## What this is, and what it is not
///
/// It is the LOOKUP half, and nothing else. The keys come from the same handle that reads their
/// values, the values are resolved through ``EnvConfig/string(_:)`` — env, then the settings
/// overlay (`docs/58`) — and the texts cross back as a blob. Every default, clamp and polarity is
/// on the far side, in `slopdesk_video::injector_gates` and `swipe_nav_config`, where a rule can
/// be tested. This is ``HostGateTable``'s sibling and holds the same line for the same reason.
///
/// ## macOS only, because the handle it feeds is
///
/// `slopdesk_injector_*` is behind the header's `MACOS-ONLY` markers — CoreGraphics event synthesis
/// and the accessibility tree, neither of which an iOS slice has. This lives in the protocol module
/// rather than the host one only because ``FECBlobList`` does, and it carries the same guard the
/// doors it calls do.
///
/// ## Why the texts are held rather than the resolved table
///
/// The injector is CONSTRUCTED per session and there may be two of them at once, so the operating
/// point is resolved by `slopdesk_injector_new` and lives inside the handle. What this type holds
/// is the list to hand it — read once, because the environment does not change under a running
/// process and the settings overlay is folded in before any of this is forced.
public enum InjectorGateTable {
    /// The blob to hand `slopdesk_injector_new`: one entry per key, in key order, ABSENT for a key
    /// nothing sets. Absent is not empty — two of these gates test presence, so `=0` turns them on.
    public static let values: [UInt8] = {
        let texts: [Data?] = keys.map { key in EnvConfig.string(key).map { Data($0.utf8) } }
        return FECBlobList.encode(texts)
    }()

    /// The scroll resampler's output rate, or `0` for the direct-post path.
    ///
    /// Read here rather than off an injector because the session's own gate table needs it BEFORE
    /// any injector exists: the scroll coalescer's default follows it, since the resampler already
    /// caps the post rate and stacking the 8 ms summing gate under it double-quantizes the stream
    /// into uneven chunks (HW: the 60–100 ms capture-stall bucket went 212 → 25 when the gate was
    /// lifted with the resampler on).
    public static let resampleHz: Int64 = values.withUnsafeBufferPointer {
        slopdesk_injector_resample_hz($0.baseAddress, $0.count)
    }

    /// Whether the resampler drives injection at all.
    public static var resamplerActive: Bool { resampleHz > 0 }

    /// The environment key names, in the order the values must be handed back.
    private static let keys: [String] = {
        let needed = Int(slopdesk_injector_gate_keys(nil, 0))
        guard needed > 0 else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            Int(slopdesk_injector_gate_keys($0.baseAddress, $0.count))
        }
        guard written == needed, let text = String(bytes: blob, encoding: .utf8) else { return [] }
        return text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }()
}
#endif
