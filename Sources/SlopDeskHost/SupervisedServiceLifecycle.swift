import Foundation
import SlopDeskProtocol

// SupervisedServiceLifecycle — the two lifecycles the five sidecar managers in this target were
// each written out longhand, and the one number-reading they all end in.
//
// ``HostServiceProcess`` already held the shape's PROSE ("spawn with port 0 and learn the bound
// port from the child's own log line, merge stdout+stderr, probe with a bounded loopback connect")
// and its production seams. What it did not hold was the CODE, so the shape existed five times:
// `CodeServerManager`, `SimulatorServerManager` and `AndroidServiceManager` each carried their own
// `Instance` record, spawn generation, probe-and-latch and drop-the-exited-child head, and
// `InspectorServiceManager` and `FileDropServiceManager` were the same file twice down to the
// blank lines.
//
// The copies had already drifted in the way that is impossible to see one file at a time:
// `CodeServerManager.endpointLocked` wrote its updated record INSIDE the `if due` block and the
// other two wrote it after, and the dropd/inspectord port parse accepted a `:0` announce where
// androidd's rejected it. Neither difference was intended by anyone; both read as correct in
// isolation. That is the argument for one implementation — `docs/55` §6's `process::basename`
// precedent, in a second target.
//
// What is NOT here is anything about which daemon this is: the socket name, the announce marker,
// the argv, the env override and the reason a given spawn failure reads `unavailable` rather than
// `starting` all stay with the face, because those are the places the daemons genuinely disagree.

/// The last step of every announce parse: a run of digits is a port, and `0` never is.
///
/// A `:0` in an announce line is the port the child was ASKED for under `--port 0`, echoed back
/// before the OS had picked one — the one value that is always a lie. It was rejected by two of the
/// five parsers and accepted by three.
enum AnnouncedPort {
    /// The digit run IMMEDIATELY after `marker`, which ends with the address and its colon.
    ///
    /// The marker is matched exactly and the digits are taken as a run, so a build that adds words
    /// after the port keeps parsing. Deliberately not the last-colon rule: these lines carry a
    /// parenthetical after the port (`(adb 127.0.0.1:5037)`) whose own colon would win it.
    static func directlyAfter(_ marker: String, in line: String) -> UInt16? {
        guard let markerRange = line.range(of: marker) else { return nil }
        return port(line[markerRange.upperBound...].prefix(while: \.isNumber))
    }

    /// The digit run after the LAST colon of what follows `marker`, for a third-party framework
    /// line that names an address we do not control: bracketed IPv6, a bare IPv4 or a whole URL all
    /// put the port after the final colon and nothing else does.
    static func afterLastColonFollowing(_ marker: String, in line: String) -> UInt16? {
        guard let markerRange = line.range(of: marker) else { return nil }
        let rest = line[markerRange.upperBound...]
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        return port(rest[rest.index(after: colon)...].prefix(while: \.isNumber))
    }

    private static func port(_ digits: Substring) -> UInt16? {
        guard let port = UInt16(digits), port > 0 else { return nil }
        return port
    }
}

/// The OTHER fact an announce line carries: the crate version of the process that printed it.
///
/// It rides this line rather than a handshake because these three daemons outlive hostd — hostd
/// re-learns a survivor's port by replaying superd's ring, so the line is already the one channel
/// that describes a child hostd did not start. A version learned anywhere else would be missing on
/// exactly the path that needs it.
///
/// Only OUR daemons announce one. `code-server` and the simulator server print third-party lines we
/// do not control, so their managers pass no version parser and read `nil` — "unknown", which the
/// audit never turns into "current".
enum AnnouncedVersion {
    /// Spelled identically as `ANNOUNCE_VERSION_PREFIX` in the three announcing daemons' `server.rs`,
    /// and compared by `scripts/check-supervisor.sh`.
    static let marker = "(v"

    /// The version between ``marker`` and the parenthetical's first `,` or `)`, searched from the
    /// end of `portMarker` so a `(v` inside a path earlier on the line cannot win.
    ///
    /// The daemons put it FIRST in the parenthetical for that reason, and so the position holds
    /// however the rest of that text grows. Empty parses to `nil` — an empty string is not a
    /// version, and reporting one as if it were would compare unequal to every real one forever.
    static func directlyAfter(_ portMarker: String, in line: String) -> String? {
        guard let markerRange = line.range(of: portMarker) else { return nil }
        let rest = line[markerRange.upperBound...]
        guard let versionRange = rest.range(of: marker) else { return nil }
        let version = rest[versionRange.upperBound...].prefix { $0 != "," && $0 != ")" }
        return version.isEmpty ? nil : String(version)
    }
}

