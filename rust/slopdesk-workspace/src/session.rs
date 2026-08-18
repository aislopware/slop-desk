//! What a pane IS, and the session → tab → pane values that hold them.
//!
//! A [`PaneSpec`] is pure INTENT: what the pane should be, never a handle to anything live. The
//! store reads it to materialize a session, and a rename mutates it without touching the tree —
//! which is the whole reason the spec lives in a side table rather than in the leaf. A tree diff
//! should mean the layout changed.
//!
//! ## What a spec deliberately does NOT carry
//!
//! The pane's live FACTS — its working directory, its project key, the title its shell last
//! asserted, the host session it resumes — are not here. They are per-pane state the workspace
//! document owns and the host pushes. The spec is exactly what can be rebuilt from the document,
//! and nothing more, so each fact has one home. The pane's resume identity is its own [`PaneId`]:
//! the client proposes the id, so the id the host keys its liveness by IS the id the layout uses.

use std::collections::{BTreeMap, BTreeSet};

use crate::identity::{PaneId, SessionId, TabId};
use crate::split_tree::SplitNode;

/// What a pane is.
///
/// A Claude session is NOT a distinct kind — it is a terminal whose foreground process the host
/// happens to recognise. A dedicated kind would have to be kept in sync with a heuristic, and the
/// pane would change identity when the heuristic changed its mind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum PaneKind {
    /// A remote PTY terminal.
    #[default]
    Terminal = 0,
    /// A whole host display, streamed over the media side-channel. It lives in its own OS window,
    /// never in the workspace tree.
    Desktop = 1,
}

/// The retired kinds an older file may still name.
///
/// Each folds to a terminal rather than trapping: the pane survives as a blank terminal and the
/// stream identity is dropped, which is what the no-backcompat rule asks for — tolerate the old
/// discriminator, keep none of its meaning. Anything ELSE unknown is genuine corruption and is
/// rejected, so the loader's reset path still has something to catch.
const RETIRED_KIND_RAW_VALUES: [&str; 5] = ["claudeCode", "web", "chooser", "remoteGUI", "systemDialog"];

impl PaneKind {
    /// Every kind, in wire order.
    pub const ALL: [Self; 2] = [Self::Terminal, Self::Desktop];

    /// The kind a byte names.
    ///
    /// Anything but `1` is a terminal — the safe default, since a pane that cannot stream still
    /// renders as a terminal, while the reverse would open a dead video pane.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        if byte == 1 { Self::Desktop } else { Self::Terminal }
    }

    /// The on-wire byte, and the byte a client's `ffiByte` must agree with.
    ///
    /// Spelled as a match rather than as `self as u8` so the map is one greppable claim per case:
    /// `scripts/check-supervisor.sh` compares it against Swift's switch, and an implicit
    /// discriminant is not something a gate can read.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        match self {
            Self::Terminal => 0,
            Self::Desktop => 1,
        }
    }

    /// The persisted discriminator — human-readable, so a workspace file can be read and edited.
    #[must_use]
    pub const fn raw(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Desktop => "desktop",
        }
    }

    /// The kind a persisted discriminator names, tolerating every retired value.
    ///
    /// `None` is genuine corruption, not an old file.
    #[must_use]
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "terminal" => Some(Self::Terminal),
            "desktop" => Some(Self::Desktop),
            other if RETIRED_KIND_RAW_VALUES.contains(&other) => Some(Self::Terminal),
            _ => None,
        }
    }

    /// Whether this pane rides the shared video flow and counts against the live-video cap.
    #[must_use]
    pub const fn is_video(self) -> bool {
        matches!(self, Self::Desktop)
    }

    /// Whether text can be typed into this pane — the recipient set for broadcast input.
    ///
    /// Only the PTY-backed terminal. A desktop pane takes input through the cursor and key
    /// side-channel, which is not a text funnel.
    #[must_use]
    pub const fn can_receive_text(self) -> bool {
        matches!(self, Self::Terminal)
    }
}

