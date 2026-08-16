//! The two things that SPAWN panes: a launch preset and a session template.
//!
//! A [`LaunchPreset`] is one command and the one or two panes it opens into the current session. A
//! [`SessionTemplate`] is a whole named session — an n-ary layout whose every leaf carries its own
//! working directory and startup command. Neither is a [`crate::canvas::LayoutPreset`], which
//! restores geometry that already exists rather than creating anything.
//!
//! ## The expansion is pure
//!
//! Applying either produces a plan — the pane specs, and the exact bytes to type into each once its
//! PTY is live. Nothing here opens a socket or spawns a process, so the whole expansion is testable
//! against its bytes.
//!
//! ## A path is not shell input
//!
//! The `cd` line a plan emits is built from LITERAL bytes and never goes through
//! [`crate::send_keys`]. A working directory is a filesystem path, and running one through the
//! token parser would let `<Enter>` inside it inject a real newline: the quoted `cd` line would end
//! early and the rest of the path would run as its own command. Quoting does not help — it escapes
//! quotes, not tokens. Only the COMMAND field, which is shell input by intent, goes through the
//! parser.

use crate::identity::{LaunchPresetId, SessionTemplateId};
use crate::send_keys;
use crate::session::{PaneKind, PaneSpec};
use crate::split_tree::{MAX_DEPTH, SplitAxis};

/// The optional second pane of a two-pane launch preset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitConfig {
    /// Which way the first pane splits to make room.
    pub axis: SplitAxis,
    /// What runs in the second pane. Empty is a plain shell beside the first.
    pub secondary_command: String,
}

impl SplitConfig {
    /// A second pane along an axis.
    #[must_use]
    pub const fn new(axis: SplitAxis, secondary_command: String) -> Self {
        Self {
            axis,
            secondary_command,
        }
    }
}

/// A named launch configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPreset {
    /// Its identity.
    pub id: LaunchPresetId,
    /// The menu label.
    pub name: String,
    /// What runs in the first pane. Empty opens a plain shell.
    pub command: String,
    /// Where the shell starts. `None` or empty is the shell's own default.
    pub working_directory: Option<String>,
    /// A second pane, or `None` for a single-pane preset.
    pub split: Option<SplitConfig>,
    /// The symbol on the menu row.
    pub symbol: String,
    /// Whether this is one of the shipped defaults rather than something a person made.
    pub is_built_in: bool,
}

impl LaunchPreset {
    /// A preset that runs a command in one pane.
    #[must_use]
    pub fn new(id: LaunchPresetId, name: impl Into<String>, command: impl Into<String>) -> Self {
        Self {
            id,
            name: name.into(),
            command: command.into(),
            working_directory: None,
            split: None,
            symbol: "terminal".to_owned(),
            is_built_in: false,
        }
    }

    /// The same preset under a symbol, marked as shipped.
    #[must_use]
    fn built_in(mut self, symbol: &str) -> Self {
        symbol.clone_into(&mut self.symbol);
        self.is_built_in = true;
        self
    }
}

/// The identity of the n-th shipped launch preset.
///
/// FIXED rather than minted, so re-seeding a workspace or resetting the settings matches the
/// existing row instead of appending a second copy of it. The bytes are a version-4 UUID by shape,
/// with the ordinal in the last byte.
const fn built_in_launch_id(ordinal: u8) -> LaunchPresetId {
    LaunchPresetId::from_bytes([
        0x11, 0x11, 0x11, 0x11, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, ordinal,
    ])
}

/// The identity of the n-th shipped session template, fixed for the same reason.
const fn built_in_template_id(ordinal: u8) -> SessionTemplateId {
    SessionTemplateId::from_bytes([
        0x22, 0x22, 0x22, 0x22, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, ordinal,
    ])
}

/// The launch presets a fresh workspace ships with.
#[must_use]
pub fn built_in_launch_presets() -> Vec<LaunchPreset> {
    vec![
        LaunchPreset::new(built_in_launch_id(1), "Claude Code", "claude").built_in("sparkles"),
        LaunchPreset::new(built_in_launch_id(2), "htop", "htop").built_in("chart.bar.xaxis"),
        LaunchPreset::new(
            built_in_launch_id(3),
            "Git log",
            "git log --oneline --graph --decorate -30",
        )
        .built_in("arrow.triangle.branch"),
    ]
}

