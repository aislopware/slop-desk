//! The two things that SPAWN panes: a launch preset and a session template.
//!
//! A [`LaunchPreset`] is one command and the one or two panes it opens into the current session. A
//! [`SessionTemplate`] is a whole named session — an n-ary layout whose every leaf carries its own
//! working directory and startup command.
//!
//! ## The expansion is pure
//!
//! Applying either produces a plan — the pane specs, and the exact bytes to type into each once its
//! PTY is live. Nothing here opens a socket or spawns a process, so the whole expansion is testable
//! against its bytes.
//!
//! ## What in here a client actually reaches
//!
//! Not all of it, and the split is worth knowing before assuming a change here is load-bearing.
//! [`keystrokes`] crosses as `slopdesk_ws_launch_keystrokes` and is the SINGLE implementation of
//! the rule below — the Swift face is a wrapper with no logic in it. [`built_in_session_templates`]
//! and [`built_in_launch_presets`] are the single implementation too, as of 2026-08-22: they cross
//! as `slopdesk_ws_built_in_templates` / `slopdesk_ws_built_in_launch_presets` and ARE
//! `SessionTemplate.builtIns` / `LaunchPreset.builtIns`, the rows a fresh device is seeded with.
//! Editing one of these tables changes what every new workspace ships, with no second list to keep
//! in step.
//!
//! They did not start that way. Both crossed on 2026-08-20 as a PIN beside Swift literals of the
//! same three rows, on the reasoning that `SessionTemplate` is `Codable` and is what the
//! device-preferences file is made of. That is true of the TYPE and says nothing about a table of
//! three constants, and a shipped default written twice is the cross-language mirror fixture
//! CLAUDE.md bans by name — so the literals are gone and the differential that held them together
//! now asserts what the seed must BE instead of that two copies of it match.
//!
//! [`TemplateNode::repaired`] is the one that really is a pin: `TemplateNode::init(from:)` is how a
//! person's saved layouts come back off disk, so Swift cannot delete its decoder, and `docs/55` §7
//! step 6 asks for a differential rather than a deletion. `SessionTemplateRepairDifferentialTests`
//! drives both sides over every degenerate layout and asserts they converge.
//!
//! A PRESET's expansion is not here and is not meant to be. A preset's plan — the pane titles, the
//! inherited spawn cwd, the split axis — is `LaunchPresetEngine.plan` on the Swift side, because it
//! is three field copies around one rule and that rule is [`keystrokes`], which already crosses. A
//! door for the expansion would marshal a whole preset to compare two spellings of an assignment.
//!
//! A Rust `plan` DID sit here until 2026-08-22, called by nothing but its own tests, and the note
//! below the built-in tables records why an unreached port is worse than an unported one rather
//! than better.
//!
//! A TEMPLATE's expansion is a different size of thing and it IS here — [`expand`] and its inverse
//! [`capture`], as of this change. A template becomes a whole tab: a tree of ids that did not exist
//! a moment ago, equal shares on every seam, a launch ORDER the caller then walks to type each
//! pane's command, and a first-leaf-is-active rule. None of that is an assignment, all of it is a
//! decision two builds could make differently, and the round trip — expand a captured layout,
//! capture the expansion — is a property no field copy has. Both are reached:
//! `SessionTemplateEngine` is a face over them with nothing left in it.
//!
//! ## Where the identities come from
//!
//! [`expand`] mints through an [`IdSource`] rather than reaching for entropy, exactly as
//! [`crate::persist::decode_file`] does. This crate has no randomness in it and should not grow
//! any: the caller that owns the process owns its identities, and a test that wants a repeatable
//! expansion supplies a counter. [`minted_ids_for_template`] is how a caller learns how many to
//! bring, for the same reason [`crate::persist::minted_ids_for`] exists — a pool one short does not
//! fail, it REPEATS an id, and two panes born with one id surface days later as a pane that will
//! not close.
//!
//! ## A path is not shell input
//!
//! The `cd` line a plan emits is built from LITERAL bytes and never goes through
//! [`crate::send_keys`]. A working directory is a filesystem path, and running one through the
//! token parser would let `<Enter>` inside it inject a real newline: the quoted `cd` line would end
//! early and the rest of the path would run as its own command. Quoting does not help — it escapes
//! quotes, not tokens. Only the COMMAND field, which is shell input by intent, goes through the
//! parser.

