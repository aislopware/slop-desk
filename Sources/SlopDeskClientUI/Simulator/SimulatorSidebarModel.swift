// SimulatorSidebarModel — the right panel's Simulators surface: find the host's simulator server,
// list its devices, and hold the one live stream.
//
// TWO LOOPS, deliberately separate. The ENSURE loop polls the host's `ensureSimulatorServer` (verb
// 21) until the server reports ready — the host's ensure never waits, so readiness is client-side
// polling by design, exactly as the workbench's is. The DEVICE loop then re-reads `/simulators.json`
// on a slower cadence. Folding them into one would tie the device refresh rate to the server-boot
// retry rate, and those want opposite cadences: fast while nothing exists, slow once it does.
//
// Scope is a MACHINE, not a project: one host, one device set. That is why this model carries no
// project root, unlike `CodeSidebarModel`.
//
// ONE stream at a time. Selecting a device tears down the previous socket rather than holding both —
// two decoders and two 350 kbit/s streams for one visible rectangle is cost with no return, and the
// server would be encoding two devices to serve one panel.
//
// The connection and the phase machine are separable on purpose: `poll` and `phase(for:)` are pure
// enough to test without a socket, and everything that is not is behind ``SimulatorControlling``.

#if canImport(SwiftUI)
import CoreGraphics
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceCore

/// The readiness phases the Simulators surface renders. One value per distinct surface — the
/// column's body switches over this and nothing else.
enum SimulatorSidebarPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (app offline) or a host too old to
    /// know verb 21. Keep polling: the connection may come up.
    case offline
    /// The host is booting (or probing) the simulator server — spinner, keep polling.
    case starting
    /// No `baguette` binary on the host — render the install hint. Still polled (slowly): a
    /// `brew install baguette` mid-session is picked up without a restart.
    case unavailable
    /// The server is reachable at this address. Everything else the panel does hangs off it.
    case ready(host: String, port: UInt16)
}

@MainActor
@Observable
final class SimulatorSidebarModel {
    // MARK: Observable state

    private(set) var phase: SimulatorSidebarPhase = .starting
    private(set) var devices: [SimulatorDevice] = []
    /// The UDID whose stream is live, or `nil` for the device list.
    private(set) var selection: String?
    /// The video path to the mounted screen view. NOT observable state, and deliberately: at the
    /// 69.5 frames per second a device under a drag was measured to produce, publishing each access
    /// unit rebuilt the whole stage seventy times a second. See ``SimulatorFrameSink``.
    let frames = SimulatorFrameSink()
    /// Whether DECODABLE video has arrived for the current selection. The one thing about the stream
    /// the panel draws differently, and the reason the sink can stay silent otherwise: this changes
    /// twice a stream, not seventy times a second.
    private(set) var hasVideo = false
    /// Set while a boot/shutdown is in flight, so the row can show it and refuse a second click.
    private(set) var pending: Set<String> = []
    /// The last failure worth showing. Cleared by the next success — a stale error over a working
    /// list is worse than no error.
    private(set) var failure: String?
    /// A short confirmation for an action whose result is not on screen — a screenshot went to the
    /// clipboard, a file reached the device. Distinct from ``failure`` so a success cannot look like
    /// an error, and self-clearing: a confirmation that outlives the action becomes noise.
    private(set) var notice: String?

    /// The selected device's physical body, once fetched. `nil` while it loads or when the server
    /// cannot describe this model — the screen then draws bare, which is the previous behaviour and a
    /// perfectly usable fallback rather than an error state.
    private(set) var chrome: SimulatorChromeAssets?
    /// The interface orientation the panel last asked for. Local because the server has no read side:
    /// it is what the next rotate is relative to, not a claim about the device.
    private(set) var orientation: SimulatorOrientation = .portrait
    /// Whether the demo status bar (9:41, full bars, full battery) is in force.
    private(set) var isStatusBarOverridden = false
    /// Set while a file is uploading, so the drop target can say so — an `.app` bundle takes long
    /// enough that silence reads as a drop that missed.
    private(set) var isSendingFile = false
    /// The device's real framebuffer size, learned from the stream rather than assumed. `nil` until
    /// the first seed or keyframe: the panel does not know how big a device is until it sends one,
    /// and printing a guess in the header would be a number that is wrong on exactly the models
    /// nobody has checked.
    private(set) var resolution: CGSize?
    /// The last position the panel pinned, for the header's readout. `nil` means the device is on
    /// live values — either never pinned, or cleared.
    private(set) var pinnedLocation: SimulatorCoordinate?

