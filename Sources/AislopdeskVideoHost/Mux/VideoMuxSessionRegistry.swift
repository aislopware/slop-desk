#if os(macOS)
import Foundation
import AislopdeskVideoProtocol

/// A lock-protected channelID → lane-sink table shared between the daemon's
/// ``VideoMuxSessionRegistry`` (which READS it on `dispatch`) and the per-lane
/// ``VideoMuxChannelTransport``s (which register/unregister SYNCHRONOUSLY on
/// `start`/`stop`).
///
/// Why a shared lock-protected table rather than actor state: the triggering `hello`
/// datagram that MINTS a lane must be delivered to that lane's sink the instant the
/// session's `transport.start(onReceive:)` has wired it — there is only ONE hello (the
/// client sends it once on session start). A synchronous register, completed INSIDE the
/// awaited `session.start()`, guarantees the sink is present before `dispatch` delivers
/// the hello. Pure data structure (no socket, no GUI) — directly unit-testable.
public final class VideoMuxSinkTable: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UInt32: @Sendable (VideoChannel, Data) -> Void] = [:]

    public init() {}

    public func register(_ channelID: UInt32, _ onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) {
        lock.withLock { sinks[channelID] = onReceive }
    }
    public func unregister(_ channelID: UInt32) {
        lock.withLock { _ = sinks.removeValue(forKey: channelID) }
    }
    public func sink(_ channelID: UInt32) -> (@Sendable (VideoChannel, Data) -> Void)? {
        lock.withLock { sinks[channelID] }
    }
    public func contains(_ channelID: UInt32) -> Bool {
        lock.withLock { sinks[channelID] != nil }
    }
    public var count: Int { lock.withLock { sinks.count } }
}

