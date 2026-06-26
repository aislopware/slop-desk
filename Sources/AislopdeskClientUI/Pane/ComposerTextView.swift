// ComposerTextView — the hosted, paste-overriding text editor backing the otty Composer field (E12 /
// ES-E12-3). The Composer's draft is edited in a real AppKit `NSTextView` (macOS) / UIKit `UITextView`
// (iOS) instead of a SwiftUI `TextField`, because the ONLY reliable way to make `⌘V` run the
// HTML/RTF→Markdown rich-paste conversion is to OVERRIDE the text view's `paste(_:)`: SwiftUI installs a
// default Edit ▸ Paste menu item that owns the `⌘V` key-equivalent and routes `paste(_:)` to the focused
// field BEFORE any `.onKeyPress` handler runs — so a pure-SwiftUI field can never intercept `⌘V`
// (verified: `AislopdeskClientApp` keeps the standard `.pasteboard` command group). A hosted text view
// also gives true caret-aware insert (splice at the selection) and full cursor/selection control — the
// `ComposerTextView` the stale `ComposerModel.selection` doc once referenced, now actually built.
//
// SINGLE SOURCE OF TRUTH: the durable ``ComposerModel`` owns the draft + caret. This view REFLECTS
// `composer.draft` (passed in as the `text` snapshot so SwiftUI re-renders + re-measures the field on
// every change) and reports user edits + caret back into the model. A paste routes through
// ``ComposerPasteHandler`` → ``ComposerModel/insert(_:at:)`` — the SAME caret-aware splice the right-click
// "Paste and continue in Composer" seam uses — so the conversion + caret logic is headlessly testable
// (``ComposerPasteHandlerTests``) without a window or live responder.
//
// Behaviours preserved 1:1 from the prior SwiftUI field: `⌘↩` send / `⌥⌘↩` enqueue / bare `↩` + `⇧↩`
// newline / queue-mode `↩` enqueue (via the PURE ``ComposerKeyResolver``), `⌘V` rich / `⇧⌘V` plain paste,
// `⎋` cancel-keep-draft, placeholder, two-way draft binding, focus (``ComposerLeafChrome/focusToken``),
// and the grow-to-`maxLines`-then-scroll-internally height.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS) || os(iOS)

// MARK: - The representable (shared shape)

/// Hosts the Composer's editable text in a platform text view. A value type whose `text` field is the
/// observed `composer.draft` snapshot — re-constructed by the SwiftUI body on every draft change so the
/// representable re-runs `updateNSView`/`updateUIView` (sync the view) and `sizeThatFits` (grow the box).
@MainActor
struct ComposerTextEditor {
    /// The current draft text (a snapshot of ``ComposerModel/draft``). Read in the SwiftUI body so the
    /// host re-renders — and the field re-measures its height — on every draft mutation (typing OR paste).
    let text: String
    /// The durable per-pane model (the source of truth for draft + caret + the send/enqueue/cancel verbs).
    let composer: ComposerModel
    /// The per-leaf chrome — `queueMode` (drives bare-`↩` enqueue) + `focusToken` (re-asserts focus).
    let chrome: ComposerLeafChrome
    let placeholder: String
    /// The field's grow band: starts at `minLines`, expands to `maxLines`, then scrolls internally.
    let minLines: Int
    let maxLines: Int
    /// `⌘↩` — send + clear + close (routes to ``ComposerModel/sendDraft()``).
    let onSend: () -> Void
    /// `⌥⌘↩` / queue-mode `↩` — append to the Prompt Queue (``ComposerModel/enqueueDraft()``).
    let onEnqueue: () -> Void
    /// `⎋` — cancel but keep the draft (``ComposerModel/cancel()``).
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
}

// MARK: - Coordinator (shared logic; platform delegate conformance added below)

extension ComposerTextEditor {
    /// Bridges the platform text view to the model: mirrors user edits + caret INTO ``ComposerModel`` and
    /// runs the resolved Return / paste actions. Holds the live `parent` value (refreshed each update) so
    /// `queueMode` and the action closures are always current when a key event fires.
    @MainActor
    final class Coordinator: NSObject {
        var parent: ComposerTextEditor
        weak var textView: ComposerTextView?
        /// Last `focusToken` we acted on, so a re-open (token bump) re-grabs focus exactly once.
        var lastFocusToken = Int.min

        init(_ parent: ComposerTextEditor) { self.parent = parent }

