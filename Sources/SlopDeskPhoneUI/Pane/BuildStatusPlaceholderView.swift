// BuildStatusPlaceholderView — the HEADLESS terminal-renderer fallback, in UIKit
// (docs/62, the pane-leaf cluster).
//
// The UIKit half of what ``SlopDeskMacUI/MacBuildStatusPlaceholderView`` draws on the Mac. libghostty IS
// the renderer (DECISIONS / doc 17), and it is injected by the Xcode app target through
// ``TerminalRendererFactory`` — so a plain `swift build`, which never compiles the embedder, has no
// renderer to mount. Rather than leave the leaf's pixel slot empty and make "the terminal is blank" mean
// two unrelated things, the leaf mounts THIS: build-status telemetry drawn over the pane's own paper.
//
// It reads only what a headless process can answer — the connection status and the byte count off
// ``TerminalViewModel`` — and never attaches a surface, so it is safe in tests and previews. That is the
// whole reason it can exist in a target that must not link Metal or libghostty.
//
// ⚠️ A `UIView`, and the SwiftUI shape it replaces is DELETED rather than kept beside it. The old
// `BuildStatusPlaceholderView: TerminalRenderingView` conformed to a seam typed in SwiftUI, which is
// exactly what ``TerminalRendererSeam``'s header records as removed: mounting it put a hosting view
// between the canvas and the one surface that must take every keystroke, and the fallback is not exempt
// from that — it occupies the same slot, and a developer typing into a pane that is *showing them why
// there is no renderer* is the least helpful moment for input to disappear.
//
// SAME RUNGS AS THE MAC, INCLUDING THE ONE WORTH FLAGGING. This panel paints its text with the CHROME
// ink ladder (``Slate/Native/Text/primary`` / `.secondary`) and its live dot with the CHROME green
// (``Slate/Native/Status/ok``), even though it sits on the terminal's glass, which has an on-glass
// vocabulary of its own (``Slate/Native/Terminal``). That may well be worth revisiting, but not HERE:
// the Mac half stands, so picking different inks would turn a debatable choice into a real
// cross-platform divergence in the one panel a developer looks at when something is already wrong.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore // BuildStatusPlaceholderCopy — the hint is spelled once, in the floor
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

/// The headless build-status panel for a terminal pane, as a `UIView` the leaf can mount directly in its
/// pixel slot.
@MainActor
final class BuildStatusPlaceholderView: UIView {
    private let model: TerminalViewModel

    /// The live dot and the status caption, kept as fields because they are the only two things that
    /// change after construction — everything else in this panel is a constant string.
    private let dot = UIView()
    private let caption = UILabel()

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        // A view's `backgroundColor` holds the dynamic `UIColor` itself and re-resolves on an appearance
        // flip without anyone asking — which is why this panel needs no trait registration at all, where
        // the Mac's `updateLayer` had to re-derive a `CGColor`. `Surface.terminal` is a computed rung off
        // the live theme, so it is re-read whenever the theme moves the pane under us.
        backgroundColor = Slate.Native.Surface.terminal
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The paper is theme-directed, and the theme is not a trait — a profile switch changes
    /// `Surface.terminal` without any UIKit appearance moving. The leaf re-mounts this panel on a theme
    /// change, so this only has to cover the case where the panel outlives one.
    func repaper() {
        backgroundColor = Slate.Native.Surface.terminal
    }

    // MARK: - The panel

    private func build() {
        let glyph = UIImageView(
            image: UIImage(
                systemName: SFSymbol.appleTerminal.rawValue,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Slate.Typeface.display, weight: .regular,
                ),
            ),
        )
        glyph.tintColor = Slate.Native.Text.secondary
        glyph.contentMode = .center

        let title = UILabel()
        title.text = "terminal"
        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        title.textColor = Slate.Native.Text.primary

        // The one actionable line in the panel, and the reason the panel exists rather than a blank pane:
        // it names the script that produces the renderer. Spelled in the floor, because the path in it
        // moves whenever that script does.
        let hint = UILabel()
        hint.text = BuildStatusPlaceholderCopy.buildHint
        hint.font = .systemFont(ofSize: Slate.Typeface.footnote)
        hint.textColor = Slate.Native.Text.secondary
        hint.textAlignment = .center
        hint.numberOfLines = 0

        dot.layer.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])

        caption.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .regular)
        caption.textColor = Slate.Native.Text.secondary

        let statusLine = UIStackView(arrangedSubviews: [dot, caption])
        statusLine.axis = .horizontal
        statusLine.spacing = 6
        statusLine.alignment = .center

        let column = UIStackView(arrangedSubviews: [glyph, title, hint, statusLine])
        column.axis = .vertical
        column.spacing = 12
        column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // Centred, and inset far enough that the sentence never touches the pane edge at the smallest leaf
        // the canvas allows. `lessThanOrEqualTo` on the sides rather than a fixed width so a narrow pane
        // shrinks the text block instead of clipping it — a phone pane is narrow far more often than a
        // window is, so the sentence wraps to three or four lines rather than two and that is correct.
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Self.sideClearance,
            ),
            column.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.sideClearance,
            ),
        ])
    }

    /// The live dot's diameter. Spelled here rather than in `Slate` because it is this panel's own
    /// punctuation — no other surface draws it, and a token nothing else reads is a token that only makes
    /// the ladder harder to scan.
    private static let dotDiameter: CGFloat = 7

    /// How far the sentence stays off the pane's edges. Not a spacing rung and not a pane inset: this is
    /// a READING measure — the width the paragraph is allowed to reach before it starts touching the
    /// glass — and the Mac twin (``SlopDeskMacUI/MacBuildStatusPlaceholderView``) holds the same 24, so
    /// the one panel a developer meets when something is already wrong reads identically on both.
    private static let sideClearance: CGFloat = 24

    // MARK: - Following the model

    /// Re-reads the two fields that can change and re-arms. `connectionStatus` and `bytesReceived` are the
    /// ONLY things this panel observes — deliberately, since a headless process has nothing else to say,
    /// and observing anything richer would make the fallback more expensive than the renderer it stands in
    /// for.
    private func follow() {
        ObservationFollow.arm(self) { panel in
            (status: panel.model.connectionStatus, bytes: panel.model.bytesReceived)
        } apply: { panel, reading in
            panel.apply(status: reading.status, bytes: reading.bytes)
        }
    }

    private func apply(status: TerminalViewModel.ConnectionStatus?, bytes: Int) {
        let live = status?.isLive ?? false
        // The dot is a plain view fill, not a layer colour: `backgroundColor` keeps the dynamic `UIColor`
        // and follows the appearance by itself, where a `CGColor` would be frozen at the appearance it was
        // assigned in.
        dot.backgroundColor = live ? Slate.Native.Status.ok : Slate.Native.Text.secondary
        caption.text = "\(status?.label ?? "—") · \(bytes) bytes"
    }
}
#endif
