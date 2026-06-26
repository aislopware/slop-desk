// ComposerBar — the otty "Composer" (`⌘⇧E`) input overlay mounted at the bottom of a terminal pane
// (E12 / WI-5). A multi-line growing field + a bottom toolbar, bound to the DURABLE per-pane
// ``ComposerModel`` (on the pane's `LivePaneSession`, WI-3/WI-4) so the draft + queue survive tab switches.
//
// Anatomy matches `composer.png`:
//   [ multi-line draft field (grows, then internal scroll) ]
//   ────────────────────────────────────────────── (thin top rule)
//   [ ⌘↩ Send   ⌥⌘↩ Queue   ⎋ Cancel ]············[ ① pin  ② float  ③ queue ]
// In Prompt-Queue input mode (`⌘⇧M`, `chrome.queueMode`) the field placeholder becomes
// "Add to Prompt Queue…", bare `↩` enqueues a line (never a newline), and the toolbar collapses to the
// queue.png "Close" + queue affordance.
//
// THE SEND CONTRACT (docs/29, decision #1): every byte leaves through ``ComposerModel/send`` → the pane's
// `InputBarModel.sendRaw` → the ONE per-pane ordered-OUT FIFO + B1 echo-dedup. This view NEVER opens a
// socket or spawns an unstructured `Task`; it only drives the model's verbs. `staticMirror` renders a
// non-interactive Text mirror for ImageRenderer snapshots (hang-safe; no responder).
//
// Return-key safety (otty's core principle — "accidental sends are impossible"): bare `↩`/`⇧↩` insert a
// newline; only `⌘↩` sends and `⌥⌘↩` enqueues. The (command, option, queueMode) → action mapping is the
// PURE ``ComposerKeyResolver`` so it is unit-tested headlessly (``ComposerKeyResolverTests``) — the view
// only dispatches the resolved action.

#if canImport(SwiftUI)
import AislopdeskClaudeCode
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Pure Return-key mapping (headless, unit-tested)

/// The action a Return-key press resolves to in the Composer. Pure value type so the (modifier, mode) →
/// action mapping is testable without a view (``ComposerKeyResolverTests``).
enum ComposerKeyAction: Equatable {
    /// `⌘↩` — send the draft now (deliver + clear + close).
    case send
    /// `⌥⌘↩` (always), or a bare `↩` while in Prompt-Queue input mode — append to the queue.
    case enqueue
    /// Bare `↩` / `⇧↩` in normal Composer mode — insert a newline (NEVER an accidental send).
    case newline
    /// `⎋` — cancel (kept here for completeness; the view routes `⎋` via `onExitCommand`/escape, not Return).
    case cancel
}

/// The PURE Return-key resolver. otty's invariant: Return alone never sends — a half-written message can't
/// fire. `⌘↩` sends, `⌥⌘↩` always enqueues, and a bare Return enqueues ONLY in Prompt-Queue input mode
/// (where the bar exists to stack lines); otherwise it is a newline.
enum ComposerKeyResolver {
    /// Resolve a Return-key press from the active modifier flags and whether the Composer is in Prompt-Queue
    /// input mode. Order matters: `⌥⌘↩` (enqueue) is checked before the bare `⌘↩` (send).
    static func resolveReturn(command: Bool, option: Bool, queueMode: Bool) -> ComposerKeyAction {
        if command, option { return .enqueue } // ⌥⌘↩ — always enqueue, never send
        if command { return .send } // ⌘↩ — send now
        if queueMode { return .enqueue } // bare ↩ in the queue-input bar adds a line
        return .newline // bare ↩ / ⇧↩ in the Composer — newline, never a send
    }
}

// MARK: - Per-leaf chrome (the wired-callback target)

/// Per-pane Composer view chrome the leaf owns and the pane's `onRequestComposer` / `onRequestPromptQueue`
/// callbacks mutate (a reference type so a `@MainActor` closure can flip it, like the find bar's
/// ``TerminalFindBarModel`` `@State`). `queueMode` switches the placeholder + bare-↩ behaviour; `focusToken`
/// is bumped to (re)assert the field's `@FocusState` each time the bar is (re)opened. Held as `@State` on the
/// `.id(PaneID)`-keyed leaf, so it is per-pane (no cross-pane bleed) and never the DURABLE model's concern.
@MainActor
@Observable
final class ComposerLeafChrome {
    /// Prompt-Queue input mode (`⌘⇧M`) vs the normal Composer (`⌘⇧E`).
    var queueMode = false
    /// Bumped on each (re)open so the field re-grabs focus even when already mounted.
    var focusToken = 0
}

// MARK: - Platform pasteboard reader (GUI-only; the pure HTML→Markdown heart is RichPasteMarkdown)