        /// Resolve + perform a Return press. Returns `true` when handled (send/enqueue/cancel); `false`
        /// for `.newline` so the platform text view inserts the newline itself (otty's "Return never sends").
        func handleReturn(command: Bool, option: Bool) -> Bool {
            switch ComposerKeyResolver.resolveReturn(
                command: command,
                option: option,
                queueMode: parent.chrome.queueMode,
            ) {
            case .send: parent.onSend()
                return true
            case .enqueue: parent.onEnqueue()
                return true
            case .cancel: parent.onCancel()
                return true
            case .newline: return false
            }
        }

        /// `⌘V` (rich) / `⇧⌘V` (plain): read the pasteboard, convert, and splice at `range` via the model.
        /// Returns `false` when there was nothing to paste so the caller can fall back to the system paste.
        @discardableResult
        func handlePaste(rich: Bool, range: NSRange) -> Bool {
            ComposerPasteHandler.paste(rich: rich, at: range, into: parent.composer)
        }
    }
}

#endif // os(macOS) || os(iOS)

// MARK: - macOS: NSTextView host

#if os(macOS)

extension ComposerTextEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        // Build the NSTextView-in-NSScrollView by hand (the canonical recipe) so the document view is our
        // paste-overriding ``ComposerTextView`` subclass rather than the one `scrollableTextView()` mints.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = ComposerTextView(frame: .zero, textContainer: container)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.placeholderString = placeholder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = NSColor(Otty.Text.primary)
        textView.insertionPointColor = NSColor(Otty.State.accent)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: Self.insetV)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        // Initial focus — defer one hop (a responder set before the view is in a window is dropped).
        DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        textView.placeholderString = placeholder
        // Sync the view from the model only on an EXTERNAL mutation (paste / editChip / send-clear) — i.e.
        // when the model's draft no longer matches what the view shows. (A user keystroke first updates the
        // view, then mirrors into the model, so the two already agree here → no caret jump.)
        if textView.string != text {
            textView.string = text
            let length = text.utf16.count
            let caret = min(max(composer.selection?.location ?? length, 0), length)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.needsDisplay = true
        }
        // Re-assert focus when the leaf bumps the focus token (re-open of an already-mounted bar).
        if context.coordinator.lastFocusToken != chrome.focusToken {
            context.coordinator.lastFocusToken = chrome.focusToken
            DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context _: Context) -> CGSize? {
        guard let textView = scroll.documentView as? ComposerTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let width = proposal.width ?? textView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let line = layout.defaultLineHeight(for: Self.font)
        let insets = Self.insetV * 2
        let minHeight = line * CGFloat(minLines) + insets
        let maxHeight = line * CGFloat(maxLines) + insets
        let height = min(maxHeight, max(minHeight, ceil(used) + insets))
        return CGSize(width: width, height: height)
    }

    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: Otty.Typeface.body, weight: .regular) }
    static let insetV: CGFloat = 2
}

/// The paste-overriding `NSTextView`. `⌘V` arrives here via the Edit ▸ Paste menu's key-equivalent (which
/// beats any SwiftUI `.onKeyPress`); Return / `⇧⌘V` / `⎋` are caught in `keyDown` and routed through the
/// coordinator. A placeholder is drawn when empty (NSTextView has no native one).
final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerTextEditor.Coordinator?
    var placeholderString = ""

    override func paste(_ sender: Any?) {
        // ⌘V / Edit ▸ Paste → rich HTML/RTF→Markdown convert + caret splice; fall back to the system paste
        // when there is nothing convertible on the pasteboard.
        guard let coordinator, coordinator.handlePaste(rich: true, range: selectedRange()) else {
            super.paste(sender)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        // ⇧⌘V — plain paste (no menu shortcut owns it, so it lands here, not in paste(_:)).
        if flags.contains(.command), flags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "v" {
            if coordinator.handlePaste(rich: false, range: selectedRange()) { return }
        }
        // Return / keypad-Enter — bare ↩/⇧↩ fall through to the editor (newline); ⌘↩ / ⌥⌘↩ / queue-mode-↩
        // are handled (the decision is the PURE resolver).
        if event.keyCode == 36 || event.keyCode == 76 {
            if coordinator.handleReturn(command: flags.contains(.command), option: flags.contains(.option)) { return }
        }
        // ⎋ — cancel (keeps the draft).
        if event.keyCode == 53 {
            coordinator.parent.onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? ComposerTextEditor.font,
            .foregroundColor: NSColor(Otty.Text.tertiary),
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height,
        )
        NSAttributedString(string: placeholderString, attributes: attrs).draw(at: origin)
    }
}

