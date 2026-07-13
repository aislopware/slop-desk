import Foundation

// MARK: - JumpBreadcrumb (the "where did that jump land" readout)

/// The pure text behind the `JUMPED · <session ▸ tab>` notice chip: a TELEPORT focus (⌘⇧U attention walk,
/// palette / Open Quickly row, a Global Search hit, a notification or connection-alert click) can swap the
/// whole viewport to a different tab — or a different session — in one frame, with no cue of where you
/// landed. The breadcrumb names the destination so the jump is orientable; a same-tab focus never shows it
/// (the caller only fires on a crossed tab boundary — absent, never wrong).
///
/// Pure + static so the title precedence and the session-qualification rule are unit-pinned
/// (`JumpBreadcrumbTests`) without a store.
public enum JumpBreadcrumb {
    /// The tab's display title, resolved with the SAME precedence the control backend / Open Quickly use:
    /// an explicit (user-renamed) `Tab.title` wins; else the active pane's last-known OSC title; else its
    /// spec title; else the "Tab" placeholder. Never empty — the chip must name SOMETHING.
    public static func tabDisplayTitle(tab: Tab, specs: [PaneID: PaneSpec]) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let active = tab.activePane ?? tab.allPaneIDs().first, let spec = specs[active] {
            if let last = spec.lastKnownTitle, !last.isEmpty { return last }
            if !spec.title.isEmpty { return spec.title }
        }
        return "Tab"
    }

    /// The breadcrumb line: `"<session> ▸ <tab>"` when the workspace has several sessions (the session
    /// name disambiguates WHICH sidebar group you landed in), else just the tab title (a lone session's
    /// name is constant noise). An empty session name degrades to the tab-only form.
    public static func text(sessionName: String, tabTitle: String, includeSession: Bool) -> String {
        guard includeSession, !sessionName.isEmpty else { return tabTitle }
        return "\(sessionName) ▸ \(tabTitle)"
    }
}
