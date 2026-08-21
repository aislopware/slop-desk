//! What a drop DOES, once the pasteboard has been classified and a zone is under the pointer.
//!
//! The zones are drawn as a green half (terminal actions) and a blue half (pane actions), and the
//! table below is the whole of what they mean:
//!
//! | Dragged      | New Tab      | Insert Path | Open In-Place | Split Left / Right |
//! |--------------|--------------|-------------|---------------|--------------------|
//! | Folder       | new tab, cd  | paste       | host open     | split at the path  |
//! | File         | —            | paste       | host open     | split at the path  |
//! | URL          | —            | paste       | —             | —                  |
//! | Text snippet | paste        | paste       | paste         | paste              |
//!
//! Three things are deliberately absent, and each is a decision rather than a gap. A **text snippet
//! pastes in every zone**, so it is answered before the zone is even read. A **URL has no viewer**:
//! the local web pane is retired, so a URL only ever pastes. And nothing here can mint a **video
//! pane** — a streamed host window comes from the picker alone, which is why [`DropAction`] carries
//! no case that could make one. A cell with no meaning answers `None`, and the overlay reads that
//! same `None` to render the zone muted, so what is offered and what would happen cannot drift.

/// Where the pointer is when the drag is released.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropZone {
    /// Top-centre: open a new terminal tab rooted at the dropped folder.
    NewTab,
    /// Centre: paste the dropped path or text into the focused terminal.
    InsertPath,
    /// Lower centre: open the dropped path where it lives, on the host.
    OpenInPlace,
    /// Left edge: split a new pane to the left, aimed at the path.
    SplitLeft,
    /// Right edge: the same, to the right.
    SplitRight,
}

/// What was dropped, as the pasteboard classifier resolved it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DroppedKind {
    /// A directory path.
    Folder,
    /// A regular file path.
    File,
    /// A non-file URL.
    Url,
    /// A plain-text snippet.
    Text,
}

/// One classified drop: what it is, and the one string it carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dropped<'a> {
    /// What the classifier made of it.
    pub kind: DroppedKind,
    /// The path, URL or text itself.
    pub value: &'a str,
}

/// The instruction a `(zone, content)` pair resolves to.
///
/// Each case names WHERE it actuates, so the thin actuator routes it without re-deriving intent:
/// the pasteboard and the PTY are the client's, the filesystem is the host's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DropAction {
    /// Paste this text or path VERBATIM into the focused terminal.
    InjectText(String),
    /// Open a new terminal tab rooted at this folder.
    NewTabCd(String),
    /// Open this path in place, on the host.
    HostOpen(String),
    /// Split the active terminal pane and aim the new pane at this path.
    SplitInjectPath {
        /// The path the new pane is aimed at.
        path: String,
        /// Whether the new pane takes the leading half — left, or top.
        leading: bool,
    },
}

/// Every zone, in the order the overlay lays them out — which is also the DRAW and HIT order
/// [`crate::drop_zone`] walks: the central column top-to-bottom, then the two edges.
///
/// One array rather than one per module. The hit test resolves overlaps by depth, not by position
/// in this list, but a second copy that drifted would still change which blob the overlay paints
/// over which.
pub(crate) const ZONES: [DropZone; 5] = [
    DropZone::NewTab,
    DropZone::InsertPath,
    DropZone::OpenInPlace,
    DropZone::SplitLeft,
    DropZone::SplitRight,
];