extension ComposerTextEditor.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? ComposerTextView else { return }
        // Mirror the user edit into the model (the source of truth). Programmatic `setString` does NOT fire
        // this, so the model→view sync in updateNSView can't echo back here.
        parent.composer.draft = textView.string
        textView.needsDisplay = true // refresh the placeholder (shown only when empty)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? ComposerTextView else { return }
        // Keep the model's caret current so the no-responder context-menu paste lands at the same point.
        parent.composer.selection = textView.selectedRange()
    }
}

#endif // os(macOS)

// MARK: - iOS: UITextView host

#if os(iOS)

extension ComposerTextEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> ComposerTextView {
        let textView = ComposerTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = UIColor(Otty.Text.primary)
        textView.tintColor = UIColor(Otty.State.accent)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true // grow-then-scroll past maxLines (height is clamped in sizeThatFits)
        textView.textContainerInset = UIEdgeInsets(top: Self.insetV, left: 0, bottom: Self.insetV, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .default
        textView.text = text
        textView.installPlaceholder(placeholder)
        context.coordinator.textView = textView
        DispatchQueue.main.async { [weak textView] in textView?.becomeFirstResponder() }
        return textView
    }

    func updateUIView(_ textView: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        textView.placeholderLabel?.text = placeholder
        if textView.text != text {
            textView.text = text
            let length = text.utf16.count
            let caret = min(max(composer.selection?.location ?? length, 0), length)
            textView.selectedRange = NSRange(location: caret, length: 0)
            textView.refreshPlaceholder()
        }
        if context.coordinator.lastFocusToken != chrome.focusToken {
            context.coordinator.lastFocusToken = chrome.focusToken
            DispatchQueue.main.async { [weak textView] in textView?.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: ComposerTextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? textView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fit = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let line = Self.font.lineHeight
        let insets = Self.insetV * 2
        let minHeight = line * CGFloat(minLines) + insets
        let maxHeight = line * CGFloat(maxLines) + insets
        let height = min(maxHeight, max(minHeight, fit.height))
        return CGSize(width: width, height: height)
    }

    static var font: UIFont { UIFont.monospacedSystemFont(ofSize: Otty.Typeface.body, weight: .regular) }
    static let insetV: CGFloat = 4
}

/// The paste-overriding `UITextView`. `⌘V` (hardware keyboard / edit menu) routes into `paste(_:)`; the
/// hardware-keyboard `⌘↩` / `⌥⌘↩` / `⇧⌘V` / `⎋` chords are `UIKeyCommand`s; bare/queue-mode Return is
/// resolved in the delegate's `shouldChangeText`. A placeholder label shows when empty.
final class ComposerTextView: UITextView {
    weak var coordinator: ComposerTextEditor.Coordinator?
    private(set) var placeholderLabel: UILabel?

    func installPlaceholder(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = UIColor(Otty.Text.tertiary)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textContainerInset.left),
        ])
        placeholderLabel = label
        refreshPlaceholder()
    }

    func refreshPlaceholder() { placeholderLabel?.isHidden = !text.isEmpty }

    override func paste(_ sender: Any?) {
        guard let coordinator, coordinator.handlePaste(rich: true, range: selectedRange) else {
            super.paste(sender)
            return
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Keep the system Paste enabled whenever the pasteboard holds something convertible, so the
        // edit-menu Paste and the hardware ⌘V both route into our paste(_:) override.
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            return pb.hasStrings || pb.hasImages || pb.hasURLs
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(composerSend)),
            UIKeyCommand(input: "\r", modifierFlags: [.command, .alternate], action: #selector(composerEnqueue)),
            UIKeyCommand(input: "v", modifierFlags: [.command, .shift], action: #selector(composerPastePlain)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(composerCancel)),
        ]
    }

    @objc
    private func composerSend() { coordinator?.parent.onSend() }
    @objc
    private func composerEnqueue() { coordinator?.parent.onEnqueue() }
    @objc
    private func composerCancel() { coordinator?.parent.onCancel() }
    @objc
    private func composerPastePlain() {
        coordinator?.handlePaste(rich: false, range: selectedRange)
    }
}

extension ComposerTextEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        parent.composer.draft = textView.text
        (textView as? ComposerTextView)?.refreshPlaceholder()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        parent.composer.selection = textView.selectedRange
    }

    func textView(_: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
        // Bare Return in Prompt-Queue input mode enqueues the line instead of inserting a newline (otty's
        // `⌘⇧M` bar). Normal mode → allow the newline (Return never sends). ⌘↩ never reaches here (it's a
        // key command), so this only governs the soft/hardware bare Return.
        guard text == "\n", parent.chrome.queueMode else { return true }
        parent.onEnqueue()
        return false
    }
}

#endif // os(iOS)
#endif // canImport(SwiftUI)