/// The lifecycle of a sidecar whose port the OS picks: spawn once, learn the port from the child's
/// own line, probe until it answers, and report where it stands RIGHT NOW — never wait.
///
/// The never-wait contract is why this type exists in the shape it does. Its callers sit on
/// per-session metadata queues answering an RPC whose client-side timeout is 5 s, and every one of
/// these children does something slow first (a Node boot, a CoreSimulator device-set enumeration,
/// an SDK locate). So `ensure` answers `starting` and the client polls, which it already does.
///
/// Crash recovery is implicit: a child that exited reads `isRunning == false` on the next round,
/// which drops the record and lets the face boot a fresh one.
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes' requests
/// race. A face with boot state of its own puts it under THIS lock via ``locked(_:)`` rather than
/// taking a second one — one lock per service, in the order the callers already had.
final class ProbedPortService: @unchecked Sendable {
    /// What a face's boot closure answers.
    enum Boot {
        /// A child is up. The service takes the handle and reports `starting` — the port arrives
        /// later, on the child's own line.
        case spawned(any HostServiceProcessHandle)
        /// No child this round, and the state to report instead. The faces disagree here on
        /// purpose: a spawn that THREW is `unavailable` for the panel backends (a broken binary
        /// reads the same as an absent one) and `starting` for androidd (superd unreachable or a
        /// thread limit is transient, and the client's poll retries).
        case notYet(MetadataCodec.ServiceState)
    }

    private struct Instance {
        var handle: any HostServiceProcessHandle
        /// Learned from the child's announce line; `nil` until it prints one.
        var port: UInt16?
        /// The crate version off the same line. `nil` for a third-party backend that announces no
        /// version, and for one that predates the field — both mean "unknown", never "current".
        var version: String?
        /// Latched on the first successful probe — a listening server is never un-probed.
        var ready = false
        var lastProbe: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var instance: Instance?
    /// Bumped per spawn; a stale child's log sink (a respawn raced its last line) must not write
    /// its old port onto the fresh instance record.
    private var spawnGeneration = 0
    private let probe: HostServiceProcess.ReadinessProbe
    private let probeInterval: Duration
    private let clock = ContinuousClock()

    init(
        readinessProbe: @escaping HostServiceProcess.ReadinessProbe,
        probeInterval: Duration = .milliseconds(500),
    ) {
        probe = readinessProbe
        self.probeInterval = probeInterval
    }

    /// The whole round, for a face whose only boot decision is "is there a binary, and did the
    /// spawn work": report on the live child, or call `boot` to make one.
    func ensure(boot: (_ generation: Int) -> Boot) -> MetadataCodec.ServiceEndpoint {
        locked { bootLocked(boot) }
    }

    /// ``ensure(boot:)``'s body, already holding the lock — for a face that has gates of its own to
    /// walk under the same lock (`CodeServerManager`'s settings seed, bridge bind and one-shot
    /// extension install), and a second entry point that has to re-run the boot in place.
    func bootLocked(_ boot: (_ generation: Int) -> Boot) -> MetadataCodec.ServiceEndpoint {
        if let live = liveEndpointLocked() { return live }
        spawnGeneration += 1
        switch boot(spawnGeneration) {
        case let .spawned(handle):
            instance = Instance(handle: handle)
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        case let .notYet(state):
            // Deliberately no record: a boot that did not produce a child must leave nothing
            // behind, so the next round tries again rather than observing a phantom.
            return MetadataCodec.ServiceEndpoint(state: state, port: 0)
        }
    }

