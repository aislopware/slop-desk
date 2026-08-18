import CSlopDeskFFI

// MARK: - ListNavigation (where the highlight goes)

/// Moving a keyboard SELECTION over a list somebody is looking at: the arrows, the page keys,
/// Home/End, a `⌘1–9` quick pick, and Tab through a ring of pills.
///
/// The rules are `rust/slopdesk-workspace`'s `list_nav` (docs/55). Nothing but counts crosses —
/// each answer is an INDEX into the list the caller already holds, so the rows themselves never
/// leave Swift.
///
/// Three overlays had written the same clamp: the picker, the command navigator and the palette.
/// One rule now, and the choice a surface makes is which FUNCTION it calls — a list clamps at both
/// ends (every macOS list does, and holding an arrow down must not run the highlight off), a ring
/// wraps, because it has no ends to sit against.
public enum ListNavigation {
    /// A selection index moved by `delta` and clamped to `[0, count - 1]`.
    ///
    /// The shared contract for arrow (`±1`), page (`±page`) and Home/End (`±count`) navigation. An
    /// empty list — any `count <= 0` — answers `0`, which is the index each of those surfaces holds
    /// while there is nothing to select. The addition saturates, so a page key over a two-row list
    /// is still an index.
    public static func clampedSelection(current: Int, delta: Int, count: Int) -> Int {
        Int(slopdesk_list_clamped_selection(Int64(current), Int64(delta), Int64(count)))
    }

    /// The 0-based row a 1-based `⌘1–9` chord names in a list of `rowCount` visible rows, or `nil`
    /// for `⌘0` (a filter chord, never a pick), a chord above nine, and a chord past the rows on
    /// screen.
    public static func quickPickIndex(_ oneBased: Int, rowCount: Int) -> Int? {
        let answer = slopdesk_list_quick_pick(Int64(oneBased), max(0, rowCount))
        return answer < 0 ? nil : Int(answer)
    }

    /// The index `delta` steps to around a ring of `count` entries, wrapping at both ends. `nil` for
    /// an empty ring and for a starting index outside it — a caller whose current value is not one
    /// of the entries has nothing to step from.
    public static func wrappedIndex(_ index: Int, delta: Int, count: Int) -> Int? {
        guard index >= 0 else { return nil }
        let answer = slopdesk_list_wrapped_index(index, Int64(delta), max(0, count))
        return answer < 0 ? nil : Int(answer)
    }
}
