import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-muxsession`'s `resize_fold`, reached through the `mux_resize`
/// door.
///
/// One pane's PTY size fold (docs/45 §8.3): every attached client makes a standing OFFER of how big
/// it wants the shell, and the pane runs at the smallest one. Monotone, so it settles — an
/// input-keyed "whoever typed last drives" latch has no hysteresis and would flap `TIOCSWINSZ` +
/// `SIGWINCH` + a full TUI repaint on every exchange between two clients.
///
/// **A handle, not a fold-by-value.** The state is a map of every subscriber's standing offer plus
/// the override and settle latches around it, it lives as long as the pane, and ``MuxChannelSession``
/// mutates it from four contexts. That is `docs/55` §4b's test for a handle.
///
/// **What stayed on this side.** The `TIOCSWINSZ` and the timers. Every method answers what the
/// grid SHOULD be, or whether a timer is worth arming and under which generation; the descriptor
/// and the `Task` belong to the session, because a descriptor cannot cross and a `Task` should not.
///
/// Not `Sendable` and deliberately unlocked: ``MuxChannelSession`` holds every call under its
/// `resizeLock`, exactly as it did when this state was its own stored properties.
final class PaneResizeFold {
    /// One client's offer, or one resolved fold.
    ///
    /// The pixels are CARRIED through the fold rather than folded — they are one client's cell
    /// metrics at one scale, and a minimum over two clients' is a number no display has.
    struct Grid: Equatable {
        var cols: UInt16
        var rows: UInt16
        var px: UInt16
        var py: UInt16

        init(cols: UInt16, rows: UInt16, px: UInt16 = 0, py: UInt16 = 0) {
            self.cols = cols
            self.rows = rows
            self.px = px
            self.py = py
        }
    }

    /// What a mutation asks the caller to schedule.
    struct Arm {
        /// The generation a scheduled task must quote back to ``resolve(ifGeneration:)`` — what
        /// makes a task already past its `sleep` (which `Task.cancel()` can no longer stop) bail
        /// when a newer change superseded it.
        var generation: UInt64
        /// Whether to arm this mutation's timer: the contributor settle for a membership change,
        /// the short debounce for an offer.
        var arm: Bool
    }

    /// One contributor as the workspace roster publishes it.
    struct Attachment {
        var subscriber: MuxSubscriberID
        /// What the fold ACTUALLY credits, not the passivity flag alone: a phone alone on a pane
        /// sizes it, and publishing `false` there would make every client render a letterbox
        /// crediting a client that is not here.
        var contributes: Bool
        var cols: UInt16
        var rows: UInt16
    }

    /// The far side, which owns the contributor map and both latches.
    private let handle: OpaquePointer?

    /// A fold for a session whose opening subscriber votes (or is size-passive — resolved HOST-side
    /// from the workspace channel's `clientKind`, never from anything the pane channel claims).
    init(openedSizePassive: Bool) {
        handle = slopdesk_resize_fold_new(openedSizePassive)
    }

    deinit { slopdesk_resize_fold_free(handle) }

    /// Registers `subscriber` as a member, or updates its passivity. An existing member KEEPS its
    /// standing offer: a reattach swaps the sub-channels while the same PTY lives on.
    func add(_ subscriber: MuxSubscriberID, sizePassive: Bool) -> Arm {
        Arm(slopdesk_resize_fold_add(handle, subscriber, sizePassive))
    }

    /// Drops `subscriber`. A pane whose set EMPTIES keeps its last size (docs/45 §8.3 rule 4).
    func remove(_ subscriber: MuxSubscriberID) -> Arm {
        Arm(slopdesk_resize_fold_remove(handle, subscriber))
    }

    /// Records `subscriber`'s LATEST offer, registering it if it was not a member — the ctl-spawned
    /// and null-sub-channel paths never open a channel, and a resize frame is itself proof that
    /// somebody is holding this pane at a size.
    ///
    /// `arm` is false while a contributor settle is outstanding: the offer joins the fold that
    /// settle will resolve, and arming the short debounce there is exactly what would make a burst
    /// of joins `SIGWINCH` the shell once per arrival.
    func offer(from subscriber: MuxSubscriberID, _ grid: Grid) -> Arm {
        Arm(slopdesk_resize_fold_offer(handle, subscriber, grid.wire))
    }

    /// Installs the ctl socket's `resize` verb as an OVERRIDE — it stands until the next CREDITED
    /// client offer — and answers the generation it applies under.
    func override(_ grid: Grid) -> UInt64 {
        slopdesk_resize_fold_override(handle, grid.wire)
    }

    /// The grid to apply, or `nil` when nobody is holding this pane at a size.
    ///
    /// - Parameter ifGeneration: the timer paths' guard. The flush paths (ack, bye, channel close)
    ///   pass `nil` and resolve unconditionally, because they must never strand a size.
    func resolve(ifGeneration generation: UInt64?) -> Grid? {
        var out = SlopDeskResizeGrid()
        guard slopdesk_resize_fold_resolve(handle, generation != nil, generation ?? 0, &out) else {
            return nil
        }
        return Grid(out)
    }

    /// The grid the fold last resolved, for the roster to publish. `nil` for a pane nothing has ever
    /// resolved — the caller falls back to the live winsize there.
    var lastResolved: Grid? {
        var out = SlopDeskResizeGrid()
        guard slopdesk_resize_fold_resolved(handle, &out) else { return nil }
        return Grid(out)
    }

    /// Releases the settle latch, guarded by the generation so a superseded task cannot unlatch a
    /// settle a newer set change owns.
    func clearSettle(ifGeneration generation: UInt64) {
        slopdesk_resize_fold_clear_settle(handle, generation)
    }

    /// Drops every member, for a pane being torn down: nobody holds a dead pane at a size. The
    /// generation is untouched, so a timer task still past its `sleep` cannot match a rewound
    /// counter and apply a fold for a session that is gone.
    func removeAll() { slopdesk_resize_fold_clear_members(handle) }

    /// Whether a contributor-set change is still settling.
    var isSettling: Bool { slopdesk_resize_fold_is_settling(handle) }

    /// Every contributor in subscriber order.
    ///
    /// Asked for its length first, then read whole: the door writes nothing into a buffer the list
    /// does not fit, which is the same retry convention every table door here uses.
    var attachments: [Attachment] {
        let count = slopdesk_resize_fold_attachments(handle, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [SlopDeskResizeAttachment](repeating: SlopDeskResizeAttachment(), count: count)
        let written = buffer.withUnsafeMutableBufferPointer { raw in
            slopdesk_resize_fold_attachments(handle, raw.baseAddress, raw.count)
        }
        guard written == count else { return [] }
        return buffer.map { entry in
            Attachment(
                subscriber: entry.subscriber,
                contributes: entry.contributes,
                cols: entry.cols,
                rows: entry.rows,
            )
        }
    }
}

extension PaneResizeFold.Grid {
    /// The door's shape of this grid.
    var wire: SlopDeskResizeGrid { SlopDeskResizeGrid(cols: cols, rows: rows, px: px, py: py) }

    /// This side's shape of what the door answered.
    init(_ wire: SlopDeskResizeGrid) {
        self.init(cols: wire.cols, rows: wire.rows, px: wire.px, py: wire.py)
    }
}

extension PaneResizeFold.Arm {
    /// What the door answered, as the two things the caller acts on.
    init(_ wire: SlopDeskResizeArm) {
        self.init(generation: wire.generation, arm: wire.arm)
    }
}
