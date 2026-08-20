// MacGuiPaneOverlays — the four decorations over a live remote-window pane, in AppKit
// (docs/56 wave R, batch R10).
//
// The AppKit halves of `StreamStallCaption`, `PasteFeedbackBanner`, `FileDropHighlight` and
// `FileUploadOverlay`. All four are pure decoration over the video surface: none of them decides
// anything, and every string, glyph and semantic tone they draw is already answered by
// ``GuiPaneReadout`` in `SlopDeskClientCore`. That is why this file is short relative to the SwiftUI
// original — the branch stayed where it was and only the drawing crossed.
//
// NON-HIT-TESTING EXCEPT THE BANNER. The caption, the drop highlight and the upload stack are readouts
// over a surface that must take every keystroke and every pointer event, so they return `nil` from
// `hitTest`. The paste banner is the one that is genuinely a control — it is a dismiss target — so it
// keeps its tracking area and its click. Getting this backwards is not cosmetic on this particular
// surface: a decoration that swallows a click over a remote desktop sends the user's click nowhere.
//
// WHY A TIMER AND NOT A `TimelineView`. The stall caption counts up from the moment the stream stalled,
// so the SwiftUI half rides `TimelineView(.periodic(by: 1))`. AppKit has no such thing; the equivalent
// is a 1 Hz repeating timer that re-reads the SAME `GuiPaneReadout.stallCaption(since:now:)`. It is
// created on show and invalidated on hide rather than living for the view's lifetime, because a stalled
// stream is the one state where a pane is doing nothing and a per-second wakeup per hidden pane is pure
// cost.

import AppKit
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore

// MARK: - A stack that is scenery

/// An `NSStackView` that refuses the pointer, so the control it sits inside is what a click finds.
///
/// SwiftUI has no need for this: a `Button`'s label is scenery by construction, and the button owns the
/// whole hit area. AppKit inverts that — an `NSTextField` label and an `NSImageView` inside an
/// `NSButton` are real views that hit-test before their ancestor does, so the top half of a banner is
/// clickable and the words in the middle of it are not. Refusing here restores the SwiftUI meaning
/// rather than inventing a new one, and it must be `hitTest` rather than a disabled flag, because a
/// disabled control also draws itself dimmed.
@MainActor
final class MacPassthroughStack: NSStackView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

// MARK: - The stall caption

/// "Stalled 12s" over a spinner — the stream is up but no frame has arrived.
///
/// The age is recomputed rather than incremented, so a caption that is hidden and shown again is
/// correct immediately instead of resuming from a counter that stopped.
@MainActor
final class MacStreamStallCaption: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var since: Date?
    private var ticker: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.backgroundColor = Slate.Native.Surface.ground
            .slateScalingAlpha(Slate.Opacity.scrim).cgColor

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A readout, never a target — the surface underneath takes the pointer.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Slate.Native.Surface.ground
            .slateScalingAlpha(Slate.Opacity.scrim).cgColor
    }

    /// Show the caption counting from `since`, or hide it and stop the clock.
    ///
    /// The epoch is the model's ``RemoteWindowModel/streamStalledAt``, not the moment this was called,
    /// so a caption mounted late still reports the true age of the stall.
    func present(since epoch: Date?) {
        since = epoch
        guard epoch != nil else {
            stop()
            isHidden = true
            return
        }
        isHidden = false
        spinner.startAnimation(nil)
        refresh()
        guard ticker == nil else { return }
        // `.common` so the count keeps moving during a divider drag or a menu tracking loop — the
        // moments a user is most likely to be staring at a stalled pane wondering if it is dead.
        // SELF-INVALIDATING, and that is not belt-and-braces. A repeating `Timer` on the run loop is
        // retained BY the run loop, so `[weak self]` stops it touching a dead view but does nothing to
        // stop it firing — it would tick once a second for the life of the process. `deinit` cannot
        // clean it up either: this class is `@MainActor` and a `deinit` is nonisolated, so it may not
        // even read the stored timer. Handing the timer its own handle is what closes both.
        // The invalidation happens OUTSIDE `assumeIsolated`, and it has to: `Timer` is not `Sendable`,
        // so the handle cannot cross into a main-actor region, while the block itself already runs
        // wherever the run loop calls it. So the isolated part answers one question — is the view still
        // there — and the unisolated part acts on the answer.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            var alive = false
            MainActor.assumeIsolated {
                if let self {
                    self.refresh()
                    alive = true
                }
            }
            if !alive { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Leaving the hierarchy stops the clock, the same teardown hook every other AppKit surface in this
    /// target uses. The self-invalidation above is the backstop for a view released without ever having
    /// been in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        spinner.stopAnimation(nil)
    }

    private func refresh() {
        label.attributedStringValue = macInstrumentString(
            GuiPaneReadout.stallCaption(since: since, now: Date()),
            color: Slate.Native.Text.primary,
        )
    }
}

// MARK: - The paste result banner

/// "Typed 41, skipped 3 unmapped" — shown only when a clipboard paste dropped characters that have no
/// US-QWERTY mapping, so the user learns the paste was incomplete rather than silently wrong.
///
/// The whole pill is the dismiss target. It is a `Button` in the SwiftUI half and an `NSButton` here for
/// the same reason: this is the one decoration in the file a click is *for*.
@MainActor
final class MacPasteFeedbackBanner: NSButton {
    private let onDismiss: () -> Void

