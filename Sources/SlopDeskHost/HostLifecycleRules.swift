import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

// MARK: - HostServiceRules (what the two sidecar lifecycles decide)

/// The decisions behind ``ProbedPortService``, ``AnnouncedPortService`` and the workbench's boot
/// gates, as `slopdesk-sidecars::service_lifecycle` answers them.
///
/// The shells above stay here because a `Process`, an `NSLock` and a `Task` are what they are. What
/// left is every question asked between two syscalls: which digits on a log line are a port, when a
/// readiness probe is due, whether a survivor on the wrong port may be adopted, and which of the
/// workbench's four gates a given boot round has to walk.
///
/// Nothing here is told WHICH daemon it is. Every announce marker crosses as an argument — including
/// the `(v` that precedes a version, whose spelling `rust/slopdesk-invariants` compares between
/// ``AnnouncedVersion/marker`` and each daemon's `server.rs`. A copy inside the artifact would be a
/// third spelling nothing compares.
public enum HostServiceRules {
    // MARK: The announce line

    /// The port a child announced, or `nil` when this line carries none.
    ///
    /// `afterLastColon` picks the dialect: `false` takes the digit run IMMEDIATELY after `marker`
    /// (our daemons, whose lines carry a parenthetical with a colon of its own), `true` the run
    /// after the LAST colon of what follows it (a third-party line naming an address we do not
    /// control — bracketed IPv6, a bare IPv4 and a whole URL all put the port there).
    ///
    /// A `:0` is the port the child was ASKED for under `--port 0`, echoed back before the OS had
    /// picked one, and is never an answer — which is why `0` can be the door's "none".
    public static func announcedPort(
        marker: String, in line: String, afterLastColon: Bool = false,
    ) -> UInt16? {
        let found = Array(marker.utf8).withUnsafeBufferPointer { needle in
            Array(line.utf8).withUnsafeBufferPointer { haystack in
                slopdesk_host_announced_port(
                    needle.baseAddress, needle.count,
                    haystack.baseAddress, haystack.count,
                    afterLastColon,
                )
            }
        }
        return found == 0 ? nil : found
    }

