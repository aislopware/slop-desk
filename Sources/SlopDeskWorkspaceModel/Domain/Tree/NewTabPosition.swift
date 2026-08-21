import CSlopDeskFFI

// MARK: - NewTabPosition (`new-tab-position` policy)

/// Where a newly opened tab is inserted into the active session's tab bar — the `new-tab-position`
/// config (`spec/user-interface__window-tab-split.md`, values `auto` / `end` /
/// `after-current`).
///
/// - ``auto``: context-aware. The default; with no surrounding window context to consult the sane
///   default is to **append**, so `.auto` is byte-identical to plain `tabs.append(...)`.
/// - ``end``: always append to the end of the tab list.
/// - ``afterCurrent``: insert immediately after the active tab (its raw value is `after-current`).
///
/// The CASE LIST is a vocabulary in two type systems (docs/55 §6) and stays: a settings picker
/// switches on it, ``WorkspaceIntent`` writes its byte onto the wire, and the `Defaults` bridge
/// stores its `rawValue`. The PLACEMENT is not part of the vocabulary and no longer lives here —
/// ``insertionIndex(activeTabIndex:tabCount:)`` asks `slopdesk_workspace`'s `NewTabPosition`.
///
/// `String`-raw + `CaseIterable` so it bridges to `Defaults` (see `SettingsKey`) and the settings
/// card grid can enumerate it. Those raw values are also the catalog TOKENS the same crate vends
/// for this group, which is what lets the placement door take a spelling rather than a fourth copy
/// of the byte map.
public enum NewTabPosition: String, Codable, Sendable, CaseIterable {
    case auto
    case end
    /// Raw value is the `after-current` config string, so the persisted setting round-trips losslessly
    /// with whatever a future Shell-settings row writes.
    case afterCurrent = "after-current"

    /// The index at which a new tab should be inserted into a tab list of `tabCount` tabs whose active tab
    /// sits at `activeTabIndex`.
    ///
    /// - ``auto`` / ``end`` → `tabCount` (the end index = an append, byte-identical to `tabs.append`).
    /// - ``afterCurrent`` → the slot after the active tab, with a stale / out-of-range active index and a
    ///   nonsense count both clamped first, so the answer can never be an invalid `Array.insert(at:)`
    ///   index. An empty list always yields `0`.
    ///
    /// The result is always a valid insertion index in `0...max(tabCount, 0)`.
    ///
    /// **This body used to be the arithmetic, and that was the more dangerous half of a pair.** The
    /// same three cases and the same two clamps live in `slopdesk_workspace::session`, and the copy
    /// that decides where a tab ACTUALLY lands is that one: every ⌘T and ⇧⌘T sends the policy as a
    /// byte inside a workspace intent and `tree_ops` places the tab on the far side. So this method
    /// had no production caller at all — it answered its own tests and nothing else, which is the
    /// one arrangement in which a divergence cannot show up as a red anything (docs/55 §8). It is a
    /// marshaller now, and the tests written against it exercise the rule that runs.
    public func insertionIndex(activeTabIndex: Int, tabCount: Int) -> Int {
        var spelling = rawValue
        let answer = spelling.withUTF8 { position in
            slopdesk_ws_new_tab_index(
                position.baseAddress, position.count, Int64(activeTabIndex), Int64(tabCount),
            )
        }
        // `clamping:` rather than a trapping conversion: the door's answer is bounded by a count
        // this caller supplied, so nothing reachable needs it — and a boundary disagreement should
        // land the tab somewhere legal rather than kill the app mid-⌘T.
        return Int(clamping: answer)
    }
}
