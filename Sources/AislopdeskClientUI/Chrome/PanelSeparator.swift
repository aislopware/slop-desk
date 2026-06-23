// PanelSeparator — the 1pt rail↔content divider (warp-window-chrome.md §8). Width 1pt, color =
// theme.outline() = fg_overlay_2 (foreground @ 10%), full column height.

import AislopdeskDesignSystem
import SwiftUI

struct PanelSeparator: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.outline)
            .frame(width: WarpSize.railDivider)
    }
}