    /// The crate version off the same announce line, searched from the end of `portMarker` so a
    /// `(v` inside a path earlier on the line cannot win. `nil` when the line announces none —
    /// which is the ordinary answer for a third-party backend, and means "unknown", never
    /// "current".
    public static func announcedVersion(
        portMarker: String, versionMarker: String, in line: String,
    ) -> String? {
        // A crate version is a handful of bytes; the guess is the whole line, which is an upper
        // bound by construction, so the size-then-retry path is never travelled.
        var room = [UInt8](repeating: 0, count: max(1, line.utf8.count))
        let needed = Array(portMarker.utf8).withUnsafeBufferPointer { port in
            Array(versionMarker.utf8).withUnsafeBufferPointer { version in
                Array(line.utf8).withUnsafeBufferPointer { haystack in
                    room.withUnsafeMutableBufferPointer { out in
                        slopdesk_host_announced_version(
                            port.baseAddress, port.count,
                            version.baseAddress, version.count,
                            haystack.baseAddress, haystack.count,
                            out.baseAddress, out.count,
                        )
                    }
                }
            }
        }
        guard needed > 0, needed <= room.count else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: room.prefix(needed), as: UTF8.self)
    }

    // MARK: The OS-picks-the-port lifecycle

    /// What one ensure round does to a probed-port service.
    public enum ProbeStep: Equatable {
        /// There is no live child: drop whatever record there is and boot one. A record that is
        /// present but not running takes this arm too, which is why a crashed child needs no reaper.
        case boot
        /// Nothing to run this round — report this endpoint. The learned port rides along even
        /// while starting: it is the honest answer to "where will it be", and the client gates on
        /// the state.
        case report(MetadataCodec.ServiceEndpoint)
        /// Run the readiness probe on this port, stamp the record with the time it ran, and ask
        /// again with the answer. Two calls, one rule: the connect is hostd's to make, and a
        /// second dialler inside the artifact would be the cross-language mirror this tree forbids.
        case probe(UInt16)
    }

    /// The whole of an ensure round, asked once with `probe` as `nil` and — only when that answered
    /// ``ProbeStep/probe(_:)`` — a second time with the probe's verdict and the SAME record: the
    /// caller latches nothing until the rule has told it what to latch.
    public static func probeStep(
        hasRecord: Bool,
        isRunning: Bool,
        port: UInt16?,
        isReady: Bool,
        sinceProbe: Duration?,
        probeInterval: Duration,
        probe: Bool?,
    ) -> ProbeStep {
        let record = SlopDeskHostProbeRecord(
            since_probe_nanos: nanoseconds(sinceProbe ?? .zero),
            port: port ?? 0,
            has_record: hasRecord,
            is_running: isRunning,
            has_port: port != nil,
            ready: isReady,
            has_probe_stamp: sinceProbe != nil,
        )
        let step = slopdesk_host_probe_step(
            record, nanoseconds(probeInterval), probe != nil, probe ?? false,
        )
        switch step.action {
        case 1:
            // The raw byte carries forward-tolerantly, exactly as the wire does: the rule and the
            // encoder share one vocabulary, so nothing is mapped through a Swift enum in between.
            return .report(MetadataCodec.ServiceEndpoint(stateByte: step.state, port: step.port))
        case 2: return .probe(step.port)
        default: return .boot
        }
    }

    /// The other half of a round that answered ``ProbeStep/probe(_:)``: the same rule, asked again
    /// with the probe's answer in hand.
    ///
    /// It is the one door either way — the record has not changed between the two calls, because
    /// the caller latches nothing until the rule has told it what to latch. The `.starting`
    /// fallback is unreachable by construction (a record that was due for a probe cannot be due
    /// again with the answer beside it) and exists so the near side holds no second copy of the
    /// state-from-readiness mapping.
    public static func probedEndpoint(port: UInt16, isReady: Bool) -> MetadataCodec.ServiceEndpoint {
        let step = probeStep(
            hasRecord: true, isRunning: true, port: port, isReady: false,
            sinceProbe: nil, probeInterval: .zero, probe: isReady,
        )
        guard case let .report(endpoint) = step else {
            return MetadataCodec.ServiceEndpoint(state: .starting, port: port)
        }
        return endpoint
    }

    /// Whether a fact read off a child's log line may be written onto the current record: FIRST
    /// WRITER WINS, and only for the generation that is still current. The child announces once, so
    /// a later line carrying the marker is not a new fact; and a respawn that raced a dying child's
    /// last line must not let the old child's port land on the fresh record.
    public static func acceptsAnnouncement(
        line: Int, current: Int, hasRecord: Bool, alreadyRecorded: Bool,
    ) -> Bool {
        slopdesk_host_accepts_announcement(
            UInt64(max(0, line)), UInt64(max(0, current)), hasRecord, alreadyRecorded,
        )
    }

    // MARK: The hostd-picks-the-port lifecycle

    /// What to do with the port a daemon announced, against the one hostd advertises.
    public enum AdoptVerdict: Equatable {
        /// It is on the wanted port — serve it.
        case adopt
        /// End it and start one on the port this hostd advertises.
        case respawn
        /// The relaunch did not land either. End it and serve the other paths — a sidecar that
        /// never came up is not fatal to hostd, exactly as a failed bind never was.
        case giveUp
    }

    /// The verify-after-adopt rule, on `attempt` (`0` is the first launch).
    ///
    /// A daemon that never spoke and one that spoke a different port get the SAME answer, and that
    /// is the point: the pane id is stable (`service:<name>`, `docs/51` §1) but the port is not, so
    /// a survivor of a hostd started on a different `--port` is on the old one. Adopting it would
    /// leave hostd advertising a port nothing listens on, which fails with no log line to say why.
    public static func adoptVerdict(attempt: Int, announced: UInt16?, wanted: UInt16) -> AdoptVerdict {
        let code = slopdesk_host_adopt_verdict(
            UInt32(max(0, attempt)), announced != nil, announced ?? 0, wanted,
        )
        switch code {
        case 0: return .adopt
        case 1: return .respawn
        default: return .giveUp
        }
    }

    // MARK: The workbench's own gates

    /// Where the one-shot marketplace install of the bundled extensions stands.
    public enum ExtensionInstall: UInt8 {
        /// Not asked yet — the next boot reads the profile registry.
        case unchecked = 0
        /// The CLI pass is running, and the spawn waits for it: install and boot writing
        /// `extensions.json` concurrently is how registrations get lost.
        case installing = 1
        /// Latched, whether the install SUCCEEDED or not — the panel is never held hostage by a
        /// nicety, and the next hostd launch retries because the registry still misses the id.
        case done = 2
    }

    /// What one workbench boot round does, in the order the properties are declared.
    public struct CodeBootStep: Equatable {
        /// The install state to latch, whatever else happens.
        public var install: ExtensionInstall
        /// The state to report when ``spawn`` is false.
        public var state: MetadataCodec.ServiceState
        /// Every gate is open — spawn the child. A spawn that then THROWS is the caller's to
        /// report; nothing in the rule has an opinion about a broken binary.
        public var spawn: Bool
        /// Fork the profile seeder first: after the child has read an absent settings file once, a
        /// seed would need a reload to take.
        public var seedSettings: Bool
        /// Then bind the bridge listener — before the child inherits its path, or the extension's
        /// first connect races the bind and burns a 5 s reconnect delay on every cold start.
        public var startBridge: Bool
        /// Then run the one-shot marketplace install.
        public var installExtensions: Bool
    }

    /// The workbench's four gates between "there is a binary" and "spawn".
    ///
    /// `launchable` is BOTH a binary and a seeder profile, because they are one answer: a workbench
    /// launched on guessed arguments is a different program, not a degraded panel, so a host
    /// missing either reports the same `unavailable` a host missing both does.
    public static func codeBootStep(
        launchable: Bool,
        settingsSeeded: Bool,
        bridgeStarted: Bool,
        install: ExtensionInstall,
        missingExtensions: Int,
    ) -> CodeBootStep {
        let step = slopdesk_host_code_boot_step(SlopDeskHostCodeGates(
            missing: max(0, missingExtensions),
            install: install.rawValue,
            launchable: launchable,
            settings_seeded: settingsSeeded,
            bridge_started: bridgeStarted,
        ))
        return CodeBootStep(
            install: ExtensionInstall(rawValue: step.install) ?? .unchecked,
            state: MetadataCodec.ServiceState(rawValue: step.state) ?? .starting,
            spawn: step.spawn,
            seedSettings: step.seed_settings,
            startBridge: step.start_bridge,
            installExtensions: step.install_extensions,
        )
    }

    /// How many times the workbench open is tried before it gives up and says so — ten, against the
    /// caller's 2 s delay, is an ~18 s window: a cold server boot, the client's poll and the
    /// webview's workbench boot before the session socket exists.
    public static var codeOpenAttempts: Int { Int(slopdesk_host_code_open_attempts()) }

    /// Which one-shot the code-server CLI is being run as.
    public enum CodeCommand: UInt8 {
        /// The one-shot marketplace fetch of a bundled extension.
        case installExtension = 0
        /// Open a target in the most recently registered workbench, routed through the per-user
        /// session socket (folder-prefix matches sort first).
        case reuseWindow = 1
    }

    /// The argv after the binary path for one code-server CLI one-shot: the rule's flag, then the
    /// caller's own identifier or target.
    public static func codeCLIArguments(_ command: CodeCommand, _ value: String) -> [String] {
        // The longer of the two flags is nineteen bytes, so this buffer is the arithmetic bound.
        var room = [UInt8](repeating: 0, count: 32)
        let needed = room.withUnsafeMutableBufferPointer { out in
            slopdesk_host_code_cli_flag(command.rawValue, out.baseAddress, out.count)
        }
        guard needed > 0, needed <= room.count else { return [value] }
        // swiftlint:disable:next optional_data_string_conversion
        return [String(decoding: room.prefix(needed), as: UTF8.self), value]
    }

    /// A request root normalized: absolute, and with its trailing `/` trimmed the way `projectKey`
    /// trims it so one project cannot spawn twins. `nil` when the path is not absolute.
    ///
    /// Whether it EXISTS and is a directory stays with the caller — that is a `stat`, and its
    /// answer changes between two calls with the same argument.
    public static func canonicalRoot(_ path: String) -> String? {
        let bytes = Array(path.utf8)
        // Trimming never grows a path, so the input's own length is the bound.
        var room = [UInt8](repeating: 0, count: max(1, bytes.count))
        let needed = bytes.withUnsafeBufferPointer { input in
            room.withUnsafeMutableBufferPointer { out in
                slopdesk_host_canonical_root(
                    input.baseAddress, input.count, out.baseAddress, out.count,
                )
            }
        }
        guard needed > 0, needed <= room.count else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: room.prefix(needed), as: UTF8.self)
    }

    /// A `Duration` as whole nanoseconds, which is the only unit that crosses.
    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        guard parts.seconds >= 0 else { return 0 }
        let whole = UInt64(clamping: parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .max }
        let fraction = UInt64(clamping: max(0, parts.attoseconds / 1_000_000_000))
        let total = whole.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? .max : total.partialValue
    }
}

