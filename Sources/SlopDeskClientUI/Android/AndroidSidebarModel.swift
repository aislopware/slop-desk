// AndroidSidebarModel — the right panel's Android surface: find the host's bridge, list its devices,
// and hold the one live mirror.
//
// TWO LOOPS, deliberately separate, for the reason ``SimulatorSidebarModel`` gives: the ENSURE loop
// polls verb 22 until the bridge reports ready, and the DEVICE loop re-reads the catalogue on a
// slower cadence. Folding them into one would tie the device refresh rate to the bridge-retry rate,
// and those want opposite cadences.
//
// The Android ensure loop usually finishes in ONE round — the bridge listens in-process, so there is
// no child to boot and no `.starting` to poll through. The loop stays because `.starting` is still
// reachable (a bind that failed under port pressure) and because a host that is offline when the tab
// opens must recover without a restart.
//
// Scope is a MACHINE, not a project: one host, one `adb` server, one set of AVDs.
//
// ONE mirror at a time. Selecting a device tears the previous socket down rather than holding both.
// This matters more than it did for simulators: `scrcpy`'s encoder runs ON the device, so a
// forgotten stream is a real battery drain on someone's phone.

// `os(macOS)` joins the guard because every type this file names — the bridge, the stream,
// the device list — is declared `#if os(macOS)` in its eighteen siblings in this directory,
// and the only mount, `CodeSidebarColumn`, is macOS-only too. Without it the type still
// COMPILED for the iOS triple and reached for symbols that are not there. It has been a hard
// error on iOS for as long as the Android panel has existed; `swift build` compiles the macOS
// slice only, so nothing said so until `make check-ios` started running.
#if canImport(SwiftUI) && os(macOS)
import CoreGraphics
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceCore

/// The readiness phases the Android surface renders. One value per distinct surface — the column's
/// body switches over this and nothing else.
enum AndroidSidebarPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (app offline) or a host too old to
    /// know verb 22. Keep polling: the connection may come up.
    case offline
    /// The host is still trying to open the bridge — spinner, keep polling.
    case starting
    /// No `adb` on the host — render the install hint. Still polled (slowly): installing the platform
    /// tools mid-session is picked up without a restart.
    case unavailable
    /// The bridge is reachable at this address. Everything else the panel does hangs off it.
    case ready(host: String, port: UInt16)
}

@MainActor
@Observable
final class AndroidSidebarModel {
    // MARK: Observable state

    private(set) var phase: AndroidSidebarPhase = .starting
    private(set) var devices: [AndroidDevice] = []
    /// The key whose mirror is live, or `nil` for the device list. The KEY rather than the serial, so
    /// a selection survives the boot that gives an AVD its serial.
    private(set) var selection: String?
    /// The video path to the mounted screen view. NOT observable state, and deliberately — see
    /// ``AndroidFrameSink``.
    let frames = AndroidFrameSink()
    /// Whether DECODABLE video has arrived for the current selection. The one thing about the stream
    /// the panel draws differently, and the reason the sink can stay silent otherwise.
    ///
    /// ⚠️ It changes exactly TWICE a session and every write to it must be guarded, because
    /// `@Observable` does not compare. The macro's setter notifies on assignment, not on change, so
    /// `hasVideo = true` on each arriving frame — which is what this handler used to do — invalidates
    /// every view that reads it at the frame rate, and the stage rebuilds header, toolbar, device
    /// body and log drawer on the main actor between the pointer events the user is making. That is
    /// the precise cost ``AndroidFrameSink`` exists to avoid, leaking back in through a one-word
    /// assignment, and it scales with how well the device is doing: at the 58 fps a hardware-rendered
    /// emulator gives, it is 58 full rebuilds a second.
    private(set) var hasVideo = false
    /// Set while a boot/shutdown is in flight, so the row can show it and refuse a second click.
    private(set) var pending: Set<String> = []
    /// The last failure worth showing. Cleared by the next success — a stale error over a working
    /// list is worse than no error.
    private(set) var failure: String?
    /// A short confirmation for an action whose result is not on screen. Distinct from ``failure`` so
    /// a success cannot look like an error, and self-clearing.
    private(set) var notice: String?

