import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import Synchronization
@testable import SlopDeskClient

/// The ONE test double every suite in this target drives a ``SlopDeskClient`` with.
///
/// `docs/63` stage G.5. What this replaces was eleven bespoke `ClientTransporting` actors, each
/// re-implementing an inbound stream, a session id, a resume-from-seq and a set of no-op sends — and
/// each, being a transport under a Swift session, quietly re-deciding a little of what the session
/// did. There is nothing left to re-decide: the dedup, the ack cadence, the resume verdict and the
/// retry ladder are all `rust/slopdesk-clientdriver`'s, so a double at ``PaneDriving`` can only SAY
/// what arrived. That is why one double serves every suite here rather than eleven serving one each.
///
/// It is a `final class` with a lock rather than an actor because ``PaneDriving`` is SYNCHRONOUS by
/// design — the shipping driver blocks a thread on a mailbox — and an actor cannot conform to a
/// synchronous protocol without every method becoming a hop the real one does not have.
///
/// The lock is an `NSLock` and not a `Mutex`, alone in this target: it sits beside two
/// `NSCondition`s that gate the parked dials, and a condition variable is a WAIT — a scoped
/// `withLock` has no way to express one. Splitting the state across both spellings would put half
/// the driver's fields where the conditions cannot reach them.
final class FakePaneDriver: PaneDriving, @unchecked Sendable {
    /// What ``connect(host:port:handshakeTimeout:)`` and ``resume(handshakeTimeout:)`` do.
    enum Dial: Sendable {
        /// Answers `.connected` at once, minting a session id on the first dial.
        case connects
        /// Answers `.superseded`: a close or a pause landed while dialling.
        case supersedes
        /// Throws, which the view model must read as "the host is unreachable".
        case fails(reason: String)
        /// BLOCKS the calling thread until ``release()``, then answers `.connected`.
        ///
        /// A condition variable and not a continuation: the caller here is
        /// `SlopDeskClient.offCallerThread`'s Dispatch global, so parking it is parking a GCD thread
        /// rather than suspending a cooperative one. `onDialStarted` fires just before the wait, so a
        /// suite can await "the handshake is in flight" without polling.
        case gated
    }

    /// A driver for a session the suite never dials, and must fail loudly if it ever does.
    ///
    /// The `fatalError` this replaces said the same thing and said it by killing the test PROCESS,
    /// which took every other suite in the target with it. A throw reaches the view model as the
    /// failure it would be, and `why` — the sentence the old `fatalError` carried — lands in
    /// whichever assertion notices.
    static func inert(_ why: String) -> FakePaneDriver {
        let driver = FakePaneDriver()
        driver.dial = .fails(reason: why)
        return driver
    }

    // MARK: - Knobs

    /// How the next dial answers. Settable mid-test — a suite that gates the first dial and lets the
    /// second through flips this between them.
    var dial: Dial {
        get { withLock { _dial } }
        set { withLock { _dial = newValue } }
    }

    /// Fired on the dialling thread the moment a `.gated` dial parks.
    var onDialStarted: (@Sendable () -> Void)?

    /// Parks the FIRST ``takeOutput()`` until ``releaseTake()``.
    ///
    /// The one interleaving point the output pump has: a batch is IN HAND and the epoch it was
    /// snapshot under is fixed, while the main actor is still free to land a reconnect. Set it before
    /// the first delivery; ``takeEntered`` says the park has happened.
    var gatesFirstTake = false

    /// Whether the gated take has parked yet.
    var takeEntered: Bool {
        takeGate.lock()
        defer { takeGate.unlock() }
        return _takeEntered
    }

    /// Releases the gated take, and every later one.
    func releaseTake() {
        takeGate.lock()
        _takeReleased = true
        takeGate.broadcast()
        takeGate.unlock()
    }

    /// Fired on every `sendControl`, after it is recorded — where a suite that ECHOES a host reply
    /// puts the echo. It is the one place a double may put words in the host's mouth, and it is a
    /// hook rather than a subclass because the shipping driver has no subclass either.
    var onControl: (@Sendable (WireMessage) -> Void)?