// MARK: - DetachRetentionRules (what the detached store keeps)

/// What ``DetachedSessionStore`` keeps and what it lets go of, as
/// `slopdesk-muxsession::detach_retention` answers it.
///
/// No identity crosses. A parked session is a `UUID` and a class instance holding a PTY, so what
/// goes over is one `detachedAt` stamp per entry and what comes back is a POSITION into the list
/// the caller still holds. The two questions only Swift can answer — is this the same OBJECT
/// (`===`, not `==`), and where does this id already sit — are asked here and passed in.
public enum DetachRetentionRules {
    /// What one insert does to the store.
    public struct InsertVerdict: Equatable {
        /// The position of the entry to evict for room, or `nil` when the cap does not bite.
        public var victim: Int?
        /// The store already holds this very session: keep the ORIGINAL entry, with its
        /// `detachedAt` and its armed TTL. Overwriting would leak the first entry's TTL task
        /// un-cancelled, and that stale timer would later kill whatever live entry holds the id.
        public var isIdempotent: Bool
        /// A DIFFERENT session holds this id: newest wins, and the displaced entry's TTL must be
        /// cancelled before it evicts the new one.
        public var displaces: Bool
    }

    /// The insert rule over the `detachedAt` stamps of every entry the store currently holds.
    ///
    /// `cap` is the OPT-IN `SLOPDESK_DETACH_MAX_SESSIONS` bound; `nil` is UNBOUNDED, the default and
    /// the tmux/zellij semantics — never silently kill a live detached session.
    public static func insertVerdict(
        stamps: [Double], occupant: (position: Int, isSameSession: Bool)?, cap: Int?,
    ) -> InsertVerdict {
        let answer = stamps.withUnsafeBufferPointer { column in
            slopdesk_host_detach_insert(
                column.baseAddress, column.count,
                occupant != nil, occupant.map { max(0, $0.position) } ?? 0,
                occupant?.isSameSession ?? false,
                cap != nil, cap.map { max(0, $0) } ?? 0,
            )
        }
        let victim = answer.has_victim && answer.victim < stamps.count ? Int(answer.victim) : nil
        return InsertVerdict(
            victim: victim, isIdempotent: answer.idempotent, displaces: answer.displace,
        )
    }

    /// Every stored entry in `detachedAt` order, as positions into `stamps`.
    ///
    /// A pane whose client quit is ALIVE — that is the entire point of the store — so the listing
    /// exists at all; it is by stamp so `slopdesk-ctl list-panes` is stable rather than
    /// dictionary-ordered, and ties keep the caller's own order rather than resolving arbitrarily.
    public static func order(stamps: [Double]) -> [Int] {
        guard !stamps.isEmpty else { return [] }
        // The answer is one position per entry, so the first buffer is the arithmetic bound.
        var slots = [UInt32](repeating: 0, count: stamps.count)
        let count = stamps.withUnsafeBufferPointer { column in
            slots.withUnsafeMutableBufferPointer { out in
                slopdesk_host_detach_order(
                    column.baseAddress, column.count, out.baseAddress, out.count,
                )
            }
        }
        guard count <= slots.count else { return Array(stamps.indices) }
        return slots.prefix(count).compactMap { slot in
            let position = Int(slot)
            return stamps.indices.contains(position) ? position : nil
        }
    }
}