    /// The size the server is encoding, from the SESSION PACKET and from nowhere else. `nil` until the
    /// stream names one.
    ///
    /// Note this is the STREAM's size, which is not the device's: the panel asks for a mirror capped
    /// at ``streamMaxSize``, and the server scales to fit. The header prints the device's real
    /// metrics — which Android, unlike iOS, states outright.
    ///
    /// ⚠️ It is not decoration. Every touch, drag, scroll and pinch is paired with this number on the
    /// wire, and the device DISCARDS a positional message carrying any other — so a second writer
    /// here, however plausible its number looks, is a mirror that silently stops responding to
    /// fingers. `AndroidScreenLayout` has the whole account.
    private(set) var streamSize: CGSize?

    /// True from the moment a device is selected until its first decodable video arrives — or until
    /// ``firstFrameDeadline`` gives up on it.
    private(set) var isAwaitingStream = false

    // MARK: The console

    /// Whether the log drawer is open. Drives the SOCKET as well as the layout: `logcat` is a child
    /// process on the host per subscriber, so a console nobody can see must not stay subscribed.
    private(set) var isConsoleOpen = false
    private(set) var logLevel: AndroidLogLevel = .info
    private(set) var logLines: [AndroidLogLine] = []
    /// True once the host reports its `logcat` child is up. The distinction the console draws is
    /// between a quiet device and a console that never started.
    private(set) var isLogStarted = false

    /// How many rows the console keeps. An Android device under load emits far more than an iOS one —
    /// `logcat` carries the whole system, not one process — so the trim matters more, but the cap is
    /// the same: far more than fits on screen, far less than a session.
    static let logCapacity = 600

    /// Bumped by the strip's reload button — part of the column's `.task` id, so a bump cancels the
    /// settled loop and re-ensures from scratch.
    private(set) var generation = 0

    func requestReload() { generation += 1 }

    // MARK: Wiring

    private let bridge: AndroidBridging
    /// Builds the mirror socket for a selection. A closure rather than a direct construction so a
    /// test can exercise selection, frame delivery and teardown without opening one.
    private let makeStream: @MainActor (@escaping (AndroidStreamEvent) -> Void) -> AndroidStreaming
    /// The console's socket, built the same injectable way and for the same reason.
    private let makeLogStream: @MainActor (@escaping (AndroidLogEvent) -> Void) -> AndroidLogStreaming
    private var stream: AndroidStreaming?
    private var logStream: AndroidLogStreaming?
    private var logSequence: UInt64 = 0
    /// Clears ``notice`` after its moment. A ``DeadlineLatch`` rather than a bare `Task`: cancel the
    /// previous timer, re-arm, and drop a fire that lost the race are the same three details every
    /// time, and the one place they are written is the latch.
    @ObservationIgnored private let noticeClear = DeadlineLatch()
    /// Gives up on a stream that never starts. Held so selecting a second device cancels the first
    /// device's verdict rather than letting it land on the new selection.
    private var streamWatchdog: Task<Void, Never>?
    /// The task chasing a device that cannot take a mirror yet — booting, or freshly booted with no
    /// serial. One at a time, cancelled by re-selection and by ``settleStream()`` — which is exactly
    /// what ``DeadlineLatch`` is, so the re-arm is not written out a second time here.
    @ObservationIgnored private let reattempt = DeadlineLatch()
    /// When the current selection began waiting for video. Attempts share this one clock, so a
    /// boot's worth of retries cannot extend the deadline forever. `nil` between campaigns.
    private var awaitBegan: ContinuousClock.Instant?
    /// The last reason a stream ended, kept so the failure shown when patience runs out is the
    /// bridge's own sentence rather than a generic one.
    private var lastEndReason: String?
    private let clock = ContinuousClock()
    private let firstFrameDeadline: Duration

    init(
        bridge: AndroidBridging = AndroidBridgeClient(),
        makeStream: @escaping @MainActor (@escaping (AndroidStreamEvent) -> Void) -> AndroidStreaming
            = { AndroidStreamConnection(sink: $0) },
        makeLogStream: @escaping @MainActor (@escaping (AndroidLogEvent) -> Void)
            -> AndroidLogStreaming = { AndroidLogConnection(sink: $0) },
        firstFrameDeadline: Duration = AndroidSidebarModel.firstFrameDeadline,
    ) {
        self.bridge = bridge
        self.makeStream = makeStream
        self.makeLogStream = makeLogStream
        self.firstFrameDeadline = firstFrameDeadline
    }