    /// True from the moment a device is selected until its first decodable video arrives — or until
    /// ``firstFrameDeadline`` gives up on it. The panel's loading state, and deliberately NOT
    /// "no frames yet": that phrasing has no end, and an indicator with no end is the bug below.
    private(set) var isAwaitingStream = false

    // MARK: The console

    /// Whether the log drawer is open. Drives the SOCKET as well as the layout: `log stream` is a
    /// child process on the host per subscriber, so a console nobody can see must not stay
    /// subscribed.
    private(set) var isConsoleOpen = false
    private(set) var logLevel: SimulatorLogLevel = .info
    private(set) var logLines: [SimulatorLogLine] = []
    /// True once the server reports its `log stream` child is up. The distinction the console draws
    /// is between a quiet device and a console that never started.
    private(set) var isLogStarted = false

    /// How many rows the console keeps. A device under load emits thousands a minute and every row
    /// is a retained view; trimming from the front bounds both the memory and the scrollback that
    /// SwiftUI has to diff. Chosen for a sidebar's width — far more than fits on screen, far less
    /// than a full session.
    static let logCapacity = 600

    /// Bumped by the strip's reload button — part of the column's `.task` id, so a bump cancels the
    /// settled loop and re-ensures from scratch (respawning a server that died).
    private(set) var generation = 0

    func requestReload() { generation += 1 }

    // MARK: Wiring

    private let control: SimulatorControlling
    /// Builds the socket for a selection. A closure rather than a direct construction so a test can
    /// exercise selection, frame delivery and teardown without opening one — this project does not
    /// build network objects in unit tests.
    private let makeStream: @MainActor (@escaping (SimulatorStreamEvent) -> Void) -> SimulatorStreaming
    /// The console's socket, built the same injectable way and for the same reason.
    private let makeLogStream: @MainActor (@escaping (SimulatorLogEvent) -> Void) -> SimulatorLogStreaming
    private var stream: SimulatorStreaming?
    private var logStream: SimulatorLogStreaming?
    private var logSequence: UInt64 = 0
    /// Bezel artwork by UDID. Worth keeping: it is per-model, never changes, and re-fetching three
    /// images every time someone steps back to the list and in again is visible as a blank frame.
    private var chromeCache: [String: SimulatorChromeAssets] = [:]
    /// Cancels an in-flight chrome fetch when the selection moves on, so a slow load for the previous
    /// device cannot land on the current one.
    private var chromeLoad: Task<Void, Never>?
    /// Clears ``notice`` after its moment. Held so a second action replaces the first's timer rather
    /// than having two racing to blank the same slot.
    private var noticeClear: Task<Void, Never>?
    /// Gives up on a stream that never starts. Held so selecting a second device cancels the first
    /// device's verdict rather than letting it land on the new selection.
    private var streamWatchdog: Task<Void, Never>?
    private let firstFrameDeadline: Duration

    init(
        control: SimulatorControlling = SimulatorControlClient(),
        makeStream: @escaping @MainActor (@escaping (SimulatorStreamEvent) -> Void) -> SimulatorStreaming
            = { SimulatorStreamConnection(sink: $0) },
        makeLogStream: @escaping @MainActor (@escaping (SimulatorLogEvent) -> Void)
            -> SimulatorLogStreaming = { SimulatorLogConnection(sink: $0) },
        firstFrameDeadline: Duration = SimulatorSidebarModel.firstFrameDeadline,
    ) {
        self.control = control
        self.makeStream = makeStream
        self.makeLogStream = makeLogStream
        self.firstFrameDeadline = firstFrameDeadline
    }

