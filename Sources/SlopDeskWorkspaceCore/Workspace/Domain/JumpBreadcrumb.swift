import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - JumpBreadcrumb (the "where did that jump land" readout)

/// The pure text behind the `JUMPED · <session ▸ tab>` notice chip, as a face over
/// `slopdesk_workspace::rail_title`: a TELEPORT focus (⌘⇧U attention walk, palette / Open Quickly row, a
/// Global Search hit, a notification or connection-alert click) can swap the whole viewport to a
/// different tab — or a different session — in one frame, with no cue of where you landed. The breadcrumb
/// names the destination so the jump is orientable; a same-tab focus never shows it (the caller only fires
/// on a crossed tab boundary — absent, never wrong).
///
/// Both DECISIONS crossed to Rust, beside the pane-title precedence they are the tab-level echo of: which
/// rung a tab's name comes from, and when the session half is worth printing. What stayed is the lookup —
/// which pane in this tab to ask, and what the mirror says its live title is — because a live tree and a
/// closure do not cross a C boundary and neither is a rule.
public enum JumpBreadcrumb {
    /// The tab's display title, resolved with the SAME precedence the control backend / Open Quickly use:
    /// an explicit (user-renamed) `Tab.title` wins; else the active pane's live OSC title; else its
    /// spec title; else the "Tab" placeholder. Never empty — the chip must name SOMETHING.
    ///
    /// - Parameter liveTitle: the pane's live shell title, which the tree does not carry — the caller
    ///   reads it from the workspace mirror. `nil` simply falls through to the spec title.
    public static func tabDisplayTitle(
        tab: Tab, specs: [PaneID: PaneSpec], liveTitle: (PaneID) -> String? = { _ in nil },
    ) -> String {
        let resolved = tab.activePane ?? tab.allPaneIDs().first
        let spec = resolved.flatMap { specs[$0] }
        var title = Array(tab.title.utf8)
        var specTitle = Array((spec?.title ?? "").utf8)
        var live = Array((resolved.flatMap(liveTitle) ?? "").utf8)
        let answer = title.withUnsafeMutableBufferPointer { tabLent in
            specTitle.withUnsafeMutableBufferPointer { specLent in
                live.withUnsafeMutableBufferPointer { liveLent in
                    wsAnswer { out, cap in
                        slopdesk_ws_tab_display_title(
                            tabLent.baseAddress, tabLent.count,
                            // The FLAG, not the length: a pane with no spec at all is a different
                            // fact from one whose spec title is blank, and the door answers them
                            // differently.
                            spec != nil, specLent.baseAddress, specLent.count,
                            liveLent.baseAddress, liveLent.count,
                            out, cap,
                        )
                    }
                }
            }
        }
        // The door's fallback is a non-empty literal, so `nil` is unreachable rather than a rung.
        return answer ?? ""
    }

    /// The breadcrumb line: `"<session> ▸ <tab>"` when the workspace has several sessions (the session
    /// name disambiguates WHICH sidebar group you landed in), else just the tab title (a lone session's
    /// name is constant noise). An empty session name degrades to the tab-only form.
    public static func text(sessionName: String, tabTitle: String, includeSession: Bool) -> String {
        var session = Array(sessionName.utf8)
        var title = Array(tabTitle.utf8)
        let answer = session.withUnsafeMutableBufferPointer { sessionLent in
            title.withUnsafeMutableBufferPointer { titleLent in
                wsAnswer { out, cap in
                    slopdesk_ws_jump_breadcrumb(
                        sessionLent.baseAddress, sessionLent.count,
                        titleLent.baseAddress, titleLent.count,
                        includeSession,
                        out, cap,
                    )
                }
            }
        }
        // The door spells an empty line `0`, which is the same nothing an untitled unqualified tab asks
        // for.
        return answer ?? ""
    }
}
