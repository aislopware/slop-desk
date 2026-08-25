import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect

// MARK: - SupervisionFold (the watch on the pane under the user's eyes)

/// The focused-finish WATCH and its two neighbours, as `slopdesk-workspace::attention_fold` answers
/// them.
///
/// ``PaneFacts`` answers what one status LANDING moves; this is the other half of the same cockpit —
/// the fold that runs over every pane a dwell clock is (or should be) ticking on, the candidacy test
/// it is written against, and the two one-line policies that stood beside it: what an empty label
/// means, and when an explicit acknowledge may settle a status.
///
/// Nothing here learns a ``PaneID``. The fold is handed one ROW per pane in whatever order the store
/// unioned its watch map with its candidate list, and answers one verdict per row in that order.
public enum SupervisionFold {
    /// One pane's standing in the focused-finish watch.
    public struct Watch: Equatable, Sendable {
        /// Whether a dwell clock is already running on this pane.
        public var watching: Bool
        /// How long that clock has run. Ignored — and never read — when ``watching`` is `false`.
        public var watched: TimeInterval
        /// Whether the pane is one a watch may run on right now (``isSettleCandidate(appActive:focused:finished:unseenFinish:)``).
        public var candidate: Bool

        public init(watching: Bool, watched: TimeInterval, candidate: Bool) {
            self.watching = watching
            self.watched = watched
            self.candidate = candidate
        }
    }

    /// What the fold says about ONE row. Exclusive by construction: a row that starts a clock cannot
    /// also be settling one.
    public enum SettleVerdict: UInt8, Sendable {
        /// Nothing to do — the clock keeps running, or there was never one to run.
        case hold = 0
        /// START a clock at the caller's instant.
        case start = 1
        /// DROP the clock: the pane stopped being a candidate, and the window measures an UNBROKEN
        /// watch, so a later return starts a fresh one.
        case drop = 2
        /// The window elapsed under an unbroken watch — ACKNOWLEDGE the pane. Reading it is seeing it.
        case settle = 3
    }

    /// The whole focused-finish fold: one verdict per row, plus whether the caller must arm its
    /// one-shot.
    ///
    /// The arming flag is the fold's second conclusion rather than a scan the caller repeats: a
    /// finished agent stops mutating the store, so a started clock is the only thing that will ever
    /// make anybody look again.
    ///
    /// The answer is exactly one verdict per row, so a buffer the size of the input is the arithmetic
    /// bound rather than a guess and the size-then-retry path is never travelled.
    public static func settleStep(
        _ rows: [Watch],
        window: TimeInterval,
    ) -> (verdicts: [SettleVerdict], armsScheduler: Bool) {
        guard !rows.isEmpty else { return ([], false) }
        let lent = rows.map { row in
            SlopDeskWsSettleWatch(watching: row.watching, candidate: row.candidate, watched: row.watched)
        }
        var codes = [UInt8](repeating: 0, count: rows.count)
        var arms = false
        let count = lent.withUnsafeBufferPointer { input in
            codes.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_settle_step(
                    input.baseAddress, input.count, window, out.baseAddress, out.count, &arms,
                )
            }
        }
        guard count == rows.count else { return ([], false) }
        return (codes.map { SettleVerdict(rawValue: $0) ?? .hold }, arms)
    }

    /// Whether a watch may run on a pane at all: focused in an ACTIVE app — a key satellite counts as
    /// focused, but only while the app itself is frontmost — and carrying a finished-turn marker,
    /// either a live `.done` or the unread latch. A live `.working` / `.needsPermission` is never
    /// unread OUTPUT, so the settle can never silence a waiting approval gate.
    public static func isSettleCandidate(
        appActive: Bool,
        focused: Bool,
        finished: Bool,
        unseenFinish: Bool,
    ) -> Bool {
        slopdesk_ws_settle_candidate(appActive, focused, finished, unseenFinish)
    }

    /// Whether a walk in progress must be abandoned: one is running, and the focus it last set has
    /// moved under it. `walking` is false before the first step, when there is nothing to compare.
    public static func walkInterrupted(walking: Bool, focusHeld: Bool) -> Bool {
        slopdesk_ws_walk_interrupted(walking, focusHeld)
    }

    /// Whether an explicit acknowledge may settle `status` to idle. Only a finished turn — a live
    /// state, and above all an approval gate, is deliberately left alone.
    public static func badgeClearSettles(_ status: ClaudeStatus) -> Bool {
        slopdesk_ws_badge_clear_settles(status.ffiByte)
    }

    /// Text with nothing in it, as the ABSENCE of a value — the store's one normalization for every
    /// host-pushed label (the agent label, the sticky session intent, the coarse process name).
    ///
    /// `nil` is what the caller REMOVES its key on, so the row falls back down its own chain instead
    /// of titling itself with a blank. The trim is the Unicode White_Space set, which is what
    /// `whitespacesAndNewlines` names too.
    public static func normalized(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let bytes = Array(text.utf8)
        // The answer is never longer than the input, so one buffer of that size always fits.
        var out = [UInt8](repeating: 0, count: bytes.count)
        let count = bytes.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_normalized_text(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
        }
        guard count > 0, count <= out.count else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(count), as: UTF8.self)
    }
}