/// One pane a preset opens, with the bytes to type into it once it is live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneLaunch {
    /// What the pane is.
    pub spec: PaneSpec,
    /// Where the preset asks the shell to START.
    ///
    /// It rides the channel open, so the host spawns the PTY there directly and there is no visible
    /// startup `cd` for the person to watch scroll past.
    pub spawn_cwd: Option<String>,
    /// The bytes to send once the pane's transport is live, or empty for a plain shell.
    pub keystrokes: Vec<u8>,
}

/// The full plan for applying a launch preset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    /// The panes to create, in order.
    pub panes: Vec<PaneLaunch>,
    /// The axis the first pane splits along to host the second, or `None` for a single-pane preset.
    pub split_axis: Option<SplitAxis>,
}

/// The plan a preset expands into.
///
/// Every pane takes the preset's NAME as its title, so the chrome reads "Claude Code" rather than
/// the command, and the second pane of a split inherits the working directory — a split beside a
/// pane starts where that pane started.
#[must_use]
pub fn plan(preset: &LaunchPreset) -> LaunchPlan {
    let primary = PaneLaunch {
        spec: PaneSpec::new(PaneKind::Terminal, preset.name.clone()),
        spawn_cwd: preset.working_directory.clone(),
        keystrokes: keystrokes(&preset.command, None),
    };
    let Some(split) = preset.split.as_ref() else {
        return LaunchPlan {
            panes: vec![primary],
            split_axis: None,
        };
    };
    let secondary = PaneLaunch {
        spec: PaneSpec::new(PaneKind::Terminal, preset.name.clone()),
        spawn_cwd: preset.working_directory.clone(),
        keystrokes: keystrokes(&split.secondary_command, None),
    };
    LaunchPlan {
        panes: vec![primary, secondary],
        split_axis: Some(split.axis),
    }
}

/// The bytes to type into a freshly spawned pane: a `cd` line when a directory is set, then the
/// command.
///
/// An empty command with no directory sends NOTHING, which is what makes a preset able to open a
/// plain shell.
#[must_use]
pub fn keystrokes(command: &str, cwd: Option<&str>) -> Vec<u8> {
    let mut out = Vec::new();
    if let Some(path) = cwd.filter(|path| !path.is_empty()) {
        // The whole line is literal UTF-8 — see the module's note on why a path must never reach the
        // token parser. The quoting is only so a directory with spaces survives.
        out.extend_from_slice(format!("cd {}", crate::shell_quoting::single_quoted(path)).as_bytes());
        out.push(0x0A);
    }
    if !command.trim().is_empty() {
        out.extend_from_slice(&send_keys::encode(command));
        out.push(0x0A);
    }
    out
}

/// One leaf of a session template: what the pane is, and how it starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplatePane {
    /// What the pane is.
    pub kind: PaneKind,
    /// Its display title.
    pub title: String,
    /// Where its shell starts.
    pub cwd: Option<String>,
    /// What it runs once its PTY is live.
    pub command: Option<String>,
}

impl TemplatePane {
    /// A terminal leaf under a title.
    #[must_use]
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            kind: PaneKind::Terminal,
            title: title.into(),
            cwd: None,
            command: None,
        }
    }

    /// The same leaf running a command.
    #[must_use]
    pub fn running(mut self, command: impl Into<String>) -> Self {
        self.command = Some(command.into());
        self
    }

    /// The bytes this leaf types into its pane once the PTY is live.
    #[must_use]
    pub fn keystrokes(&self) -> Vec<u8> {
        keystrokes(self.command.as_deref().unwrap_or_default(), None)
    }
}

/// The title a repaired template falls back to.
///
/// A template must expand to at least one pane, so a node with nothing left in it becomes a plain
/// terminal rather than nothing at all.
pub const FALLBACK_PANE_TITLE: &str = "Terminal";