    /// How long a freshly opened stream may stay silent before the panel stops believing in it.
    ///
    /// ⚠️ THE SERVER DOES NOT SAY NO. Measured 2026-08-04 against the live server: selecting a BOOTED
    /// device produces its avcC and first IDR 0.09 s after the upgrade, while selecting a device that
    /// is NOT booted gets a `101 Switching Protocols` and then nothing at all — no error text, no
    /// close frame, no bytes, indefinitely. There is nothing on the wire to turn into a failure, so a
    /// panel that waits for one waits forever. That is the whole bug, and the only possible fix is
    /// this deadline plus the read-back in ``giveUpOnStream``.
    ///
    /// Five seconds is fifty-odd times the measured healthy case — wide enough for a cold encoder or
    /// a slow link, short enough that nobody sits watching a rectangle that is never going to fill.
    static let firstFrameDeadline: Duration = .seconds(5)

    // MARK: The ensure loop

    /// Poll `ensure` until `.ready` (or cancellation). `host` is read per round — the connection
    /// target can change mid-loop, and a reconnect to a different host must not bake in the stale
    /// name. The not-yet-running phases re-poll fast (a boot is seconds); `unavailable`/`offline`
    /// back off, since they only change on operator action (install / reconnect).
    func poll(
        host: @MainActor () -> String?,
        ensure: () async -> MetadataCodec.ServiceEndpoint?,
        interval: Duration = .milliseconds(900),
    ) async {
        // A KNOWN-GOOD address survives a restart. This loop restarts every time the surface is
        // mounted — leaving the tab and coming back, or reopening the collapsed panel — and resetting
        // to `.starting` unconditionally replaced the whole surface with "Starting simulator server…"
        // for one round-trip on every return, over a server that had never stopped running. The first
        // ensure round overwrites this in either direction, so a host that really did go away is
        // still one round-trip from saying so.
        if case .ready = phase {} else { phase = .starting }
        while !Task.isCancelled {
            let endpoint = await ensure()
            guard !Task.isCancelled else { return }
            phase = Self.phase(for: endpoint, host: host())
            switch phase {
            case .ready: return
            case .starting: try? await Task.sleep(for: interval)
            case .offline,
                 .unavailable: try? await Task.sleep(for: interval * 4)
            }
        }
    }

    /// One ensure round's endpoint → the phase to render. Pure — pinned by
    /// `SimulatorSidebarModelTests`. A `ready` endpoint with no usable address degrades to
    /// `.offline`, never a trap.
    static func phase(
        for endpoint: MetadataCodec.ServiceEndpoint?, host: String?,
    ) -> SimulatorSidebarPhase {
        guard let endpoint else { return .offline }
        switch endpoint.state {
        case .unavailable: return .unavailable
        case .starting: return .starting
        case .ready:
            guard let host, !host.isEmpty, endpoint.port != 0 else { return .offline }
            return .ready(host: host, port: endpoint.port)
        }
    }

    // MARK: The device loop

    /// Re-read the device list on a slow cadence for as long as the caller's task lives. Separate
    /// from the ensure loop because the cadences want to be different, and separate from a one-shot
    /// refresh because a boot started elsewhere (Xcode, a terminal) should still show up here.
    func watchDevices(interval: Duration = .seconds(4)) async {
        while !Task.isCancelled {
            await refreshDevices()
            try? await Task.sleep(for: interval)
        }
    }

    func refreshDevices() async {
        guard case let .ready(host, port) = phase else { return }
        do {
            devices = try await control.devices(host: host, port: port)
            failure = nil
            // A device that disappeared (deleted, or a device-set switch) cannot stay selected — the
            // stream is already dead and the panel would show a frozen last frame forever.
            if let selection, !devices.contains(where: { $0.udid == selection }) {
                select(nil)
            }
        } catch {
            failure = Self.describe(error)
        }
    }

    // MARK: Lifecycle actions

    func boot(_ udid: String) async { await act(udid) { try await control.boot(host: $0, port: $1, udid: udid) } }