// MARK: - MirrorFold (what this side still asks about the replica)

/// What this side still asks ABOUT the replica of the host-owned document, as
/// `slopdesk-workspace::mirror_fold` answers it.
///
/// The replica is not here and neither is any decision about a frame: `WorkspaceMirrorBox` holds
/// the document itself, on the Rust side of one handle. What is left is the folds whose inputs are
/// values this side already has in hand — which candidate is the running command, whether the host
/// published a grid, whether a document change may reconcile, which intent a spec edit becomes, and
/// who, other than you, is viewing or holding a pane.
///
/// No identity crosses. The two roster joins see clients as dense `UInt32` tokens this side minted
/// and answer POSITIONS into the array it still holds, so the join decides WHICH label and the caller
/// reads it.
public enum MirrorFold {
    // MARK: Reads

    /// Which of the three candidates names the command a pane is RUNNING.
    public enum RunningCommand: Equatable, Sendable {
        /// The host's own open block, trimmed.
        case hosted(String)
        /// This client's newest OPEN block, trimmed.
        case open(String)
        /// The caller's cleaned-up foreground-process name — the string never crossed, because the
        /// cleanup that produced it is the interface's and it is already holding it.
        case processLabel
        /// Nothing is known, so the caller's remaining chain keeps resolving.
        case absent
    }