    /// The longest edge the mirror is scaled to, in pixels.
    ///
    /// 1024 rather than the device's own resolution, and it is not a compromise: a 1440×3120 phone
    /// encoded at native size is four times the pixels for a rectangle that occupies at most a third
    /// of a sidebar, and `scrcpy`'s own default for the same reason is 1920. Measured 2026-08-04
    /// against this host's emulator at 1024: 4 Mbit/s ceiling, 25 frames/s under a continuous drag,
    /// and an idle floor of 547 B/s.
    static let streamMaxSize = 1024

    /// How long a freshly opened mirror may stay silent before the panel stops believing in it.
    ///
    /// Eight seconds rather than the simulator panel's five, measured rather than guessed: the host
    /// has to push the server jar over `adb`, start `app_process`, and wait for the device's encoder
    /// to produce its first IDR. A warm emulator did it in 0.83 s; a cold physical device on USB is
    /// the slow case this covers.
    static let firstFrameDeadline: Duration = .seconds(8)

    /// How long a selection keeps chasing a device that is not ready before the panel declares
    /// failure. Measured on this host, 2026-08-07: a cold boot sits `offline` in `adb` for ~21 s
    /// and produces its first video at ~39 s, with `open` refused or stalling throughout; a
    /// first-ever boot that still has dexopt to do runs minutes on a slower machine. The window is
    /// generous because everything inside it stays QUIET — the veil, not an error.
    static let deviceGrace: Duration = .seconds(120)

    /// The pause between attempts while the device is coming up. Short enough that the mirror opens
    /// within a beat or two of the device turning ready; long enough that a booting host is not
    /// answering a `list` and an `open` for the same panel every frame.
    static let reattemptPause: Duration = .milliseconds(1500)

    // MARK: The ensure loop

    /// Poll `ensure` until `.ready` (or cancellation). `host` is read per round — the connection
    /// target can change mid-loop, and a reconnect to a different host must not bake in the stale
    /// name.
    func poll(
        host: @MainActor () -> String?,
        ensure: () async -> MetadataCodec.ServiceEndpoint?,
        interval: Duration = .milliseconds(900),
    ) async {
        // A KNOWN-GOOD address survives a restart: this loop runs again every time the surface is
        // mounted, and resetting to `.starting` unconditionally would replace the whole surface for
        // one round trip on every return to the tab.
        if case .ready = phase {} else { phase = .starting }
        while !Task.isCancelled {
            let endpoint = await ensure()
            guard !Task.isCancelled else { return }
            phase = Self.phase(for: endpoint, host: host())
            bridge.endpoint = Self.address(of: phase)
            switch phase {
            case .ready: return
            case .starting: try? await Task.sleep(for: interval)
            case .offline,
                 .unavailable: try? await Task.sleep(for: interval * 4)
            }
        }
    }

    /// One ensure round's endpoint → the phase to render. Pure. A `ready` endpoint with no usable
    /// address degrades to `.offline`, never a trap.
    static func phase(
        for endpoint: MetadataCodec.ServiceEndpoint?, host: String?,
    ) -> AndroidSidebarPhase {
        guard let endpoint else { return .offline }
        switch endpoint.state {
        case .unavailable: return .unavailable
        case .starting: return .starting
        case .ready:
            guard let host, !host.isEmpty, endpoint.port != 0 else { return .offline }
            return .ready(host: host, port: endpoint.port)
        }
    }

    static func address(of phase: AndroidSidebarPhase) -> (host: String, port: UInt16)? {
        guard case let .ready(host, port) = phase else { return nil }
        return (host, port)
    }

    // MARK: The device loop

    /// Re-read the device list on a slow cadence for as long as the caller's task lives.
    ///
    /// Four seconds, matching the simulator panel, and the cost is not the same: each round is one
    /// `adb devices -l` plus one `adb shell` per RUNNING device. Devices that are `offline` or
    /// `unauthorized` are listed without a probe (host-side), which is what keeps a half-connected
    /// phone from spending the whole interval on a timeout.
    func watchDevices(interval: Duration = .seconds(4)) async {
        while !Task.isCancelled {
            await refreshDevices()
            try? await Task.sleep(for: interval)
        }
    }