/// Which remote target a video pane streams.
///
/// The host and ports are NOT here — every video pane rides the one shared flow at the app-global
/// connection target. What varies per pane is only which display or window it names.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct VideoEndpoint {
    /// The host-side window being mirrored. Zero for a display target.
    pub window_id: u32,
    /// A readable target title, shown in the pane chrome before the stream is live.
    pub title: String,
    /// The owning app's name at capture time, for a window-shaped endpoint. Empty for a display.
    pub app_name: String,
    /// A whole host display, zero being the main one. Set, it wins over the window.
    pub display_id: Option<u32>,
}

impl VideoEndpoint {
    /// The stable TARGET identity latched modes are keyed by.
    ///
    /// A desktop pane keys by its display. A window-shaped endpoint keys by its owning APP, because
    /// window ids recycle across host restarts and the app is the identity that survives — falling
    /// back to the raw window id only when no app name is known.
    #[must_use]
    pub fn modes_key(&self) -> String {
        if let Some(display) = self.display_id {
            return format!("display:{display}");
        }
        if self.app_name.is_empty() {
            format!("window:{}", self.window_id)
        } else {
            format!("app:{}", self.app_name)
        }
    }
}

/// The latched modes of a video pane.
///
/// Device-local and keyed by the stream TARGET rather than by the pane, so closing a tab and
/// reopening the same target restores them — a reopened target mints a brand-new pane, and keying
/// by pane would lose the setting exactly when the person expected it to persist.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VideoPaneModes {
    /// Immersive system-key capture: the system chords go to the host.
    pub immersive: bool,
    /// Host app audio streamed into this pane.
    pub audio_enabled: bool,
    /// The viewport position lock — edge-hover auto-pan frozen.
    pub viewport_locked: bool,
    /// A live encode-rate cap. Zero is automatic.
    pub fps_cap: u32,
    /// A live bitrate ceiling. Zero is automatic.
    pub bitrate_ceiling_bps: u64,
}

impl VideoPaneModes {
    /// Whether every mode is at its default, in which case the spec stores nothing at all.
    #[must_use]
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

/// The full value description of a leaf.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneSpec {
    /// What the pane is.
    pub kind: PaneKind,
    /// Its display title.
    pub title: String,
    /// For a video pane, which host display or window it streams.
    pub video: Option<VideoEndpoint>,
    /// Whether the person EXPLICITLY renamed this pane.
    ///
    /// An explicit flag rather than a heuristic. Comparing the title against the live one misfires
    /// the moment a shell emits a second title: the stored title stays where it was while the live
    /// one advances, the comparison flips true, and a stale title latches as though it had been
    /// chosen on purpose. Only a real rename sets this.
    pub user_renamed: bool,
}

impl PaneSpec {
    /// A pane of a kind, with a title.
    #[must_use]
    pub fn new(kind: PaneKind, title: impl Into<String>) -> Self {
        Self {
            kind,
            title: title.into(),
            video: None,
            user_renamed: false,
        }
    }

    /// The display FOLDER NAME of a working directory: its last path component, the root as itself,
    /// a bare `~` kept as written.
    ///
    /// `None` for a blank input, so a caller falls back cleanly instead of showing an empty title.
    #[must_use]
    pub fn cwd_display_name(cwd: Option<&str>) -> Option<String> {
        let path = cwd?.trim();
        if path.is_empty() {
            return None;
        }
        let trimmed = strip_trailing_slashes(path);
        if trimmed == "/" {
            return Some("/".to_owned());
        }
        let leaf = trimmed.split('/').rfind(|part| !part.is_empty());
        Some(leaf.map_or_else(|| trimmed.to_owned(), str::to_owned))
    }

