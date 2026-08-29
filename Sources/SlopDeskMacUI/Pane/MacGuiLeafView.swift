// MacGuiLeafView — the remote-window (PATH 2) pane leaf, in AppKit: the video parallel of
// ``MacTerminalLeafView`` and the third of docs/56 batch R10's three files.
//
// THE LEAF IS ``GuiLeafCore``; THIS FILE IS ITS PIXELS. Everything that is not drawing — the seam's
// session, the cap-enforced activation lifecycle, the three gates, the immersive tap, the drop's
// routing and the whole tracked read — is in the floor and shared with the phone's `GuiLeafView`,
// which is the same leaf in UIKit. What is left here is the seven pieces of chrome drawn over the
// stream, where they sit, and how they fade. The DECISIONS were always somewhere else and are
// unchanged: `RemoteGUIDisplay.resolve` picks live / entry-form / cap-gated, `GuiPaneReadout` owns
// every gate and string, `GuiPaneUploads` routes a drop, and `PaneImmersiveCapture` owns the tap.
//
// THE ONE THING SWIFTUI DID FOR FREE THAT STILL SHOWS HERE: an AppKit canvas has no render pass, so
// the chrome is PUSHED. `GuiLeafCore.read()` gathers one `GuiLeafChrome` per pass and
// ``applyChrome(_:)`` paints it — never half of one update and half of the next.
//
// EDGE-TO-EDGE, unlike the terminal leaf's inset: every point of a video pane is remote pixels, so a
// gutter here is wasted stream area rather than a reading margin. The chrome floats over it.

import AppKit
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The leaf

@MainActor
final class MacGuiLeafView: NSView {
    // MARK: What the leaf was handed

    private let core: GuiLeafCore

    // MARK: The pixels

    /// Shows through whenever no surface is mounted. The seam's view goes in above it.
    private let placeholder = MacGuiPlaceholderView()

    // MARK: The chrome — every piece STANDING, hidden rather than absent

    private let controlBar = MacGuiPaneControlBar()
    private let collapsedChip = MacGuiCollapsedControlsChip()
    private let stallCaption = MacStreamStallCaption()
    private let statsReadout = MacGuiStatsReadout()
    private let uploadOverlay = MacFileUploadOverlay()
    private let dropHighlight = MacFileDropHighlight()
    private let readOnlyPill: MacPaneStatusPillView
    /// The ONE piece that is rebuilt: its copy is baked in at init, and it is transient by design.
    private var pasteBanner: MacPasteFeedbackBanner?
    /// The paste banner clears the control bar when the bar is expanded, so this constant moves.
    private var pasteBannerBottom: NSLayoutConstraint?

    /// The live follow. Stored for BOTH reasons the handle exists: ``follow()`` is re-entered from
    /// every core edge, so each arm must displace the last, and ``stopFollowing()`` ends the
    /// following while this leaf lives on waiting to be re-attached.
    private var leafFollow: ObservationFollow?

    // MARK: - Life

    init(live: LivePaneSession?, isFocused: Bool, isVisible: Bool, store: WorkspaceStore, paneID: PaneID) {
        core = GuiLeafCore(live: live, isFocused: isFocused, isVisible: isVisible, store: store, paneID: paneID)
        readOnlyPill = MacPaneStatusPillView(pill: .readOnly) { store.setPaneReadOnly(paneID, false) }
        super.init(frame: .zero)
        build()
        core.start(host: self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        paint()
        registerForDraggedTypes([.fileURL])

        core.wireControls(bar: controlBar, chip: collapsedChip)

        // THE WHOLE MOUNT is ``GuiLeafChromeLayout``'s: z-order, which corner each overlay takes, and
        // the two rungs the corners sit at. All three are readings of what is free rather than
        // framework spellings, and they were twenty-eight character-identical lines in both shells
        // until they went down. What stays here is the one word that genuinely differs — how AppKit
        // takes an overlay out of the picture.
        NSLayoutConstraint.activate(GuiLeafChromeLayout.mount(
            in: self,
            placeholder: placeholder,
            overlays: GuiLeafChromeLayout.Overlays(
                controlBar: controlBar,
                collapsedChip: collapsedChip,
                stallCaption: stallCaption,
                statsReadout: statsReadout,
                uploadOverlay: uploadOverlay,
                readOnlyPill: readOnlyPill,
            ),
            dropHighlight: dropHighlight,
            conceal: { overlay in
                overlay.alphaValue = 0
                overlay.isHidden = true
            },
        ))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { paint() }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Attach / detach

    /// The AppKit spelling of `.onAppear` / `.onDisappear`. Only the OBSERVATION rides the view
    /// tree — the cap slot does not, and ``GuiLeafCore/detach()`` records why.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, superview == nil {
            core.detach()
        } else if window != nil {
            core.attach()
        }
    }