    /// Resolves the running-command chain: the host's open block, then this client's newest one, then
    /// the process label. Blank at any rung is ABSENT at that rung, not a blank answer.
    public static func runningCommand(
        hosted: String?,
        open: String?,
        hasProcessLabel: Bool,
    ) -> RunningCommand {
        let hostedBytes = Array((hosted ?? "").utf8)
        let openBytes = Array((open ?? "").utf8)
        var source: UInt8 = 0
        // Neither trimmed answer can outgrow its own input, so the longer of the two always fits.
        var out = [UInt8](repeating: 0, count: max(hostedBytes.count, openBytes.count, 1))
        let count = hostedBytes.withUnsafeBufferPointer { first in
            openBytes.withUnsafeBufferPointer { second in
                out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_mirror_running_command(
                        first.baseAddress, first.count,
                        second.baseAddress, second.count,
                        hasProcessLabel, &source,
                        buffer.baseAddress, buffer.count,
                    )
                }
            }
        }
        guard count <= out.count else { return .absent }
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: out.prefix(count), as: UTF8.self)
        switch source {
        case 1: return .hosted(text)
        case 2: return .open(text)
        case 3: return .processLabel
        default: return .absent
        }
    }

    /// Whether the host has actually RESOLVED a grid for a pane. Both axes, or neither: a zero on
    /// either is the roster's "not published yet", and letterboxing against it would place a pane
    /// behind a fiction.
    public static func gridPublished(cols: Int, rows: Int) -> Bool {
        slopdesk_ws_mirror_grid_published(UInt32(max(0, cols)), UInt32(max(0, rows)))
    }

    /// Whether a document change may reconcile the registry against the layout it produced.
    public static func reconcileAdmitted(
        reconciling: Bool,
        projected: Bool,
        bootstrapArmed: Bool,
        adoptPending: Bool,
        epochIsSeed: Bool,
    ) -> Bool {
        slopdesk_ws_mirror_reconcile_admitted(
            reconciling, projected, bootstrapArmed, adoptPending, epochIsSeed,
        )
    }

    /// Which intent a spec edit becomes.
    public enum SpecIntent: UInt8, Sendable {
        /// REFUSED — the edit touched a field this client cannot publish, and the next host frame
        /// would erase it. The caller names it in the debug log rather than dropping it silently.
        case refused = 0
        /// The VIDEO BINDING moved.
        case videoTarget = 1
        /// An AUTHORED title. A DERIVED one needs no op: it follows the binding, and sending it as a
        /// rename would set the authorship flag and make the next re-pick unable to update it.
        case rename = 2
    }

    /// Picks the intent for a spec edit that actually changed something. The video binding is checked
    /// first and exclusively — a re-point that also moved the derived title is one gesture.
    public static func specIntent(
        videoMoved: Bool,
        userRenamed: Bool,
        titleMoved: Bool,
        wasUserRenamed: Bool,
    ) -> SpecIntent {
        SpecIntent(
            rawValue: slopdesk_ws_mirror_spec_intent(videoMoved, userRenamed, titleMoved, wasUserRenamed),
        ) ?? .refused
    }

    // MARK: The roster's two joins

    /// One roster client, as the joins read it — a token this side minted for its instance id, plus
    /// the two facts the joins turn on.
    public struct PresenceClient: Equatable, Sendable {
        /// The dense token minted for the client's instance id.
        public var token: UInt32
        /// Whether the client published a label anybody can read.
        public var labelled: Bool
        /// Whether the client is looking at the pane being asked about.
        public var viewing: Bool

        public init(token: UInt32, labelled: Bool, viewing: Bool) {
            self.token = token
            self.labelled = labelled
            self.viewing = viewing
        }
    }

    /// The other clients currently LOOKING at a pane, as POSITIONS into `clients`. An unlabelled
    /// viewer is dropped — there is nothing to print — which is exactly where this differs from
    /// ``holders(attachments:clients:own:)``.
    public static func viewers(_ clients: [PresenceClient], own: UInt32?) -> [Int] {
        guard !clients.isEmpty else { return [] }
        let lent = clients.map { seat in
            SlopDeskWsPresenceClient(token: seat.token, labelled: seat.labelled, viewing: seat.viewing)
        }
        var out = [UInt32](repeating: 0, count: clients.count)
        let count = lent.withUnsafeBufferPointer { rows in
            out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_mirror_viewers(
                    rows.baseAddress, rows.count, own != nil, own ?? 0,
                    buffer.baseAddress, buffer.count,
                )
            }
        }
        guard count <= out.count else { return [] }
        return out.prefix(count).compactMap { position in
            clients.indices.contains(Int(position)) ? Int(position) : nil
        }
    }

    /// The other clients HOLDING a channel on a pane: one answer per surviving attachment, in
    /// `attachments` order.
    ///
    /// A POSITION into `clients` names the holder; `nil` is an attachment no roster client names —
    /// a real client holding a real pane that nothing can label. It is REPORTED rather than dropped,
    /// or a pane held by a bare client would read as unheld and the resolved grid's arithmetic would
    /// be unexplainable.
    public static func holders(
        attachments: [UInt32],
        clients: [PresenceClient],
        own: UInt32?,
    ) -> [Int?] {
        guard !attachments.isEmpty else { return [] }
        let lent = clients.map { seat in
            SlopDeskWsPresenceClient(token: seat.token, labelled: seat.labelled, viewing: seat.viewing)
        }
        var out = [Int](repeating: -1, count: attachments.count)
        let count = attachments.withUnsafeBufferPointer { held in
            lent.withUnsafeBufferPointer { rows in
                out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_mirror_holders(
                        held.baseAddress, held.count, rows.baseAddress, rows.count,
                        own != nil, own ?? 0, buffer.baseAddress, buffer.count,
                    )
                }
            }
        }
        guard count <= out.count else { return [] }
        return out.prefix(count).map { position in
            clients.indices.contains(position) ? position : nil
        }
    }
}
