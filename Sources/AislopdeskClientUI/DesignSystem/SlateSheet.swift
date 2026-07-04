// SlateSheet — the shared native-sheet chrome (MERIDIAN C3): ONE header recipe and ONE footer recipe
// for every native `.sheet` body (Connect-to-Host, the Remote-Window picker, the keyboard cheat sheet),
// so the sheets can't drift. Before C3 each sheet hand-rolled the same header (headline + the 20/18/6
// inset) and bottom bar (Divider + trailing buttons + the 20/14 inset).
//
// NATIVE voice ON PURPOSE: sheets are native chrome (the everything-outside-the-workspace-is-native
// directive), so the header speaks `.headline` and the buttons stay system-styled — the Slate
// instrument voice belongs to the workspace, not to these dialogs.

#if canImport(SwiftUI)
import SwiftUI

/// The sheet's title row: a native `.headline` title (optionally icon-led) + an optional trailing
/// accessory (a Refresh button, a Done button). The insets are the one shared recipe.
struct SlateSheetHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline)
            } else {
                Text(title).font(.headline)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

extension SlateSheetHeader where Trailing == EmptyView {
    /// A plain title header (no trailing accessory).
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

/// The sheet's bottom bar: a `Divider` + a TRAILING-aligned native button row (Cancel / the prominent
/// default action), on the shared 20/14 inset.
struct SlateSheetFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Slate.Metric.space3) {
                Spacer(minLength: 0)
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}
#endif