    func refreshDevices() async {
        guard case .ready = phase else { return }
        switch await bridge.devices() {
        case let .success(list):
            devices = list
            failure = nil
            // A device that disappeared (unplugged, or an AVD deleted) cannot stay selected — the
            // mirror is already dead and the panel would show a frozen last frame forever.
            if let selection, !list.contains(where: { $0.key == selection }) {
                select(nil)
            }
        case let .failure(problem):
            failure = problem.message
        }
    }

    // MARK: Lifecycle actions

    /// Boot an AVD. Headless on the host — see the bridge's `boot`.
    ///
    /// The spinner holds until the boot is VISIBLE — the serial folded into this row — and not
    /// merely until the host accepts the launch, because the launch is fire-and-forget: `emulator`
    /// is spawned and the request returns. A play button that comes back while the emulator is
    /// still surfacing invites a second instance against the same AVD, which the emulator refuses
    /// with a lock error that reads as a broken panel. The wait is usually a second or two, but the
    /// fold rides the console answering, which under load can lag well past any polite cap — so the
    /// deadline here is long, and running out of it is a REPORTED failure, never a silently
    /// re-armed button. The boot itself is tens of seconds more, and the LIST carries that part:
    /// the named row says "Starting up…" from the attached shelf.
    func boot(_ device: AndroidDevice) async {
        guard let avd = device.avdName, device.serial == nil else { return }
        guard case .ready = phase, !pending.contains(device.key) else { return }
        pending.insert(device.key)
        defer { pending.remove(device.key) }
        if let problem = await bridge.boot(avd: avd) {
            failure = problem
            return
        }
        let key = device.key
        if await !holdWhilePending(deadline: Self.bootVisibleDeadline, until: {
            Self.bootIsVisible($0, key: key)
        }) {
            failure = "\(device.name) did not start."
        }
    }

    /// The launch has SURFACED: the booted serial folded into the row that was pressed. State does
    /// not matter — `offline` is a boot in progress and the row already says so from the shelf.
    static func bootIsVisible(_ list: [AndroidDevice], key: String) -> Bool {
        list.first { $0.key == key }?.serial != nil
    }

    /// The shutdown has LANDED: no row carries the serial any more, under whatever key the dying
    /// emulator was listed. Keyed on the serial rather than the row because the row itself outlives
    /// the shutdown — the AVD stays listed, merely no longer running.
    static func shutdownIsVisible(_ list: [AndroidDevice], serial: String) -> Bool {
        !list.contains { $0.serial == serial }
    }

    func shutdown(_ device: AndroidDevice) async {
        guard let serial = device.serial else { return }
        // Drop the mirror FIRST: shutting a device down with its socket open leaves the panel
        // decoding a stream about to be killed, and the frozen final frame reads as a hang.
        if selection == device.key { select(nil) }
        guard case .ready = phase, !pending.contains(device.key) else { return }
        pending.insert(device.key)
        defer { pending.remove(device.key) }
        if let problem = await bridge.shutdown(serial: serial) {
            failure = problem
            return
        }
        // `adb emu kill` is as fire-and-forget as the launch: it asks, and the serial leaves the
        // list whenever the emulator finishes dying. Holding the spinner until it is GONE is what
        // keeps the card from sitting there as a healthy-looking "Attached" with a pressable stop
        // for however long that takes.
        if await !holdWhilePending(deadline: Self.shutdownVisibleDeadline, until: {
            Self.shutdownIsVisible($0, serial: serial)
        }) {
            failure = "\(device.name) did not shut down."
        }
    }

