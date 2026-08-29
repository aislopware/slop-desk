// NavigatorChromeCopy — the navigator column's own words, the ones no row reading carries.
//
// Everything about a ROW is already shared and mostly already Rust: ``SidebarRowReading`` resolves what
// the row says, ``SidebarRowMenu`` resolves the verbs on it, ``SidebarGitLine`` resolves the project
// header's git dialect. What was left over is the column's CHROME — the filter field above the list,
// the two plates beside it, the drop slot a dragged pane can be broken out into, and the one verb on the
// project header's context menu.
//
// Four strings, and none of them depends on anything: a placeholder, two spoken plate names and a menu
// row. That is exactly why each stayed in its renderer and got typed once per shell
// (``SlopDeskMacUI/MacNavigatorColumn`` / ``SlopDeskMacUI/MacSidebarHeader`` against
// `SlopDeskPhoneUI/NavigatorColumnViewController`) — there was no reading for them to travel in. A
// sentence spelled twice is a translation bug that has already happened, which is what
// `shared-vocabulary-ceiling` counts (`rust/slopdesk-invariants/src/rules/two_shells.rs`, docs/56 §3).
//
// ⚠️ THE FILTER FIELD IS NOT THE SEARCH OVERLAY. ``GlobalSearchPresentation`` owns the cross-tab search's
// words (`slopdesk_workspace::global_search::QUERY_PROMPT`), and that surface asks a different question
// — it looks INSIDE panes. This one narrows the list that is already on screen, which is why its prompt
// names tabs rather than everything.

// Four `String`s and nothing else: this file imports nothing.

/// The navigator column's chrome labels.
package enum NavigatorChromeCopy {
    /// The filter field's placeholder. It names what is being narrowed, not the act — a field that said
    /// "Search" would read as the cross-tab search this one is not.
    package static let searchPrompt = "Search tabs"

    /// The clear plate beside it — a glyph on both platforms, so this is the only form of it a pointer
    /// or a screen reader can reach.
    package static let clearSearch = "Clear search"

    /// The new-tab affordance: the `+` plate's spoken name on the phone, and the label drawn INSIDE the
    /// Mac's drop slot, which mounts only while a pane drag is live. One word for both, because a slot
    /// that promised something other than what the plate makes would be two features wearing one name.
    package static let newTab = "New Tab"

    /// The project header's one context-menu verb: re-ask the host for this project's git summary.
    ///
    /// Title Case, because it is a menu row and that is the platform's register for one. It names GIT
    /// STATUS rather than "Refresh" alone, since the header carries a branch, a dirty mark and an
    /// ahead/behind pair, and a bare verb would not say which of them is being re-read.
    package static let refreshGitStatus = "Refresh Git Status"
}
