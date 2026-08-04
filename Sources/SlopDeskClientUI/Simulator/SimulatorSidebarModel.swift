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
    /// The latest frame message for the screen view. A one-slot mailbox, not a queue: the view
    /// enqueues into a display layer that has its own, and buffering here would only add latency.
    private(set) var frame = SimulatorScreenFrame()
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
    private var stream: SimulatorStreaming?
    private var frameSequence: UInt64 = 0
    /// Bezel artwork by UDID. Worth keeping: it is per-model, never changes, and re-fetching three
    /// images every time someone steps back to the list and in again is visible as a blank frame.
    private var chromeCache: [String: SimulatorChromeAssets] = [:]
    /// Cancels an in-flight chrome fetch when the selection moves on, so a slow load for the previous
    /// device cannot land on the current one.
    private var chromeLoad: Task<Void, Never>?
    /// Clears ``notice`` after its moment. Held so a second action replaces the first's timer rather
    /// than having two racing to blank the same slot.
    private var noticeClear: Task<Void, Never>?

    init(
        control: SimulatorControlling = SimulatorControlClient(),
        makeStream: @escaping @MainActor (@escaping (SimulatorStreamEvent) -> Void) -> SimulatorStreaming
            = { SimulatorStreamConnection(sink: $0) },
    ) {
        self.control = control
        self.makeStream = makeStream
    }

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
        phase = .starting
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
        frame = SimulatorScreenFrame(latest: .none, sequence: nextSequence())
        selection = udid
        // Both are claims about the PREVIOUS device. Carrying them over would have the new screen
        // rotate from the old one's angle and its status-bar toggle show the wrong position.
        orientation = .portrait
        isStatusBarOverridden = false

        guard let udid, case let .ready(host, port) = phase else {
            chromeLoad?.cancel()
            chrome = nil
            return
        }
        loadChrome(for: udid)
        let connection = makeStream { [weak self] event in
            self?.handle(event, for: udid)
        }
        stream = connection
        connection.connect(host: host, port: port, udid: udid)
    }

    /// Send one input envelope to the live stream. No-op when nothing is selected.
    func send(_ envelope: SimulatorInputEnvelope) {
        stream?.send(envelope)
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
            // The server's only channel for "this device will not stream". Silence here is how a
            // permanently blank panel with no explanation happens.
            failure = text
        case let .ended(reason):
            if let reason { failure = reason }
        }
    }

    private func apply(_ message: SimulatorStreamMessage) {
        switch message {
        case let .configuration(record):
            guard let configuration = SimulatorWireProtocol.parseAVCConfiguration(record) else { return }
            frame = SimulatorScreenFrame(latest: .configuration(configuration), sequence: nextSequence())
        case let .accessUnit(data, isKeyframe):
            frame = SimulatorScreenFrame(
                latest: .accessUnit(data, isKeyframe: isKeyframe), sequence: nextSequence(),
            )
        case let .jpeg(data):
            frame = SimulatorScreenFrame(latest: .seed(data), sequence: nextSequence())
        case .unknown:
            break
        }
    }

    /// Monotonic, so two identical frames still read as two updates. SwiftUI coalesces equal values,
    /// and two consecutive delta frames of identical bytes are entirely possible on a static screen.
    private func nextSequence() -> UInt64 {
        frameSequence &+= 1
        return frameSequence
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