/// The recursive, n-ary layout a session template expands into.
///
/// It mirrors [`crate::split_tree::SplitNode`] but carries each pane's launch intent instead of an
/// id, and it has no weights at all: a template describes STRUCTURE, and pinning exact divider
/// positions into it would make every restore fight whatever the person had since dragged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateNode {
    /// One pane.
    Pane(TemplatePane),
    /// A partition among children.
    Split {
        /// Which way it partitions.
        axis: SplitAxis,
        /// Its children, in visual order.
        children: Vec<Self>,
    },
}

impl TemplateNode {
    /// A split of these children.
    #[must_use]
    pub const fn split(axis: SplitAxis, children: Vec<Self>) -> Self {
        Self::Split { axis, children }
    }

    /// How many leaves the layout expands into.
    #[must_use]
    pub fn pane_count(&self) -> usize {
        match self {
            Self::Pane(_) => 1,
            Self::Split { children, .. } => children.iter().map(Self::pane_count).sum(),
        }
    }

    /// The nesting depth. A lone pane is one.
    #[must_use]
    pub fn depth(&self) -> usize {
        match self {
            Self::Pane(_) => 1,
            Self::Split { children, .. } => 1 + children.iter().map(Self::depth).max().unwrap_or(0),
        }
    }

    /// The first leaf in depth-first order.
    #[must_use]
    pub fn first_pane(&self) -> TemplatePane {
        match self {
            Self::Pane(pane) => pane.clone(),
            Self::Split { children, .. } => {
                children
                    .first()
                    .map_or_else(|| TemplatePane::new(FALLBACK_PANE_TITLE), Self::first_pane)
            },
        }
    }

    /// The layout with every invariant re-established: repaired, never rejected.
    ///
    /// A persisted template is untrusted, so a degenerate one decodes to a SOUND layout rather than
    /// trapping. A split with one child collapses into it, a childless split becomes a plain
    /// terminal, and anything nested past [`MAX_DEPTH`] collapses to its first pane — which is what
    /// keeps the tree the template later builds inside the tree's own depth bound.
    #[must_use]
    pub fn repaired(&self) -> Self {
        let repaired = match self {
            Self::Pane(pane) => Self::Pane(pane.clone()),
            Self::Split { axis, children } => {
                let children: Vec<Self> = children.iter().map(Self::repaired).collect();
                match children.len() {
                    0 => Self::Pane(TemplatePane::new(FALLBACK_PANE_TITLE)),
                    1 => {
                        children.into_iter().next().unwrap_or_else(|| {
                            // Unreachable: the arm matched a length of exactly one. Written as a
                            // fallback rather than an unwrap because the crate's lint table denies
                            // panicking, and a plain terminal is a sound answer either way.
                            Self::Pane(TemplatePane::new(FALLBACK_PANE_TITLE))
                        })
                    },
                    _ => {
                        Self::Split {
                            axis: *axis,
                            children,
                        }
                    },
                }
            },
        };
        if repaired.depth() > MAX_DEPTH {
            return Self::Pane(repaired.first_pane());
        }
        repaired
    }
}

/// A named project profile: a whole session's layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTemplate {
    /// Its identity.
    pub id: SessionTemplateId,
    /// The menu label.
    pub name: String,
    /// The symbol on the menu row.
    pub symbol: String,
    /// Whether this is one of the shipped defaults.
    pub is_built_in: bool,
    /// The layout it expands into.
    pub layout: TemplateNode,
}

impl SessionTemplate {
    /// A template over a layout.
    #[must_use]
    pub fn new(id: SessionTemplateId, name: impl Into<String>, layout: TemplateNode) -> Self {
        Self {
            id,
            name: name.into(),
            symbol: "rectangle.split.2x1".to_owned(),
            is_built_in: false,
            layout,
        }
    }

    /// The same template under a symbol, marked as shipped.
    #[must_use]
    fn built_in(mut self, symbol: &str) -> Self {
        symbol.clone_into(&mut self.symbol);
        self.is_built_in = true;
        self
    }
}