/// What a drop into `zone` does, or `None` for a cell with no meaning.
#[must_use]
pub fn resolve(zone: DropZone, content: Dropped<'_>) -> Option<DropAction> {
    // Text pastes into the focused terminal wherever it lands: both halves behave the same for a
    // snippet, so the zone never comes into it.
    if content.kind == DroppedKind::Text {
        return Some(DropAction::InjectText(content.value.to_owned()));
    }
    let path = content.value.to_owned();
    match (zone, content.kind) {
        (DropZone::NewTab, DroppedKind::Folder) => Some(DropAction::NewTabCd(path)),
        // Insert Path pastes whatever it is handed, a URL included, so it is read before the two
        // rules below that answer nothing.
        (DropZone::InsertPath, _) => Some(DropAction::InjectText(path)),
        // No "open as terminal" for a file, and no viewer or split for a URL: the local web pane is
        // retired, so a URL only ever pastes.
        (DropZone::NewTab, _) | (_, DroppedKind::Url) => None,
        (DropZone::OpenInPlace, _) => Some(DropAction::HostOpen(path)),
        (DropZone::SplitLeft, _) => Some(DropAction::SplitInjectPath { path, leading: true }),
        (DropZone::SplitRight, _) => Some(DropAction::SplitInjectPath { path, leading: false }),
    }
}

#[cfg(test)]
mod tests {
    use super::{DropAction, DropZone, Dropped, DroppedKind, ZONES, resolve};

    const fn dropped(kind: DroppedKind, value: &str) -> Dropped<'_> {
        Dropped { kind, value }
    }

    #[test]
    fn a_text_snippet_pastes_wherever_it_lands() {
        for zone in ZONES {
            assert_eq!(
                resolve(zone, dropped(DroppedKind::Text, "hello")),
                Some(DropAction::InjectText("hello".to_owned())),
                "both halves behave the same for a snippet"
            );
        }
    }

    #[test]
    fn only_a_folder_can_become_a_new_tab() {
        assert_eq!(
            resolve(DropZone::NewTab, dropped(DroppedKind::Folder, "/repo")),
            Some(DropAction::NewTabCd("/repo".to_owned()))
        );
        assert_eq!(
            resolve(DropZone::NewTab, dropped(DroppedKind::File, "/repo/a.txt")),
            None,
            "there is no open-as-terminal for a file"
        );
        assert_eq!(
            resolve(DropZone::NewTab, dropped(DroppedKind::Url, "https://x.dev")),
            None
        );
    }

    #[test]
    fn insert_path_pastes_anything_it_is_given() {
        for kind in [DroppedKind::Folder, DroppedKind::File, DroppedKind::Url] {
            assert_eq!(
                resolve(DropZone::InsertPath, dropped(kind, "value")),
                Some(DropAction::InjectText("value".to_owned()))
            );
        }
    }

    #[test]
    fn a_url_has_no_viewer_and_no_split() {
        let url = dropped(DroppedKind::Url, "https://x.dev");
        assert_eq!(resolve(DropZone::OpenInPlace, url), None);
        assert_eq!(resolve(DropZone::SplitLeft, url), None);
        assert_eq!(resolve(DropZone::SplitRight, url), None);
    }

    #[test]
    fn a_path_opens_on_the_host_and_splits_to_either_side() {
        let file = dropped(DroppedKind::File, "/repo/a.txt");
        assert_eq!(
            resolve(DropZone::OpenInPlace, file),
            Some(DropAction::HostOpen("/repo/a.txt".to_owned()))
        );
        assert_eq!(
            resolve(DropZone::SplitLeft, file),
            Some(DropAction::SplitInjectPath {
                path: "/repo/a.txt".to_owned(),
                leading: true,
            })
        );
        assert_eq!(
            resolve(DropZone::SplitRight, file),
            Some(DropAction::SplitInjectPath {
                path: "/repo/a.txt".to_owned(),
                leading: false,
            })
        );
    }

    #[test]
    fn a_zone_is_allowed_exactly_when_it_would_do_something() {
        // Asked the way the only caller asks it: `resolve` is the exported door, and the overlay
        // derives "allowed" by filtering it. A predicate beside `resolve` would be a second way to
        // ask one question, so the sugar that used to sit here is gone and the fact stays.
        let url = dropped(DroppedKind::Url, "https://x.dev");
        let allowed: Vec<DropZone> = ZONES
            .into_iter()
            .filter(|zone| resolve(*zone, url).is_some())
            .collect();
        assert_eq!(
            allowed,
            [DropZone::InsertPath],
            "a URL only ever pastes, so only one zone lights up"
        );
    }
}
