// WebAddressBar — the Web surface's one bar: which page, where it is, and how to open another.
//
// It sits BELOW the panel's tab strip rather than in it, because everything on it is about the page
// (a subject that only exists on this surface) while the strip is about the panel. The strip's own
// reload plate reloads the FRONTEND; the page has its own controls inside DevTools.
//
// The address is a technical line, so it renders in the instrument face (MERIDIAN L2) at the
// command-input size — the same register the connect form's fields use, and one that sidesteps the
// 11pt SwiftUI field jump `SlateSearchField` documents.

#if os(macOS)
import SFSafeSymbols
import SwiftUI

struct WebAddressBar: View {
    @Bindable var model: WebSidebarModel

    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            tabPicker
            field
            PlateIconButton(symbol: .plus) {
                Task { await model.openTab() }
            }
            .help("Open a new tab in the host's browser")
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightBar)
        .background(Slate.Surface.raised)
    }

    /// A menu rather than a tab row: a browser's tabs carry titles, and a sidebar this narrow can
    /// show one title or five illegible ones. The menu names the current page at rest, which is the
    /// fact the surface owes the reader; the rest is one click away.
    private var tabPicker: some View {
        Menu {
            ForEach(model.targets) { target in
                Button {
                    Task { await model.select(target.id) }
                } label: {
                    if target.id == model.selection {
                        Label(target.displayName, systemSymbol: .checkmark)
                    } else {
                        Text(target.displayName)
                    }
                }
            }
            if model.targets.count > 1, let selection = model.selection {
                Divider()
                Button("Close This Tab", role: .destructive) {
                    Task { await model.closeTab(selection) }
                }
            }
        } label: {
            Image(systemSymbol: .squareOnSquare)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.selectedTarget.map { "Tabs — showing \($0.displayName)" } ?? "Tabs")
    }

    /// The address itself. Submitting points the CURRENT page at it (never opens a new one — see
    /// ``WebSidebarModel/submitAddress()``), and focus is reported to the model so a page that
    /// navigates on its own cannot rewrite the line under a cursor that is mid-URL.
    private var field: some View {
        TextField("Address", text: $model.address)
            .textFieldStyle(.plain)
            .font(Slate.Typeface.instrument(Slate.Typeface.body))
            .foregroundStyle(Slate.Text.primary)
            .lineLimit(1)
            .focused($addressFocused)
            .onSubmit {
                addressFocused = false
                Task { await model.submitAddress() }
            }
            .onChange(of: addressFocused) { _, focused in
                if focused { model.beginEditingAddress() } else { model.endEditingAddress() }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(maxWidth: .infinity)
            .frame(height: Slate.Metric.heightControl)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .fill(Slate.Surface.ground),
            )
    }
}
#endif
