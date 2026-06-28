// SnippetEditorSheet — the "Edit Text Snippet" modal (E16 WI-7, `docs/otty-clone/screenshots/textsnippet-
// setting.png`). A self-contained SwiftUI sheet that edits a snippet's Name / Alias / Text and hands the
// three strings back to its presenter (Settings → Recipes) via `onSave`; it never touches the store directly,
// so it is pure-view + cross-platform (macOS Settings window + the iOS settings sheet host the same struct).
//
// FIDELITY (textsnippet-setting.png): a card-surface sheet with a bold title + `×` close, then three labeled
// fields each with the exact otty helper line — **Name** ("Shown in the command palette and this list."),
// **Alias** ("Trigger word typed at the shell prompt to expand this snippet.", monospaced), **Text** (a
// multiline monospaced editor) — a placeholder reference line (`{{cursor}} · {{clipboard}} · {{date}} ·
// {{time}}`), and a footer with a plain **Cancel** and a solid-accent **Save Changes**. The literal white of
// the screenshot is the otty Paper theme; here every surface reads the live `Otty` theme tokens (so it adapts
// to the Monokai-Pro default) — match the design SYSTEM, not the captured pixels.
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SwiftUI

/// The modal snippet editor. Presented with the snippet's current values (empty for a new snippet); on
/// **Save Changes** it calls `onSave(name, alias, body)` and dismisses. Alias whitespace is normalized by the
/// store's CRUD (`Snippet.normalizeAlias`), so this view stores the raw text and lets the store clean it.
struct SnippetEditorSheet: View {
    /// Whether this is a fresh snippet (titles the sheet "New Text Snippet") or an existing one ("Edit Text
    /// Snippet", the screenshot case).
    let isNew: Bool
    /// Called with the edited (name, alias, body) when the user taps Save Changes. The presenter routes it to
    /// `WorkspaceStore.addSnippet` / `updateSnippet`.
    let onSave: (_ name: String, _ alias: String, _ body: String) -> Void

    @State private var name: String
    @State private var alias: String
    /// The snippet body text. Named `snippetText` (NOT `body`) so it does not collide with the SwiftUI
    /// `var body: some View` requirement.
    @State private var snippetText: String

    @Environment(\.dismiss) private var dismiss

    init(
        isNew: Bool,
        name: String = "",
        alias: String = "",
        body: String = "",
        onSave: @escaping (_ name: String, _ alias: String, _ body: String) -> Void,
    ) {
        self.isNew = isNew
        self.onSave = onSave
        _name = State(initialValue: name)
        _alias = State(initialValue: alias)
        _snippetText = State(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space4) {
            header
            field(
                label: "Name",
                helper: "Shown in the command palette and this list.",
                text: $name,
                mono: false,
            )
            field(
                label: "Alias",
                helper: "Trigger word typed at the shell prompt to expand this snippet.",
                text: $alias,
                mono: true,
            )
            textArea
            footer
        }
        .padding(Otty.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Otty.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
    }

    // MARK: Header (title + close)

    private var header: some View {
        HStack {
            Text(isNew ? "New Text Snippet" : "Edit Text Snippet")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Single-line field (Name / Alias)

    private func field(label: String, helper: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text(label)
                .font(.system(size: Otty.Typeface.base, weight: .medium))
                .foregroundStyle(Otty.Text.primary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(mono
                    ? .system(size: Otty.Typeface.body).monospaced()
                    : .system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .padding(Otty.Metric.space2)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(Otty.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
                )
            Text(helper)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary)
        }
    }

    // MARK: Multiline text area (Text + the placeholder reference line)

    private var textArea: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text("Text")
                .font(.system(size: Otty.Typeface.base, weight: .medium))
                .foregroundStyle(Otty.Text.primary)
            TextEditor(text: $snippetText)
                .font(.system(size: Otty.Typeface.body).monospaced())
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(Otty.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
                )
            // The reserved template vars (resolved by `ReservedSnippetVars`, never user-prompted) — the otty
            // helper line, verbatim, so the user knows the four built-in placeholders exist.
            Text("Placeholders: {{cursor}} · {{clipboard}} · {{date}} · {{time}}")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary)
        }
    }

    // MARK: Footer (Cancel + Save Changes)

    private var footer: some View {
        HStack(spacing: Otty.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)

            Button {
                onSave(name, alias, snippetText)
                dismiss()
            } label: {
                Text("Save Changes")
                    .font(.system(size: Otty.Typeface.body, weight: .semibold))
                    .foregroundStyle(Otty.Surface.card)
                    .padding(.horizontal, Otty.Metric.space3)
                    .padding(.vertical, Otty.Metric.space1)
                    .background(
                        RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                            .fill(Otty.State.accent),
                    )
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
