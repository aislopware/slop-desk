import CoreGraphics

// MARK: - The one responsive switch (pure)

/// The single adaptation decision for the whole app (docs/22 §4): is the workspace being shown in a
/// **compact** projection (one leaf at a time, the phone carousel) or the **regular** projection (the
/// full recursive split tree)?
///
/// Pulled out of the view as a pure, synchronously-testable function so the breakpoint is pinned in
/// one place and unit-tested with zero SwiftUI. `WorkspaceRootView` computes it once from
/// `@Environment(\.horizontalSizeClass)` + the detail width and branches exactly once on the result.
public enum WorkspaceLayout {
    /// The width below which a regular layout collapses to compact when no size class is available
    /// (macOS has no `horizontalSizeClass`). This is a DETAIL-area width (the NavigationSplitView
    /// detail column), NOT the whole window: at the 720pt window floor the detail is ~500pt (720 minus
    /// the ~220 ideal sidebar), so the threshold sits a hair below that (460) — the macOS minimum
    /// window resolves REGULAR, and only a truly phone-narrow detail falls back to compact. On iOS the
    /// PRIMARY signal is `horizontalSizeClass` (the first term below), independent of this width gate.
    public static let compactWidthThreshold: CGFloat = 460

    /// The width below which a regular layout collapses to compact when the breakpoint is measured
    /// against the OUTER WINDOW rather than the detail column (the macOS path — ITEM #6). The whole
    /// window is the right signal there: the detail GeometryReader can transiently report a half-laid
    /// NavigationSplitView width during a resize, so keying on `view.window?.frame.width` is steadier.
    /// Set just below the 720pt macOS minimum-window floor (`minWidth: 720` in `WorkspaceRootView`) so
    /// the floor window resolves REGULAR and only a genuinely sub-floor window (a future
    /// smaller-min platform, or a transient pre-constraint frame) falls back to compact.
    public static let compactWindowWidthThreshold: CGFloat = 680

    /// Whether to use the compact projection.
    ///
    /// - Parameters:
    ///   - horizontalSizeClassCompact: `true` when `@Environment(\.horizontalSizeClass) == .compact`
    ///     (iPhone, iPad slide-over). On macOS — which has no size class — pass `false`; the width
    ///     fallback then decides.
    ///   - width: the available width of the detail area.
    /// - Returns: compact iff the size class is compact OR the width is below
    ///   ``compactWidthThreshold`` (docs/22 §4). The size class is the PRIMARY signal; the width is
    ///   the macOS / narrow-window fallback.
    public static func isCompact(horizontalSizeClassCompact: Bool, width: CGFloat) -> Bool {
        horizontalSizeClassCompact || width < compactWidthThreshold
    }

    /// The OUTER-WINDOW-aware overload (ITEM #6): resolve the breakpoint against the whole window's
    /// width when it is known (macOS), falling back to the detail-column width when it is not.
    ///
    /// `horizontalSizeClass` stays the PRIMARY signal (iOS keeps its size-class-driven decision
    /// unchanged — iOS passes `windowWidth: nil`, so this reduces to the detail-width gate). On macOS —
    /// no size class — the window width is the steadier geometry: the detail GeometryReader can
    /// momentarily report a partially laid-out width mid-resize, while the `NSWindow` frame is
    /// authoritative.
    ///
    /// Each geometry is compared against ITS OWN threshold (ITEM #6 / F6 — branch on presence, do NOT
    /// collapse with `windowWidth ?? detailWidth`):
    /// - when `windowWidth` is known → compare the WHOLE WINDOW against ``compactWindowWidthThreshold``
    ///   (680, just below the 720 macOS floor) — the floor window resolves regular;
    /// - when `windowWidth` is `nil` (iOS always; macOS before the `NSWindow` reader fires) → fall back
    ///   to the DETAIL width against ``compactWidthThreshold`` (460). Collapsing both into one
    ///   `(windowWidth ?? detailWidth) < 680` is wrong: it would compare the ~500pt detail of the macOS
    ///   floor window against 680 (a one-frame compact carousel before the window reader fires) and
    ///   silently move the iPad-regular detail fallback from 460 to 680.
    ///
    /// - Parameters:
    ///   - horizontalSizeClassCompact: as above — the primary, short-circuiting signal.
    ///   - detailWidth: the detail GeometryReader width (the `nil`-window fallback geometry).
    ///   - windowWidth: the outer window's width when measurable (macOS), else `nil`.
    /// - Returns: compact iff the size class is compact, OR (window known) the window width is below
    ///   ``compactWindowWidthThreshold``, OR (no window) the detail width is below
    ///   ``compactWidthThreshold``.
    public static func isCompact(
        horizontalSizeClassCompact: Bool,
        detailWidth: CGFloat,
        windowWidth: CGFloat?
    ) -> Bool {
        if let windowWidth {
            return horizontalSizeClassCompact || windowWidth < compactWindowWidthThreshold
        } else {
            return horizontalSizeClassCompact || detailWidth < compactWidthThreshold
        }
    }
}

