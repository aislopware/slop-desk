// MacBuildStatusPlaceholderView — the HEADLESS terminal-renderer fallback, in AppKit
// (docs/56 wave R, batch R9).
//
// The AppKit half of ``BuildStatusPlaceholderView``. libghostty IS the renderer (DECISIONS / doc 17),
// and it is injected by the Xcode app target through `TerminalRendererFactory` — so a plain
// `swift build`, which never compiles the embedder, has no renderer to mount. Rather than leave the
// leaf's pixel slot empty and make "the terminal is blank" mean two unrelated things, the leaf mounts
// THIS: build-status telemetry drawn over the pane's own paper.
//
// It reads only what a headless process can answer — the connection status and the byte count off
// ``TerminalViewModel`` — and never attaches a surface, so it is safe in tests and previews. That is
// the whole reason it can exist in a target that must not link Metal or libghostty.
//
// PORTED FAITHFULLY, INCLUDING ONE THING WORTH FLAGGING. The SwiftUI half paints its text with the
// CHROME ink ladder (`Slate.Text.primary` / `.secondary`) and its live dot with the CHROME green
// (`Slate.Status.ok`), even though the panel sits on the terminal's glass, which has an on-glass
// vocabulary of its own (``Slate/Native/Terminal`` — `ink`, `ink2`, `ok`, straight off the profile).
// That may well be worth revisiting, but not HERE: the SwiftUI half stays standing until the fold, so
// picking different inks would turn a debatable choice into a real cross-renderer divergence in the
// one panel a developer looks at when something is already wrong. Same rungs, both halves; if the
// ladder is wrong it is wrong in one place and moves in one change.

import AppKit
import SFSafeSymbols
import SlopDeskSlate
import SlopDeskWorkspaceCore

/// The headless build-status panel for a terminal pane, as an `NSView` the leaf can mount directly
/// in its pixel slot.
///
/// An `NSView` rather than a hosted `some View` because the leaf's pixel slot is the one surface that
/// must take every keystroke: an `NSHostingView` there claims the hit-test over it, which is the exact
/// full-bleed hit-claim stage D spent five increments removing. The fallback is not exempt from that —
/// it occupies the same slot, and a developer typing into a pane that is *showing them why there is no
/// renderer* is the least helpful moment for input to disappear.
@MainActor
final class MacBuildStatusPlaceholderView: NSView {
    private let model: TerminalViewModel

    /// The live dot and the status caption, kept as fields because they are the only two things that
    /// change after construction — everything else in this panel is a constant string.
    private let dot = NSView()
    private let caption = NSTextField(labelWithString: "")

    /// Guards the observation re-arm against a stale `onChange` firing after this view is gone. Every
    /// AppKit surface in this target carries one; see the idiom in ``MacTerminalLeafView``.
    private var generation = 0

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The paper is theme-directed, so an appearance change re-resolves it. Nothing else here moves:
    /// the inks below are `NSColor`s held by their labels, which re-resolve themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
    }

    // MARK: - The panel

    private func build() {
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: SFSymbol.appleTerminal.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Slate.Typeface.display, weight: .regular))
        glyph.contentTintColor = Slate.Native.Text.secondary

        let title = NSTextField(labelWithString: "terminal")
        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        title.textColor = Slate.Native.Text.primary

        // The one actionable line in the panel, and the reason the panel exists rather than a blank
        // pane: it names the script that produces the renderer.
        let hint = NSTextField(
            wrappingLabelWithString:
            "Run ThirdParty/ghostty/build-libghostty.sh — the headless build renders this panel.",
        )
        hint.font = .systemFont(ofSize: Slate.Typeface.footnote)
        hint.textColor = Slate.Native.Text.secondary
        hint.alignment = .center
        hint.isSelectable = false
        // A wrapping label with no width preference stretches to the pane; 320 is where the sentence
        // breaks into two balanced lines at the footnote rung, which is what the SwiftUI half's
        // `.multilineTextAlignment(.center)` gets from its `VStack`'s natural width.
        hint.preferredMaxLayoutWidth = 320

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])

        caption.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .regular)
        caption.textColor = Slate.Native.Text.secondary

        let statusLine = NSStackView(views: [dot, caption])
        statusLine.orientation = .horizontal
        statusLine.spacing = 6
        statusLine.alignment = .centerY

        let column = NSStackView(views: [glyph, title, hint, statusLine])
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // Centred, and inset far enough that the sentence never touches the pane edge at the smallest
        // leaf the canvas allows. `lessThanOrEqualTo` on the sides rather than a fixed width so a
        // narrow pane shrinks the text block instead of clipping it.
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    /// The live dot's diameter. Spelled here rather than in `Slate` because it is this panel's own
    /// punctuation — no other surface draws it, and a token nothing else reads is a token that only
    /// makes the ladder harder to scan.
    private static let dotDiameter: CGFloat = 7

    // MARK: - Following the model

    /// Re-reads the two fields that can change and re-arms. `connectionStatus` and `bytesReceived` are
    /// the ONLY things this panel observes — deliberately, since a headless process has nothing else to
    /// say, and observing the byte stream itself would make the fallback more expensive than the
    /// renderer it stands in for.
    private func follow() {
        generation &+= 1
        let token = generation
        var status: TerminalViewModel.ConnectionStatus?
        var bytes = 0
        withObservationTracking {
            status = model.connectionStatus
            bytes = model.bytesReceived
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.follow()
                }
            }
        }
        apply(status: status, bytes: bytes)
    }

    private func apply(status: TerminalViewModel.ConnectionStatus?, bytes: Int) {
        let live = status?.isLive ?? false
        dot.layer?.backgroundColor = (live ? Slate.Native.Status.ok : Slate.Native.Text.secondary).cgColor
        caption.stringValue = "\(status?.label ?? "—") · \(bytes) bytes"
    }
}