    /// Slept inside every THIRD `sendInput` / `sendResize`, to scramble any ordering the caller did
    /// not actually impose. Zero by default.
    ///
    /// Every third rather than every one, and a sleep rather than a random delay: the failure this
    /// catches is a `Task`-per-event send, where independent tasks hop in scheduler order rather
    /// than creation order. One reliable stall mid-run is enough to expose that, and it is the same
    /// run every time.
    var sendJitter: Duration = .zero

    /// What ``resumeOutcome`` reports. The driver derives this from the seq stream; here it is stated.
    var resumeOutcome: SlopDeskClient.SessionResumeOutcome {
        get { withLock { _resumeOutcome } }
        set { withLock { _resumeOutcome = newValue } }
    }

    var smoothedRTTMS: Double? {
        get { withLock { _rtt } }
        set { withLock { _rtt = newValue } }
    }

    var highestContiguousSeq: Int64 {
        get { withLock { _seq } }
        set { withLock { _seq = newValue } }
    }

    // MARK: - What was recorded

    /// Every `sendInput`, in the order the driver saw them.
    var sentInput: [Data] { withLock { _sentInput } }
    /// Every `sendResize`, in order.
    var sentResizes: [(cols: UInt16, rows: UInt16)] { withLock { _sentResizes } }
    /// Every `sendControl`, in order.
    var sentControl: [WireMessage] { withLock { _sentControl } }
    /// How many dials were attempted, gated or not.
    var dialCount: Int { withLock { _dialCount } }
    var pauseCount: Int { withLock { _pauseCount } }
    var closeCount: Int { withLock { _closeCount } }
    var initialCwd: String? { withLock { _initialCwd } }

    // MARK: - Driving the session

    /// Emits one lifecycle event to whoever ``SlopDeskClient`` attached.
    func deliver(_ event: SlopDeskClient.Event) { sinks().events?(event) }

    /// Emits one INBOUND wire message, folded exactly as the shipping driver folds it. A verb the
    /// fold drops is dropped here too, which is the point of routing through it.
    func deliverWire(_ message: WireMessage) {
        guard let event = SlopDeskClient.Event(message) else { return }
        deliver(event)
    }

    /// Appends output bytes and wakes the single consumer, once per chunk — LEVEL-triggered, the way
    /// the door is.
    func deliverOutput(_ bytes: Data) {
        withLock { _inbox.append(bytes) }
        sinks().wake?()
    }

    /// The host closed this pane's channel. Sets the reason the store's redial fan-out reads, and
    /// surfaces the `.disconnected` a real close would.
    func hostClose(_ reason: MuxCloseReason) {
        withLock {
            _hostCloseReason = reason
            _live = false
        }
        deliver(.disconnected(reason: "host closed the channel"))
    }

    /// Releases a `.gated` dial.
    func release() {
        gate.lock()
        _released = true
        gate.broadcast()
        gate.unlock()
    }

    // MARK: - PaneDriving

    func attach(
        events: @escaping @Sendable (SlopDeskClient.Event) -> Void,
        wake: @escaping @Sendable () -> Void,
    ) {
        withLock {
            _events = events
            _wake = wake
        }
    }

    func setInitialCwd(_ cwd: String?) { withLock { _initialCwd = cwd } }

    func connect(host _: String, port _: UInt16, handshakeTimeout _: Duration) throws -> PaneDialOutcome {
        let mode = withLock { () -> Dial in
            _dialCount += 1
            return _dial
        }
        switch mode {
        case .connects:
            withLock {
                _sessionID = _sessionID ?? UUID()
                _live = true
            }
            return .connected
        case .supersedes:
            return .superseded
        case let .fails(reason):
            throw ClientError.notConnected(reason)
        case .gated:
            onDialStarted?()
            gate.lock()
            while !_released { gate.wait() }
            gate.unlock()
            withLock {
                _sessionID = _sessionID ?? UUID()
                _live = true
            }
            return .connected
        }
    }

    func resume(handshakeTimeout: Duration) throws -> PaneDialOutcome {
        let outcome = try connect(host: "", port: 0, handshakeTimeout: handshakeTimeout)
        // A resume that LANDED is no longer paused, and `isPaused` is what the chrome reads to decide
        // whether a pane is holding or dead. Leaving the pause count standing would report a live
        // session as paused for the rest of its life.
        if outcome == .connected { withLock { _pauseCount = 0 } }
        return outcome
    }