/// Reads the platform pasteboard at the `⌘V` / `⇧⌘V` call site and hands the result to the Composer. The
/// HTML/RTF→Markdown conversion is the PURE ``AislopdeskClaudeCode/RichPasteMarkdown`` (unit-tested, E12
/// WI-2); only the platform read (NSPasteboard / UIPasteboard, both AppKit/UIKit, GUI-only, untested by
/// `swift test`) lives here. Validate-then-degrade: every read is optional and a missing flavour falls
/// through to the next; nothing traps.
enum ComposerPasteboard {
    /// `⌘V` — the richest available flavour converted to Markdown: HTML → Markdown, else RTF → HTML →
    /// Markdown, else an image → a Markdown image ref, else the plain string. `nil` when the pasteboard is
    /// empty / unreadable.
    static func richMarkdown() -> String? {
        #if os(macOS)
        let pb = NSPasteboard.general
        if let html = pb.string(forType: .html), !html.isEmpty {
            return RichPasteMarkdown.markdown(fromHTML: html)
        }
        if let html = htmlFromRTF(pb.data(forType: .rtf)) {
            return RichPasteMarkdown.markdown(fromHTML: html)
        }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return imageMarkdownPlaceholder
        }
        return pb.string(forType: .string)
        #elseif os(iOS)
        let pb = UIPasteboard.general
        if let data = pb.data(forPasteboardType: "public.html"),
           let html = String(data: data, encoding: .utf8), !html.isEmpty
        {
            return RichPasteMarkdown.markdown(fromHTML: html)
        }
        if let html = htmlFromRTF(pb.data(forPasteboardType: "public.rtf")) {
            return RichPasteMarkdown.markdown(fromHTML: html)
        }
        if pb.hasImages {
            return imageMarkdownPlaceholder
        }
        return pb.string
        #else
        return nil
        #endif
    }

    /// `⇧⌘V` — the plain-text flavour, inserted verbatim (no conversion).
    static func plainText() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    #if os(macOS) || os(iOS)
    /// A pasted image has no transmissible byte path in a CR-terminated prompt line, so it degrades to a
    /// Markdown image ref placeholder (the agent at least sees an image was intended). A path-backed embed
    /// is a documented follow-up.
    private static let imageMarkdownPlaceholder = "![pasted image]()"

    /// Renders RTF bytes to an HTML string via `NSAttributedString` (GUI-only; the round-trip runs on the
    /// main actor at the `⌘V` call site). Returns `nil` on any failure — validate-then-degrade, never trap.
    private static func htmlFromRTF(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil,
        ) else { return nil }
        guard let htmlData = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html],
        ) else { return nil }
        return String(data: htmlData, encoding: .utf8)
    }
    #endif
}

// MARK: - The view

/// The Composer overlay strip (the view). Owns only its `@FocusState`; every draft / send / enqueue / paste
/// mutation routes through ``ComposerModel`` (the durable per-pane model) so the GUI and the headless tests
/// drive the same logic.
struct ComposerBar: View {
    /// The durable per-pane Composer model (draft + queue + send sink). Reference type (`@Observable`), so
    /// the bar re-renders on every draft / visibility / queue mutation.
    let composer: ComposerModel
    /// The per-leaf chrome (queue-input mode + focus token), owned by the leaf as `@State`.
    let chrome: ComposerLeafChrome
    /// The field's growing line budget (derived by the leaf from the `composerMaxHeight` pref); the field
    /// grows from `minLines` to this, then scrolls internally.
    var maxLines: Int = 12
    /// EAGER/STATIC render path for headless ImageRenderer snapshots (no interactive field, no responder).
    var staticMirror: Bool = false

    @FocusState private var fieldFocused: Bool

    /// The grow band: at least 3 lines (a comfortable multi-line start), up to the pref-derived `maxLines`.
    private var lineLimitRange: ClosedRange<Int> { 3...max(3, maxLines) }

    private var placeholder: String {
        chrome.queueMode ? "Add to Prompt Queue…" : "Message…"
    }

