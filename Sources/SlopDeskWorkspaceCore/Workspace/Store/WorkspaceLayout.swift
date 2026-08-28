// MARK: - The one responsive switch (marshalling)

/// The single adaptation decision for the whole app (docs/22 §4): is the workspace being shown in a
/// **compact** projection (one leaf at a time, the phone carousel) or the **regular** projection (the
/// full recursive split tree)?
///
/// The rule is `slopdesk_workspace::responsive` — including the two thresholds and the reason each
/// geometry is read against its own. What is here is the call.
import CoreGraphics
import CSlopDeskFFI

public enum WorkspaceLayout {
    /// Whether to use the compact projection.
    ///
    /// `horizontalSizeClassCompact` is the PRIMARY signal and short-circuits everything else; iOS
    /// decides on it alone and passes `windowWidth: nil`. macOS has no size class, so it passes the
    /// outer window's width, which is authoritative where the detail area's own reported width can be
    /// half-laid-out mid-resize — the reason the two geometries are read against different thresholds.
    ///
    /// ⚠️ NO PRODUCTION CALLER TODAY — only ``WorkspaceLayoutTests``. The one call was SwiftUI's, from a
    /// body that read `@Environment(\.horizontalSizeClass)` and a detail `GeometryReader`; both shells
    /// now pick their projection structurally instead (the Mac is `MacContentColumn`, the phone is its
    /// carousel), so nobody asks this question at runtime. The RULE still lives in Rust
    /// (`slopdesk_workspace::responsive`) and this is still its only Swift door, so deleting the door
    /// would strand the rule rather than retire it — decide the two together, not this one alone.
    public static func isCompact(
        horizontalSizeClassCompact: Bool,
        detailWidth: CGFloat,
        windowWidth: CGFloat?,
    ) -> Bool {
        slopdesk_ws_is_compact(
            horizontalSizeClassCompact,
            Double(detailWidth),
            Double(windowWidth ?? 0),
            windowWidth != nil,
        )
    }
}

// MARK: - Per-device live-video ceiling (marshalling)

/// The device class the live-video ceiling is keyed on (docs/22 §7). A video pane's stack
/// is 2 UDP sockets + a `VTDecompressionSession` + a `CVDisplayLink`; the safe concurrent count scales
/// with the host's decode/compositing headroom, which differs sharply between a phone, an iPad, and a
/// Mac. `Sendable` so it can cross into the (Sendable-`Int`) store init without ceremony.
public enum VideoDeviceClass: Sendable {
    case phone
    case pad
    case mac

    /// The case index `slopdesk_ws_video_*` speaks.
    var ffiByte: UInt8 {
        switch self {
        case .phone: 0
        case .pad: 1
        case .mac: 2
        }
    }

    /// The near-side case for a door's answer. An unrecognised byte reads as the phone tier, which is
    /// the conservative floor the crate answers with too.
    init(ffiByte: UInt8) {
        switch ffiByte {
        case 1: self = .pad
        case 2: self = .mac
        default: self = .phone
        }
    }
}

/// The per-device concurrent live-video ceiling (the number passed to ``WorkspaceStore/liveVideoCap``).
/// The tiers and the signals behind them live in `slopdesk_workspace::responsive`.
public enum VideoCapPolicy {
    /// The concurrent live-video ceiling for `deviceClass`.
    public static func cap(for deviceClass: VideoDeviceClass) -> Int {
        Int(slopdesk_ws_video_cap(deviceClass.ffiByte))
    }

    /// Resolves the ``VideoDeviceClass`` from the platform/idiom/size-class signals: `.mac` on macOS;
    /// else `.pad` only when it is a pad idiom AND not compact; else `.phone`.
    public static func deviceClass(
        isMac: Bool,
        horizontalSizeClassCompact: Bool,
        userInterfaceIdiomPad: Bool,
    ) -> VideoDeviceClass {
        VideoDeviceClass(ffiByte: slopdesk_ws_video_device_class(
            isMac,
            horizontalSizeClassCompact,
            userInterfaceIdiomPad,
        ))
    }

    /// The composed convenience: resolve the device class from the platform signals AND map it to the
    /// concurrent live-video ceiling in one call (the shape the view layer wants when it knows the size
    /// class, e.g. an iPad that has dropped to compact in slide-over should fall to the phone cap).
    public static func cap(
        isMac: Bool,
        horizontalSizeClassCompact: Bool,
        userInterfaceIdiomPad: Bool,
    ) -> Int {
        cap(for: deviceClass(
            isMac: isMac,
            horizontalSizeClassCompact: horizontalSizeClassCompact,
            userInterfaceIdiomPad: userInterfaceIdiomPad,
        ))
    }
}
