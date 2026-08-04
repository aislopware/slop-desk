// SimulatorStageView — the whole streaming surface: what device this is, the device itself, what you
// can do to it, and what it is saying.
//
// Split out of `CodeSidebarColumn` when the panel grew past a screen and two buttons. The column now
// picks a surface; this file owns everything inside the Simulators one, which is what keeps the
// column readable as a switch rather than as a device panel with a code panel attached.
//
// FOUR BANDS, top to bottom: identity, device, verbs, output. The order is not decorative — it is
// what makes a caption a caption and a drawer a drawer. The header names the thing the other three
// bands are about, so it goes above them; the console is what the device just said, so it goes below
// the device rather than beside it, and the tap-watch-read loop stays one column.
//
// TWO SURFACES, NOT FOUR (MERIDIAN L5, depth by light). The first cut painted every band the chrome
// tone, which left the one lit, live thing in the panel sitting on exactly the same grey as the
// buttons around it — a flat sheet with hairlines ruled across it. The device and its output are
// CONTENT and take the lit `face`; the header is HOUSING and stays on `ground`. The toolbar is what
// forced the decision: given a band of its own it would stripe the column (dim, lit, dim, lit), so
// it lost its background entirely and became a rail of trays floating ON the stage — which is also
// where a device's buttons belong, beside the device rather than in a separate strip about it.
//
// THE BODY OR A BARE RECT. With chrome loaded the stream is seated in the real device, side buttons
// and all. Without it — still loading, or a model the server cannot describe — it falls back to the
// plain rectangle, because a working screen with no bezel is a working screen, and refusing to draw
// until the artwork arrives would make a slow fetch look like a dead stream.
//
// THE TOOLBAR is the buttons the BODY cannot offer. Power, volume and the action button are physical
// and live on the bezel where the eye already expects them; Home, the app switcher and the pull-down
// shades are gestures with no hardware to click, and rotate, capture, the demo status bar, the
// console and the simulated position are host-side settings. Splitting them that way is why the
// toolbar is a strip rather than a palette.
//
// DROP TO INSTALL. The server routes a dropped file by extension — an `.app`/`.ipa` is installed, an
// image or video lands in Photos — so this side deliberately accepts any file and lets the server
// classify it. Getting that taxonomy wrong locally would reject the one build someone wanted.

#if os(macOS)
import SFSafeSymbols
import SwiftUI
import UniformTypeIdentifiers

struct SimulatorStageView: View {
    @Bindable var model: SimulatorSidebarModel

