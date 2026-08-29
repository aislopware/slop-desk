import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - WorkspaceCoreHandle (the store's own decisions)

/// The Swift face of `slopdesk-workspace`'s `store_core`, reached through the `slopdesk_ws_core_*`
/// door.
///
/// Four things the store keeps that are neither facts about the tree nor runtime plumbing: the
/// launch dial gate, the save-generation guard, the document cache's provenance rule, and the
/// revision every projection of the document is keyed on. Each was a stored property on
/// ``WorkspaceStore``, with the deciding written out at whichever site happened to ask.
///
/// **One handle, because of the revision.** It is both the projection cache's key and the
/// Observation shadow every reader of ``WorkspaceStore/tree`` binds to. Splitting the gate from the
/// guard would give that counter two owners, and a memo keyed on a number neither side fully
/// controls is a layout that either repaints for nothing or freezes.
///
/// **The edges come back, they are not observed.** Every mutating call answers what this side now
/// owes the world — arm or cancel the backstop `Task`, fan the re-dials out, write the file. The
/// `Task`s and the pane walk stay here, because a task's lifetime is Swift's; the decision to run
/// one never is.
///
/// **Identity stayed here too.** A ``PaneID`` is a UUID and never crosses. The one string that does
/// is a `host:port`, which is a value the store already prints and persists.
///
/// Not `Sendable` and deliberately unlocked: ``WorkspaceStore`` is `@MainActor` and every call site
/// is main-actor-isolated, exactly as it was when this state was its stored properties.
final class WorkspaceCoreHandle {
    /// What the workspace channel is, as far as the dial gate is concerned.
    ///
    /// Deliberately coarser than ``WorkspaceChannelClient/State``: the gate draws two lines through
    /// it, and `.closed` sits with the live states rather than beside `.refused`. Reading a close as
    /// an answer is what made a host switch churn — the app tears the shared connection down BEFORE
    /// it commits the new target, so a dead subscription says nothing about whose ids are on screen.
    enum Channel: UInt8 {
        /// No channel at all — headless, or a unit test.
        case absent = 0
        /// The host does not serve the workspace channel class, so it will never publish a document.
        case refused = 1
        /// The channel serves an in-process document, whose loopback adopted the seeded mirror.
        case localDocument = 2
        /// A real host channel, in any of `idle` / `opening` / `live` / `closed`.
        case attached = 3
    }

    /// What to do with the wall clock the current hold may not outlive.
    enum Backstop: UInt8 {
        /// Leave whatever is armed exactly as it is.
        case leave = 0
        /// A hold began: start the timer.
        case arm = 1
        /// An answer arrived: cancel it, so a re-engaged hold gets its own full window.
        case cancel = 2
    }

    /// What one gate recomputation asks this side to do.
    struct GateEdge {
        /// Whether the published answer moved at all.
        let changed: Bool
        /// The RELEASING edge: dial everything the hold was holding.
        let opened: Bool
        /// What to do with the backstop timer.
        let backstop: Backstop
    }

    /// The three facts the gate needs that live on objects the core has never seen.
    ///
    /// Handed in on EVERY call rather than pushed and remembered. Each one's owner is elsewhere — a
    /// channel client, the automation environment, the mirror's pending set — so a copy on the far
    /// side would go stale in the gap between the write that moved the fact and the call that pushed
    /// it, and the gate would answer from the previous frame.
    struct Inputs {
        /// What the workspace channel is.
        let channel: Channel
        /// Whether an automation bootstrap owns this launch's layout and publishes it itself.
        let bootstrapArmed: Bool
        /// Whether this launch's `adoptWorkspace` proposal is still outstanding.
        let offerPending: Bool

        /// The C shape.
        var raw: SlopDeskWsCoreInputs {
            SlopDeskWsCoreInputs(
                channel: channel.rawValue,
                bootstrap_armed: bootstrapArmed,
                offer_pending: offerPending,
            )
        }
    }

    /// What one folded document frame asks for, past the effects already run.
    struct FrameEdge {
        /// The gate recomputation this frame implied.
        let gate: GateEdge
        /// Whether this frame stamped the attached host as the one vouching for the ids on screen.
        let provenanceStamped: Bool
        /// Whether a booked re-dial fan-out came due.
        let redialBookingFired: Bool
    }

    /// The far side, which owns all four subjects.
    private let handle: OpaquePointer?

    /// A core whose document cache was seeded from `cacheHostKey` — the connect gate's launch
    /// target. Empty (the test and headless default) reads and writes nothing.
    init(cacheHostKey: String) {
        var key = Array(cacheHostKey.utf8)
        handle = key.withUnsafeMutableBufferPointer { slopdesk_ws_core_new($0.baseAddress, $0.count) }
    }

    deinit { slopdesk_ws_core_free(handle) }

    // MARK: The revision

    /// The projection key as it stands.
    var revision: UInt { UInt(slopdesk_ws_core_revision(handle)) }

    /// Moves the projection key, answering its new value.
    ///
    /// The two LOCAL overlays that touch no document — the divider drag preview and this device's
    /// own focus — call this themselves, because a frame that skipped it would neither repaint nor
    /// invalidate.
    @discardableResult
    func bumpRevision() -> UInt { UInt(slopdesk_ws_core_bump_revision(handle)) }

    // MARK: The dial gate

    /// Whether the panes on screen may open their host channels.
    var panesMayDial: Bool { slopdesk_ws_core_panes_may_dial(handle) }

    /// Recomputes the gate against the near side's facts as they stand now.
    func refreshDialGate(_ inputs: Inputs) -> GateEdge {
        Self.edge(slopdesk_ws_core_refresh_dial_gate(handle, inputs.raw))
    }

    /// The backstop ran out with no answer of any kind, which opens the hold.
    func noteBackstopExpired(_ inputs: Inputs) -> GateEdge {
        Self.edge(slopdesk_ws_core_note_backstop_expired(handle, inputs.raw))
    }

    /// A connect committed `hostKey` as this run's target.
    func commitConnectionTarget(_ inputs: Inputs, hostKey: String) -> GateEdge {
        var key = Array(hostKey.utf8)
        return Self.edge(key.withUnsafeMutableBufferPointer {
            slopdesk_ws_core_commit_connection_target(handle, inputs.raw, $0.baseAddress, $0.count)
        })
    }

    // MARK: The folded frame

    /// Books the establish fan-out a second run, on the first document frame the attached host folds.
    func armRedialOnDocument() { slopdesk_ws_core_arm_redial_on_document(handle) }

    /// A document frame folded.
    ///
    /// - Parameters:
    ///   - inputs: the near side's facts, including the offer's pending reading re-read from the
    ///     mirror rather than remembered — a frame retiring a patch and an `intentResult` snapping it
    ///     away are both answers, and neither is announced any other way.
    ///   - framesApplied: the mirror's own fold count, which is what tells a frame from a repaint.
    ///   - epochIsSeed: whether that document is still the store's own seed — the question, never a
    ///     host's answer.
    func noteDocumentFrame(_ inputs: Inputs, framesApplied: UInt64, epochIsSeed: Bool) -> FrameEdge {
        let edge = slopdesk_ws_core_note_document_frame(
            handle, inputs.raw, framesApplied, epochIsSeed,
        )
        return FrameEdge(
            gate: Self.edge(edge.gate),
            provenanceStamped: edge.provenance_stamped,
            redialBookingFired: edge.redial_booking_fired,
        )
    }

    /// Whether the armed launch offer may go out now.
    ///
    /// A pure fold, so it needs no handle: every input is the caller's, and asking for one would
    /// suggest the answer depended on state the core remembers.
    static func launchOfferReady(_ inputs: Inputs, knownEpochIsSeed: Bool, canMutate: Bool) -> Bool {
        slopdesk_ws_core_launch_offer_ready(inputs.raw, knownEpochIsSeed, canMutate)
    }

    // MARK: The save guard

    /// Arms the debounced write, after the construction reconcile.
    func enableSaving() { slopdesk_ws_core_enable_saving(handle) }

    /// Claims a generation for a debounced write, or `nil` while writes are disarmed.
    func beginSave() -> UInt64? {
        var generation: UInt64 = 0
        guard slopdesk_ws_core_begin_save(handle, &generation) else { return nil }
        return generation
    }

    /// Claims a generation for a write happening RIGHT NOW, whatever is in flight.
    @discardableResult
    func supersedeSave() -> UInt64 { slopdesk_ws_core_supersede_save(handle) }

    /// Whether a captured generation is still the live one.
    func isCurrentSaveGeneration(_ generation: UInt64) -> Bool {
        slopdesk_ws_core_is_current_save_generation(handle, generation)
    }

    /// The live generation as a value — what an observer asks to see whether a mutation moved the
    /// guard at all, which the predicate above cannot answer without also claiming.
    var saveGeneration: UInt64 { slopdesk_ws_core_save_generation(handle) }

    /// Whether debounced writes are armed at all — the guard the cache's own debounce shares.
    var savingEnabled: Bool { slopdesk_ws_core_saving_enabled(handle) }

    // MARK: The cache provenance

    /// The `host:port` the cached picture is written under, or empty when it may not be written.
    var cacheHostKey: String {
        let bytes = wsAnswerBytes { out, cap in
            slopdesk_ws_core_cache_host_key(handle, out, cap)
        }
        // The producer is `store_core`'s own `String`, so these bytes cannot be invalid UTF-8. A
        // failable init would add a `nil` branch meaning "may not be written", which is a different
        // answer from the empty key that already means exactly that.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The Swift shape of a gate edge. An unrecognised backstop code reads as `leave`, which changes
    /// nothing — the conservative reading of a byte this side did not write.
    private static func edge(_ raw: SlopDeskWsCoreGateEdge) -> GateEdge {
        GateEdge(
            changed: raw.changed,
            opened: raw.opened,
            backstop: Backstop(rawValue: raw.backstop) ?? .leave,
        )
    }
}
