import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-muxsession`'s `registry`, reached through the `registry` door.
///
/// Which channel names which pane, which subscriber of it a channel is, where a pane's agent hooks
/// route, and which document id a project path has. A fanned-out pane is ONE ``MuxChannelSession``
/// under N channel keys, so every event is either about one member or about all of them — and that
/// split used to be spelled with two dictionaries that had to be written in one critical section to
/// stay in agreement. It is one record now, on the far side.
///
/// The OBJECTS stay here, keyed by the slot that is their identity over there: a dictionary keyed by
/// an id this side already has is not a relation, it is the retention itself.
///
/// Not `Sendable` and deliberately unlocked: ``HostServer`` calls every method with its `lock`
/// held, exactly as it did when these were its stored dictionaries.
final class HostSessionRegistry {
    /// One registered channel, resolved back to the object it names.
    struct Member {
        /// The channel.
        let key: MuxSessionKey
        /// Which subscriber of the pane this channel is.
        let subscriber: MuxSubscriberID
        /// The pane it names.
        let session: MuxChannelSession
    }

    /// The far side, which owns every relation.
    private let handle: OpaquePointer?

    /// slot → the session object it names, for panes on a channel.
    private var panes: [UInt64: MuxChannelSession] = [:]

    /// slot → the session object it names, for standalone `ctl`-spawned panes.
    private var controls: [UInt64: MuxChannelSession] = [:]

    init() { handle = slopdesk_host_registry_new() }

    deinit { slopdesk_host_registry_free(handle) }

    /// A fresh session identity, unique for the life of the process and never zero.
    ///
    /// Minted once per ``MuxChannelSession`` and carried by it, because object identity is the one
    /// thing that cannot cross: every `===` question hostd asks is asked of this number instead.
    static func mintSlot() -> UInt64 { slopdesk_host_slot_mint() }

    /// The subscriber id a pane's ORIGINAL channel rides.
    static var primarySubscriber: MuxSubscriberID { slopdesk_host_primary_subscriber() }

    // MARK: - Live panes

    /// The pane `key` names, or `nil` when the key is not registered.
    subscript(key: MuxSessionKey) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_slot(handle, Self.flat(key))
        return slot == 0 ? nil : panes[slot]
    }

    /// Which subscriber of its pane `key` is. An unregistered key reads as the primary, which is
    /// what every caller that reaches this without a session does with the answer anyway.
    func subscriber(of key: MuxSessionKey) -> MuxSubscriberID {
        var member = Self.emptyMember
        guard slopdesk_host_registry_member(handle, Self.flat(key), &member) else {
            return Self.primarySubscriber
        }
        return member.subscriber
    }

    /// Registers `key` as `subscriber` of `session`.
    func attach(
        _ key: MuxSessionKey,
        session: MuxChannelSession,
        subscriber: MuxSubscriberID = HostSessionRegistry.primarySubscriber,
    ) {
        panes[session.registrySlot] = session
        slopdesk_host_registry_attach(
            handle,
            Self.flat(key),
            session.registrySlot,
            Self.flat(session.sessionID),
            subscriber,
        )
    }

    /// Removes exactly one member — the leaving client, not the pane — and answers the pane it
    /// named. The object is released here only when its LAST channel is gone.
    @discardableResult
    func detach(_ key: MuxSessionKey) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_detach_key(handle, Self.flat(key))
        guard slot != 0 else { return nil }
        let session = panes[slot]
        if !slopdesk_host_registry_slot_is_attached(handle, slot) { panes[slot] = nil }
        return session
    }

    /// Removes `key` only while it still names `session`.
    ///
    /// The identity guard: the detach window can mint a fresh session under a key its predecessor is
    /// still winding down on, and an unguarded removal unregisters the LIVE successor.
    @discardableResult
    func detach(_ key: MuxSessionKey, ifNames session: MuxChannelSession) -> Bool {
        let removed = slopdesk_host_registry_detach_key_if_slot(
            handle,
            Self.flat(key),
            session.registrySlot,
        )
        if removed, !slopdesk_host_registry_slot_is_attached(handle, session.registrySlot) {
            panes[session.registrySlot] = nil
        }
        return removed
    }

    /// Every key that names `session`, in key order.
    func keys(naming session: MuxChannelSession) -> [MuxSessionKey] {
        let slot = session.registrySlot
        let count = slopdesk_host_registry_keys_for_slot(handle, slot, nil, 0)
        guard count > 0 else { return [] }
        return withUnsafeTemporaryAllocation(of: SlopDeskHostKey.self, capacity: count) { buffer in
            let written = slopdesk_host_registry_keys_for_slot(
                handle, slot, buffer.baseAddress, count,
            )
            return (0..<min(written, count)).map { Self.key(buffer[$0]) }
        }
    }

    /// Removes EVERY key that names `session` — the reap — and answers them.
    ///
    /// Leaving an alias behind keeps a dead pane in every enumeration hostd has: the ctl listing,
    /// the stop drain, the rebind scan.
    @discardableResult
    func reap(_ session: MuxChannelSession) -> [MuxSessionKey] {
        let slot = session.registrySlot
        let count = slopdesk_host_registry_keys_for_slot(handle, slot, nil, 0)
        guard count > 0 else {
            panes[slot] = nil
            return []
        }
        let doomed = withUnsafeTemporaryAllocation(
            of: SlopDeskHostKey.self,
            capacity: count,
        ) { buffer -> [MuxSessionKey] in
            let written = slopdesk_host_registry_detach_slot(handle, slot, buffer.baseAddress, count)
            return (0..<min(written, count)).map { Self.key(buffer[$0]) }
        }
        panes[slot] = nil
        return doomed
    }

    /// Whether `session` is still named by any channel.
    func isAttached(_ session: MuxChannelSession) -> Bool {
        slopdesk_host_registry_slot_is_attached(handle, session.registrySlot)
    }

    /// Every member riding `connectionID`, in key order.
    func members(on connectionID: UUID) -> [Member] {
        read(
            count: { slopdesk_host_registry_members_for_connection(handle, Self.flat(connectionID), nil, 0) },
            fill: { buffer, capacity in
                slopdesk_host_registry_members_for_connection(
                    handle, Self.flat(connectionID), buffer, capacity,
                )
            },
        )
    }

    /// Removes every member riding `connectionID` — the link-drop snapshot — and answers them.
    ///
    /// The removal lands BEFORE the caller retires anything, so a racing `channelOpen` cannot find a
    /// member of a connection that is already gone.
    func detachAll(on connectionID: UUID) -> [Member] {
        let leaving: [Member] = read(
            count: { slopdesk_host_registry_members_for_connection(handle, Self.flat(connectionID), nil, 0) },
            fill: { buffer, capacity in
                slopdesk_host_registry_detach_connection(
                    handle, Self.flat(connectionID), buffer, capacity,
                )
            },
        )
        for member in leaving where !isAttached(member.session) {
            panes[member.session.registrySlot] = nil
        }
        return leaving
    }

    /// Every member, in key order — the roster's join from a subscriber back to its connection.
    var members: [Member] {
        read(
            count: { slopdesk_host_registry_members(handle, nil, 0) },
            fill: { buffer, capacity in slopdesk_host_registry_members(handle, buffer, capacity) },
        )
    }

    /// Every DISTINCT pane on a channel.
    ///
    /// A fanned-out pane is N members and ONE session: an enumeration that repeated it would shut
    /// the same PTY N times and fan N teardowns against a strictly-balanced prevent-sleep counter.
    var liveSessions: [MuxChannelSession] {
        slots(from: { buffer, capacity in slopdesk_host_registry_slots(handle, buffer, capacity) })
            .compactMap { panes[$0] }
    }

    /// How many CHANNELS are registered — one per watching client, not one per pane.
    var memberCount: Int { slopdesk_host_registry_member_count(handle) }

    /// How many distinct CONNECTIONS hold at least one pane — the "N client(s) connected" count.
    var connectionCount: Int { slopdesk_host_registry_connection_count(handle) }

    /// The channel key one SUBSCRIBER of `session` rides, if it is registered.
    func key(of session: MuxChannelSession, subscriber: MuxSubscriberID) -> MuxSessionKey? {
        var found = Self.emptyKey
        guard slopdesk_host_registry_key_for(
            handle, session.registrySlot, subscriber, &found,
        ) else { return nil }
        return Self.key(found)
    }

    /// The live pane serving `sessionID` under some OTHER key — the join question.
    func session(_ sessionID: UUID, liveExcluding key: MuxSessionKey) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_slot_elsewhere(
            handle, Self.flat(sessionID), Self.flat(key),
        )
        return slot == 0 ? nil : panes[slot]
    }

    /// The live pane serving `sessionID` from any channel.
    func session(_ sessionID: UUID) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_slot_for_session(handle, Self.flat(sessionID))
        return slot == 0 ? nil : panes[slot]
    }

    /// Empties the channel map and answers every distinct pane that was in it — the `stop()` drain.
    func drainPanes() -> [MuxChannelSession] {
        let live = slots(from: { buffer, capacity in
            slopdesk_host_registry_drain_panes(handle, buffer, capacity)
        }).compactMap { panes[$0] }
        panes.removeAll()
        return live
    }

    // MARK: - Standalone control panes

    /// Registers a `ctl`-spawned pane, which holds no channel and no connection.
    func attachControl(_ session: MuxChannelSession) {
        controls[session.registrySlot] = session
        slopdesk_host_registry_attach_control(
            handle, Self.flat(session.sessionID), session.registrySlot,
        )
    }

    /// The standalone pane serving `sessionID`, if any.
    func controlSession(_ sessionID: UUID) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_control_slot(handle, Self.flat(sessionID))
        return slot == 0 ? nil : controls[slot]
    }

    /// Removes the standalone pane serving `sessionID` and answers it. Idempotent.
    @discardableResult
    func detachControl(_ sessionID: UUID) -> MuxChannelSession? {
        let slot = slopdesk_host_registry_detach_control(handle, Self.flat(sessionID))
        guard slot != 0 else { return nil }
        return controls.removeValue(forKey: slot)
    }

    /// Every standalone pane.
    var controlSessions: [MuxChannelSession] {
        slots(from: { buffer, capacity in
            slopdesk_host_registry_control_slots(handle, buffer, capacity)
        }).compactMap { controls[$0] }
    }

    /// Empties the standalone map and answers what was in it.
    func drainControl() -> [MuxChannelSession] {
        let live = slots(from: { buffer, capacity in
            slopdesk_host_registry_drain_control(handle, buffer, capacity)
        }).compactMap { controls[$0] }
        controls.removeAll()
        return live
    }

    // MARK: - Agent-hook sinks

    /// Records where `session`'s agent hooks route. The owner is the session's own identity, so the
    /// teardown guard and every other identity question read the same number.
    func registerHook(session: MuxChannelSession, paneID: String) {
        var bytes = Array(paneID.utf8)
        slopdesk_host_registry_register_hook(
            handle, Self.flat(session.sessionID), &bytes, bytes.count, session.registrySlot,
        )
    }

    /// Re-points `session`'s sink at the current object without moving where it routes — the
    /// reattach edge — and answers the pane id, or `nil` when hooks were off at spawn.
    ///
    /// The pane id is the one baked into the child's environment and is immutable for the shell's
    /// life: a per-reattach key could never route AND would leak one dead sink per wifi flap.
    func rebindHook(session: MuxChannelSession) -> String? {
        guard slopdesk_host_registry_rebind_hook(
            handle, Self.flat(session.sessionID), session.registrySlot,
        ) else { return nil }
        return hookPaneID(session: session.sessionID)
    }

    /// Removes `session`'s sink while it still owns it, and answers the pane id it routed to.
    ///
    /// `nil` for an entry owned by somebody else: a stale teardown for a same-UUID ghost stands down
    /// rather than dropping the key its live successor just registered.
    func unregisterHook(session: MuxChannelSession) -> String? {
        let id = Self.flat(session.sessionID)
        let owner = session.registrySlot
        let count = slopdesk_host_registry_unregister_hook(handle, id, owner, nil, 0)
        guard count > 0 else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count) { buffer -> String? in
            let written = slopdesk_host_registry_unregister_hook(
                handle, id, owner, buffer.baseAddress, count,
            )
            guard written > 0, written <= count, let base = buffer.baseAddress else { return nil }
            return String(bytes: UnsafeBufferPointer(start: base, count: written), encoding: .utf8)
        }
    }

    /// How many hook sinks are registered — the leak check a per-reattach key would fail.
    var hookCount: Int { slopdesk_host_registry_hook_count(handle) }

    /// Where `sessionID`'s hooks route, without touching the entry.
    private func hookPaneID(session sessionID: UUID) -> String? {
        let id = Self.flat(sessionID)
        let count = slopdesk_host_registry_hook_pane(handle, id, nil, 0)
        guard count > 0 else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count) { buffer -> String? in
            let written = slopdesk_host_registry_hook_pane(handle, id, buffer.baseAddress, count)
            guard written > 0, written <= count, let base = buffer.baseAddress else { return nil }
            return String(bytes: UnsafeBufferPointer(start: base, count: written), encoding: .utf8)
        }
    }

    // MARK: - Project document ids

    /// The document object id for `path`, minting one the first time the path is seen.
    func projectID(for path: String, mint: () -> UUID) -> UUID {
        var bytes = Array(path.utf8)
        var answer = Self.flat(UUID())
        slopdesk_host_registry_project_id(
            handle, &bytes, bytes.count, Self.flat(mint()), &answer,
        )
        return UUID(uuid: answer.bytes)
    }

    /// How many projects have an id.
    var projectCount: Int { slopdesk_host_registry_project_count(handle) }

    // MARK: - Buffer plumbing

    /// Sizes, then fills, then resolves each member back to its object. The two calls happen under
    /// the caller's one lock hold, so the count cannot move between them.
    private func read(
        count: () -> Int,
        fill: (UnsafeMutablePointer<SlopDeskHostMember>?, Int) -> Int,
    ) -> [Member] {
        let total = count()
        guard total > 0 else { return [] }
        return withUnsafeTemporaryAllocation(
            of: SlopDeskHostMember.self,
            capacity: total,
        ) { buffer -> [Member] in
            let written = fill(buffer.baseAddress, total)
            return (0..<min(written, total)).compactMap { index in
                let flat = buffer[index]
                guard let session = panes[flat.slot] else { return nil }
                return Member(
                    key: Self.key(flat.key),
                    subscriber: flat.subscriber,
                    session: session,
                )
            }
        }
    }

    /// The same sizing dance for a door that answers slots.
    private func slots(from fill: (UnsafeMutablePointer<UInt64>?, Int) -> Int) -> [UInt64] {
        let total = fill(nil, 0)
        guard total > 0 else { return [] }
        return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: total) { buffer -> [UInt64] in
            let written = fill(buffer.baseAddress, total)
            return (0..<min(written, total)).map { buffer[$0] }
        }
    }

    private static let emptyKey = SlopDeskHostKey(connection: SlopDeskWsUuid(), channel: 0)

    private static let emptyMember = SlopDeskHostMember(key: emptyKey, slot: 0, subscriber: 0)

    private static func flat(_ uuid: UUID) -> SlopDeskWsUuid { SlopDeskWsUuid(bytes: uuid.uuid) }

    private static func flat(_ key: MuxSessionKey) -> SlopDeskHostKey {
        SlopDeskHostKey(connection: flat(key.connectionID), channel: key.channelID)
    }

    private static func key(_ flat: SlopDeskHostKey) -> MuxSessionKey {
        MuxSessionKey(connectionID: UUID(uuid: flat.connection.bytes), channelID: flat.channel)
    }
}