    var body: some View {
        VStack(spacing: 0) {
            field
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.top, Otty.Metric.space2)
                .padding(.bottom, Otty.Metric.space1)
            toolbar
        }
        .background(NativePaneColor.terminalBackground)
        // 1px top rule = the divider between the terminal surface (or the queue strip) and the Composer.
        .overlay(alignment: .top) {
            Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
        }
    }

    // MARK: Field

    @ViewBuilder private var field: some View {
        if staticMirror {
            Text(composer.draft.isEmpty ? placeholder : composer.draft)
                .font(.system(size: Otty.Typeface.body).monospaced())
                .foregroundStyle(composer.draft.isEmpty ? Otty.Text.tertiary : Otty.Text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(lineLimitRange)
        } else {
            interactiveField
        }
    }

    private var interactiveField: some View {
        TextField(placeholder, text: draftBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: Otty.Typeface.body).monospaced())
            .foregroundStyle(Otty.Text.primary)
            .tint(Otty.State.accent)
            .focused($fieldFocused)
            .lineLimit(lineLimitRange)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Return-key routing — bare ↩/⇧↩ fall through to the editor (newline); ⌘↩ / ⌥⌘↩ / queue-mode-↩
            // are handled. The decision is the PURE resolver so it is unit-tested.
            .onKeyPress(.return, phases: .down) { press in
                let action = ComposerKeyResolver.resolveReturn(
                    command: press.modifiers.contains(.command),
                    option: press.modifiers.contains(.option),
                    queueMode: chrome.queueMode,
                )
                switch action {
                case .send: composer.sendDraft()
                    return .handled
                case .enqueue: composer.enqueueDraft()
                    return .handled
                case .cancel: composer.cancel()
                    return .handled
                case .newline: return .ignored // let the editor insert the newline
                }
            }
            // ⌘V rich paste (HTML/RTF/image → Markdown) / ⇧⌘V plain. Best-effort interception of the field's
            // native paste; the reliable rich-paste path is the context-menu `onPasteToComposer` seam (leaf).
            .onKeyPress(KeyEquivalent("v"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                if press.modifiers.contains(.shift) {
                    if let text = ComposerPasteboard.plainText() { composer.pastePlain(text) }
                } else {
                    if let markdown = ComposerPasteboard.richMarkdown() { composer.pasteRich(markdown) }
                }
                return .handled
            }
            .onAppear { focusSoon() }
            .onChange(of: chrome.focusToken) { _, _ in focusSoon() }
        #if os(macOS)
            .onExitCommand { composer.cancel() } // ⎋ — cancel (keeps the draft)
        #else
            .onKeyPress(.escape, phases: .down) { _ in composer.cancel()
                return .handled
            }
        #endif
    }

    /// Two-way binding into the durable model's draft (read live, write back so every keystroke persists on
    /// the `LivePaneSession` and survives a tab switch).
    private var draftBinding: Binding<String> {
        Binding(get: { composer.draft }, set: { composer.draft = $0 })
    }

    /// Defer the `@FocusState` set one runloop hop (a set in the same tick the field appears, before its
    /// responder exists, is dropped — the palette / find-bar idiom).
    private func focusSoon() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Otty.Metric.space2) {
            if chrome.queueMode {
                // queue.png: minimal — a Close text button + the queue glyph on the right.
                Spacer(minLength: 0)
                hintButton(label: "Close") { composer.cancel() }
                OttyPlateButton(symbol: .listBullet, help: "Add to Prompt Queue (↩)", size: iconSize, plate: plate) {
                    composer.enqueueDraft()
                }
            } else {
                // composer.png: ⌘↩ Send / ⌥⌘↩ Queue / ⎋ Cancel low-weight labels, then pin / float / queue.
                hintButton(chord: "⌘↩", label: "Send") { composer.sendDraft() }
                hintButton(chord: "⌥⌘↩", label: "Queue") { composer.enqueueDraft() }
                hintButton(chord: "⎋", label: "Cancel") { composer.cancel() }
                Spacer(minLength: 0)
                OttyPlateButton(
                    symbol: composer.isPinned ? .pinFill : .pin,
                    help: composer.isPinned ? "Unpin composer" : "Pin composer (stays across tabs)",
                    size: iconSize,
                    plate: plate,
                    tint: composer.isPinned ? Otty.State.accent : Otty.Text.icon,
                ) { composer.isPinned.toggle() }
                OttyPlateButton(
                    symbol: .arrowUpForwardApp,
                    help: composer.isFloating ? "Dock composer back" : "Float composer on top",
                    size: iconSize,
                    plate: plate,
                    tint: composer.isFloating ? Otty.State.accent : Otty.Text.icon,
                ) { composer.isFloating.toggle() }
                OttyPlateButton(symbol: .listBullet, help: "Add to Prompt Queue (⌥⌘↩)", size: iconSize, plate: plate) {
                    composer.enqueueDraft()
                }
            }
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space1)
        .frame(maxWidth: .infinity)
    }

    // Platform hit-target sizing (iOS finger targets; macOS compact).
    #if os(iOS)
    private let plate: CGFloat = 34
    private let iconSize: CGFloat = 16
    #else
    private let plate: CGFloat = Otty.Metric.plate
    private let iconSize: CGFloat = Otty.Metric.iconSize
    #endif

    /// A low-weight chord+label hint that is also clickable (composer.png renders these as plain text, not
    /// pills). The chord segment is omitted for the bare "Close" label.
    private func hintButton(chord: String? = nil, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space1) {
                if let chord {
                    Text(chord)
                        .font(.system(size: Otty.Typeface.footnote, weight: .medium, design: .monospaced))
                        .foregroundStyle(Otty.Text.tertiary)
                }
                Text(label)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
