import CAislopdeskFFI
import Foundation

/// Swift-side bridge from `AislopdeskVideoHost` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the host module is contained here; the host's policy types
/// call these typed wrappers so their public APIs stay unchanged. The realtime bitrate logic
/// lives in the Rust core (`aislopdesk-core`) and is exposed over the C-ABI boundary; golden
/// vectors assert byte-/bit-exact output, so the macOS/iOS host and a future Android client
/// drive the identical algorithm from one core. Env knobs stay resolved Swift-side and are
/// passed in, keeping the core env-free.
enum RustVideoHostFFI {
    /// Resolution-aware target bitrate (bits/sec). Wraps `aisd_live_bitrate_target`.
    static func liveBitrateTarget(
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Int,
        floor: Int,
        bitsPerPixel: Double,
    ) -> Int {
        Int(
            aisd_live_bitrate_target(
                Int64(pixelWidth), Int64(pixelHeight), Int64(fps), Int64(floor), bitsPerPixel,
            ),
        )
    }

    /// The absolute minimum live bitrate (bits/sec). Wraps `aisd_live_bitrate_minimum`.
    static func liveBitrateMinimum() -> Int {
        Int(aisd_live_bitrate_minimum())
    }
}
