// MacFirstLaunchSheet — the guided first-launch checklist, in AppKit.
//
// A real sheet on the workspace window (`beginSheet`), not a SwiftUI `.sheet`: the flow is four cards
// and two buttons, and what it needed from SwiftUI was presentation, which AppKit gives directly on the
// window the sheet belongs to.
//
// EVERYTHING THIS DRAWS IS `FirstLaunchModel`'s. The step set, the order, the "Step N of M", each step's
// title, subtitle and glyph, which step is first and which is last — all of it comes off the pure model
// in `SlopDeskWorkspaceCore`, which is also what drops the two macOS-only steps for the phone. So this
// file names no step and no wording, and the phone's `FirstLaunchView` renders the same model.
//
// TWO OF THE FOUR STEPS ARE THE MAC'S ALONE, and they are drawn here in AppKit: registering as the
// default terminal and putting `slopdesk` on the PATH are LaunchServices and `/usr/local/bin`, which the
// phone has no version of. The other two exist on both platforms, so they are drawn ONCE in SwiftUI
// (`FirstLaunchStepSurface`) and hosted — the same division the settings page makes between a control
// kind, which each half draws its own way, and a surface, which there is nothing to differ about.
//
// A REBUILD IS THE UPDATE: `FirstLaunchModel` is `@Observable`, and every mutation here goes through a
// button in this file, so the button rebuilds. There is no second writer to miss.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // FirstLaunchStepSurface — the checklist steps, drawn once
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SwiftUI

/// Presents the guided first-launch sheet over the workspace window.
@preconcurrency
@MainActor
public final class MacFirstLaunchSheet: NSObject, NSWindowDelegate {
    private let model: FirstLaunchModel
    private let agentHooks: AgentHooksController?
    private var sheet: NSWindow?

    public init(model: FirstLaunchModel, agentHooks: AgentHooksController? = nil) {
        self.model = model
        self.agentHooks = agentHooks
    }

    /// Show the checklist over `host`, or do nothing if it is already up.
    public func present(over host: NSWindow) {
        guard sheet == nil else { return }
        let content = MacFirstLaunchController(model: model, agentHooks: agentHooks) { [weak self] in
            self?.dismiss()
        }
        let created = NSWindow(contentViewController: content)
        created.styleMask = [.titled, .fullSizeContentView]
        created.setContentSize(NSSize(width: 540, height: 580))
        sheet = created
        host.beginSheet(created) { [weak self] _ in
            // ANY path out of the sheet completes first launch — Done, Skip Setup, or the window going
            // away underneath it. The flag is a single `Defaults` write and `finish()` is idempotent, so
            // there is no path that leaves the checklist to re-present tomorrow.
            self?.model.finish()
            self?.sheet = nil
        }
    }

    private func dismiss() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}

// MARK: - The sheet's content

/// The checklist shell: a header (glyph + "Step N of M" + title/subtitle), the step's body, and a footer
/// (Back · progress dots · Skip Setup · Next/Done).
@MainActor
final class MacFirstLaunchController: NSViewController {
    private let model: FirstLaunchModel
    private let agentHooks: AgentHooksController?
    private let onDismiss: () -> Void

    private let glyph = NSImageView()
    private let counter = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let bodyArea = NSStackView()
    private let footer = NSStackView()

    init(model: FirstLaunchModel, agentHooks: AgentHooksController?, onDismiss: @escaping () -> Void) {
        self.model = model
        self.agentHooks = agentHooks
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        counter.font = .preferredFont(forTextStyle: .caption1)
        counter.textColor = Slate.Native.Text.tertiary
        headline.font = .preferredFont(forTextStyle: .headline)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = Slate.Native.Text.secondary
        subtitle.isSelectable = false

        let words = NSStackView(views: [counter, headline, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Slate.Metric.space1

        glyph.contentTintColor = Slate.Native.accent
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 44).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let header = NSStackView(views: [glyph, words])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = Slate.Metric.space3
        header.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )

        bodyArea.orientation = .vertical
        bodyArea.alignment = .leading
        bodyArea.spacing = Slate.Metric.space3
        bodyArea.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )
        let scroll = NSScrollView()
        scroll.documentView = bodyArea
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        bodyArea.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bodyArea.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            bodyArea.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            bodyArea.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Slate.Metric.space2
        footer.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space3, left: Slate.Metric.space4,
            bottom: Slate.Metric.space3, right: Slate.Metric.space4,
        )

        let column = NSStackView(views: [header, rule(), scroll, rule(), footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setHuggingPriority(.defaultLow, for: .vertical)
        for band in [header, footer] {
            band.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        view = column
        rebuild()
    }

    // MARK: Building

    private func rebuild() {
        let step = model.currentStep
        glyph.image = NSImage(systemSymbolName: step.systemImage, accessibilityDescription: nil)
        counter.stringValue = "Step \(model.stepNumber) of \(model.stepCount)"
        headline.stringValue = step.title
        subtitle.stringValue = step.subtitle

        replace(bodyArea, with: [card(for: step)])
        replace(footer, with: footerControls())
    }

    /// One step's body, in a card.
    ///
    /// The two macOS-only steps are AppKit here; the two cross-platform ones are the SwiftUI surface both
    /// platforms show, hosted. A step this build has no body for draws nothing rather than an empty card.
    private func card(for step: FirstLaunchStep) -> NSView {
        let inner: NSView =
            switch step {
            case .defaultTerminal: MacOSIntegrationRows { [model] in model.markComplete(.defaultTerminal) }
            case .installCLI: MacCLIInstallCard { [model] in model.markComplete(.installCLI) }
            case .onLaunch,
                 .installClaudeHooks:
                hosted(step)
            }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Slate.Metric.radiusCard
        card.layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
        card.layer?.borderWidth = Slate.Metric.hairline
        card.layer?.borderColor = Slate.Native.Line.card.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        let pad = Slate.Metric.space4
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
        ])
        card.widthAnchor.constraint(equalTo: bodyArea.widthAnchor).isActive = true
        return card
    }

    private func hosted(_ step: FirstLaunchStep) -> NSView {
        let host = NSHostingView(
            rootView: FirstLaunchStepSurface(step: step, model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
                .agentHooksController(agentHooks),
        )
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    private func footerControls() -> [NSView] {
        var controls: [NSView] = []
        if !model.isFirstStep {
            controls.append(MacActionButton(title: "Back") { [weak self] in
                self?.model.back()
                self?.rebuild()
            })
        }
        controls.append(NSView())
        controls.append(dots())
        controls.append(NSView())

        let skip = MacActionButton(title: "Skip Setup") { [weak self] in self?.onDismiss() }
        skip.isBordered = false
        skip.contentTintColor = Slate.Native.Text.secondary
        controls.append(skip)

        if model.isLastStep {
            let done = MacActionButton(title: "Done") { [weak self] in self?.onDismiss() }
            done.keyEquivalent = "\r"
            done.bezelStyle = .rounded
            controls.append(done)
        } else {
            let next = MacActionButton(title: "Next") { [weak self] in
                self?.model.advance()
                self?.rebuild()
            }
            next.keyEquivalent = "\r"
            next.bezelStyle = .rounded
            controls.append(next)
        }
        return controls
    }

    /// The progress dots — one per step, the current one filled.
    private func dots() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Slate.Metric.space1
        for position in model.steps.indices {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = position == model.index
                ? Slate.Native.accent.cgColor
                : Slate.Native.Line.subtle.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            row.addArrangedSubview(dot)
        }
        return row
    }

    private func replace(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views { stack.addArrangedSubview(view) }
    }

    private func rule() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