    /// Runs `body` under the service's lock. For a face that keeps boot state beside the child's.
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The log sink to hand the spawner: it parses every line and records the port, unless a
    /// respawn has already superseded the generation that produced it (a dying child's last line
    /// must not poison the new record).
    ///
    /// `parseVersion` runs on the SAME line and is separate because the two facts have different
    /// availability: every backend here announces a port, only ours announces a version.
    ///
    /// Weak on purpose — the service holds the handle that holds this closure.
    func portSink(
        generation: Int,
        parseVersion: (@Sendable (String) -> String?)? = nil,
        parse: @escaping HostServiceProcess.PortParser,
    ) -> @Sendable (String) -> Void {
        { [weak self] line in
            // The version is read off the announce line, so it must be recorded BEFORE the port —
            // `servedPort` turning non-nil is what a caller waits on, and a version that landed
            // after it would be missed by anyone who audited on that signal.
            if let version = parseVersion?(line) {
                self?.recordVersion(version, spawnedAs: generation)
            }
            guard let port = parse(line) else { return }
            self?.recordPort(port, spawnedAs: generation)
        }
    }

    /// The port the running child announced, once it has.
    var servedPort: UInt16? {
        locked { instance?.port }
    }

    /// The crate version the running child announced, or `nil` when it announced none.
    var announcedVersion: String? {
        locked { instance?.version }
    }

    /// Drops the record and answers the handle, for the caller to end (``shutdown``) or release
    /// (``relinquish``). `alsoUnderLock` is the face's own forgetting, kept in the same critical
    /// section as this one.
    func forget(_ alsoUnderLock: () -> Void = {}) -> (any HostServiceProcessHandle)? {
        locked {
            let stranded = instance
            instance = nil
            alsoUnderLock()
            return stranded?.handle
        }
    }

    // MARK: - Internals

    /// The endpoint of the LIVE child, or `nil` when there is none to report on — the caller's cue
    /// to boot. Drops a child that has exited. Caller holds the lock.
    private func liveEndpointLocked() -> MetadataCodec.ServiceEndpoint? {
        guard let existing = instance else { return nil }
        guard existing.handle.isRunning else {
            instance = nil
            return nil
        }
        return endpointLocked(for: existing)
    }

    /// The endpoint for a LIVE instance, probing readiness at most once per ``probeInterval``.
    /// Mutates the record (latched `ready`, probe stamp) — caller holds the lock.
    private func endpointLocked(for live: Instance) -> MetadataCodec.ServiceEndpoint {
        guard let port = live.port else {
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        if live.ready {
            return MetadataCodec.ServiceEndpoint(state: .ready, port: port)
        }
        var updated = live
        let now = clock.now
        let due = live.lastProbe.map { now - $0 >= probeInterval } ?? true
        if due {
            updated.lastProbe = now
            updated.ready = probe(port)
        }
        instance = updated
        // The learned port rides along even while starting: it is the honest answer to "where will
        // it be", and the client gates on the STATE.
        return MetadataCodec.ServiceEndpoint(state: updated.ready ? .ready : .starting, port: port)
    }

    private func recordPort(_ port: UInt16, spawnedAs generation: Int) {
        locked {
            guard generation == spawnGeneration, var live = instance, live.port == nil else { return }
            live.port = port
            instance = live
        }
    }

    /// Same first-writer-wins rule as ``recordPort(_:spawnedAs:)``, for the same reason: the child
    /// announces once, and a later line that happened to contain the marker is not a new fact.
    private func recordVersion(_ version: String, spawnedAs generation: Int) {
        locked {
            guard generation == spawnGeneration, var live = instance, live.version == nil else { return }
            live.version = version
            instance = live
        }
    }
}

/// The lifecycle of a sidecar whose port hostd CHOOSES: spawn (or adopt a survivor), wait a bounded
/// while for the child's announce line, and verify that what it announced is the port this hostd
/// advertises — respawning it when it is not.
///
/// The waiting is the difference from ``ProbedPortService``, and it is affordable for exactly one
/// reason: these two run on hostd's STARTUP path, where there is no RPC deadline to miss, and the
/// port they serve is going into a metadata answer that must be right the first time. There is no
/// readiness probe here for the same reason — a daemon that printed its announce line has bound.
///
/// ## Why the port is VERIFIED after an adopt
/// The pane id is stable (`service:<name>`, `docs/51` §1) but the port is not: a hostd started on a
/// different `--port` wants a different sidecar port, and the survivor is on the old one. Adopting
/// it would leave hostd advertising a port nothing listens on, which fails with no log line to say
/// why. So the announced port is compared against the wanted one, and a mismatch is ended and
/// respawned — the same answer a daemon that never spoke at all gets.
final class AnnouncedPortService: @unchecked Sendable {
    private let lock = NSLock()
    private let spawn: HostServiceProcess.Spawner
    private let locateBinary: HostServiceProcess.BinaryLocator
    private let parsePort: HostServiceProcess.PortParser
    private let parseVersion: (@Sendable (String) -> String?)?
    private let announceTimeout: Duration
    private var handle: (any HostServiceProcessHandle)?
    private var announcedPort: UInt16?
    private var announcedVersionValue: String?

