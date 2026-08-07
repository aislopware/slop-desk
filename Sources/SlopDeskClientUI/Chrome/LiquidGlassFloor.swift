// LiquidGlassFloor — the behind-window material under the whole frame floor (trial,
// user-directed 2026-08-07). The floor's authored tone is no longer opaque: every floor paint
// (`Slate.Surface.field` in the three columns, the divider gap) is the SAME tint at
// `Slate.Surface.floorGlassAlpha` over this one full-bleed material, so the frame keeps its
// colour while the desktop blurs through — the Tahoe liquid-glass read, without giving any
// single column its own material (the round-5 seam this design deliberately removed).

#if os(macOS)
import AppKit
import SwiftUI

/// The one behind-window material the frame floor stands on. Mounted ONCE as the background of
/// the workspace split (`WorkspaceRootView`), beneath every column and the divider gaps.
struct LiquidGlassFloor: NSViewRepresentable {
    func makeNSView(context _: Context) -> LiquidGlassFloorView {
        LiquidGlassFloorView()
    }

    func updateNSView(_: LiquidGlassFloorView, context _: Context) {}
}

/// The effect view, appearance-pinned to the CHROME polarity: it sits OUTSIDE the split's
/// column subtree (a SwiftUI background at the window root), which inherits the app-level GLASS
/// polarity — under Dracula that would resolve a DARK material beneath the light lavender tint
/// and muddy the frame. Pinned here and re-pinned on every theme change instead.
final class LiquidGlassFloorView: NSVisualEffectView {
    // `nonisolated(unsafe)`: written once in init, read in deinit — no concurrent access.
    private nonisolated(unsafe) var themeToken: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        // Pinned active: the floor is the window's ground, and a deactivate that swaps the
        // material for the solid inactive tone would flash the whole frame on every focus change.
        state = .active
        pinChromeAppearance()
        themeToken = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinChromeAppearance() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
    }

    private func pinChromeAppearance() {
        appearance = NSAppearance(named: Slate.theme.chromeIsLight ? .aqua : .darkAqua)
    }
}
#endif
