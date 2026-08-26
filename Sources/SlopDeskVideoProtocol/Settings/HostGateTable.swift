import CSlopDeskFFI
import Foundation

/// The video host's whole `SLOPDESK_*` operating point, resolved once through
/// `rust/slopdesk-video`'s `host_gates`.
///
/// ## What moved, and what did not
///
/// The host used to hold thirty-three `private static let`s, each hand-writing its own
/// `ProcessInfo` read, its own parse, its own clamp and its own default. The DEFAULTS and the
/// CLAMPS are rules, so they are Rust's now; the four hundred lines of prose recording the
/// measurement behind each one stay exactly where they were, beside the field that acts on it.
///
/// ## Why the lookup stays here
///
/// The far side is handed the resolved TEXTS, never asked to read the environment itself. The
/// env → settings-overlay precedence (``EnvConfig/string(_:)``, `docs/58`) is a property of this
/// process — the host folds `video-prefs.json` into ``EnvConfig/overlay`` at launch, before any
/// consumer's `static let` is forced — and a `std::env::var` on the other side would quietly stop
/// honouring a setting the day one of these keys became user-facing. It is also a strict
/// improvement on what it replaces: those thirty-three statics read `ProcessInfo` DIRECTLY, so the
/// overlay could never have reached them at all.
///
/// ## Order
///
/// The key list comes from the same table that reads the values, so the two cannot disagree about
/// what position a key occupies. An unset key crosses as an ABSENT blob rather than an empty one —
/// two of these gates test presence, so `=0` turns them ON, and one is overridden by the mere
/// presence of a sibling key.
public enum HostGateTable {
    /// Resolves the operating point.
    ///
    /// - Parameters:
    ///   - scrollResamplerActive: whether the input injector's scroll resampler is running — the
    ///     default the scroll coalescer follows while its own key is unset.
    ///   - keepaliveInterval: the floor a client-silence pause threshold is lifted to.
    ///   - idleTimeout: the (open) ceiling that threshold is held under.
    public static func resolve(
        scrollResamplerActive: Bool,
        keepaliveInterval: Double,
        idleTimeout: Double,
    ) -> SlopDeskVideoHostGates {
        let values: [Data?] = keys.map { key in EnvConfig.string(key).map { Data($0.utf8) } }
        let blob = FECBlobList.encode(values)
        var gates = SlopDeskVideoHostGates()
        let resolved = blob.withUnsafeBufferPointer { bytes in
            slopdesk_video_host_gates(
                bytes.baseAddress, bytes.count, scrollResamplerActive, keepaliveInterval,
                idleTimeout, &gates,
            )
        }
        // The only inputs are a list this file built from a list the same crate handed it, so a
        // refusal means the two sides no longer agree about the shape — a state the host must not
        // come up in, because the answer it would come up with is every gate off.
        precondition(resolved, "the host gate table refused a list it dictated the shape of")
        return gates
    }

    /// The environment key names, in the order the values must be handed back.
    ///
    /// Read once. A door per key would be the right rule at the wrong rate only in the other
    /// direction — this runs once per process — but one call is also one place the split can be
    /// wrong, rather than thirty-three.
    private static let keys: [String] = {
        let needed = Int(slopdesk_video_host_gate_keys(nil, 0))
        guard needed > 0 else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            Int(slopdesk_video_host_gate_keys($0.baseAddress, $0.count))
        }
        guard written == needed, let text = String(bytes: blob, encoding: .utf8) else { return [] }
        return text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }()
}
