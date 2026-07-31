// SlateOverlayControls — the floating family's shared CONTROLS, one component per recurring shape.
//
// ``SlateOverlayCard`` gives every overlay the same SURFACE (glass, rim, plates, keycaps); this file gives
// them the same FURNITURE. Before it, each card hand-rolled its own copy of the same four shapes — the caps
// micro-label, the labelled input, the search bar, the Cancel/confirm footer — and the copies drifted:
// one card's label sat a point tighter than another's, one search bar deferred its focus grab and another
// didn't. A surface family only reads as a family while its parts are literally the same parts, so the
// shapes live here once and the overlays compose them.
//
// The ink is ``SlateOverlayInk`` throughout (neutral, system-semantic — never the terminal theme), and the
// editable controls stay NATIVE (`.roundedBorder` at `.large`): the card is ours, what sits in it is the
// system's. The system controls take the app's one neutral accent (the AccentColor asset), so nothing here
// re-tints anything.
//
// No AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

// MARK: - The caps micro-label

/// A section-level caps micro-label in the instrument voice — a LIST region's caption ("RECENT", the
/// palette's category headers), never a form-field's name. Field labels are sentence-case system text
/// (see ``SlateLabeledField``): a caps-mono run above every input read as instrument engraving, and the
/// photographed form carried three of them stacked. Caps survive only where the palette family already
/// wears them well — naming a run of rows, one per region.
struct SlateCapsLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
            .tracking(Slate.Typeface.instrumentTracking)
            .foregroundStyle(SlateOverlayInk.tertiary)
    }
}

// MARK: - The labelled input

/// One labelled form input: a sentence-case label in the system face (`base`/medium/`secondary` — the
/// register modern form dialogs use; the caps-mono label was photographed and rejected as engraving),
/// then a REAL macOS text field under it. `.roundedBorder` at `.large` is the whole point — it is the
/// system's field, at the system's size, so it takes the focus ring, the selection and the height a user
/// expects instead of a look-alike plate that comes up short (a hand-drawn plate was tried and rejected
/// on sight as cramped).
struct SlateLabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    /// Monospace the CONTENT (a port, a number being read back); a hostname is a name and keeps the
    /// system face.
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(SlateOverlayInk.secondary)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(mono ? .body.monospaced() : .body)
        }
    }
}

// MARK: - The search bar

/// The card-top search input every list overlay opens with: a quiet magnifier, a plain field in the
/// family ink, the input-strip height — and the focus-grab timing quirk handled ONCE. A `@FocusState`
/// set in the same tick the view appears (before its backing responder exists) is silently dropped, so
/// the grab defers one runloop hop; every copy of this bar used to carry that idiom by hand.
///
/// The FOCUS stays the caller's (`FocusState<Bool>.Binding`): the overlays re-grab it on their own
/// events (an advance, a filter change), which a component-private focus could not serve.
struct SlateSearchBar: View {
    let prompt: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    var showsMagnifier: Bool = true
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            if showsMagnifier {
                Image(systemSymbol: .magnifyingglass)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(SlateOverlayInk.secondary)
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(SlateOverlayInk.primary)
                .tint(SlateOverlayInk.primary) // the caret is the text's own ink, not an accent
                .focused(focus)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: Slate.Metric.heightInput)
        .onAppear {
            DispatchQueue.main.async { focus.wrappedValue = true }
        }
    }
}

// MARK: - The footer

/// A form card's closing line: Cancel and the confirming action, trailing-aligned, on the card's own
/// padding. No `Divider` above it — the card's edge already ends the surface, and a rule here is the
/// stacked-boxes look the grouped `Form` left behind. The confirm button is the native prominent one in
/// the app's neutral accent; Esc and ↩ take their standard meanings.
struct SlateCardFooter: View {
    let confirmTitle: String
    var confirmDisabled: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirmDisabled)
        }
        .padding(.horizontal, Slate.Metric.space4)
        .padding(.bottom, Slate.Metric.space4)
    }
}

// MARK: - The warning row

/// A validation / failure line — amber, because this one IS a status: the neutrality rule is about the
/// chrome not competing for attention, never about suppressing an actual signal.
struct SlateWarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