/// The daemon-side registry that turns ONE shared ``NWVideoMuxDatagramTransport`` into
/// N independent ``AislopdeskVideoHostSession``s — one per client video channel (per
/// `channelID`), each watching its OWN window via its OWN hello (Stage S3).
///
/// ## The critical asymmetry (spec §2)
/// Two video panes on the SAME host watch DIFFERENT windows → distinct hellos (distinct
/// `requestedWindowID`s) → distinct host sessions. So the registry cannot pre-mint; it
/// mints lazily on the FIRST `hello` it sees for a never-before-seen channelID, picking
/// the window the hello names. Subsequent datagrams for that channelID route to the
/// already-built session's lane sink (the shared ``VideoMuxSinkTable``).
///
/// ## Per-channel loss isolation (spec §4.4)
/// A datagram for an unknown channelID that is NOT a hello is dropped (it cannot be
/// bound to a session) — never fatal, never affecting sibling lanes. A `bye` on one
/// lane retires only that lane (the lane transport's `resetClientFlow` →
/// ``VideoMuxRouter/retire`` + ``VideoMuxSinkTable/unregister``); sibling sessions keep
/// streaming.
///
/// ## Headless-testable seam
/// The actual session minting (SCShareableContent window enumeration +
/// ``AislopdeskVideoHostSession`` + capture/encode) is GUI-only and HANGS in a test — so it
/// is injected as `mintSession`. The registry's PURE concern — "is this the first
/// datagram for a new channelID and is it a hello? (mint) vs route to an existing lane
/// vs drop" — is exercised through ``DispatchDecision`` and ``decide(channelID:channel:data:)``
/// without ever calling the GUI factory.
public actor VideoMuxSessionRegistry {
    /// What the daemon should do with one demultiplexed inbound datagram.
    public enum DispatchDecision: Equatable, Sendable {
        /// A live lane exists for `channelID` — deliver `(channel, payload)` to its session sink.
        case deliver(channelID: UInt32)
        /// A never-seen `channelID` carrying a `hello` — mint a new session for it, then deliver.
        case mint(channelID: UInt32)
        /// An unknown `channelID` whose first datagram is NOT a hello — cannot bind; drop (benign).
        case dropUnbound(channelID: UInt32)
    }

    /// The shared sink table the lane transports register into synchronously inside `session.start()`.
    public let sinkTable: VideoMuxSinkTable
    /// channelIDs we have already begun minting, so a burst of hello retransmits for the same new
    /// lane mints exactly one session (the hello may repeat over UDP).
    private var minting: Set<UInt32> = []
    /// Live sessions, kept so the daemon can `stop()` them all on shutdown.
    private var sessions: [UInt32: AislopdeskVideoHostSession] = [:]

    /// GUI-only factory: enumerate the window the hello names, build + start a
    /// ``AislopdeskVideoHostSession`` bound to a ``VideoMuxChannelTransport`` for `channelID` (whose
    /// `start` synchronously registers the lane sink into ``sinkTable``), and return it. Throws if
    /// the window is gone / the hello is malformed (the datagram is then dropped).
    private let mintSession: @Sendable (_ channelID: UInt32, _ hello: VideoControlMessage) async throws -> AislopdeskVideoHostSession

    /// Called when a mint FAILS (window gone / malformed hello) so the shared transport forgets the
    /// flow it remembered for the bootstrap hello — otherwise that `channelMediaConn`/`channelCursorConn`
    /// entry leaks (the lane was never admitted, so nothing else cleans it). Wired to the transport's
    /// `retire`; default no-op for tests that don't exercise it.
    private let forgetLane: @Sendable (UInt32) -> Void

    public init(
        sinkTable: VideoMuxSinkTable = VideoMuxSinkTable(),
        forgetLane: @escaping @Sendable (UInt32) -> Void = { _ in },
        mintSession: @escaping @Sendable (UInt32, VideoControlMessage) async throws -> AislopdeskVideoHostSession
    ) {
        self.sinkTable = sinkTable
        self.forgetLane = forgetLane
        self.mintSession = mintSession
    }

    /// The PURE dispatch decision for one demultiplexed datagram (no GUI, no socket). A live lane
    /// (sink already present) delivers; a never-seen channelID mints iff its first datagram is a
    /// `hello`; otherwise drop. `decide` is the headless-testable core of `dispatch`.
    public func decide(channelID: UInt32, channel: VideoChannel, data: Data) -> DispatchDecision {
        if sinkTable.contains(channelID) { return .deliver(channelID: channelID) }
        if minting.contains(channelID) { return .deliver(channelID: channelID) }   // mint already in flight
        if channel == .control, let msg = try? VideoControlMessage.decode(data), case .hello = msg {
            return .mint(channelID: channelID)
        }
        return .dropUnbound(channelID: channelID)
    }

    // MARK: - Live dispatch (called by the daemon from the shared transport's onReceive)

    /// Routes one demultiplexed datagram for `channelID` on `channel`. Mints a session on the first
    /// hello for a new lane (idempotent under hello retransmits), then delivers to the lane sink.
    public func dispatch(channelID: UInt32, channel: VideoChannel, data: Data) async {
        switch decide(channelID: channelID, channel: channel, data: data) {
        case .deliver:
            sinkTable.sink(channelID)?(channel, data)
        case .mint:
            minting.insert(channelID)
            let hello = (try? VideoControlMessage.decode(data)) ?? .bye
            do {
                let session = try await mintSession(channelID, hello)
                sessions[channelID] = session
                // session.start() registered the lane sink SYNCHRONOUSLY in sinkTable; deliver the
                // hello that triggered the mint so the session's state machine processes it.
                sinkTable.sink(channelID)?(channel, data)
            } catch {
                minting.remove(channelID)
                // Mint failed (window gone / malformed hello): the lane was never admitted, so the
                // flow the transport remembered for the bootstrap hello would leak. Tell the
                // transport to forget it. The client retries under a FRESH channelID, so retiring
                // this dead one is safe.
                forgetLane(channelID)
            }
        case .dropUnbound:
            break
        }
    }

    /// Drops a lane's session bookkeeping (the lane retired itself via its transport, which already
    /// unregistered its sink). Clears the mint mark + session map so a reconnect re-mints. Sibling
    /// lanes are untouched. Idempotent.
    ///
    /// ⚠️ Does NOT call `session.stop()` — historically this was the clean-bye path where the lane
    /// transport had already torn itself down. For the crash-without-bye reaper (and a clean
    /// last-lane close) use ``retireAndStop(_:)``, which also STOPS the session so capture actually
    /// stops; otherwise the minted ``AislopdeskVideoHostSession`` keeps its SCStream/encoder running with
    /// no client (the CONCURRENCY-HOST-1 mux leak).
    public func retire(_ channelID: UInt32) {
        sinkTable.unregister(channelID)
        minting.remove(channelID)
        sessions.removeValue(forKey: channelID)
    }

    /// CONCURRENCY-HOST-1 crash-without-bye (mux analogue): retire the lane bookkeeping AND stop its
    /// session so capture/encode actually stops — the gap ``retire(_:)`` leaves (it only forgets the
    /// sink). This is the async hop the transport's reaper drives via `onReapLane`. Snapshots the
    /// session BEFORE `retire` clears the map, then awaits its `stop()` (stops the SCStream /
    /// VTCompressionSession / timers). Idempotent — a no-op `stop()` on an already-gone session.
    public func retireAndStop(_ channelID: UInt32) async {
        let session = sessions[channelID]
        retire(channelID)                 // sink unregister + minting/sessions map clear
        await session?.stop()             // stops SCStream / VTCompressionSession / timers
    }

    /// Stops every live session (daemon shutdown). The shared transport is cancelled separately.
    public func stopAll() async {
        let live = Array(sessions.values)
        sessions.removeAll()
        minting.removeAll()
        for session in live { await session.stop() }
    }

    /// The number of live lanes (for a test / lsof-style assertion).
    public var liveChannelCount: Int { sinkTable.count }
}
#endif