    /// Polls the list until `until` sees the state change, or the deadline passes — the caller
    /// keeps its `pending` entry for the whole wait, which is the entire point: `pending` means
    /// "this device's state is in flight", and it must not resolve before the state does.
    ///
    /// One-second cadence rather than the watcher's four: this loop runs only while a lifecycle
    /// verb is outstanding, and it is also what carries the change to the screen sooner than the
    /// ambient poll would.
    private func holdWhilePending(
        deadline: Duration, until visible: ([AndroidDevice]) -> Bool,
    ) async -> Bool {
        let began = clock.now
        while clock.now - began < deadline {
            await refreshDevices()
            if visible(devices) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// How long a launch may stay invisible before the panel calls it failed. Generous on purpose:
    /// the serial itself registers within seconds, but its NAME (the fold) needs the QEMU console,
    /// whose accept-and-greet can lag on a loaded host.
    static let bootVisibleDeadline: Duration = .seconds(60)
    /// A snapshot save on the way down is the slow case (measured runs land well inside this).
    static let shutdownVisibleDeadline: Duration = .seconds(45)

    /// Stop every emulator that is running. Offered only where more than one is up, because that is
    /// the only place it is a different verb from the card's own stop button — and it is the state a
    /// day of testing leaves behind. Physical devices are never included: this panel may not power
    /// off someone's phone.
    ///
    /// Sequential rather than concurrent: `shutdown` refuses a second call for a key already in
    /// flight but not for a different one, and firing every shutdown at once would have each read
    /// the device list back while the others were still landing.
    func shutdownAll() async {
        for device in devices where device.isRunning && device.isEmulator {
            await shutdown(device)
        }
    }

    // MARK: The mirror

    /// Show `key`'s screen, or `nil` to go back to the list. Idempotent for the same device, so a
    /// re-render cannot restart a healthy stream.
    func select(_ key: String?) {
        guard key != selection else { return }
        stream?.disconnect()
        stream = nil
        settleStream()
        // DISCARD, not reset: the stage keys its screen on the selection, so this device's surface is
        // about to be replaced rather than reused — and it stays on screen through the navigation
        // transition, which a flush would spend on a blanked layer. See ``AndroidFrameSink/discard``.
        frames.discard()
        hasVideo = false
        selection = key
        // Every one of these is a claim about the PREVIOUS device.
        streamSize = nil
        lastEndReason = nil
        logLines.removeAll()
        isLogStarted = false
        logStream?.disconnect()
        logStream = nil

        guard let key, let device = devices.first(where: { $0.key == key }),
              case let .ready(host, port) = phase
        else {
            // Leaving the list open with the drawer still latched would reopen a console for whatever
            // gets selected next, which nobody asked for.
            isConsoleOpen = false
            return
        }
        // The drawer stays latched across a device switch — someone reading logs while stepping
        // between two devices means to keep reading logs — so the socket follows the selection.
        if isConsoleOpen { openConsole() }
        guard let serial = device.serial else {
            // Selected before the boot gave it a serial. The stage waits on the device rather than
            // stalling on a mirror that cannot exist yet.
            beginAwaiting(key)
            return
        }
        openStream(key, serial: serial, host: host, port: port)
    }

    /// The stage is waiting on the DEVICE, not on a socket: keep the veil up and look again shortly.
    private func beginAwaiting(_ key: String) {
        if awaitBegan == nil { awaitBegan = clock.now }
        isAwaitingStream = true
        scheduleReattempt(key)
    }

    /// Whether the current wait still has patience left. With no campaign running there is nothing
    /// to be out of patience with.
    private var withinGrace: Bool {
        awaitBegan.map { clock.now - $0 < Self.deviceGrace } ?? true
    }

    /// Open the mirror for `key` and start the clock on it. Shared by selection, resume and retry, so
    /// none of them can drift into a subtly different way of connecting.
    private func openStream(_ key: String, serial: String, host: String, port: UInt16) {
        if awaitBegan == nil { awaitBegan = clock.now }
        let connection = makeStream { [weak self] event in
            self?.handle(event, for: key)
        }
        stream = connection
        connection.connect(host: host, port: port, serial: serial, maxSize: Self.streamMaxSize)
        isAwaitingStream = true
        streamWatchdog?.cancel()
        streamWatchdog = Task { [weak self, firstFrameDeadline] in
            try? await Task.sleep(for: firstFrameDeadline)
            guard !Task.isCancelled else { return }
            await self?.reattemptStream(key)
        }
    }

    /// Try the selected device's mirror again, keeping everything else about the selection. The
    /// device is still the subject — its console stays subscribed — so this is deliberately not a
    /// re-selection, which would close it too.
    func retry() {
        guard let key = selection, case let .ready(host, port) = phase else { return }
        stream?.disconnect()
        stream = nil
        settleStream()
        failure = nil
        frames.reset()
        hasVideo = false
        guard let serial = serial(for: key) else {
            // The device lost its serial (a reboot in progress) — wait for it the same way a fresh
            // selection would, rather than refusing the click.
            beginAwaiting(key)
            return
        }
        openStream(key, serial: serial, host: host, port: port)
    }

    /// A frame arrived. Called on EVERY one, so it must be free once the first has landed — see the
    /// warning on ``hasVideo``.
    private func noteVideoArrived() {
        guard Self.videoArrivalIsNews(hasVideo: hasVideo, isAwaitingStream: isAwaitingStream) else {
            return
        }
        settleStream()
        lastEndReason = nil
        hasVideo = true
    }

    /// Whether an arriving frame has anything to tell the observable layer.
    ///
    /// The FIRST one does — it ends the wait and turns the stage from a veil into a screen. Every one
    /// after it says only what the layer already knows, and saying it anyway is a full SwiftUI
    /// invalidation per frame (``hasVideo``). Both flags are read because they can disagree: a retry
    /// re-arms the wait, so a stream that is awaited again is news again.
    static func videoArrivalIsNews(hasVideo: Bool, isAwaitingStream: Bool) -> Bool {
        !hasVideo || isAwaitingStream
    }

    /// The stream has answered — with video, with an error, or by the panel giving up. Ends the
    /// whole campaign: watchdog, reattempts and the patience clock all reset together.
    private func settleStream() {
        streamWatchdog?.cancel()
        streamWatchdog = nil
        reattempt.cancel()
        awaitBegan = nil
        isAwaitingStream = false
    }

    private func scheduleReattempt(_ key: String) {
        reattempt.arm(after: Self.reattemptPause) { [weak self] in
            await self?.reattemptStream(key)
        }
    }

    /// What to do about a selection with no video yet, given what the device list just said. Pure —
    /// the timing around it stays untested, the decision does not.
    ///
    /// This is the piece that turns a boot from a dead end into a wait. Measured 2026-08-07 against
    /// a cold boot: `open` is REFUSED for the first ~21 s (`offline`), can stall for ~15 s more the
    /// moment the state turns `device`, and succeeds cleanly after that — so a refused or silent
    /// attempt while the device is not (yet) running means "again shortly", not "broken".
    enum StreamVerdict: Equatable {
        /// The device is ready — open (or re-open) the mirror now.
        case connect
        /// Not ready yet, patience left — keep the veil up and look again shortly.
        case wait
        /// The device left the list entirely. Say so and go back; there is nothing to look at.
        case gone
        /// Patience ran out on a RUNNING device — the stall message, with the retry button.
        case stalled
        /// Patience ran out on a device that never reached `device` state.
        case neverReady
    }

    static func verdict(for device: AndroidDevice?, withinGrace: Bool) -> StreamVerdict {
        guard let device else { return .gone }
        switch (device.isRunning, withinGrace) {
        case (true, true): return .connect
        case (true, false): return .stalled
        case (false, true): return .wait
        case (false, false): return .neverReady
        }
    }

    /// The wait's one revisit point: the per-attempt watchdog and the reattempt pause both land
    /// here, ask the bridge what the device is NOW, and act on the verdict. The read-back is what
    /// turns a hang into a sentence — the panel's own list is up to four seconds stale, and the
    /// common causes (a boot in progress, a device that went away between poll and click) both live
    /// inside that staleness.
    private func reattemptStream(_ key: String) async {
        guard selection == key, isAwaitingStream, case let .ready(host, port) = phase else { return }
        let name = devices.first { $0.key == key }?.name ?? "This device"
        let live = try? await bridge.devices().get()
        // The await let the world move: a frame may have landed, or the selection moved on.
        guard selection == key, isAwaitingStream else { return }
        if let live { devices = live }
        let device = devices.first { $0.key == key }
        switch Self.verdict(for: device, withinGrace: withinGrace) {
        case .connect:
            guard let serial = device?.serial else { return }
            // A fresh socket rather than more patience with the silent one: the measured mid-boot
            // failure is an `open` that stalled inside the host's `adb push`, and the attempt after
            // it succeeds in under a second.
            stream?.disconnect()
            openStream(key, serial: serial, host: host, port: port)
        case .wait:
            stream?.disconnect()
            stream = nil
            scheduleReattempt(key)
        case .gone:
            settleStream()
            failure = "\(name) is no longer running."
            select(nil)
        case .stalled:
            settleStream()
            failure = lastEndReason ?? "The device is running, but no video has arrived."
        case .neverReady:
            settleStream()
            failure = lastEndReason ?? "\(name) never finished starting."
        }
    }

    /// Send one control message to the live mirror. No-op when nothing is selected.
    func send(_ message: Data) {
        stream?.send(message)
    }

    /// Send a sequence, in order. The hardware buttons are all down-then-up pairs.
    func send(_ messages: [Data]) {
        for message in messages { stream?.send(message) }
    }

    // MARK: Parking

    /// Drop the live sockets while KEEPING the selection — the surface has gone off screen (another
    /// panel tab, or the whole right column collapsed) and nobody is looking at this device.
    ///
    /// The simulator panel's measurement applies here with one addition that makes it matter more: a
    /// forgotten mirror keeps the DEVICE's hardware encoder running. On an emulator that is host CPU;
    /// on a plugged-in phone it is that phone's battery, for a rectangle in a collapsed panel.
    ///
    /// The last keyframe stays in the sink on purpose — ``resume()`` reconnects, and the replay shows
    /// the device as it was left rather than a black rectangle that fills a beat later.
    func park() {
        stream?.disconnect()
        stream = nil
        settleStream()
        logStream?.disconnect()
        logStream = nil
        isLogStarted = false
    }

    /// Re-open what ``park()`` dropped. Idempotent by the `stream == nil` guard.
    func resume() {
        guard stream == nil, !isAwaitingStream, let key = selection,
              case let .ready(host, port) = phase else { return }
        if isConsoleOpen { openConsole() }
        guard let serial = serial(for: key) else {
            // Parked while the device was still coming up — resume the wait, not just the socket.
            beginAwaiting(key)
            return
        }
        openStream(key, serial: serial, host: host, port: port)
    }

    // MARK: Device controls

    /// A hardware button, as the device's own key press.
    func press(_ keycode: AndroidKeycode) {
        send(AndroidControlMessage.keyPress(keycode))
    }

    /// Turn the device. `rotateDevice` is `scrcpy`'s own toggle rather than an absolute setting —
    /// there is no orientation to read back and none to remember, because the mirror's geometry
    /// follows the device: a turn restarts the encoder and the new session packet names the new size.
    /// That is why this model, unlike ``SimulatorSidebarModel``, carries no orientation state at all.
    func rotate() {
        send(AndroidControlMessage.simple(.rotateDevice))
    }

    /// Turn the DEVICE's own screen off while the mirror keeps running — `scrcpy`'s
    /// `SET_DISPLAY_POWER`. Worth a button because it is the one control with no equivalent anywhere
    /// else: a phone on a desk lighting up the room while someone mirrors it is a real annoyance, and
    /// the stream is unaffected.
    func setDisplayPower(on: Bool) {
        send(AndroidControlMessage.displayPower(on: on))
        show(notice: on ? "Device screen on" : "Device screen off")
    }

    /// Push text to the device's clipboard, optionally pasting it. Sequence 0 always — see
    /// ``AndroidControlMessage/setClipboard(_:paste:)`` for why an acknowledgement is unaskable here.
    func setClipboard(_ text: String, paste: Bool) {
        guard let message = AndroidControlMessage.setClipboard(text, paste: paste) else { return }
        send(message)
        show(notice: paste ? "Pasted to device" : "Copied to device")
    }

    /// The emulator console, for the things that are not input: GPS, battery, network, folding.
    ///
    /// Emulator-only by nature — the console is a QEMU feature — so the caller checks
    /// ``AndroidDevice/isEmulator`` before offering it.
    @discardableResult
    func console(_ command: String) async -> String? {
        guard let key = selection, let serial = serial(for: key) else { return nil }
        switch await bridge.console(command, serial: serial) {
        case let .success(output): return output
        case let .failure(problem):
            failure = problem.message
            return nil
        }
    }

    /// Capture the device's screen to the CLIPBOARD rather than to a file. A screenshot's next stop is
    /// almost always a message or a pull request, the app is sandboxed so a file needs a save panel in
    /// the way, and the pasteboard needs no permission at all. Same call the simulator panel makes.
    ///
    /// `key` defaults to the open device; the LIST passes one explicitly, because a running device's
    /// screen can be worth a picture without being worth opening.
    func copyScreenshot(of key: String? = nil) async {
        guard let key = key ?? selection, let serial = serial(for: key) else { return }
        switch await bridge.screenshot(serial: serial) {
        case let .success(png):
            // Decoded before it is written, not after: bytes the device truncated would otherwise
            // reach the pasteboard as something nothing can paste, and the panel would call that a
            // success.
            guard AndroidPasteboard.write(png: png) != nil else {
                failure = "The screenshot could not be read."
                return
            }
            show(notice: "Screenshot copied")
        case let .failure(problem):
            failure = problem.message
        }
    }

    /// The size the session packet named. The stream's only writer — see ``streamSize``.
    func observed(streamSize size: CGSize) {
        guard size.width > 0, size.height > 0, streamSize != size else { return }
        streamSize = size
    }

    func serial(for key: String) -> String? {
        devices.first { $0.key == key }?.serial
    }

    var selectedDevice: AndroidDevice? {
        guard let selection else { return nil }
        return devices.first { $0.key == selection }
    }

    // MARK: The console

    func toggleConsole() {
        if isConsoleOpen {
            closeConsole()
        } else {
            openConsole()
        }
    }

    /// Re-subscribe at a new level. `logcat` takes its filter spec at spawn time and has no way to
    /// change it on a live child, so this reconnects — and keeps the rows already collected, since
    /// dropping the history someone just widened the level to explain would be the wrong half to
    /// throw away.
    func setLogLevel(_ level: AndroidLogLevel) {
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
        guard let key = selection, let serial = serial(for: key),
              case let .ready(host, port) = phase else { return }
        let connection = makeLogStream { [weak self] event in
            self?.handle(event, for: key)
        }
        logStream = connection
        connection.connect(host: host, port: port, serial: serial, level: logLevel)
    }

    private func closeConsole() {
        isConsoleOpen = false
        isLogStarted = false
        logStream?.disconnect()
        logStream = nil
    }

    private func handle(_ event: AndroidLogEvent, for key: String) {
        // A late event from a socket opened for the previous device must not paint into this one's
        // console.
        guard selection == key, isConsoleOpen else { return }
        switch event {
        case .started:
            isLogStarted = true
        case let .lines(lines):
            append(lines)
        case let .ended(reason):
            isLogStarted = false
            if let reason { failure = reason }
        }
    }

    /// Append a batch and trim from the front. One splice per batch rather than per line: an
    /// observable write per line would make SwiftUI diff the whole console at `logcat`'s own rate,
    /// which on a booting device is hundreds of lines a second.
    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        logLines.append(contentsOf: lines.map { text in
            var line = AndroidLogLine.parse(text)
            logSequence &+= 1
            line.id = logSequence
            return line
        })
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
    }

    /// A failure raised by the VIEW rather than by a call.
    func report(_ text: String) {
        notice = nil
        noticeClear.cancel()
        failure = text
    }

    /// How long a confirmation stays up. Long enough to read one short line, short enough that it is
    /// gone before it can be mistaken for state.
    static let noticeLifetime: Duration = .seconds(2)

    private func show(notice text: String) {
        failure = nil
        notice = text
        noticeClear.arm(after: Self.noticeLifetime) { [weak self] in self?.notice = nil }
    }

    private func handle(_ event: AndroidStreamEvent, for key: String) {
        // A late event from a torn-down connection must not paint over the current one.
        guard selection == key else { return }
        switch event {
        case .opened:
            failure = nil
        case let .size(width, height):
            // The session packet names the geometry BEFORE the decoder can, which is what lets the
            // stage draw a correctly-shaped frame during the beat before the first keyframe.
            observed(streamSize: CGSize(width: width, height: height))
        case let .parameterSets(sets, codec):
            noteVideoArrived()
            frames.deliver(parameterSets: sets, codec: codec)
        case let .accessUnit(data, isKeyframe):
            noteVideoArrived()
            frames.deliver(accessUnit: data, isKeyframe: isKeyframe)
        case let .ended(reason):
            // An ended stream is a fact about the CONNECTION; whether it is a failure is a fact
            // about the DEVICE, and the reattempt loop is where the device gets asked. A refused
            // `open` against a booting device and a mirror that died mid-session both land here,
            // and both re-enter the same wait a fresh selection starts in — the veil, a look at
            // the list, and either a reconnect or, once patience runs out, the reason kept below.
            stream = nil
            hasVideo = false
            lastEndReason = reason
            streamWatchdog?.cancel()
            streamWatchdog = nil
            if awaitBegan == nil { awaitBegan = clock.now }
            isAwaitingStream = true
            scheduleReattempt(key)
        }
    }
}
#endif