    @State private var isTargeted = false
    @State private var isLocationOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // The STAGE: the device and the rail that drives it, on one lit surface. Grouped rather
            // than stacked loose so the toolbar can sit on the same tone as the device it acts on —
            // the thing that stops the column reading as four ruled bands.
            VStack(spacing: 0) {
                device
                toolbar
            }
            .background(Slate.Surface.face)
            console
        }
        .overlay(alignment: .top) { banner }
        .overlay { dropHighlight }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted.animation(Slate.Anim.smallFade)) { providers in
            accept(providers)
        }
    }

    // MARK: Identity

    /// Absent while the selection has been made but the device list has not caught up — the header's
    /// whole job is to state facts about a known device, and a header of placeholders would be the
    /// panel captioning a device it cannot name.
    @ViewBuilder
    private var header: some View {
        if let device = selected {
            SimulatorDeviceHeader(
                device: device,
                resolution: model.resolution,
                orientation: model.orientation,
                pinnedLocation: model.pinnedLocation,
                isStreaming: isStreaming,
                onBack: { model.select(nil) },
            )
        }
    }

    private var selected: SimulatorDevice? {
        guard let udid = model.selection else { return nil }
        return model.devices.first { $0.udid == udid }
    }

    /// Streaming means DECODABLE VIDEO is arriving, which is why the seed does not count: the JPEG
    /// seed is what the panel shows while the encoder is still starting, so treating it as streaming
    /// would drop the header's "Connecting…" over a picture that is already several seconds old and
    /// will never change.
    private var isStreaming: Bool {
        switch model.frame.latest {
        case .accessUnit,
             .configuration: true
        case .none,
             .seed: false
        }
    }

    // MARK: The device

    private var device: some View {
        Group {
            if let chrome = model.chrome {
                SimulatorBezelView(
                    assets: chrome, frame: model.frame, orientation: model.orientation,
                    send: { model.send($0) }, onContentSize: { model.observed(resolution: $0) },
                )
                .padding(Slate.Metric.space3)
            } else {
                SimulatorBareScreen(
                    frame: model.frame, orientation: model.orientation,
                    send: { model.send($0) }, onContentSize: { model.observed(resolution: $0) },
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Identity by DEVICE: switching devices must build a fresh view rather than feed a second
        // stream's frames into a layer configured for the first one's parameter sets.
        .id(model.selection)
    }

    // MARK: The toolbar

    /// Three trays and a trailing pair: turn it, drive it, capture it — then look at it. Ten loose
    /// plates in a row read as texture rather than as verbs, so each job takes a ``SlatePlateGroup``
    /// and the rail becomes four objects instead of twelve. The `Spacer` before the inspect pair is
    /// what makes the rail degrade by widening a gutter rather than by clipping a button off the end.
    ///
    /// The inspect pair stays OFF the trays on purpose. Both are latching — a pinned position and an
    /// open console outlive the click — and a latched plate is drawn as a lit key, which reads as lit
    /// only against the panel's own tone. Sitting them on a tray would put a lit key inside a lit
    /// tray and cost exactly the signal they exist to carry.
    private var toolbar: some View {
        HStack(spacing: Slate.Metric.space2) {
            SlatePlateGroup {
                PlateIconButton(symbol: .rotateLeft) { Task { await model.rotate(.left) } }
                    .help("Rotate Left")
                PlateIconButton(symbol: .rotateRight) { Task { await model.rotate(.right) } }
                    .help("Rotate Right")
            }
            SlatePlateGroup {
                PlateIconButton(symbol: .house) { model.send(.button("home")) }
                    .help("Home")
                // A TOGGLE, and the tooltip says so. Measured 2026-08-04 against a booted device:
                // the verb is the swipe-up-and-hold gesture, so it opens the card stack from an app
                // or the home screen and DISMISSES it when the stack is already up — and on a device
                // with nothing backgrounded it does nothing visible, exactly like the hardware.
                // `swipe-to-app-switcher` behaves identically; neither is an idempotent "show".
                PlateIconButton(symbol: .squareOnSquare) { model.send(.button("app-switcher")) }
                    .help("App Switcher — press again to dismiss")
                // NOTIFICATION CENTRE AND LOCK ARE GONE (user-directed 2026-08-04). Both were here
                // because the server offers the verb, which is not a reason: nobody driving an app
                // reaches for the shade or the lock screen, and both are DESTRUCTIVE to the thing
                // you are actually doing — a mis-click blanks the device and costs a wake and a
                // swipe to undo. A rail earns its width by what gets used, and the cost of the
                // wrong plate being adjacent to Home outweighed a verb neither of us ever sent.
                // The server still accepts `pull-down-to-notification-center` and `lock`; nothing
                // upstream changed, only what this panel puts under the pointer.
            }
            SlatePlateGroup {
                PlateIconButton(symbol: .cameraViewfinder) { Task { await model.copyScreenshot() } }
                    .help("Copy Screenshot")
                PlateIconButton(symbol: .clock, active: model.isStatusBarOverridden) {
                    Task { await model.toggleStatusBarOverride() }
                }
                .help(model.isStatusBarOverridden
                    ? "Restore the real status bar"
                    : "Demo status bar (9:41)")
            }
            Spacer(minLength: 0)
            if model.isSendingFile { WorkingSpinner() }
            location
            // A ruled list, not a terminal prompt: this opens a READER over the device's output, and
            // the `>_` glyph promises a place to type. (`.terminal` is also the Terminal.app icon and
            // deprecated at this target.)
            PlateIconButton(symbol: .listBulletRectangle, active: model.isConsoleOpen) {
                model.toggleConsole()
            }
            .help(model.isConsoleOpen ? "Hide the device log" : "Show the device log")
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.bottom, Slate.Metric.space2)
    }

    /// Latched while a position is pinned, so the toolbar says the device is somewhere else without
    /// anyone opening the popover to find out. The header carries the actual coordinate; this is the
    /// glance.
    private var location: some View {
        PlateIconButton(symbol: .location, active: model.pinnedLocation != nil) {
            isLocationOpen.toggle()
        }
        .help(model.pinnedLocation == nil ? "Simulate a location" : "Simulated location")
        .popover(isPresented: $isLocationOpen, arrowEdge: .bottom) {
            SimulatorLocationPopover(pinned: model.pinnedLocation) { coordinate in
                Task { await model.pin(coordinate) }
            }
        }
    }

    // MARK: Output

    /// A fixed band under the device rather than a split the user drags. The device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting; a drawer
    /// that always returns the same amount of screen is a drawer nobody has to re-tune after every
    /// use.
    @ViewBuilder
    private var console: some View {
        if model.isConsoleOpen {
            SimulatorConsoleView(model: model)
                .frame(height: Slate.Metric.heightDrawer)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Feedback

    /// One slot, failure winning. Both cannot be true — a failure clears the notice and a notice
    /// clears the failure — but stating the precedence here means a future third source cannot
    /// silently outrank an error.
    ///
    /// ONLY THE FAILURE IS COLOURED (user-directed 2026-08-04). A notice says a thing the reader just
    /// asked for worked, and a banner appearing at all already says that; ringing it in green made
    /// the panel's alarm colour the thing it shows most often, which is how an interface teaches
    /// people to stop reading its colours. Across this whole panel a hue now means one thing.
    @ViewBuilder
    private var banner: some View {
        if let failure = model.failure {
            capsule(failure, tint: Slate.Status.err)
        } else if let notice = model.notice {
            capsule(notice, tint: Slate.Line.active)
        }
    }

    private func capsule(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.primary)
            .lineLimit(2)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(tint, lineWidth: Slate.Metric.hairline)
            }
            .padding(Slate.Metric.space2)
            .transition(.opacity)
            .animation(Slate.Anim.smallFade, value: text)
    }

    /// The drop affordance is a border, not a dimming veil: the point of dropping onto a live screen
    /// is watching the install land, and covering the device to say "you may drop here" hides it.
    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusPanel)
                .strokeBorder(Slate.State.accent, lineWidth: Slate.Metric.cardBorderWidth)
                .padding(Slate.Metric.space1)
                .allowsHitTesting(false)
        }
    }

    /// Takes the FIRST file of a multi-file drop. The server's route is one file per request and the
    /// install it triggers is not instant, so fanning a folder-full of builds at a device would queue
    /// installs nobody asked for.
    ///
    /// `loadObject(ofClass:)` rather than the newer `loadTransferable` — the pane drop receiver reads
    /// dropped URLs the same way, and matching the one that is already proven in this app beats a
    /// second spelling of the same load.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, model.selection != nil,
              provider.canLoadObject(ofClass: URL.self) else { return false }
        Task { @MainActor in
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { value, _ in
                    continuation.resume(returning: value)
                }
            }
            guard let url, url.isFileURL else { return }
            // The URL carries a sandbox extension that has to be opened before the bytes can be read;
            // the app is sandboxed, so without this the read fails on every drop from outside it.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let contents = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                model.report("Could not read \(url.lastPathComponent).")
                return
            }
            await model.send(file: url, contents: contents)
        }
        return true
    }
}
#endif
