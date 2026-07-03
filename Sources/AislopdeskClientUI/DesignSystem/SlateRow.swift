// SlateRow — the section-header idiom, styled NATIVELY (system semantic styles; the Slate token layer is
// retiring from chrome — native-chrome migration, 2026-07-03). The old custom `SlateSidebarRow`
// (white-card selection) is deleted: sidebar/list rows are native `List` rows now.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A sidebar section header: uppercase, tertiary, small — with an optional trailing accessory (e.g. "+").
struct SlateSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

extension SlateSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
#endif