/// The session templates a fresh workspace ships with.
#[must_use]
pub fn built_in_session_templates() -> Vec<SessionTemplate> {
    vec![
        SessionTemplate::new(
            built_in_template_id(1),
            "Editor + Terminal",
            TemplateNode::split(SplitAxis::Horizontal, vec![
                TemplateNode::Pane(TemplatePane::new("Editor")),
                TemplateNode::Pane(TemplatePane::new("Terminal")),
            ]),
        )
        .built_in("rectangle.split.2x1"),
        SessionTemplate::new(
            built_in_template_id(2),
            "Editor · Server · Git",
            TemplateNode::split(SplitAxis::Horizontal, vec![
                TemplateNode::Pane(TemplatePane::new("Editor")),
                TemplateNode::split(SplitAxis::Vertical, vec![
                    TemplateNode::Pane(TemplatePane::new("Server")),
                    TemplateNode::Pane(TemplatePane::new("Git").running("git status")),
                ]),
            ]),
        )
        .built_in("rectangle.split.3x1"),
        SessionTemplate::new(
            built_in_template_id(3),
            "Claude + Terminal",
            TemplateNode::split(SplitAxis::Horizontal, vec![
                TemplateNode::Pane(TemplatePane::new("Claude").running("claude")),
                TemplateNode::Pane(TemplatePane::new("Terminal")),
            ]),
        )
        .built_in("sparkles"),
    ]
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing plan entry is a test failure with nothing to return"
    )]

    use std::collections::BTreeSet;

    use super::{
        FALLBACK_PANE_TITLE, LaunchPreset, SplitConfig, TemplateNode, TemplatePane, built_in_launch_presets,
        built_in_session_templates, keystrokes, plan,
    };
    use crate::identity::LaunchPresetId;
    use crate::split_tree::{MAX_DEPTH, SplitAxis};

    fn preset() -> LaunchPreset {
        LaunchPreset::new(LaunchPresetId::from_bytes([7; 16]), "Git log", "git log")
    }

    #[test]
    fn a_plain_preset_opens_one_pane_and_types_its_command() {
        let expanded = plan(&preset());
        assert_eq!(expanded.split_axis, None);
        assert_eq!(expanded.panes.len(), 1);
        let Some(pane) = expanded.panes.first() else {
            panic!("a preset always plans at least one pane");
        };
        assert_eq!(pane.keystrokes, b"git log\n".to_vec());
        assert_eq!(
            pane.spec.title, "Git log",
            "the pane is labelled by the preset, not the command"
        );
    }

    #[test]
    fn a_two_pane_preset_carries_the_axis_and_the_shared_directory() {
        let mut two = preset();
        two.working_directory = Some("/tmp/work".to_owned());
        two.split = Some(SplitConfig::new(SplitAxis::Vertical, "watch ls".to_owned()));
        let expanded = plan(&two);
        assert_eq!(expanded.split_axis, Some(SplitAxis::Vertical));
        assert_eq!(expanded.panes.len(), 2);
        for pane in &expanded.panes {
            assert_eq!(
                pane.spawn_cwd.as_deref(),
                Some("/tmp/work"),
                "a split inherits the directory it was opened beside",
            );
        }
    }

    #[test]
    fn an_empty_command_and_no_directory_sends_nothing() {
        assert!(keystrokes("", None).is_empty());
        assert!(keystrokes("   ", None).is_empty(), "whitespace is not a command");
    }

    #[test]
    fn a_directory_becomes_a_quoted_cd_line_before_the_command() {
        assert_eq!(
            keystrokes("ls", Some("/tmp/my work")),
            b"cd '/tmp/my work'\nls\n".to_vec(),
        );
    }

    #[test]
    fn a_quote_in_the_path_is_escaped_the_posix_way() {
        assert_eq!(
            keystrokes("", Some("/tmp/it's")),
            b"cd '/tmp/it'\\''s'\n".to_vec(),
        );
    }

    #[test]
    fn a_token_in_a_path_can_never_break_out_of_the_cd_line() {
        let hostile = "/tmp/proj<Enter>rm -rf x";
        let bytes = keystrokes("", Some(hostile));
        assert_eq!(
            bytes
                .iter()
                .filter(|byte| **byte == 0x0A || **byte == 0x0D)
                .count(),
            1,
            "the only newline is the one ending the cd line",
        );
        assert!(
            String::from_utf8_lossy(&bytes).contains("<Enter>"),
            "the marker stays literal text inside the quoted path",
        );
    }

    #[test]
    fn a_token_in_a_command_still_resolves() {
        assert_eq!(keystrokes("make<Space>test", None), b"make test\n".to_vec());
    }

    #[test]
    fn the_built_in_ids_are_stable_and_distinct() {
        let presets = built_in_launch_presets();
        let ids: BTreeSet<_> = presets.iter().map(|preset| preset.id).collect();
        assert_eq!(
            ids.len(),
            presets.len(),
            "a re-seed must match a row, not append one"
        );
        assert_eq!(
            built_in_launch_presets(),
            presets,
            "the ids are fixed, not minted"
        );
        let templates = built_in_session_templates();
        let template_ids: BTreeSet<_> = templates.iter().map(|template| template.id).collect();
        assert_eq!(template_ids.len(), templates.len());
        assert!(presets.iter().all(|preset| preset.is_built_in));
        assert!(templates.iter().all(|template| template.is_built_in));
    }

    #[test]
    fn a_built_in_template_expands_into_the_panes_it_names() {
        let templates = built_in_session_templates();
        let Some(three) = templates.get(1) else {
            panic!("three templates ship");
        };
        assert_eq!(three.layout.pane_count(), 3);
        assert_eq!(three.layout.depth(), 3);
    }

    #[test]
    fn a_single_child_split_collapses_into_its_child() {
        let lone = TemplateNode::split(SplitAxis::Horizontal, vec![TemplateNode::Pane(
            TemplatePane::new("Editor"),
        )]);
        assert_eq!(lone.repaired(), TemplateNode::Pane(TemplatePane::new("Editor")));
    }

    #[test]
    fn a_childless_split_becomes_a_plain_terminal_rather_than_nothing() {
        let empty = TemplateNode::split(SplitAxis::Horizontal, Vec::new());
        assert_eq!(
            empty.repaired(),
            TemplateNode::Pane(TemplatePane::new(FALLBACK_PANE_TITLE)),
            "a template must always expand to at least one pane",
        );
    }

    #[test]
    fn a_degenerate_child_is_repaired_before_its_parent_counts_it() {
        let nested = TemplateNode::split(SplitAxis::Horizontal, vec![
            TemplateNode::Pane(TemplatePane::new("Editor")),
            TemplateNode::split(SplitAxis::Vertical, vec![TemplateNode::Pane(TemplatePane::new(
                "Server",
            ))]),
        ]);
        let repaired = nested.repaired();
        assert_eq!(repaired.depth(), 2, "the lone-child split is gone");
        assert_eq!(repaired.pane_count(), 2);
    }

    #[test]
    fn a_layout_nested_past_the_cap_collapses_to_its_first_pane() {
        let mut deep = TemplateNode::Pane(TemplatePane::new("Deepest"));
        for _ in 0..MAX_DEPTH + 2 {
            deep = TemplateNode::split(SplitAxis::Horizontal, vec![
                deep,
                TemplateNode::Pane(TemplatePane::new("Filler")),
            ]);
        }
        let repaired = deep.repaired();
        assert!(
            repaired.depth() <= MAX_DEPTH,
            "however deep the file went, the kept layout stays inside the tree's own bound",
        );
        assert_eq!(
            repaired.first_pane(),
            TemplatePane::new("Deepest"),
            "the collapse keeps the innermost leaf rather than synthesizing a fallback",
        );
    }

    #[test]
    fn a_sound_layout_survives_the_repair_untouched() {
        let templates = built_in_session_templates();
        for template in &templates {
            assert_eq!(template.layout.repaired(), template.layout);
        }
    }

    #[test]
    fn a_leaf_types_its_own_command_and_a_bare_one_types_nothing() {
        assert_eq!(
            TemplatePane::new("Git").running("git status").keystrokes(),
            b"git status\n".to_vec()
        );
        assert!(TemplatePane::new("Terminal").keystrokes().is_empty());
    }
}
