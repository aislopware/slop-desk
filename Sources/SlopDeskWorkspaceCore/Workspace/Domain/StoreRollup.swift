import CSlopDeskFFI

// MARK: - StoreRollup (what a whole set of leaves says)

/// The two precedence LADDERS the store folds a set of per-leaf facts through, as
/// `slopdesk-workspace::store_rollup` answers them.
///
/// Both are asked the same way from three places each — over a session's leaves, over a tab's leaves,
/// and (progress only) over every leaf in the tree for the macOS Dock tile — so the rule is about the
/// COLUMN, never about the pane. Nothing here is told which panes it is reading.
public enum StoreRollup {
    /// The ERROR-DOMINANT `OSC 9;4` rollup over a set of leaves: any `.error` wins (at the FIRST
    /// failing leaf's percent — a later failure must not rewrite the number already on screen), else
    /// any `.determinate` at the MAX percent (a bar fills toward done, so the closest-to-done leaf is
    /// the honest reading), else any `.indeterminate` spinner, else `nil`.
    ///
    /// A determinate leaf at ZERO still outranks a spinner: a program that knows its own scale and
    /// has not started says more than one that does not.
    public static func aggregateProgress(_ states: [PaneProgress?]) -> PaneProgress? {
        let leaves = states.map { state in
            SlopDeskWsLeafProgress(kind: state?.ffiRollup ?? 0, percent: state?.ffiPercent ?? 0)
        }
        let rolled = leaves.withUnsafeBufferPointer { column in
            slopdesk_ws_aggregate_progress(column.baseAddress, column.count)
        }
        return PaneProgress(ffiRollup: rolled.kind, percent: rolled.percent)
    }

    /// The completion rollup over a set of leaves: `.failure` if any leaf failed, else `.success` if
    /// any succeeded, else `nil`. A failure is the more urgent thing to surface, and a green tick over
    /// a session holding one would be the surface lying about the only thing worth interrupting for.
    public static func rollupCompletion(_ badges: [PaneCompletionBadge?]) -> PaneCompletionBadge? {
        let column = badges.map { $0?.ffiByte ?? 0 }
        let rolled = column.withUnsafeBufferPointer { bytes in
            slopdesk_ws_rollup_completion(bytes.baseAddress, bytes.count)
        }
        return PaneCompletionBadge(ffiByte: rolled)
    }
}

// MARK: - RecentsRing (the one dedupe-to-front-and-cap, and the walk down it)

/// The most-recently-used RING policy, as `slopdesk-workspace::store_rollup` answers it — one rule
/// behind every ring in the store.
///
/// There were four spellings of it, one per element type the store happened to be ringing: the
/// session-retention LRU, the pane visit ring, the palette's recent commands, and the clipboard
/// history. Every one was `removeAll { $0 == x }` · `insert(x, at: 0)` · trim to a cap, written out in
/// place, and a fifth ring would have been a fifth. They are one call now.
///
/// The rule never learns an element. It is handed one ROLE per existing entry and answers SLOTS —
/// where each surviving entry came from — so a `SessionID`, a `PaneID`, a palette catalogue id and a
/// clipboard text all cross as the same three bytes. The comparison that assigns the roles is the
/// caller's, because the values are.
public enum RecentsRing {
    /// `list` with `incoming` pushed to the front: deduped (a repeat MOVES rather than duplicating),
    /// optionally keeping `previous` retained behind it, and capped at `cap` by trimming the BACK —
    /// which is what makes this an LRU rather than a queue.
    ///
    /// `previous` is the OUTGOING entry a switch leaves behind, and it is seeded in front of the
    /// survivors only when the ring does not already hold it: that is the first-switch-away case, where
    /// the outgoing entry was never itself pushed through this path and nothing else would have put it
    /// in the ring. A `previous` already in the ring keeps the place it had — it is not what was just
    /// chosen, only what must not be lost.
    ///
    /// A `previous` equal to `incoming` is NOT a previous, and is resolved here rather than across the
    /// boundary: retaining the thing you are promoting is not a second entry, and both orderings of the
    /// spelling this replaced collapse to the plain push.
    ///
    /// A `cap` of zero answers an empty ring — including without the push.
    public static func pushing<Element: Equatable>(
        _ incoming: Element,
        into list: [Element],
        cap: Int,
        retaining previous: Element? = nil,
    ) -> [Element] {
        let retained: Element? = previous == incoming ? nil : previous
        let roles: [UInt8] = list.map { (entry: Element) -> UInt8 in
            if entry == incoming { return 1 }
            if let retained, entry == retained { return 2 }
            return 0
        }
        // The answer is at most the ring plus the push plus the seeded previous, so the first buffer
        // is the arithmetic bound rather than a guess and the size-then-retry path is never travelled.
        var slots = [SlopDeskWsRingSlot](repeating: SlopDeskWsRingSlot(), count: list.count + 2)
        let count = roles.withUnsafeBufferPointer { bytes in
            slots.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_ring_push(
                    bytes.baseAddress, bytes.count, retained != nil, max(0, cap),
                    out.baseAddress, out.count,
                )
            }
        }
        guard count <= slots.count else { return list }
        return slots.prefix(count).compactMap { (slot: SlopDeskWsRingSlot) -> Element? in
            switch slot.kind {
            case 1: return incoming
            case 2: return retained
            default:
                let position = Int(slot.index)
                return list.indices.contains(position) ? list[position] : nil
            }
        }
    }

    /// The first entry of `mru` that is still in `survivors`, or `nil` when none is.
    ///
    /// The ring is deliberately never pruned — a pane that closes simply stops being offered, because
    /// every reader intersects with the live set on the way past — so walking over ids nothing can
    /// focus any more is the normal case. `nil` is a real verdict rather than a failure: the tree
    /// operation's own neighbour rule stands rather than being overridden with a guess.
    ///
    /// The membership test stays here (it is a set of UUIDs, which is the caller's); the rule is handed
    /// one flag per entry and answers a POSITION.
    public static func mostRecentSurvivor<Element: Hashable>(
        mru: [Element],
        survivors: Set<Element>,
    ) -> Element? {
        let survives = mru.map { survivors.contains($0) }
        let position = survives.withUnsafeBufferPointer { flags in
            slopdesk_ws_most_recent_survivor(flags.baseAddress, flags.count)
        }
        guard position >= 0, position < mru.count else { return nil }
        return mru[position]
    }
}

// MARK: - The bytes each vocabulary crosses as

extension PaneProgress {
    /// The inverse of ``ffiRollup`` / ``ffiPercent``: the `OSC 9;4` discriminant a rollup came back
    /// as. `0` — and anything this build cannot name — is the ABSENCE of an indicator, which is what
    /// "no leaf had any" answers with.
    init?(ffiRollup kind: UInt8, percent: UInt8) {
        switch kind {
        case 1: self = .determinate(percent: percent)
        case 2: self = .error(percent: percent)
        case 3: self = .indeterminate
        default: return nil
        }
    }
}

extension PaneCompletionBadge {
    /// `1` a clean finish · `2` a failure. `0` is the absence of a badge, which has no case here.
    var ffiByte: UInt8 {
        switch self {
        case .success: 1
        case .failure: 2
        }
    }

    /// The inverse. Anything unnamed is no badge — never a failure nobody reported.
    init?(ffiByte raw: UInt8) {
        switch raw {
        case 1: self = .success
        case 2: self = .failure
        default: return nil
        }
    }
}