    func shutdown(_ udid: String) async {
        // Drop the stream FIRST: shutting a device down while its socket is open leaves the panel
        // decoding a stream the server is about to kill, and the frozen final frame reads as a hang.
        if selection == udid { select(nil) }
        await act(udid) { try await control.shutdown(host: $0, port: $1, udid: udid) }
    }

    private func act(_ udid: String, _ body: (String, UInt16) async throws -> Void) async {
        guard case let .ready(host, port) = phase, !pending.contains(udid) else { return }
        pending.insert(udid)
        defer { pending.remove(udid) }
        do {
            try await body(host, port)
            // Read back rather than assume: the request succeeding means the server accepted it, not
            // that the device reached the state. The next list is the truth.
            await refreshDevices()
        } catch {
            failure = Self.describe(error)
        }
    }

    // MARK: The stream

    /// Show `udid`'s screen, or `nil` to go back to the list. Idempotent for the same device, so a
    /// re-render cannot restart a healthy stream.
    func select(_ udid: String?) {
        guard udid != selection else { return }
        stream?.disconnect()
        stream = nil
        settleStream()
        // DISCARD, not reset: the stage keys its screen on the selection, so this device's surface is
        // about to be replaced rather than reused — and it stays on screen through the navigation
        // transition, which a flush would spend on a blanked layer. See ``SimulatorFrameSink/discard``.
        frames.discard()
        hasVideo = false
        selection = udid
        // Every one of these is a claim about the PREVIOUS device. Carrying them over would have the
        // new screen rotate from the old one's angle, its status-bar toggle show the wrong position,
        // its header print the old model's resolution, and its console keep the old device's output
        // under a new device's name.
        orientation = .portrait
        isStatusBarOverridden = false
        resolution = nil
        pinnedLocation = nil
        logLines.removeAll()
        isLogStarted = false
        logStream?.disconnect()
        logStream = nil

        guard let udid, case let .ready(host, port) = phase else {
            chromeLoad?.cancel()
            chrome = nil
            // Leaving the list open with the drawer still latched would reopen a console for
            // whatever gets selected next, which nobody asked for.
            isConsoleOpen = false
            return
        }
        loadChrome(for: udid)
        // The drawer stays latched across a device switch — someone reading logs while stepping
        // between two devices means to keep reading logs — so the socket follows the selection.
        if isConsoleOpen { openConsole() }
        openStream(udid, host: host, port: port)
    }

    /// Open the socket for `udid` and start the clock on it. Shared by selection and by ``retry``, so
    /// a retry cannot drift into a second, subtly different way of connecting.
    private func openStream(_ udid: String, host: String, port: UInt16) {
        let connection = makeStream { [weak self] event in
            self?.handle(event, for: udid)
        }
        stream = connection
        connection.connect(host: host, port: port, udid: udid)
        isAwaitingStream = true
        streamWatchdog = Task { [weak self, firstFrameDeadline] in
            try? await Task.sleep(for: firstFrameDeadline)
            guard !Task.isCancelled else { return }
            await self?.giveUpOnStream(udid)
        }
    }

    /// Try the selected device's stream again, keeping everything else about the selection. The
    /// device is still the subject — its console stays subscribed, its bezel stays loaded — so this
    /// is deliberately not a re-selection, which would close both and cost a second artwork fetch.
    func retry() {
        guard let udid = selection, case let .ready(host, port) = phase else { return }
        stream?.disconnect()
        settleStream()
        failure = nil
        frames.reset()
        hasVideo = false
        openStream(udid, host: host, port: port)
    }

    /// The stream has answered — with video, with an error, or by ending. Stops the loading state and
    /// stands the watchdog down; anything after this point has an explanation of its own.
    private func settleStream() {
        streamWatchdog?.cancel()
        streamWatchdog = nil
        isAwaitingStream = false
    }

