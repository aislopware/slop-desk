import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - VideoSlotLedger (who is decoding, who is letting go, and who may start)

/// The Swift face of `slopdesk-workspace`'s `store_video_slots`, reached through the
/// `slopdesk_ws_video_slots_*` door.
///
/// The concurrent live-video ceiling of docs/22 §7. Each video pane owns its own
/// `VTDecompressionSession`, display link and Metal renderer, so the cap bounds decode + composite
/// cost — the part that a shared UDP flow between same-host panes does not make cheaper.
///
/// **A handle, not a fold-by-value.** Three sets of facts that outlive every call — the ceiling,
/// who is decoding, who has closed but not finished letting go — plus a promotion counter that only
/// moves on the transitions that actually free something, mutated from four contexts in the store.
/// That is `docs/55` §4b's test for a handle, and ``PaneResizeFold`` set the shape.
///
/// **What stayed on this side.** Every reading off a live pane. Whether a pane IS a video pane,
/// whether it is decoding right now, whether an activation took — these are facts about a
/// ``PaneSessionHandle`` the far side has never seen, so they cross as ARGUMENTS. The ledger is
/// never the thing that flips a pane on; it is told what happened and answers what may happen next.
///
/// **Identity stayed here too.** A ``PaneID`` is a UUID. This mints a dense `UInt32` per pane and
/// crosses that, so the door's only claim about a token is that two equal tokens name one pane. The
/// map is never pruned: a pane that closes simply stops being asked about, and the cost of a token
/// nothing will use again is four bytes for the life of the store.
///
/// Not `Sendable` and deliberately unlocked: ``WorkspaceStore`` is `@MainActor` and every call site
/// is main-actor-isolated, exactly as it was when this state was three of its stored properties.
final class VideoSlotLedger {
    /// What a request to start decoding is answered with.
    enum Admission {
        /// No slot free, or not a video pane at all. Show the gated placeholder; touch nothing.
        case refuse
        /// Already decoding. Report success without re-activating anything.
        case alreadyLive
        /// A slot is free — activate, then report back what the pane actually did.
        case proceed
    }

    /// The far side, which owns the ceiling, both sets and the promotion counter.
    private let handle: OpaquePointer?

    /// Each pane's dense token. Grow-only; see the type's note on why it is never pruned.
    private var tokens: [PaneID: UInt32] = [:]

    /// The next token to mint. Wrapping is unreachable — it would take four billion panes in one
    /// launch — and a wrapped token would collide rather than crash, which is the safe direction.
    private var nextToken: UInt32 = 0

    /// A ledger with a ceiling of `cap` concurrent decoding panes. A negative cap is read as zero,
    /// which admits nothing — the honest reading of a nonsense ceiling.
    init(cap: Int) {
        handle = slopdesk_ws_video_slots_new(max(0, cap))
    }

    deinit { slopdesk_ws_video_slots_free(handle) }

    /// `id`'s token, minting one on first sight.
    private func token(_ id: PaneID) -> UInt32 {
        if let existing = tokens[id] { return existing }
        let minted = nextToken
        nextToken &+= 1
        tokens[id] = minted
        return minted
    }

    /// The verdict on a request to make `id` decode.
    ///
    /// - Parameters:
    ///   - isVideo: whether the pane's kind decodes video at all, read off the live handle.
    ///   - alreadyLive: whether it is decoding right now, read off the same handle.
    func admit(_ id: PaneID, isVideo: Bool, alreadyLive: Bool) -> Admission {
        switch slopdesk_ws_video_slots_admit(handle, token(id), isVideo, alreadyLive) {
        case 1: .alreadyLive
        case 2: .proceed
        default: .refuse
        }
    }

    /// Whether a slot is free FOR `id` right now — the pure read, with no mutation. Self-excluding
    /// and releasing-aware, so it agrees with what an ``admit(_:isVideo:alreadyLive:)`` this same
    /// tick would decide.
    func admits(_ id: PaneID) -> Bool {
        slopdesk_ws_video_slots_admits(handle, token(id))
    }

    /// Records what `id`'s pane ACTUALLY is after something flipped it — the confirm-read after an
    /// activation, and the resync after a pause or resume flipped the flag directly.
    func noteLive(_ id: PaneID, _ live: Bool) {
        slopdesk_ws_video_slots_note_live(handle, token(id), live)
    }

    /// `id` stops decoding while staying open, answering the promotion generation to publish.
    /// `wasLive` is the reading taken BEFORE the pane was stood down.
    func standDown(_ id: PaneID, wasLive: Bool) -> Int {
        Int(slopdesk_ws_video_slots_stand_down(handle, token(id), wasLive))
    }

    /// `id` CLOSED, answering the promotion generation to publish. `holdsStack` is the reading
    /// taken before teardown nils it: a video pane that was really decoding keeps its slot booked
    /// until ``release(_:)``.
    func orphan(_ id: PaneID, holdsStack: Bool) -> Int {
        Int(slopdesk_ws_video_slots_orphan(handle, token(id), holdsStack))
    }

    /// Whether `id`'s decode stack is still letting go — the guard on the caller's settle sleep.
    func isReleasing(_ id: PaneID) -> Bool {
        slopdesk_ws_video_slots_is_releasing(handle, token(id))
    }

    /// `id`'s decode stack is released, answering the promotion generation to publish. A pane that
    /// was not booked freed nothing, and the generation does not move.
    func release(_ id: PaneID) -> Int {
        Int(slopdesk_ws_video_slots_release(handle, token(id)))
    }

    /// Forgets every releasing token, for a caller that has drained every teardown it spawned.
    /// Silent: a repair does not announce a slot as newly free.
    func clearReleasing() {
        slopdesk_ws_video_slots_clear_releasing(handle)
    }

    /// The promotion generation as it stands.
    var generation: Int {
        Int(slopdesk_ws_video_slots_generation(handle))
    }
}