    func pause() {
        withLock {
            _pauseCount += 1
            _live = false
        }
        deliver(.disconnected(reason: "paused"))
    }

    func close() {
        withLock {
            _closeCount += 1
            _closed = true
            _live = false
        }
    }

    func sendInput(_ bytes: Data) throws {
        try requireLive()
        jitter()
        withLock { _sentInput.append(bytes) }
    }

    func sendResize(cols: UInt16, rows: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) throws {
        try requireLive()
        jitter()
        withLock { _sentResizes.append((cols: cols, rows: rows)) }
    }

    func sendControl(_ message: WireMessage) throws {
        try requireLive()
        withLock { _sentControl.append(message) }
        onControl?(message)
    }

    /// Refuses a send on a link that is not up, the way the driver's `SendError::NotConnected` does.
    ///
    /// Without this a double would silently ACCEPT a request made before the first dial, and the
    /// caller — `MetadataClient`, say — would wait out its whole timeout for a reply nobody was ever
    /// going to send. A refusal is the answer that lets it fail immediately.
    private func requireLive() throws {
        guard withLock({ _live }) else {
            throw ClientError.notConnected("the pane driver has no live channel")
        }
    }

    func flushAck() {}

    func takeOutput() -> [Data] {
        if gatesFirstTake {
            takeGate.lock()
            if !_takeArmed {
                _takeArmed = true
                _takeEntered = true
                while !_takeReleased { takeGate.wait() }
            }
            takeGate.unlock()
        }
        return withLock {
            let taken = _inbox
            _inbox.removeAll(keepingCapacity: true)
            return taken
        }
    }

    var sessionID: UUID? {
        get { withLock { _sessionID } }
        set { withLock { _sessionID = newValue } }
    }

    var isPaused: Bool { withLock { _pauseCount > 0 && !_closed } }
    var isClosed: Bool { withLock { _closed } }
    var isExited: Bool { withLock { _exited } }
    var hostCloseReason: MuxCloseReason? { withLock { _hostCloseReason } }

    /// Marks the remote child gone, which is terminal for the session.
    func markExited(code: Int32 = 0) {
        withLock { _exited = true }
        deliver(.exit(code: code))
    }

    // MARK: - State

    private let lock = NSLock()
    private let gate = NSCondition()
    private var _released = false
    private let takeGate = NSCondition()
    private var _takeArmed = false
    private var _takeEntered = false
    private var _takeReleased = false

    private var _dial: Dial = .connects
    private var _dialCount = 0
    private var _pauseCount = 0
    private var _closeCount = 0
    private var _closed = false
    private var _live = false
    private var _exited = false
    private var _sessionID: UUID?
    private var _seq: Int64 = 0
    private var _rtt: Double?
    private var _resumeOutcome: SlopDeskClient.SessionResumeOutcome = .undetermined
    private var _hostCloseReason: MuxCloseReason?
    private var _initialCwd: String?
    private var _inbox: [Data] = []
    private var _sendCount = 0
    private var _sentInput: [Data] = []
    private var _sentResizes: [(cols: UInt16, rows: UInt16)] = []
    private var _sentControl: [WireMessage] = []
    private var _events: (@Sendable (SlopDeskClient.Event) -> Void)?
    private var _wake: (@Sendable () -> Void)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Reads both sinks under ONE acquisition and calls neither while holding it — a sink re-enters
    /// this object (a subscriber that reads `sessionID` on the event) and would deadlock otherwise.
    private func sinks() -> (events: (@Sendable (SlopDeskClient.Event) -> Void)?, wake: (@Sendable () -> Void)?) {
        withLock { (_events, _wake) }
    }

    private func jitter() {
        guard sendJitter > .zero else { return }
        let due = withLock { () -> Bool in
            _sendCount += 1
            return _sendCount.isMultiple(of: 3)
        }
        guard due else { return }
        Thread.sleep(forTimeInterval: Double(sendJitter.components.attoseconds) / 1e18
            + Double(sendJitter.components.seconds))
    }
}