    /// The deadline passed with the socket silent. Rather than blame the stream, ASK WHAT THE DEVICE
    /// IS — the reported case was a row that said Booted, a click, and a load that never ended,
    /// because the device had been shut down elsewhere and this panel's list was up to four seconds
    /// stale. The read-back is what turns a hang into a sentence, and it is worth an extra request
    /// precisely because it is the difference between the two causes: a device that is gone (say so
    /// and go back, since there is nothing to look at) and a device that is running but not encoding
    /// (stay, because the screen is the thing being worked on and re-selecting it is one click).
    private func giveUpOnStream(_ udid: String) async {
        guard selection == udid, isAwaitingStream, case let .ready(host, port) = phase else { return }
        let name = devices.first { $0.udid == udid }?.name ?? "This device"
        let live = try? await control.devices(host: host, port: port)
        // The await let the world move: a frame may have landed, or the selection moved on.
        guard selection == udid, isAwaitingStream else { return }
        settleStream()
        // The two verdicts that LEAVE the device on screen do not name it: the report is carried by the
        // app's notification, which prints the device as the card's own subject, and the header behind
        // the card is still naming it too. The third does — it takes the reader back to the list, where
        // nothing else is left saying which device this was about.
        guard let live else {
            failure = "No video has arrived from this device."
            return
        }
        devices = live
        if live.first(where: { $0.udid == udid })?.isBooted == true {
            failure = "The device is running, but no video has arrived."
        } else {
            failure = "\(name) is no longer running."
            select(nil)
        }
    }

    /// Send one input envelope to the live stream. No-op when nothing is selected.
    func send(_ envelope: SimulatorInputEnvelope) {
        stream?.send(envelope)
    }

    // MARK: Parking

    /// Drop the live sockets while KEEPING the selection — the surface has gone off screen (another
    /// panel tab, or the whole right column collapsed) and nobody is looking at this device.
    ///
    /// MEASURED 2026-08-04, with a device open and the panel switched to its other tab: both
    /// websockets stayed up and the server kept encoding. 33 KB/s on the wire for a device at REST,
    /// 5.4% of a core on the client decoding into a layer that is no longer in any window, and 2.3%
    /// on the host producing it — and every one of those is the FLOOR, since a device being driven
    /// was measured at 2.1 Mbps. The device polls stopped on their own, because their `.task`s are
    /// cancelled with the view; the stream did not, because the model that owns it is `@State` on the
    /// column and survives the unmount by design. Nothing here was a leak — it was a socket doing
    /// exactly what it was told, for a viewer that had left.
    ///
    /// The console's socket goes with it, and matters more per byte: `log stream` is a CHILD PROCESS
    /// on the host per subscriber.
    ///
    /// The last keyframe stays in the sink on purpose. ``resume`` reconnects and the server's first
    /// IDR lands 0.09 s later (measured), so coming back to the tab shows the device as it was left
    /// rather than a grey veil that resolves a moment after the eye has already read it.
    func park() {
        stream?.disconnect()
        stream = nil
        settleStream()
        logStream?.disconnect()
        logStream = nil
        isLogStarted = false
    }

    /// Re-open what ``park`` dropped. Idempotent by the `stream == nil` guard: an appearance with a
    /// live socket, or with no device selected, does nothing at all.
    func resume() {
        guard stream == nil, let udid = selection, case let .ready(host, port) = phase else { return }
        openStream(udid, host: host, port: port)
        // Latched consoles come back with the device, for the same reason they survive a device
        // switch: someone who left the drawer open meant to keep reading it.
        if isConsoleOpen { openConsole() }
    }

    // MARK: Device controls

