// SimulatorLocationPopover — where the device thinks it is.
//
// A POPOVER, not a drawer. Unlike the console this is set-and-forget: the value is applied once and
// then matters as a fact, not as a stream, so it belongs somewhere that closes. What stays visible
// afterwards is the header's readout — which is the whole reason the header carries it.
//
// PRESETS FIRST, field second. The realistic use is "run this as if it were somewhere else", and the
// honest answer to that is a short list of somewhere-elses. The field exists because the other real
// use is a coordinate pasted out of a map, and no list can anticipate that one.
//
// iOS-ONLY since docs/56 increment 52a; the Mac draws the same popover in
// `MacSimulatorLocationPopover`. The five words and the live/pinned fold are
// ``SimulatorPresentation/Location``'s — the fold in particular, because "Clear" being ABSENT rather
// than disabled while nothing is pinned is a decision, and a renderer holding two loose labels is a
// renderer that can draw the verb that undoes nothing.

#if os(iOS)
import SlopDeskDevicePanels
import SlopDeskSlate
import SwiftUI

struct SimulatorLocationPopover: View {
    var pinned: SimulatorCoordinate?
    var apply: (SimulatorCoordinate?) -> Void

    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            Text(SimulatorPresentation.Location.title)
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)

            places
            Divider()
            entry
            footer
        }
        .padding(Slate.Metric.space3)
        .frame(width: Slate.Metric.popoverWidth)
    }

    private var places: some View {
        VStack(spacing: 0) {
            ForEach(SimulatorPlace.all) { place in
                SlateListRow(
                    active: pinned == place.coordinate,
                    onTap: { send(place.coordinate) },
                    title: {
                        Text(place.name)
                            .font(.system(size: Slate.Typeface.base))
                            .foregroundStyle(Slate.Text.primary)
                            .lineLimit(1)
                    },
                    titleTrailing: { _ in
                        Text(place.coordinate.readout)
                            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .regular))
                            .foregroundStyle(Slate.Text.tertiary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    },
                    trailingOverlay: { _ in EmptyView() },
                )
            }
        }
    }

    /// The button is the only submit path. `SlateSearchField` is a search field and reports text as it
    /// changes, with no return action to hang a submit on — and giving this one field a bespoke return
    /// handler would make it a different control from every other field in the app that looks exactly
    /// like it.
    private var entry: some View {
        HStack(spacing: Slate.Metric.space1) {
            SlateSearchField(
                placeholder: SimulatorPresentation.Location.placeholder, text: $text,
            )
            Button(SimulatorPresentation.Location.set) { if let parsed { send(parsed) } }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(parsed == nil ? Slate.Text.tertiary : Slate.State.accent)
                .disabled(parsed == nil)
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightControl)
        .slateChromeFieldPlate()
    }

    /// The footer says what is true now and offers the one verb that undoes it. "Clear" is absent
    /// while nothing is pinned, because a control that undoes nothing is a control that has to be
    /// reasoned about before it is ignored.
    private var footer: some View {
        HStack(spacing: Slate.Metric.space1) {
            if let pinned {
                Text(SimulatorPresentation.Location.pinned(pinned))
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                Spacer(minLength: Slate.Metric.space1)
                Button(SimulatorPresentation.Location.clear) { send(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.StatusInk.err)
            } else {
                Text(SimulatorPresentation.Location.live)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var parsed: SimulatorCoordinate? { SimulatorCoordinate.parse(text) }

    /// Applying closes the popover. The result is reported in the header and in the panel's own
    /// banner, so keeping it open would leave a sheet over the device to say something already said
    /// twice behind it.
    private func send(_ coordinate: SimulatorCoordinate?) {
        apply(coordinate)
        dismiss()
    }
}
#endif