// MARK: - Per-device live-video ceiling (pure)

/// The device class the live-video ceiling is keyed on (docs/22 §7). A `.remoteGUI` pane's video stack
/// is 2 UDP sockets + a `VTDecompressionSession` + a `CVDisplayLink`; the safe concurrent count scales
/// with the host's decode/compositing headroom, which differs sharply between a phone, an iPad, and a
/// Mac. `Sendable` so it can cross into the (Sendable-`Int`) store init without ceremony.
public enum VideoDeviceClass: Sendable {
    case phone, pad, mac
}

/// The pure policy that maps a ``VideoDeviceClass`` to its concurrent live-video ceiling (the number
/// passed to ``WorkspaceStore/liveVideoCap``). Pulled out of the view/app glue as a synchronously
/// unit-testable function so the per-tier numbers are pinned in one place (docs/22 §7). The store
/// itself stays `liveVideoCap: Int` (unchanged shape) — this only decides which Int the app injects.
///
/// The tiers are deliberately distinct and monotone (phone ≤ pad ≤ mac): a phone can safely decode the
/// fewest concurrent windows, a Mac the most.
public enum VideoCapPolicy {
    /// iPhone (and any compact-width iOS projection): a single live video window.
    public static let phoneCap = 1
    /// iPad in a regular (non-compact) projection: two concurrent live video windows.
    public static let padCap = 2
    /// macOS: three concurrent live video windows.
    public static let macCap = 3

    /// The concurrent live-video ceiling for `deviceClass`.
    public static func cap(for deviceClass: VideoDeviceClass) -> Int {
        switch deviceClass {
        case .phone: return phoneCap
        case .pad:   return padCap
        case .mac:   return macCap
        }
    }

    /// Resolves the ``VideoDeviceClass`` from the platform/idiom/size-class signals.
    ///
    /// - Parameters:
    ///   - isMac: `true` on macOS (the highest tier; idiom/size-class are then irrelevant).
    ///   - horizontalSizeClassCompact: `true` when `@Environment(\.horizontalSizeClass) == .compact`
    ///     (iPhone, or an iPad in slide-over / a phone-narrow split) — forces the phone tier even on a
    ///     pad idiom.
    ///   - userInterfaceIdiomPad: `true` when `UIDevice.current.userInterfaceIdiom == .pad`.
    /// - Returns: `.mac` if `isMac`; else `.pad` only when it is a pad idiom AND not compact; else
    ///   `.phone` (the conservative floor for an iPhone or any compact iOS projection).
    public static func deviceClass(
        isMac: Bool,
        horizontalSizeClassCompact: Bool,
        userInterfaceIdiomPad: Bool
    ) -> VideoDeviceClass {
        if isMac { return .mac }
        if userInterfaceIdiomPad && !horizontalSizeClassCompact { return .pad }
        return .phone
    }

    /// The composed convenience: resolve the device class from the platform signals AND map it to the
    /// concurrent live-video ceiling in one call (the shape the view layer wants when it knows the size
    /// class, e.g. an iPad that has dropped to compact in slide-over should fall to the phone cap).
    public static func cap(
        isMac: Bool,
        horizontalSizeClassCompact: Bool,
        userInterfaceIdiomPad: Bool
    ) -> Int {
        cap(for: deviceClass(
            isMac: isMac,
            horizontalSizeClassCompact: horizontalSizeClassCompact,
            userInterfaceIdiomPad: userInterfaceIdiomPad
        ))
    }
}