    /// The pane is closed for good.
    func teardown() { core.teardown() }

    // MARK: - What the mounter pushes

    func setLive(_ live: LivePaneSession?) { core.setLive(live) }

    func setFocused(_ isFocused: Bool) { core.setFocused(isFocused) }

    func setVisible(_ isVisible: Bool) { core.setVisible(isVisible) }
}

// MARK: - The five sentences the shell owns

extension MacGuiLeafView: GuiLeafHost {
    /// `positioned:relativeTo:` rather than a plain `addSubview`, because the chrome was added in
    /// ``build()`` and a plain add would put the remote pixels ON TOP of the control bar — which would
    /// not merely look wrong, it would put an opaque `CAMetalLayer` over every overlay in the file.
    func mountSurface(_ seam: RemoteSurfaceHosting) {
        let view = seam.surfaceView
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: controlBar)
        NSLayoutConstraint.activate(view.slateEdges(of: self))
        placeholder.isHidden = true
    }

    func unmountSurface(_ seam: RemoteSurfaceHosting) { seam.surfaceView.removeFromSuperview() }

    func stopFollowing() {
        leafFollow?.stop()
        leafFollow = nil
    }

    func presentPlaceholder(_ display: RemoteGUIDisplay) {
        placeholder.isHidden = false
        placeholder.present(display)
    }

    func refollow() { follow() }
}

// MARK: - The live read

private extension MacGuiLeafView {
    /// ONE tracked read of everything this leaf draws, activates on, or triggers an immersive edge
    /// from.
    ///
    /// One arm rather than one per concern for the same reason the terminal leaf gives: the tracking
    /// fires on the FIRST change to anything `read` touched, so N arms cost N callbacks for one edit
    /// and give nothing back. `replacing:` because every core edge re-enters this method — see
    /// ``leafFollow``.
    func follow() {
        leafFollow = ObservationFollow.arm(self, replacing: leafFollow) { leaf in
            leaf.core.read()
        } apply: { leaf, reading in
            leaf.core.apply(reading)
            leaf.applyChrome(reading.chrome)
        }
    }

    // MARK: - The chrome

    func applyChrome(_ chrome: GuiLeafChrome) {
        controlBar.present(
            model: core.model, store: core.store, paneID: core.paneID,
            showStats: chrome.showStats, immersiveOn: chrome.immersiveOn,
            isDesktop: chrome.isDesktop,
        )
        MacGuiOverlayFade.set(controlBar, shown: chrome.showControlBar && chrome.controlsExpanded)
        collapsedChip.latched = chrome.hasLatchedMode
        MacGuiOverlayFade.set(collapsedChip, shown: chrome.showControlBar && !chrome.controlsExpanded)

        stallCaption.present(since: chrome.stalledAt)
        MacGuiOverlayFade.set(stallCaption, shown: chrome.stalled && chrome.live)

        statsReadout.present(chrome.telemetry)
        MacGuiOverlayFade.set(statsReadout, shown: chrome.showStats && chrome.live)

        uploadOverlay.present(chrome.uploads)
        MacGuiOverlayFade.set(uploadOverlay, shown: !chrome.uploads.isEmpty)

        MacGuiOverlayFade.set(readOnlyPill, shown: chrome.readOnly)
        MacGuiOverlayFade.set(dropHighlight, shown: chrome.dropTargeted)
        applyPasteBanner(chrome.pasteFeedback, barExpanded: chrome.showControlBar && chrome.controlsExpanded)
    }

