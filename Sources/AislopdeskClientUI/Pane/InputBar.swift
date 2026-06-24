// InputBar — the command input row (REBUILD-V2, L2). A prompt glyph + an editable monospaced TextField,
// with a 1px top Divider separating it from the terminal surface above. Bound to ``InputBarModel`` (which
// wraps the proven `InputBoxModel`): the affordance adapts the prompt (shell `>` vs CLI-agent compose),
// and submit/edit route through the model's single OUT funnel.
//
// The real key routing lives in WorkspaceCore (`InputBarModel.submit()`/`sendText`/`sendRaw`); this view
// only binds the compose text + a Return action. For ImageRenderer SNAPSHOT tests use `staticMirror:
// true` — it renders a non-interactive Text mirror of the compose buffer. SYSTEM colours/fonts only.

#if canImport(SwiftUI)
import AislopdeskClaudeCode
import AislopdeskWorkspaceCore
import SwiftUI

/// Pure layout mapping for the input field — kept free of SwiftUI so the rich-mode rendering effect is
/// unit-testable without a view.
enum InputBarLayout {
    /// The field's line-limit range: a single line in plain mode, 3…8 lines in rich (multi-line) mode.
    static func lineLimit(richMode: Bool) -> ClosedRange<Int> { richMode ? 3...8 : 1...1 }
}

struct InputBar: View {
    let model: InputBarModel
    /// EAGER/STATIC render path for headless ImageRenderer snapshots (no interactive TextField).
    var staticMirror: Bool = false

    @FocusState private var fieldFocused: Bool

    /// Prompt glyph per affordance: a shell `>` for `.shellCommand`, an agentic compose glyph otherwise.
    private var promptGlyph: String {
        switch model.affordance {
        case .shellCommand: "chevron.right"
        case .tuiCompose: "sparkle"
        }
    }

    private var placeholder: String {
        switch model.affordance {
        case .shellCommand: "Run a command"
        case .tuiCompose: "Message the agent"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: promptGlyph)
                .font(.system(size: Otty.Typeface.base, weight: .semibold))
                .foregroundStyle(model.affordance == .tuiCompose ? Color.accentColor : .secondary)
            field
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativePaneColor.terminalBackground)
        // 1px top border = the divider between the terminal surface and the input area.
        .overlay(alignment: .top) { Divider() }
    }

    /// Rich mode → a multi-line editor (3…8 lines); plain mode → a single line. Reading `model.richMode`
    /// (an `@Observable`) here makes the rich-input toggle actually re-render the field. The pure mapping is
    /// in ``InputBarLayout`` so the rich-mode rendering effect is unit-gated.
    private var lineLimitRange: ClosedRange<Int> { InputBarLayout.lineLimit(richMode: model.richMode) }

    @ViewBuilder private var field: some View {
        if staticMirror {
            // Static mirror for ImageRenderer: a plain Text of the compose buffer (or placeholder).
            Text(model.compose.isEmpty ? placeholder : model.compose)
                .font(.system(size: Otty.Typeface.body).monospaced())
                .foregroundStyle(model.compose.isEmpty ? .tertiary : .primary)
                .lineLimit(lineLimitRange)
        } else {
            TextField(
                placeholder,
                text: Binding(get: { model.compose }, set: { model.compose = $0 }),
                axis: model.richMode ? .vertical : .horizontal,
            )
            .textFieldStyle(.plain)
            .font(.system(size: Otty.Typeface.body).monospaced())
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .lineLimit(lineLimitRange)
            .onSubmit { model.submit() }
            // In rich (`.vertical`) mode a bare Return inserts a newline; ⌘Return submits. (In plain mode
            // `.onSubmit` already handles Return; this handler is harmless there.)
            .onKeyPress(.return, phases: .down) { press in
                guard model.richMode else { return .ignored }
                if press.modifiers.contains(.command) {
                    model.submit()
                    return .handled
                }
                return .ignored // bare Return → let the editor insert a newline
            }
        }
    }
}
#endif