    /// Turn the device a quarter turn. The video's own dimensions follow on the next keyframe, so the
    /// layout needs no help — only the next rotation needs to know where this one left off.
    func rotate(_ direction: SimulatorOrientation.Turn) async {
        guard case let .ready(host, port) = phase, let udid = selection else { return }
        let target = orientation.turned(direction)
        do {
            try await control.setOrientation(host: host, port: port, udid: udid, value: target.wireValue)
            orientation = target
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Capture the screen to the CLIPBOARD rather than to a file. A screenshot's next stop is almost
    /// always a message or a pull request, the app is sandboxed so a file needs a save panel in the
    /// way, and the pasteboard needs no permission at all.
    func copyScreenshot() async {
        guard case let .ready(host, port) = phase, let udid = selection else { return }
        do {
            let jpeg = try await control.screenshot(host: host, port: port, udid: udid)
            // Decoded before it is written, not after: a JPEG the server truncated would otherwise
            // reach the pasteboard as bytes nothing can paste, and the panel would call that a
            // success.
            guard SimulatorPasteboard.write(jpeg: jpeg) != nil else {
                failure = "The screenshot could not be read."
                return
            }
            show(notice: "Screenshot copied")
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Flip the demo status bar: Apple's own 9:41 with full bars and a full battery, or back to the
    /// device's real one. The single reason anyone reaches for a status-bar override is a clean
    /// capture, so this is that preset rather than a form.
    func toggleStatusBarOverride() async {
        guard case let .ready(host, port) = phase, let udid = selection else { return }
        let overrides = isStatusBarOverridden ? [:] : SimulatorStatusBar.demo
        do {
            try await control.setStatusBar(host: host, port: port, udid: udid, overrides: overrides)
            isStatusBarOverridden.toggle()
            show(notice: isStatusBarOverridden ? "Demo status bar on" : "Status bar restored")
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Hand the device a dropped file. The server routes on the extension — an `.app`/`.ipa` is
    /// installed, an image or a video lands in Photos — so this side deliberately does not try to
    /// classify it and get the taxonomy wrong.
    func send(file url: URL, contents: Data) async {
        guard case let .ready(host, port) = phase, let udid = selection, !isSendingFile else { return }
        isSendingFile = true
        defer { isSendingFile = false }
        let name = url.lastPathComponent
        do {
            try await control.sendFile(
                host: host, port: port, udid: udid, name: name, contents: contents,
            )
            show(notice: "Sent \(name)")
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Pin the device somewhere, or pass `nil` to restore live values. The readout follows the call
    /// rather than the click: a pin the server refused must not leave the header claiming a position
    /// the device is not at.
    func pin(_ coordinate: SimulatorCoordinate?) async {
        guard case let .ready(host, port) = phase, let udid = selection else { return }
        do {
            try await control.setLocation(host: host, port: port, udid: udid, coordinate: coordinate)
            pinnedLocation = coordinate
            show(notice: coordinate.map { "Location \($0.readout)" } ?? "Live location restored")
        } catch {
            failure = Self.describe(error)
        }
    }

    /// The device's framebuffer size, reported by the view that decoded it. A callback rather than a
    /// read: only the decoder knows, and the alternative is parsing the SPS a second time here to
    /// learn something the layer already worked out.
    func observed(resolution size: CGSize) {
        guard size.width > 0, size.height > 0, resolution != size else { return }
        resolution = size
    }

    // MARK: The console

    /// Open or close the log drawer, opening and closing the socket with it.
    func toggleConsole() {
        if isConsoleOpen {
            closeConsole()
        } else {
            openConsole()
        }
    }

    /// Re-subscribe at a new level. The server takes `--level` at subscribe time and has no way to
    /// change it on a live socket, so this reconnects — and keeps the rows already collected, since
    /// dropping the history someone just widened the level to explain would be the wrong half to
    /// throw away.
    func setLogLevel(_ level: SimulatorLogLevel) {
        guard level != logLevel else { return }
        logLevel = level
        guard isConsoleOpen else { return }
        openConsole()
    }

    func clearLog() {
        logLines.removeAll()
    }

    private func openConsole() {
        logStream?.disconnect()
        logStream = nil
        isConsoleOpen = true
        isLogStarted = false
        guard let udid = selection, case let .ready(host, port) = phase else { return }
        let connection = makeLogStream { [weak self] event in
            self?.handle(event, for: udid)
        }
        logStream = connection
        connection.connect(host: host, port: port, udid: udid, level: logLevel)
    }

    private func closeConsole() {
        isConsoleOpen = false
        isLogStarted = false
        logStream?.disconnect()
        logStream = nil
    }

    private func handle(_ event: SimulatorLogEvent, for udid: String) {
        // A late event from a socket opened for the previous device must not paint into this one's
        // console.
        guard selection == udid, isConsoleOpen else { return }
        switch event {
        case .connected:
            break
        case .started:
            isLogStarted = true
        case let .lines(lines):
            append(lines)
        case let .ended(reason):
            isLogStarted = false
            if let reason { failure = reason }
        }
    }

    /// Append a batch and trim from the front. One splice per batch rather than per line: the server
    /// batches at ~50 ms precisely so its consumers can, and an observable write per line would make
    /// SwiftUI diff the whole console twenty times a second.
    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        logLines.append(contentsOf: lines.map { text in
            var line = SimulatorLogLine.parse(text)
            logSequence &+= 1
            line.id = logSequence
            return line
        })
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
    }

    /// A failure raised by the VIEW rather than by a call. A dropped file the sandbox will not let it
    /// read never reaches the client at all, and silence there looks like a drop that missed the
    /// target.
    func report(_ text: String) {
        notice = nil
        noticeClear?.cancel()
        failure = text
    }

    /// How long a confirmation stays up. Long enough to read one short line, short enough that it is
    /// gone before it can be mistaken for state.
    static let noticeLifetime: Duration = .seconds(2)

    private func show(notice text: String) {
        failure = nil
        notice = text
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Chrome

    /// Fetch the selected device's body. Cache first so stepping back to the list and in again does
    /// not blank the bezel; a failure is left silent on purpose — the panel simply draws bare, which
    /// is a working screen, and an error banner over a working screen is worse than no bezel.
    private func loadChrome(for udid: String) {
        chromeLoad?.cancel()
        if let cached = chromeCache[udid] {
            chrome = cached
            return
        }
        chrome = nil
        guard case let .ready(host, port) = phase else { return }
        let control = control
        chromeLoad = Task { [weak self] in
            let assets = await SimulatorChromeAssets.load(
                udid: udid, host: host, port: port, control: control,
            )
            guard let assets, !Task.isCancelled, let self, selection == udid else { return }
            chromeCache[udid] = assets
            chrome = assets
        }
    }

    private func handle(_ event: SimulatorStreamEvent, for udid: String) {
        // A late event from a torn-down connection must not paint over the current one.
        guard selection == udid else { return }
        switch event {
        case .connected:
            failure = nil
        case let .message(message):
            apply(message)
        case let .text(text):
            // One of the server's two channels for "this device will not stream", and the only one it
            // ever uses out loud. The other is silence, which is ``firstFrameDeadline``'s job.
            settleStream()
            failure = text
        case let .ended(reason):
            settleStream()
            if let reason { failure = reason }
        }
    }

    private func apply(_ message: SimulatorStreamMessage) {
        switch message {
        case let .configuration(record):
            guard let configuration = SimulatorWireProtocol.parseAVCConfiguration(record) else { return }
            settleStream()
            hasVideo = true
            frames.deliver(configuration: configuration)
        case let .accessUnit(data, isKeyframe):
            // DECODABLE VIDEO ends the loading state; the JPEG seed below does NOT. The seed is a
            // still the server sends while its encoder starts, so treating it as arrival would drop
            // the indicator over a picture that is already stale and may never move — which is the
            // hang this deadline exists to catch, wearing a screenshot as a disguise.
            settleStream()
            hasVideo = true
            frames.deliver(accessUnit: data, isKeyframe: isKeyframe)
        case let .jpeg(data):
            frames.deliver(seed: data)
        case .unknown:
            break
        }
    }

    /// One line, for a placeholder. The status code matters (a refused boot is a 4xx and says so);
    /// the URLError's full description does not.
    static func describe(_ error: Error) -> String {
        switch error {
        case SimulatorControlError.noEndpoint: "No simulator server address."
        case let SimulatorControlError.status(code): "The simulator server answered \(code)."
        case SimulatorControlError.malformedResponse: "The simulator server sent something unexpected."
        default: (error as NSError).localizedDescription
        }
    }
}
#endif