/// Mints ``FakePaneDriver``s and keeps every one it handed out.
///
/// Half the suites here assert on the COUNT — "a remount must not dial a second time", "the redial
/// fan-out reached the detached pane too" — and the other half need the driver a `makeClient`
/// closure just built, which is otherwise unreachable from the test body. One recorder answers both,
/// and `configure` is where a suite states what kind of driver it wants before the session gets it.
final class PaneDriverRecorder: @unchecked Sendable {
    /// Applied to each driver before it is handed out. Set it BEFORE the first dial.
    ///
    /// The one reason this recorder is still `@unchecked`: a suite writes it before the first dial,
    /// not concurrently with one. Everything the dials themselves touch is inside the `Mutex`.
    var configure: (@Sendable (FakePaneDriver) -> Void)?

    private struct Log {
        var made: [FakePaneDriver] = []
        var started = 0
    }

    private let log = Mutex(Log())
    private let gated: Bool

    /// - Parameter gated: every minted driver parks its dial until ``releaseAll()``, and each park is
    ///   counted in ``startedDials``. This is how a suite pins "at most ONE handshake is in flight":
    ///   the count is what a second, wrongly-concurrent dial would move.
    init(gated: Bool = false, configure: (@Sendable (FakePaneDriver) -> Void)? = nil) {
        self.gated = gated
        self.configure = configure
    }

    /// How many drivers were minted, which is how many dials were attempted.
    var count: Int { log.withLock { $0.made.count } }

    /// How many gated dials have reached their park.
    var startedDials: Int { log.withLock { $0.started } }

    /// Every driver in mint order.
    var drivers: [FakePaneDriver] { log.withLock { $0.made } }

    /// The most recent driver, or `nil` before the first dial.
    var last: FakePaneDriver? { drivers.last }

    /// Every `sendInput` byte across every driver, concatenated in send order.
    ///
    /// Across ALL of them rather than the newest, because the ORDER question these suites ask spans
    /// a teardown: a keystroke sent before a re-dial and one sent after must still come out in call
    /// order, and reading one driver would silently drop half the evidence.
    var inputBytes: Data { drivers.flatMap(\.sentInput).reduce(into: Data()) { $0 += $1 } }

    /// Every `sendResize` across every driver, in order.
    var resizes: [(cols: UInt16, rows: UInt16)] { drivers.flatMap(\.sentResizes) }

    func make() -> FakePaneDriver {
        let driver = FakePaneDriver()
        if gated {
            driver.dial = .gated
            driver.onDialStarted = { [weak self] in
                self?.log.withLock { $0.started += 1 }
            }
        }
        configure?(driver)
        log.withLock { $0.made.append(driver) }
        return driver
    }

    /// Polls until `n` gated dials have parked. Bounded, so a broken serialization fails the suite
    /// with an assertion rather than hanging the whole target.
    func waitForStartedDials(_ n: Int, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while startedDials < n, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Releases every gated dial minted SO FAR.
    ///
    /// A driver minted afterwards parks again, which is what lets a suite step through a serialized
    /// ladder one dial at a time: release, wait for the next park, release again.
    func releaseAll() { for driver in drivers { driver.release() } }
}

/// ``PaneDriverRecorder`` keyed by ``PaneID``, for the store-level suites.
///
/// Those suites assert on WHICH pane opened a channel and how many times — "the fan-out reached
/// the evicted pane", "nothing dialled the reaped one" — so the order of ids is the evidence and
/// the live driver per pane is how the host is played against it.
final class PaneDialLedger: Sendable {
    private struct Ledger {
        var ids: [PaneID] = []
        var live: [PaneID: FakePaneDriver] = [:]
    }

    private let ledger = Mutex(Ledger())

    /// Every dial, in order, as the pane that made it.
    var dialled: [PaneID] { ledger.withLock { $0.ids } }

    /// How many channels `pane` has opened over the whole run.
    func count(_ pane: PaneID) -> Int { dialled.filter { $0 == pane }.count }

    /// The driver behind `pane`'s CURRENT channel.
    func driver(for pane: PaneID) -> FakePaneDriver? { ledger.withLock { $0.live[pane] } }

    func make(for pane: PaneID) -> FakePaneDriver {
        let driver = FakePaneDriver()
        ledger.withLock {
            $0.ids.append(pane)
            $0.live[pane] = driver
        }
        return driver
    }
}
