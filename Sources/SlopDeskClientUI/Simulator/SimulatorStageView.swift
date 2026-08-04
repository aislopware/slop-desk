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
            device
            toolbar
            console
        }
        .background(Slate.Surface.ground)
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

    /// Live means DECODABLE VIDEO is arriving, which is why the seed does not count: the JPEG seed is
    /// what the panel shows while the encoder is still starting, and calling that "Live" would light
    /// the dot green over a picture that is already several seconds old and never changes.
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

    /// Four groups: turn it, drive it, capture it, inspect it. Ten plates at 24pt plus the gaps fit a
    /// 220pt sidebar with room to spare, and the `Spacer` before the inspect pair is what makes the
    /// strip degrade by widening a gutter rather than by clipping a button off the end.
    private var toolbar: some View {
        HStack(spacing: Slate.Metric.space1) {
            PlateIconButton(symbol: .rotateLeft) { Task { await model.rotate(.left) } }
                .help("Rotate Left")
            PlateIconButton(symbol: .rotateRight) { Task { await model.rotate(.right) } }
                .help("Rotate Right")
            separator
            PlateIconButton(symbol: .house) { model.send(.button("home")) }
                .help("Home")
            PlateIconButton(symbol: .squareOnSquare) { model.send(.button("app-switcher")) }
                .help("App Switcher")
            // The shade, which a device only has as an edge swipe and a mouse therefore cannot reach:
            // the drag has to START outside the frame and end inside it, and a press that begins off
            // the screen is a press this panel never sees. Control Centre has no counterpart here on
            // purpose — the server's button set is home, lock, power, the volume pair, action, the
            // crown, the side buttons, the app switcher, the two swipe-to gestures, the lock-screen
            // pull and this one. There is no control-centre token to send.
            PlateIconButton(symbol: .bell) { model.send(.button("pull-down-to-notification-center")) }
                .help("Notification Centre")
            PlateIconButton(symbol: .lock) { model.send(.button("lock")) }
                .help("Lock")
            separator
            PlateIconButton(symbol: .cameraViewfinder) { Task { await model.copyScreenshot() } }
                .help("Copy Screenshot")
            PlateIconButton(symbol: .clock, active: model.isStatusBarOverridden) {
                Task { await model.toggleStatusBarOverride() }
            }
            .help(model.isStatusBarOverridden ? "Restore the real status bar" : "Demo status bar (9:41)")
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
        .frame(height: Slate.Metric.heightBar)
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

    /// A hairline between the toolbar's jobs — turning the device, driving its gestures, and
    /// capturing it. Cheaper than three labelled groups in a sidebar's width, and enough to stop a
    /// row of plates reading as one undifferentiated strip.
    private var separator: some View {
        Rectangle()
            .fill(Slate.Line.divider)
            .frame(width: Slate.Metric.hairline, height: Slate.Metric.iconSize)
            .padding(.horizontal, Slate.Metric.space1)
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
    @ViewBuilder
    private var banner: some View {
        if let failure = model.failure {
            capsule(failure, tint: Slate.Status.err)
        } else if let notice = model.notice {
            capsule(notice, tint: Slate.Status.ok)
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