    /// The same directory as a BADGE reads it — the command palette's WORKING DIRECTORY pill and
    /// every other place that prints a whole path rather than its leaf:
    /// `/Users/abner/Workplace/myproject` → `~/Workplace/myproject/`.
    ///
    /// Two display-only transforms. A leading home prefix collapses to `~`, and a trailing `/` says
    /// the value is a DIRECTORY — the one thing a bare path does not say about itself.
    ///
    /// ⚠️ The home is matched by SHAPE — `/Users/<name>` or `/home/<name>` — and never by asking
    /// this machine where its own home is. The path arrives from the REMOTE host over the `cwd()`
    /// metadata RPC, so the client's `$HOME` is an answer to a different question. A root with no
    /// name segment after it (`/Users`, `/Users/`) is a directory that happens to be called Users,
    /// not somebody's home.
    ///
    /// Total: an empty path stays empty rather than becoming a bare `/`, the filesystem root stays
    /// `/`, and a path already rooted at `~` keeps it.
    #[must_use]
    pub fn cwd_badge_path(cwd: &str) -> String {
        if cwd.is_empty() {
            return String::new();
        }
        let collapsed = Self::tilde_collapsed(cwd);
        if collapsed.ends_with('/') {
            collapsed
        } else {
            collapsed + "/"
        }
    }

    /// Replaces a leading home prefix with `~`, or returns the path as written.
    fn tilde_collapsed(path: &str) -> String {
        if path == "~" || path.starts_with("~/") {
            return path.to_owned();
        }
        for root in ["/Users/", "/home/"] {
            let Some(after_root) = path.strip_prefix(root) else {
                continue;
            };
            // The first segment after the root is the user NAME, and the home boundary is the end
            // of it. Nothing there, or another slash, means the root itself was the whole path.
            if after_root.is_empty() || after_root.starts_with('/') {
                return path.to_owned();
            }
            return match after_root.split_once('/') {
                Some((_, below)) => format!("~/{below}"),
                None => "~".to_owned(),
            };
        }
        path.to_owned()
    }

    /// Whether a path is almost certainly a plugin manager's TRANSIENT cache directory rather than
    /// somewhere a person navigated to.
    ///
    /// Without an OSC-7 hook a pane's directory comes only from asking the kernel what the shell's
    /// working directory is — which observes every internal `chdir` the shell makes, including a
    /// plugin manager stepping into a cache directory to source it. Race that and the pane's
    /// directory becomes a plugin's, so a later split or relaunch spawns its shell THERE.
    ///
    /// The signature is a path component of the form `owner---repo`, the flattening zinit uses. A
    /// triple dash is vanishingly unlikely in a real project path, so the drop is tight.
    #[must_use]
    pub fn looks_like_transient_plugin_cwd(path: &str) -> bool {
        path.split('/').any(|component| component.contains("---"))
    }
}

fn strip_trailing_slashes(path: &str) -> &str {
    let mut trimmed = path;
    while trimmed.len() > 1 && trimmed.ends_with('/') {
        trimmed = trimmed.get(..trimmed.len() - 1).unwrap_or(trimmed);
    }
    trimmed
}

/// One tiled split tree within a session.
#[derive(Debug, Clone, PartialEq)]
pub struct Tab {
    /// Its identity.
    pub id: TabId,
    /// Its title. Empty means "derive it from the active pane's live title at render time".
    pub title: String,
    /// The tiled tree. Never empty for a live tab — a tab with no panes is a tab that gets closed.
    pub root: SplitNode,
    /// The focused leaf, or `None` when none is resolved yet.
    pub active_pane: Option<PaneId>,
    /// The OUT-OF-TREE zoom.
    ///
    /// Render-only: the tree is untouched and every sibling stays mounted but invisible, which is
    /// what makes zooming in and out free rather than a teardown and remount of everything else.
    pub zoomed_pane: Option<PaneId>,
}

impl Tab {
    /// A tab around a tree.
    #[must_use]
    pub fn new(id: TabId, root: SplitNode) -> Self {
        let active_pane = root.first_leaf_id();
        Self {
            id,
            title: String::new(),
            root,
            active_pane,
            zoomed_pane: None,
        }
    }

    /// Every pane in this tab, in pre-order.
    #[must_use]
    pub fn all_pane_ids(&self) -> Vec<PaneId> {
        self.root.all_pane_ids()
    }

    /// Whether a pane is a leaf in this tab.
    #[must_use]
    pub fn contains(&self, id: PaneId) -> bool {
        self.root.contains(id)
    }
}