    init(feedback: RemoteWindowModel.PasteFeedback, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.borderWidth = Slate.Metric.hairline
        paint()
        toolTip = "Dismiss"
        target = self
        action = #selector(dismissTapped)

        let glyph = NSImageView()
        glyph.image = NSImage(
            systemSymbolName: SFSymbol.exclamationmarkTriangle.rawValue, accessibilityDescription: nil,
        )
        glyph.contentTintColor = Slate.Native.accent

        let text = NSTextField(
            labelWithString: "Typed \(feedback.typed), skipped \(feedback.skipped) unmapped",
        )
        text.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        text.textColor = Slate.Native.Text.primary

        let row = MacPassthroughStack(views: [glyph, text])
        row.orientation = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = Slate.Native.Surface.face.cgColor
        layer?.borderColor = Slate.Native.Line.divider.cgColor
    }

    @objc
    private func dismissTapped() { onDismiss() }
}

// MARK: - The file-drop highlight

/// An accent inset border while a file is dragged over a live desktop pane — the remote side will
/// accept the drop as an upload.
///
/// NO VEIL, deliberately: the stream stays fully visible and only the frame lights. A drop target that
/// dims what it is over is telling the user the content is unavailable, which is the opposite of true
/// here.
@MainActor
final class MacFileDropHighlight: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.borderWidth = Self.rim
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The drag is tracked by the pane's own drop receiver, so this must not intercept it.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() { layer?.borderColor = Slate.Native.accent.cgColor }

    /// Two points, matching the SwiftUI half's `lineWidth: 2`. Heavier than a hairline on purpose — it
    /// has to read as a state over arbitrary video content, not as a rule.
    private static let rim: CGFloat = 2

    /// The inset the SwiftUI half spends as `.padding(Slate.Metric.space2)`; the mounting view applies
    /// it, so it is published rather than baked into a frame here.
    static let inset = Slate.Metric.space2
}

// MARK: - The upload stack

/// One row per in-flight or just-settled drag-drop upload: a state glyph, a name, and either a progress
/// bar or the failure reason.
///
/// The rows are rebuilt wholesale on each update rather than diffed. The list is bounded by what a user
/// can drag at once and each row is three views, so a diff would cost more to read than it saves — and
/// a rebuild cannot leave a stale row behind, which is the failure that actually matters for a readout
/// whose whole job is to say what is happening right now.
@MainActor
final class MacFileUploadOverlay: NSView {
    private let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        paint()

        column.orientation = .vertical
        column.spacing = Slate.Metric.space1
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A readout over a surface that takes every event.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = Slate.Native.Surface.ground
            .slateScalingAlpha(Slate.Opacity.scrim).cgColor
    }

    /// The SwiftUI half's `.frame(maxWidth: 320)` — a name is truncated in the MIDDLE rather than
    /// letting the stack grow across the pane, because the tail of a path is what identifies a file.
    private static let maxWidth: CGFloat = 320

    func present(_ uploads: [FileUploadProgress]) {
        isHidden = uploads.isEmpty
        for stale in column.arrangedSubviews { stale.removeFromSuperview() }
        for upload in uploads { column.addArrangedSubview(row(upload)) }
    }

    private func row(_ upload: FileUploadProgress) -> NSView {
        let glyph = NSImageView()
        glyph.image = NSImage(
            systemSymbolName: GuiPaneReadout.uploadGlyph(upload.phase), accessibilityDescription: nil,
        )?.withSymbolConfiguration(.init(pointSize: Slate.Typeface.small, weight: .semibold))
        glyph.contentTintColor = tint(upload.phase)

        let name = NSTextField(labelWithString: upload.name)
        name.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        name.textColor = Slate.Native.Text.primary
        name.lineBreakMode = .byTruncatingMiddle
        name.usesSingleLineMode = true

        let detail: NSView
        if upload.phase == .failed {
            let reason = NSTextField(labelWithString: upload.reason ?? "failed")
            reason.font = .systemFont(ofSize: Slate.Typeface.small)
            reason.textColor = Slate.Native.Text.secondary
            reason.lineBreakMode = .byTruncatingTail
            reason.usesSingleLineMode = true
            detail = reason
        } else {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = upload.fraction
            bar.controlSize = .small
            detail = bar
        }

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.spacing = 2
        text.alignment = .leading

        let row = NSStackView(views: [glyph, text])
        row.orientation = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .centerY
        return row
    }

    /// The row's tone, looked up from the SEMANTIC ``GuiUploadTint``: the branch is
    /// ``GuiPaneReadout/uploadTint(_:)``'s and the token is this framework's. Only the part that could
    /// ever be wrong crosses — the same split the SwiftUI half makes, for the same reason a colour
    /// cannot descend below the token floor.
    private func tint(_ phase: FileUploadProgress.Phase) -> NSColor {
        switch GuiPaneReadout.uploadTint(phase) {
        case .icon: Slate.Native.Text.icon
        case .accent: Slate.Native.accent
        }
    }
}