    /// - Parameters:
    ///   - parseAnnouncedVersion: reads the crate version off the same line. Optional because only
    ///     the daemons in this repo print one.
    ///   - announceTimeout: how long ``start(port:arguments:)`` waits for the child's announce line
    ///     before giving up on verifying the port. Bounded, because this runs on the daemon's
    ///     startup path.
    init(
        spawner: @escaping HostServiceProcess.Spawner,
        binaryLocator: @escaping HostServiceProcess.BinaryLocator,
        parseAnnouncedPort: @escaping HostServiceProcess.PortParser,
        parseAnnouncedVersion: (@Sendable (String) -> String?)? = nil,
        announceTimeout: Duration = .seconds(3),
    ) {
        spawn = spawner
        locateBinary = binaryLocator
        parsePort = parseAnnouncedPort
        parseVersion = parseAnnouncedVersion
        self.announceTimeout = announceTimeout
    }

    /// Brings the daemon up on `port`, adopting a survivor when there is one.
    ///
    /// Returns the port actually being served, or `nil` when there is no binary, superd is
    /// unreachable, or the child never announced. A `nil` is NOT fatal to hostd: it logs and serves
    /// the other paths, exactly as a failed bind used to.
    @discardableResult
    func start(port: UInt16, arguments: [String]) async -> UInt16? {
        guard let binary = locateBinary() else { return nil }
        guard let first = try? launch(binary: binary, arguments: arguments) else { return nil }
        if let announced = await awaitAnnouncedPort(), announced == port { return announced }

        // Either it never spoke, or it is the survivor of a hostd that wanted a different port.
        // Both are answered the same way: end it and start one on the port this hostd advertises.
        first.terminate()
        clearAnnouncement()
        guard let second = try? launch(binary: binary, arguments: arguments) else { return nil }
        guard let announced = await awaitAnnouncedPort(), announced == port else {
            second.terminate()
            return nil
        }
        return announced
    }

    /// Lets the daemon GO: hostd stops listening to its log and superd keeps it, with everything it
    /// had in flight. What a daemon SHUTDOWN calls.
    func relinquish() {
        forget()?.relinquish()
    }

    /// Ends the daemon for good. Only a deliberate stop may call it.
    func shutdown() {
        forget()?.terminate()
    }

    /// The port the running daemon announced, once it has.
    var servedPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return announcedPort
    }

    /// The crate version the running daemon announced, or `nil` when it announced none.
    var announcedVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return announcedVersionValue
    }

    // MARK: - Internals

    private func forget() -> (any HostServiceProcessHandle)? {
        lock.lock()
        let stranded = handle
        handle = nil
        announcedPort = nil
        announcedVersionValue = nil
        lock.unlock()
        return stranded
    }

    private func launch(binary: String, arguments: [String]) throws -> any HostServiceProcessHandle {
        let parse = parsePort
        let version = parseVersion
        let started = try spawn(binary, arguments) { [weak self] line in
            // Before the port, for the reason ``ProbedPortService/portSink(generation:parseVersion:parse:)``
            // gives: `servedPort` is what callers wait on, so anything learned after it is missed.
            if let announced = version?(line) { self?.recordVersion(announced) }
            guard let port = parse(line) else { return }
            self?.recordPort(port)
        }
        lock.lock()
        handle = started
        lock.unlock()
        return started
    }

    private func awaitAnnouncedPort() async -> UInt16? {
        let deadline = ContinuousClock.now + announceTimeout
        while ContinuousClock.now < deadline {
            if let port = servedPort { return port }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return servedPort
    }

    private func recordPort(_ port: UInt16) {
        lock.lock()
        announcedPort = port
        lock.unlock()
    }

    private func recordVersion(_ version: String) {
        lock.lock()
        announcedVersionValue = version
        lock.unlock()
    }

    private func clearAnnouncement() {
        lock.lock()
        announcedPort = nil
        announcedVersionValue = nil
        lock.unlock()
    }
}