/// A pane the person pulled out into its own OS window.
///
/// It has left every tab's tree but is still a first-class member of its session: its spec stays in
/// the side table and its live handle stays registered, so the process survives the move and only
/// the VIEW remounts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DetachedPane {
    /// The detached pane, which is also its spec and registry key.
    pub pane: PaneId,
    /// The tab it detached from — the preferred place to put it back. `None`, or a tab that has
    /// since closed, falls back to the active tab.
    pub origin_tab: Option<TabId>,
}

/// A named group of tabs: the top of the hierarchy.
///
/// It carries NO host association. Which host a client talks to is device-local, so the committed
/// connection target lives in the device's own preferences rather than in a document that syncs.
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    /// Its identity.
    pub id: SessionId,
    /// Its name.
    pub name: String,
    /// Its tabs, in tab-bar order. At least one for a live session.
    pub tabs: Vec<Tab>,
    /// The selected tab, clamped to the tabs by the normalizer and by every op.
    pub active_tab_index: usize,
    /// Each pane's spec, tree leaf or detached alike.
    ///
    /// The invariant is that its keys are exactly the leaves plus the detached panes. Ordered by
    /// id, so persisting it is byte-stable: a hash-ordered map would rewrite the file on every
    /// save and make its diffs unreadable.
    pub specs: BTreeMap<PaneId, PaneSpec>,
    /// Panes detached into their own windows, in detach order.
    pub detached: Vec<DetachedPane>,
}

impl Session {
    /// A fresh single-tab, single-pane session.
    ///
    /// The ids are supplied rather than minted, for the reason [`crate::identity`] gives.
    #[must_use]
    pub fn single_pane(
        id: SessionId,
        name: impl Into<String>,
        tab: TabId,
        pane: PaneId,
        spec: PaneSpec,
    ) -> Self {
        let mut specs = BTreeMap::new();
        specs.insert(pane, spec);
        Self {
            id,
            name: name.into(),
            tabs: vec![Tab::new(tab, SplitNode::Leaf(pane))],
            active_tab_index: 0,
            specs,
            detached: Vec::new(),
        }
    }

    /// Every pane across every tab, in tab order then pre-order.
    #[must_use]
    pub fn all_pane_ids(&self) -> Vec<PaneId> {
        self.tabs.iter().flat_map(Tab::all_pane_ids).collect()
    }

    /// The leaves of every tab, as a set.
    #[must_use]
    pub fn leaf_id_set(&self) -> BTreeSet<PaneId> {
        self.all_pane_ids().into_iter().collect()
    }

    /// The panes detached into their own windows, as a set.
    #[must_use]
    pub fn detached_id_set(&self) -> BTreeSet<PaneId> {
        self.detached.iter().map(|entry| entry.pane).collect()
    }

    /// Whether a pane is detached into its own window here.
    #[must_use]
    pub fn is_detached(&self, id: PaneId) -> bool {
        self.detached.iter().any(|entry| entry.pane == id)
    }

    /// Whether a pane is a leaf anywhere in this session.
    #[must_use]
    pub fn contains(&self, id: PaneId) -> bool {
        self.tabs.iter().any(|tab| tab.contains(id))
    }

    /// A pane's spec — tree leaf or detached, both being members of the side table.
    ///
    /// `None` when this session does not own the pane, which is a different answer from "owns it
    /// and has no spec" and is why the membership is checked first.
    #[must_use]
    pub fn spec_for(&self, id: PaneId) -> Option<&PaneSpec> {
        (self.contains(id) || self.is_detached(id))
            .then(|| self.specs.get(&id))
            .flatten()
    }

    /// The selected tab, falling back to the first when the index has gone stale.
    #[must_use]
    pub fn active_tab(&self) -> Option<&Tab> {
        self.tabs.get(self.active_tab_index).or_else(|| self.tabs.first())
    }

    /// The index of the tab whose tree holds a pane.
    #[must_use]
    pub fn tab_index_containing(&self, id: PaneId) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.contains(id))
    }

    /// Where a new tab lands under a policy, for THIS session's tab list.
    #[must_use]
    pub const fn new_tab_index(&self, position: NewTabPosition) -> usize {
        position.insertion_index(self.active_tab_index, self.tabs.len())
    }
}