    /// The one rebuilt overlay: its copy is baked in at init, so a NEW feedback is a new banner.
    func applyPasteBanner(_ feedback: RemoteWindowModel.PasteFeedback?, barExpanded: Bool) {
        let clearance = barExpanded ? Slate.Metric.paneHeaderHeight + Slate.Metric.space2 : Slate.Metric.space2
        pasteBannerBottom?.constant = -clearance
        guard feedback != pasteBanner?.feedback else { return }
        if let banner = pasteBanner {
            MacGuiOverlayFade.retire(banner)
            pasteBanner = nil
            pasteBannerBottom = nil
        }
        guard let feedback else { return }
        let banner = MacPasteFeedbackBanner(feedback: feedback) { [weak self] in
            self?.core.model?.dismissPasteFeedback()
        }
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alphaValue = 0
        banner.isHidden = true
        addSubview(banner, positioned: .below, relativeTo: dropHighlight)
        let bottom = banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -clearance)
        NSLayoutConstraint.activate([bottom, banner.centerXAnchor.constraint(equalTo: centerXAnchor)])
        pasteBannerBottom = bottom
        pasteBanner = banner
        MacGuiOverlayFade.set(banner, shown: true)
    }
}

// MARK: - The file drop (PATH 4)

extension MacGuiLeafView {
    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation {
        guard core.isDesktopUploadTarget else { return [] }
        setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_: NSDraggingInfo) -> NSDragOperation {
        core.isDesktopUploadTarget ? .copy : []
    }

    override func draggingExited(_: NSDraggingInfo?) { setDropTargeted(false) }

    /// The belt to `draggingExited`'s braces — a drag released outside, or cancelled by the system,
    /// leaves the highlight lit otherwise.
    override func draggingEnded(_: NSDraggingInfo) { setDropTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropTargeted(false)
        return core.handleDrop(sender.draggingPasteboard.slateDroppedFileURLs())
    }

    private func setDropTargeted(_ targeted: Bool) {
        guard let shown = core.dropTargeted(targeted) else { return }
        MacGuiOverlayFade.set(dropHighlight, shown: shown)
    }
}

// MARK: - The collapsed chip

/// The way back into the control bar: one plate on the stall caption's dim-ground material,
/// bottom-trailing.
///
/// A CLICK target, never hover-reveal — the bottom edge of a video pane is the edge-hover auto-pan
/// strip, so a hover-revealed bar would fight the pan gesture.
///
/// LATCHED IS INK AND WEIGHT HERE, not the accent the SwiftUI half tints it with, and the divergence
/// is deliberate: `MacPlateIconButton` carries the chrome's own rule (a hue carrying state is the
/// pattern this app reversed twice), and primary ink one weight up says "a mode is engaged" in the two
/// channels that survive any theme. What the tint was FOR — no latched mode is ever invisible once the
/// bar is folded away — is kept exactly.
@MainActor
final class MacGuiCollapsedControlsChip: NSView, GuiLeafCollapsedChipWiring {
    var onExpand: () -> Void = {}

    var latched: Bool {
        get { plate.active }
        set { plate.active = newValue }
    }

    private let plate = MacPlateIconButton(symbolName: SFSymbol.ellipsis.rawValue)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        paint()

        plate.toolTip = GuiPaneReadout.Tooltip.expandControls
        plate.onClick = { [weak self] in self?.onExpand() }
        addSubview(plate)
        NSLayoutConstraint.activate(plate.slateEdges(of: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.ground
                .slateScalingAlpha(Slate.Opacity.scrim).cgColor
        }
    }
}