use slopdesk_ids::identity::{IdSource, LaunchPresetId, PaneId, SessionTemplateId};
use slopdesk_tree::session::PaneKind;
use slopdesk_tree::split_tree::{MAX_DEPTH, SplitAxis, SplitNode, SplitWeight, WeightedChild};

use crate::send_keys;

/// The optional second pane of a two-pane launch preset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitConfig {
    /// Which way the first pane splits to make room.
    pub axis: SplitAxis,
    /// What runs in the second pane. Empty is a plain shell beside the first.
    pub secondary_command: String,
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
    fn new(id: LaunchPresetId, name: impl Into<String>, command: impl Into<String>) -> Self {
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

// There is no `plan` here, and its absence is a decision rather than an omission.
//
// A launch preset's expansion — the pane titles, the inherited spawn cwd, the split axis — lives in
// `LaunchPresetEngine.plan` and stays there. It is three field copies around one real rule, and
// that rule is [`keystrokes`] below, which already crosses as `slopdesk_ws_launch_keystrokes`; a
// door for the expansion would marshal a whole preset across the boundary to compare two spellings
// of an assignment. docs/55 §8 records the same judgement.
//
// What DID live here until 2026-08-22 was a Rust `plan` with `LaunchPlan` and `PaneLaunch` beside
// it, called by nothing but its own two tests. That is the arrangement the one-implementation rule
// exists to stop, and it is worse than the usual case rather than better: a port that is never
// reached cannot be caught disagreeing, because no input ever reaches both copies. Nothing in the
// tree could have compared them, and `dead_code` cannot see a `pub` item in a library crate — so it
// would have sat here accumulating drift against the Swift for as long as anyone cared to leave it.
// `TemplatePane::keystrokes` went with it, for the same reason and with an extra one of its own: it
// hardcoded `None` for the cwd, so it could not emit the `cd` line its Swift counterpart takes a
// directory in order to write. The two had already stopped being the same function.

/// The bytes to type into a freshly spawned pane: a `cd` line when a directory is set, then the
/// command.
///
/// An empty command with no directory sends NOTHING, which is what makes a preset able to open a
/// plain shell.
#[must_use]
pub fn keystrokes(command: &str, cwd: Option<&str>) -> Vec<u8> {
    let mut out = Vec::new();
    // Trimmed, the way the command gate below is. The asymmetry this replaces was a real drift: the
    // Swift face gated on a TRIMMED cwd and this gated on an untrimmed one, so a whitespace-only
    // directory was "no directory" on one side and `cd '  '` — a line the shell answers with an
    // error at every launch — on the other. Neither production caller passes one today, which is
    // exactly why the pair could sit disagreeing. The gate only decides; the path is still quoted
    // verbatim, because what was typed is what the person meant to type.
    if let Some(path) = cwd.filter(|path| !path.trim().is_empty()) {
        // The whole line is literal UTF-8 — see the module's note on why a path must never reach
        // the token parser. The quoting is only so a directory with spaces survives.
        out.extend_from_slice(format!("cd {}", slopdesk_ids::shell_quoting::single_quoted(path)).as_bytes());
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
    fn running(mut self, command: impl Into<String>) -> Self {
        self.command = Some(command.into());
        self
    }
}

/// The title a repaired template falls back to.
///
/// A template must expand to at least one pane, so a node with nothing left in it becomes a plain
/// terminal rather than nothing at all.
///
/// It re-exports [`slopdesk_tree::workspace::DEFAULT_PANE_TITLE`] instead of spelling the same word
/// again. The two ask one question — what is a pane nobody has named called — from two directions,
/// and a second literal would let them answer it differently: rename the default and a repaired
/// template would go on producing panes titled the old thing, while every gesture-made pane took
/// the new one. Nothing would fail; the workspace would just have two kinds of unnamed pane in it.
pub const FALLBACK_PANE_TITLE: &str = slopdesk_tree::workspace::DEFAULT_PANE_TITLE;

/// The recursive, n-ary layout a session template expands into.
///
/// It mirrors [`slopdesk_tree::split_tree::SplitNode`] but carries each pane's launch intent
/// instead of an id, and it has no weights at all: a template describes STRUCTURE, and pinning
/// exact divider positions into it would make every restore fight whatever the person had since
/// dragged.
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
    fn first_pane(&self) -> TemplatePane {
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
    ///
    /// ## It is written twice, and the twin is pinned rather than trusted
    ///
    /// Swift's `TemplateNode.init(from: Decoder)` is the other implementation, and it cannot be
    /// deleted: `SessionTemplate` is `Codable` and is the currency of the device-preferences file,
    /// so that decoder is how a person's saved layouts actually come back. `docs/55` §7 step 6 is
    /// exactly that case and asks for a differential instead —
    /// `Tests/SlopDeskWorkspaceModelTests/SessionTemplateRepairDifferentialTests.swift`, which
    /// reaches this function through `slopdesk_ws_template_repair` and drives both sides over every
    /// degenerate shape there is.
    ///
    /// The two agree case for case, and did before the suite existed; what disagreed was the
    /// PROSE. Swift's comment called the depth cap a rejection where this one calls it a repair,
    /// which described a parser beside a repairer — `docs/55` §8's exact signature for a pair about
    /// to go wrong — over two implementations that were doing the same thing. Both comments say the
    /// same true thing now, and the suite is what keeps that from being a claim with no gate behind
    /// it.
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
    fn new(id: SessionTemplateId, name: impl Into<String>, layout: TemplateNode) -> Self {
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

// MARK: - Expansion: a template becomes a live tab

/// One leaf of an expanded template: the identity it was just minted with, and what to do in it.
///
/// The two travel together because the caller needs both at once — it seeds a spec under the id and
/// types the pane's command into the same pane once its PTY is live — and because separating them
/// would put the two lists in the caller's hands to keep in step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpandedPane {
    /// The freshly minted pane identity.
    pub id: PaneId,
    /// The template's intent for it: kind, title, working directory, startup command.
    pub pane: TemplatePane,
}

/// A template, expanded into the tab it describes.
#[derive(Debug, Clone, PartialEq)]
pub struct Expansion {
    /// The split tree, with a fresh identity on every leaf and every seam.
    pub root: SplitNode,
    /// Its leaves in DEPTH-FIRST order, which is the order the caller opens and types into them.
    ///
    /// Never empty: a layout is either a pane or a split over children, and a split with no
    /// children cannot survive [`TemplateNode::repaired`], which every persisted layout goes
    /// through. An unrepaired childless split expands to an empty tree here rather than to an
    /// invented pane — inventing one would be a repair this function made up, at the one place a
    /// caller cannot tell the difference.
    pub launches: Vec<ExpandedPane>,
}

impl Expansion {
    /// The pane that takes focus: the FIRST leaf in depth-first order.
    ///
    /// Reading order, and it is the same leaf whichever surface asks — which is the point of it
    /// being here rather than at each caller, where "the first leaf" and "the first launch" are two
    /// spellings that agree until someone reorders one of them.
    #[must_use]
    pub fn active_pane(&self) -> Option<PaneId> {
        self.launches.first().map(|launch| launch.id)
    }
}

/// How many identities [`expand`] spends on `layout`: one per leaf, one per seam.
///
/// Asked rather than transcribed, for [`crate::persist::minted_ids_for`]'s reason — a pool one
/// short does not fail, it repeats an identity, and a repeated pane id is a pane that will not
/// close.
#[must_use]
pub fn minted_ids_for_template(layout: &TemplateNode) -> usize {
    match layout {
        TemplateNode::Pane(_) => 1,
        TemplateNode::Split { children, .. } => {
            1 + children.iter().map(minted_ids_for_template).sum::<usize>()
        },
    }
}

/// A template layout as a live split tree: fresh ids, EQUAL shares, leaves in launch order.
///
/// Three decisions, none of them a field copy:
///
/// * **Every seam is `Flex(1)`.** A template describes structure, not divider positions — pinning
///   the exact geometry into it would make every restore fight whatever the person had since
///   dragged. Equal shares are what the layout solver then normalises.
/// * **Depth-first is the launch order.** It is also reading order, so the first pane to come up is
///   the top-left one, and the caller's "open, then type" loop matches what the user watches
///   happen.
/// * **The first leaf is active.** See [`Expansion::active_pane`].
///
/// The caller's `layout` is used as given. A persisted one has already been through
/// [`TemplateNode::repaired`], which is where the depth cap and the degenerate shapes are handled;
/// re-repairing here would silently accept a layout the decoder was supposed to have refused.
pub fn expand(layout: &TemplateNode, mint: &mut impl IdSource) -> Expansion {
    let mut launches = Vec::with_capacity(layout.pane_count());
    let root = expanded_node(layout, mint, &mut launches);
    Expansion { root, launches }
}

/// One node of [`expand`]'s walk, appending each leaf to `launches` as it is reached.
fn expanded_node(
    node: &TemplateNode,
    mint: &mut impl IdSource,
    launches: &mut Vec<ExpandedPane>,
) -> SplitNode {
    match node {
        TemplateNode::Pane(pane) => {
            let id = mint.pane();
            launches.push(ExpandedPane {
                id,
                pane: pane.clone(),
            });
            SplitNode::Leaf(id)
        },
        TemplateNode::Split { axis, children } => {
            // The seam's identity is taken BEFORE its children's, so the pool is spent in the same
            // order whatever the tree looks like — a walk that took it after would hand two
            // differently-shaped layouts different ids for the same node.
            let id = mint.split();
            let children = children
                .iter()
                .map(|child| WeightedChild::new(SplitWeight::Flex(1.0), expanded_node(child, mint, launches)))
                .collect();
            SplitNode::Split {
                id,
                axis: *axis,
                children,
            }
        },
    }
}

// MARK: - Capture: a live tab becomes a template

/// What one leaf of a live tab says about itself when a template is captured from it.
///
/// Only the two facts a [`slopdesk_tree::session::PaneSpec`] holds. A working directory and a
/// running command are the PTY's, not the tree's, so they cannot be read back off a running session
/// at all — which is why a captured template's panes carry neither.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedPane {
    /// The leaf's kind.
    pub kind: PaneKind,
    /// The leaf's title, exactly as its spec spells it — including blank.
    pub title: String,
}

/// A live tab's geometry as [`capture`] reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CapturedNode {
    /// One leaf, and what the session's side table says about it.
    ///
    /// `None` means the side table has NO spec for that leaf, which is a different fact from a spec
    /// whose title is blank: the first is a document that has lost track of one of its own panes
    /// and is repaired, the second is a pane the user never named and is captured verbatim.
    Pane(Option<CapturedPane>),
    /// A partition among children, in visual order.
    Split {
        /// Which way it partitions.
        axis: SplitAxis,
        /// Its children, in visual order.
        children: Vec<Self>,
    },
}

/// A live tab's geometry as a reusable template: same shape, same order, specs turned back into
/// launch intents.
///
/// `tab` is `None` when the session has NO active tab, which captures a single default terminal
/// pane. That is the same validate-then-repair the missing-spec case takes, one level up: a
/// template must expand to at least one pane, so a session with nothing to capture yields the
/// smallest layout that is still a layout rather than an empty one that would fail on the way back
/// in.
#[must_use]
pub fn capture(tab: Option<&CapturedNode>) -> TemplateNode {
    let Some(tab) = tab else {
        return TemplateNode::Pane(TemplatePane::new(FALLBACK_PANE_TITLE));
    };
    captured_node(tab)
}

/// One node of [`capture`]'s walk.
fn captured_node(node: &CapturedNode) -> TemplateNode {
    match node {
        CapturedNode::Pane(spec) => {
            let pane = spec.as_ref().map_or_else(
                || TemplatePane::new(FALLBACK_PANE_TITLE),
                |spec| {
                    TemplatePane {
                        kind: spec.kind,
                        title: spec.title.clone(),
                        cwd: None,
                        command: None,
                    }
                },
            );
            TemplateNode::Pane(pane)
        },
        CapturedNode::Split { axis, children } => {
            TemplateNode::split(*axis, children.iter().map(captured_node).collect())
        },
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing plan entry is a test failure with nothing to return"
    )]

    use std::collections::BTreeSet;

    use slopdesk_ids::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
    use slopdesk_tree::session::PaneKind;
    use slopdesk_tree::split_tree::{MAX_DEPTH, SplitAxis, SplitNode, SplitWeight};

    use super::{
        CapturedNode, CapturedPane, ExpandedPane, FALLBACK_PANE_TITLE, TemplateNode, TemplatePane,
        built_in_launch_presets, built_in_session_templates, capture, expand, keystrokes,
        minted_ids_for_template,
    };

    /// A repeatable identity pool: the nth id ever taken is `n`, whatever it is for.
    ///
    /// One counter across all four kinds rather than four, because that is what the FFI pool is —
    /// a caller hands over a flat list and the walk spends it in order — and a test with four
    /// counters would agree with an implementation that spent them in the wrong order.
    #[derive(Default)]
    struct Counter(u8);

    impl Counter {
        fn take(&mut self) -> [u8; 16] {
            self.0 = self.0.wrapping_add(1);
            [self.0; 16]
        }
    }

    impl IdSource for Counter {
        fn pane(&mut self) -> PaneId {
            PaneId::from_bytes(self.take())
        }

        fn tab(&mut self) -> TabId {
            TabId::from_bytes(self.take())
        }

        fn session(&mut self) -> SessionId {
            SessionId::from_bytes(self.take())
        }

        fn split(&mut self) -> SplitNodeId {
            SplitNodeId::from_bytes(self.take())
        }
    }

    /// A shape fingerprint that ignores identity — axes, nesting and leaf count only.
    ///
    /// The same fingerprint `SessionTemplateEngineTests` used in Swift, and the reason the
    /// round-trip property can be stated at all: expansion mints ids, so two expansions of one
    /// layout are never equal and their SHAPES always are.
    #[derive(Debug, PartialEq, Eq)]
    enum Shape {
        Leaf,
        Split(SplitAxis, Vec<Self>),
    }

    fn tree_shape(node: &SplitNode) -> Shape {
        match node {
            SplitNode::Leaf(_) => Shape::Leaf,
            SplitNode::Split { axis, children, .. } => {
                Shape::Split(*axis, children.iter().map(|c| tree_shape(&c.node)).collect())
            },
        }
    }

    fn layout_shape(node: &TemplateNode) -> Shape {
        match node {
            TemplateNode::Pane(_) => Shape::Leaf,
            TemplateNode::Split { axis, children } => {
                Shape::Split(*axis, children.iter().map(layout_shape).collect())
            },
        }
    }

    /// A whole expansion read back as the tab a caller would capture from it.
    fn as_captured(node: &SplitNode, specs: &[(PaneId, CapturedPane)]) -> CapturedNode {
        match node {
            SplitNode::Leaf(id) => {
                CapturedNode::Pane(
                    specs
                        .iter()
                        .find(|(key, _)| key == id)
                        .map(|(_, spec)| spec.clone()),
                )
            },
            SplitNode::Split { axis, children, .. } => {
                CapturedNode::Split {
                    axis: *axis,
                    children: children
                        .iter()
                        .map(|child| as_captured(&child.node, specs))
                        .collect(),
                }
            },
        }
    }

    /// The specs a caller seeds from an expansion — the side table `makeSession` builds.
    fn seeded(launches: &[ExpandedPane]) -> Vec<(PaneId, CapturedPane)> {
        launches
            .iter()
            .map(|launch| {
                (launch.id, CapturedPane {
                    kind: launch.pane.kind,
                    title: launch.pane.title.clone(),
                })
            })
            .collect()
    }

    #[test]
    fn an_empty_command_and_no_directory_sends_nothing() {
        assert!(keystrokes("", None).is_empty());
        assert!(keystrokes("   ", None).is_empty(), "whitespace is not a command");
        assert!(keystrokes("", Some("")).is_empty());
        // A whitespace-only directory is not a directory either, and it is the arm the Swift face
        // used to answer differently: `cd '  '` is a line the shell only ever errors on.
        assert!(
            keystrokes("   ", Some("  ")).is_empty(),
            "whitespace is not a directory"
        );
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

    // MARK: Expansion

    /// `SessionTemplateEngineTests.testMakeSessionBuildsSplitTreeAndSeedsSpecs`, carried over: the
    /// tree, the DFS launch list, the equal shares and the active leaf, in one expansion.
    #[test]
    fn a_two_pane_template_expands_to_a_split_with_equal_shares() {
        let layout = TemplateNode::split(SplitAxis::Horizontal, vec![
            TemplateNode::Pane(TemplatePane::new("Editor")),
            TemplateNode::Pane(TemplatePane::new("Terminal")),
        ]);
        let expansion = expand(&layout, &mut Counter::default());

        assert_eq!(expansion.root.leaf_count(), 2);
        assert_eq!(
            expansion
                .launches
                .iter()
                .map(|launch| launch.pane.title.as_str())
                .collect::<Vec<_>>(),
            ["Editor", "Terminal"],
            "the launch list is the leaves in depth-first order"
        );
        assert_eq!(
            expansion.active_pane(),
            expansion.root.all_pane_ids().first().copied(),
            "the active pane is the first leaf in reading order"
        );
        let SplitNode::Split { children, .. } = &expansion.root else {
            panic!("a two-pane layout expands to a split");
        };
        assert_eq!(
            children.iter().map(|child| child.weight).collect::<Vec<_>>(),
            [SplitWeight::Flex(1.0), SplitWeight::Flex(1.0)],
            "a template describes structure, so every seam starts even"
        );
    }

    /// `SessionTemplateEngineTests.testMakeSessionNestedLayoutPreservesSpecsKindsAndCount`, over
    /// the same shipped template it named.
    #[test]
    fn a_nested_template_keeps_every_leafs_kind_title_and_command() {
        let templates = built_in_session_templates();
        let Some(template) = templates.get(1) else {
            panic!("the shipped table has at least two rows");
        };
        let expansion = expand(&template.layout, &mut Counter::default());

        assert_eq!(expansion.root.leaf_count(), expansion.launches.len());
        assert!(
            expansion
                .launches
                .iter()
                .all(|launch| launch.pane.kind == PaneKind::Terminal)
        );
        let titles: BTreeSet<&str> = expansion
            .launches
            .iter()
            .map(|launch| launch.pane.title.as_str())
            .collect();
        assert_eq!(titles, BTreeSet::from(["Editor", "Server", "Git"]));
        assert_eq!(
            expansion
                .launches
                .iter()
                .find(|launch| launch.pane.title == "Git")
                .and_then(|launch| launch.pane.command.as_deref()),
            Some("git status"),
            "a leaf's command rides the launch list, which is what the caller types"
        );
    }

    /// A repeated id is a pane that will not close, so the walk must spend the pool once per node.
    #[test]
    fn every_identity_an_expansion_spends_is_its_own() {
        for template in &built_in_session_templates() {
            let expansion = expand(&template.layout, &mut Counter::default());
            let panes: BTreeSet<PaneId> = expansion.root.all_pane_ids().into_iter().collect();
            assert_eq!(
                panes.len(),
                expansion.root.leaf_count(),
                "{} — two leaves share an id",
                template.name
            );
        }
    }

    /// The pool the caller has to bring, against the pool the expansion actually spends.
    #[test]
    fn the_declared_pool_is_the_pool_the_walk_spends() {
        let nested = TemplateNode::split(SplitAxis::Horizontal, vec![
            TemplateNode::Pane(TemplatePane::new("A")),
            TemplateNode::split(SplitAxis::Vertical, vec![
                TemplateNode::Pane(TemplatePane::new("B")),
                TemplateNode::Pane(TemplatePane::new("C")),
            ]),
        ]);
        assert_eq!(minted_ids_for_template(&nested), 5, "three leaves and two seams");
        assert_eq!(
            minted_ids_for_template(&TemplateNode::Pane(TemplatePane::new("Solo"))),
            1
        );

        let mut mint = Counter::default();
        let expansion = expand(&nested, &mut mint);
        assert_eq!(
            usize::from(mint.0),
            minted_ids_for_template(&nested),
            "the walk took exactly what it declared — one short repeats an id, one over is harmless"
        );
        assert_eq!(expansion.launches.len(), 3);
    }

    // MARK: Capture

    /// `SessionTemplateEngineTests.testCaptureTemplateWalksActiveTabAndDropsCwdCommand`.
    #[test]
    fn a_capture_keeps_the_shape_and_drops_what_the_tree_never_held() {
        let layout = TemplateNode::split(SplitAxis::Vertical, vec![
            TemplateNode::Pane(TemplatePane {
                kind: PaneKind::Terminal,
                title: "A".to_owned(),
                cwd: Some("/w".to_owned()),
                command: Some("should-not-survive".to_owned()),
            }),
            TemplateNode::Pane(TemplatePane::new("B")),
        ]);
        let expansion = expand(&layout, &mut Counter::default());
        let captured = capture(Some(&as_captured(&expansion.root, &seeded(&expansion.launches))));

        let TemplateNode::Split { axis, children } = &captured else {
            panic!("a split tab captures as a split layout");
        };
        assert_eq!(*axis, SplitAxis::Vertical);
        assert_eq!(children.len(), 2);
        for child in children {
            let TemplateNode::Pane(pane) = child else {
                panic!("both children are leaves");
            };
            assert_eq!(
                (pane.cwd.as_deref(), pane.command.as_deref()),
                (None, None),
                "a working directory and a command live in the PTY, not in the tree"
            );
        }
    }

    /// `SessionTemplateEngineTests.testRoundTripPreservesTreeShape`, as the property it was written
    /// as: expand, capture, expand again — the axes, the nesting and the leaf count survive.
    #[test]
    fn expanding_a_captured_expansion_lands_on_the_same_shape() {
        for template in &built_in_session_templates() {
            let first = expand(&template.layout, &mut Counter::default());
            let original = tree_shape(&first.root);
            let captured = capture(Some(&as_captured(&first.root, &seeded(&first.launches))));
            let rebuilt = expand(&captured, &mut Counter::default());

            assert_eq!(
                layout_shape(&captured),
                original,
                "{} — the captured layout is the tab's own shape",
                template.name
            );
            assert_eq!(
                tree_shape(&rebuilt.root),
                original,
                "{} — and it expands back into it",
                template.name
            );
        }
    }

    /// `SessionTemplateEngineTests.testCaptureSingleLeafSession`.
    #[test]
    fn a_single_leaf_tab_captures_as_a_single_pane() {
        let captured = capture(Some(&CapturedNode::Pane(Some(CapturedPane {
            kind: PaneKind::Terminal,
            title: "Solo".to_owned(),
        }))));
        assert_eq!(
            captured,
            TemplateNode::Pane(TemplatePane::new("Solo")),
            "no split to describe, so the layout is the leaf"
        );
    }

    /// The two absences, which are different absences and both repair rather than trap.
    #[test]
    fn a_missing_spec_and_a_missing_tab_both_capture_a_default_terminal() {
        assert_eq!(
            capture(Some(&CapturedNode::Pane(None))),
            TemplateNode::Pane(TemplatePane::new(FALLBACK_PANE_TITLE)),
            "a leaf the side table has lost is captured as an unnamed terminal"
        );
        assert_eq!(
            capture(None),
            TemplateNode::Pane(TemplatePane::new(FALLBACK_PANE_TITLE)),
            "a session with no active tab still captures a layout, never an empty one"
        );
    }

    /// A blank title is a pane the user never named, and it is captured verbatim — the case the
    /// presence flag exists to keep apart from the one above.
    #[test]
    fn a_blank_spec_title_is_captured_rather_than_repaired() {
        assert_eq!(
            capture(Some(&CapturedNode::Pane(Some(CapturedPane {
                kind: PaneKind::Desktop,
                title: String::new(),
            })))),
            TemplateNode::Pane(TemplatePane {
                kind: PaneKind::Desktop,
                title: String::new(),
                cwd: None,
                command: None,
            }),
            "a spec that exists is captured as it is, blank title and all"
        );
    }
}