/// Where a newly opened tab is inserted into the tab bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum NewTabPosition {
    /// Context-aware, and the default. With no surrounding window context to consult, appending is
    /// the sane answer — so this is byte-identical to [`End`](Self::End) until there is one.
    #[default]
    Auto = 0,
    /// Always at the end.
    End = 1,
    /// Immediately after the active tab. Its config spelling is `after-current`.
    AfterCurrent = 2,
}

impl NewTabPosition {
    /// Every value, for a settings row that enumerates them.
    pub const ALL: [Self; 3] = [Self::Auto, Self::End, Self::AfterCurrent];

    /// The position a byte names.
    ///
    /// An unknown byte from a newer client is [`Auto`](Self::Auto) — whatever the person's own
    /// preference resolves to, which is the least surprising place for a tab to land. Total, so a
    /// gesture is never dropped over a byte nobody has to interpret.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::End,
            2 => Self::AfterCurrent,
            _ => Self::Auto,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The config spelling.
    #[must_use]
    pub const fn raw(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::End => "end",
            Self::AfterCurrent => "after-current",
        }
    }

    /// The policy a config string names, or `None` when it names nothing.
    #[must_use]
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|position| position.raw() == raw)
    }

    /// Where to insert into a list of `tab_count` tabs whose active one sits at `active_index`.
    ///
    /// Always a VALID insertion index — at most the count. A stale active index, which a restore or
    /// a race can easily produce, is clamped rather than trusted: an out-of-range insert would be a
    /// panic in the caller, and landing the tab at the end is a far better answer than that.
    #[must_use]
    pub const fn insertion_index(self, active_index: usize, tab_count: usize) -> usize {
        match self {
            Self::Auto | Self::End => tab_count,
            Self::AfterCurrent => {
                if tab_count == 0 {
                    return 0;
                }
                let clamped = if active_index < tab_count {
                    active_index
                } else {
                    tab_count - 1
                };
                clamped + 1
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DetachedPane, NewTabPosition, PaneKind, PaneSpec, Session, Tab, VideoEndpoint, VideoPaneModes,
    };
    use crate::identity::{PaneId, SessionId, SplitNodeId, TabId};
    use crate::split_tree::{SplitAxis, SplitNode, WeightedChild};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn tab_id(byte: u8) -> TabId {
        TabId::from_bytes([byte; 16])
    }

    fn spec() -> PaneSpec {
        PaneSpec::new(PaneKind::Terminal, "shell")
    }

    fn session() -> Session {
        Session::single_pane(SessionId::from_bytes([0; 16]), "work", tab_id(1), pane(1), spec())
    }

    #[test]
    fn every_retired_kind_folds_to_a_terminal_rather_than_trapping() {
        for raw in ["claudeCode", "web", "chooser", "remoteGUI", "systemDialog"] {
            assert_eq!(
                PaneKind::from_raw(raw),
                Some(PaneKind::Terminal),
                "{raw} must not trap"
            );
        }
    }

    #[test]
    fn a_genuinely_unknown_kind_is_still_corruption() {
        assert!(PaneKind::from_raw("hologram").is_none());
    }

    #[test]
    fn a_kind_round_trips_through_its_persisted_form() {
        for kind in [PaneKind::Terminal, PaneKind::Desktop] {
            assert_eq!(PaneKind::from_raw(kind.raw()), Some(kind));
        }
    }

    #[test]
    fn only_a_terminal_takes_typed_text_and_only_a_desktop_is_video() {
        assert!(PaneKind::Terminal.can_receive_text() && !PaneKind::Terminal.is_video());
        assert!(PaneKind::Desktop.is_video() && !PaneKind::Desktop.can_receive_text());
    }

    #[test]
    fn a_display_endpoint_keys_by_its_display() {
        let endpoint = VideoEndpoint {
            display_id: Some(0),
            window_id: 42,
            app_name: "Finder".to_owned(),
            title: String::new(),
        };
        assert_eq!(
            endpoint.modes_key(),
            "display:0",
            "the display wins over the window"
        );
    }

    #[test]
    fn a_window_endpoint_keys_by_its_app_because_window_ids_recycle() {
        let endpoint = VideoEndpoint {
            window_id: 42,
            app_name: "Finder".to_owned(),
            ..VideoEndpoint::default()
        };
        assert_eq!(endpoint.modes_key(), "app:Finder");
        let anonymous = VideoEndpoint {
            window_id: 42,
            ..VideoEndpoint::default()
        };
        assert_eq!(
            anonymous.modes_key(),
            "window:42",
            "the raw id is the last resort"
        );
    }

    #[test]
    fn default_modes_are_stored_as_nothing_at_all() {
        assert!(VideoPaneModes::default().is_default());
        assert!(
            !VideoPaneModes {
                immersive: true,
                ..VideoPaneModes::default()
            }
            .is_default()
        );
    }

    #[test]
    fn a_directorys_display_name_is_its_last_component() {
        assert_eq!(
            PaneSpec::cwd_display_name(Some("/a/b/repo")).as_deref(),
            Some("repo")
        );
        assert_eq!(
            PaneSpec::cwd_display_name(Some("/a/b/repo/")).as_deref(),
            Some("repo")
        );
        assert_eq!(PaneSpec::cwd_display_name(Some("/")).as_deref(), Some("/"));
        assert_eq!(PaneSpec::cwd_display_name(Some("~")).as_deref(), Some("~"));
    }

    #[test]
    fn a_blank_directory_has_no_display_name_rather_than_an_empty_one() {
        assert!(PaneSpec::cwd_display_name(None).is_none());
        assert!(PaneSpec::cwd_display_name(Some("   ")).is_none());
    }

    #[test]
    fn a_badge_collapses_either_platforms_home_and_marks_the_directory() {
        assert_eq!(
            PaneSpec::cwd_badge_path("/Users/abner/Workplace/myproject"),
            "~/Workplace/myproject/"
        );
        assert_eq!(PaneSpec::cwd_badge_path("/home/abner/src/proj"), "~/src/proj/");
    }

    #[test]
    fn the_home_directory_itself_is_the_whole_badge() {
        assert_eq!(PaneSpec::cwd_badge_path("/Users/abner"), "~/");
        assert_eq!(PaneSpec::cwd_badge_path("/home/abner"), "~/");
        assert_eq!(PaneSpec::cwd_badge_path("/Users/abner/"), "~/");
    }

    #[test]
    fn a_home_root_without_a_name_under_it_is_an_ordinary_directory() {
        assert_eq!(PaneSpec::cwd_badge_path("/Users"), "/Users/");
        assert_eq!(PaneSpec::cwd_badge_path("/home"), "/home/");
        assert_eq!(PaneSpec::cwd_badge_path("/Users/"), "/Users/");
    }

    #[test]
    fn a_name_that_merely_starts_with_the_users_name_is_not_that_user() {
        assert_eq!(PaneSpec::cwd_badge_path("/Users/abnerson/code"), "~/code/");
    }

    #[test]
    fn a_path_outside_any_home_keeps_itself_and_gains_the_marker() {
        assert_eq!(PaneSpec::cwd_badge_path("/etc"), "/etc/");
        assert_eq!(PaneSpec::cwd_badge_path("/var/log/system"), "/var/log/system/");
        assert_eq!(PaneSpec::cwd_badge_path("/etc/"), "/etc/");
    }

    #[test]
    fn the_two_paths_that_are_already_their_own_badge() {
        assert_eq!(PaneSpec::cwd_badge_path(""), "", "nothing stays nothing");
        assert_eq!(PaneSpec::cwd_badge_path("/"), "/", "the root is its own leaf");
        assert_eq!(PaneSpec::cwd_badge_path("~"), "~/");
        assert_eq!(
            PaneSpec::cwd_badge_path("~/Workplace/myproject"),
            "~/Workplace/myproject/"
        );
    }

    #[test]
    fn a_plugin_cache_directory_is_recognised_wherever_it_sits_in_the_path() {
        assert!(PaneSpec::looks_like_transient_plugin_cwd(
            "/home/me/.zinit/plugins/zsh-users---zsh-autosuggestions"
        ));
        assert!(!PaneSpec::looks_like_transient_plugin_cwd("/work/alpha"));
        assert!(
            !PaneSpec::looks_like_transient_plugin_cwd("/work/my-project"),
            "a single dash is an ordinary name",
        );
    }

    #[test]
    fn a_fresh_session_holds_its_invariant_at_birth() {
        let session = session();
        assert_eq!(session.leaf_id_set().len(), 1);
        assert_eq!(session.specs.len(), 1, "the specs are exactly the leaves");
        assert!(session.contains(pane(1)));
        assert_eq!(session.spec_for(pane(1)), Some(&spec()));
    }

    #[test]
    fn a_pane_this_session_does_not_own_has_no_spec_here() {
        assert!(session().spec_for(pane(9)).is_none());
    }

    #[test]
    fn a_detached_pane_stays_a_member_of_its_session() {
        let mut session = session();
        session.detached.push(DetachedPane {
            pane: pane(2),
            origin_tab: Some(tab_id(1)),
        });
        session.specs.insert(pane(2), spec());
        assert!(session.is_detached(pane(2)));
        assert!(!session.contains(pane(2)), "it has left every tree");
        assert_eq!(session.spec_for(pane(2)), Some(&spec()), "but keeps its spec");
        assert_eq!(session.detached_id_set().len(), 1);
    }

    #[test]
    fn a_stale_active_index_falls_back_to_the_first_tab() {
        let mut session = session();
        session.active_tab_index = 7;
        assert_eq!(session.active_tab().map(|tab| tab.id), Some(tab_id(1)));
    }

    #[test]
    fn a_tab_takes_its_first_leaf_as_the_focus() {
        let tree = SplitNode::Split {
            id: SplitNodeId::from_bytes([1; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![WeightedChild::leaf(pane(3)), WeightedChild::leaf(pane(4))],
        };
        let tab = Tab::new(tab_id(2), tree);
        assert_eq!(tab.active_pane, Some(pane(3)));
        assert_eq!(tab.all_pane_ids(), vec![pane(3), pane(4)]);
    }

    #[test]
    fn the_panes_of_a_session_read_in_tab_order_then_tree_order() {
        let mut session = session();
        session.tabs.push(Tab::new(tab_id(2), SplitNode::Leaf(pane(5))));
        assert_eq!(session.all_pane_ids(), vec![pane(1), pane(5)]);
        assert_eq!(session.tab_index_containing(pane(5)), Some(1));
        assert!(session.tab_index_containing(pane(9)).is_none());
    }

    #[test]
    fn the_default_policy_appends() {
        assert_eq!(NewTabPosition::default(), NewTabPosition::Auto);
        assert_eq!(NewTabPosition::Auto.insertion_index(0, 3), 3);
        assert_eq!(NewTabPosition::End.insertion_index(0, 3), 3);
    }

    #[test]
    fn after_current_lands_next_to_the_active_tab() {
        assert_eq!(NewTabPosition::AfterCurrent.insertion_index(0, 3), 1);
        assert_eq!(NewTabPosition::AfterCurrent.insertion_index(2, 3), 3);
    }

    #[test]
    fn a_stale_active_index_still_yields_a_valid_insertion_index() {
        assert_eq!(
            NewTabPosition::AfterCurrent.insertion_index(99, 3),
            3,
            "an out-of-range insert would panic in the caller; the end is a better answer",
        );
        assert_eq!(NewTabPosition::AfterCurrent.insertion_index(0, 0), 0);
    }

    #[test]
    fn the_config_spellings_round_trip() {
        for position in NewTabPosition::ALL {
            assert_eq!(NewTabPosition::from_raw(position.raw()), Some(position));
        }
        assert_eq!(NewTabPosition::from_raw("afterCurrent"), None);
    }

    #[test]
    fn a_session_reads_the_policy_against_its_own_tab_list() {
        let session = session();
        assert_eq!(session.new_tab_index(NewTabPosition::AfterCurrent), 1);
        assert_eq!(session.new_tab_index(NewTabPosition::End), 1);
    }
}