// MARK: - The placeholder

/// The non-live states: the cap-gated "video paused" notice, or the calm idle mirror of the
/// pre-admission beat. One glyph, one line, both from `GuiPaneReadout`.
@MainActor
final class MacGuiPlaceholderView: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        paint()

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        label.isSelectable = false
        label.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)

        let column = NSStackView(views: [glyph, label])
        column.orientation = .vertical
        column.spacing = Slate.Metric.space3
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        present(.entryForm)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        repaint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    func present(_ state: RemoteGUIDisplay) {
        label.stringValue = GuiPaneReadout.placeholderLabel(state)
        repaint()
    }

    private func repaint() {
        label.textColor = Slate.Native.Text.primary
        glyph.image = NSImage(systemSymbolName: SFSymbol.display.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.display, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Slate.Native.Text.secondary])),
            )
    }
}

// MARK: - The reveal

/// The chrome's arrival and departure.
///
/// The SwiftUI half spends `.transition(.opacity)` (and, on three of these, a `.move(edge:)`) under
/// `.animation(Slate.Anim.reveal, value:)`. Everything here is pinned by constraints rather than
/// arranged in a stack, so there is no reflow to animate and no neighbour to slide past — the FADE is
/// the whole transition, which is also what the SwiftUI half degrades to for an overlay whose
/// neighbours do not move.
///
/// `isHidden` rides with the alpha rather than replacing it: a fully transparent view still hit-tests,
/// and a control bar that took clicks while invisible would eat the stream's pointer input.
@MainActor
private enum MacGuiOverlayFade {
    static func set(_ view: NSView, shown: Bool) {
        let wanted: CGFloat = shown ? 1 : 0
        guard view.alphaValue != wanted else {
            view.isHidden = !shown
            return
        }
        if shown { view.isHidden = false }
        animate({ view.animator().alphaValue = wanted }, thenHiding: shown ? nil : view)
    }

    static func retire(_ view: NSView) {
        animate({ view.animator().alphaValue = 0 }, thenRemoving: view)
    }

    /// A VIEW, NEVER A CLOSURE, for the reason `MacTerminalLeafView` records at length:
    /// `runAnimationGroup`'s completion handler is `@Sendable` and a bare closure is not, while an
    /// `NSView` crosses freely because `@MainActor` classes are implicitly `Sendable`.
    private static func animate(
        _ body: @escaping () -> Void, thenHiding hiding: NSView? = nil, thenRemoving retiring: NSView? = nil,
    ) {
        let curve = Slate.Motion.reveal
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            context.allowsImplicitAnimation = true
            body()
        } completionHandler: {
            // `MainActor.assumeIsolated` for the reason `MacTerminalLeafView` gives at its own
            // `animate`: the handler is `@Sendable`, both calls below are main-actor isolated, and
            // AppKit runs it on the main thread without having said so in the type.
            MainActor.assumeIsolated {
                hiding?.isHidden = true
                retiring?.removeFromSuperview()
            }
        }
    }
}

// The Objective-C class is the API's, not a preference: `readObjects(forClasses:options:)` takes
// `NSPasteboardReading` conformers and `URL` does not conform. Swift bridges what comes BACK, which
// is why the read goes out through the class and returns value types — the same shape and the same
// reason as `MacPaneDropReceiver`'s provider reads.
// swiftlint:disable:next legacy_objc_type
private let slateDroppableURLClasses: [AnyClass] = [NSURL.self]

private extension NSPasteboard {
    /// The FILE urls on a drag, and only those. `urlReadingFileURLsOnly` is what keeps a web-link drag
    /// out: an upload path that accepted `https://…` would send the host a URL as a file.
    func slateDroppedFileURLs() -> [URL] {
        let objects = readObjects(
            forClasses: slateDroppableURLClasses, options: [.urlReadingFileURLsOnly: true],
        ) ?? []
        return objects.compactMap { $0 as? URL }
    }
}
