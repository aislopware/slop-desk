//! Screen-tier agent detection: what a pane's screen SAYS the agent is doing.
//!
//! This is tier 2 of `docs/50` — inference from pixels an agent drew for a human. Tier 1 (Claude
//! Code hooks, the ctl `report` verb) never comes near it and stays in hostd, because tier 1 is
//! not a screen at all.
//!
//! ## Why the whole tier lives here now
//! hostd used to ask this socket for the SCREEN and then decide for itself: a `feed` returned the
//! full grid as JSON — every visible row, every ~300 ms, per pane — which hostd re-joined into one
//! string and ran ~20 ICU regexes over. Three separate walks of the same chunk (this socket's
//! parser, the OSC tracker, the sync-frame tracker) and a per-pane screen's worth of JSON crossing
//! the socket, to answer a question whose answer is about a hundred bytes.
//!
//! So the question crosses instead of the screen: one [`Verb::Detect`](crate::protocol::Verb) per
//! tick carries the pane's new bytes and gets back a [`Verdict`].
//!
//! ## What did NOT move
//! Everything that reads a CLOCK. The startup grace, the working→idle hold, the blocked→idle
//! confirmation count, the sync-frame timeout cap and the scan cadence are all in hostd, where the
//! scan timer is. The line is: **screend owns what reads the bytes, hostd owns what reads the
//! clock** — which is why [`Verdict`] reports [`Verdict::frame_open`] and
//! [`Verdict::frame_generation`] as FACTS and lets hostd decide how long it will wait on them.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::manifest::{Manifest, Rule, State};
use crate::osc::OscTracker;
use crate::rules::{CompiledManifest, Explain, KNOWN_AGENT_IDLE_FALLBACK_REASON};
use crate::syncwatch::SyncFrameTracker;

/// One evaluation input: the already trimmed/joined screen text plus the retained OSC evidence.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Input {
    /// herdr's `detection_text` — every visible row, trailing blank rows dropped.
    pub screen: String,
    /// The retained OSC 0/2 title.
    pub osc_title: String,
    /// The retained OSC 9 payload.
    pub osc_progress: String,
}

impl Input {
    /// A screen-only input — the shape `explain` uses, where OSC evidence is out of scope.
    #[must_use]
    pub fn from_screen(screen: impl Into<String>) -> Self {
        Self {
            screen: screen.into(),
            osc_title: String::new(),
            osc_progress: String::new(),
        }
    }
}

/// The engine's verdict, plus the two sync-frame facts hostd's timeout is keyed on.
///
/// `camelCase` on the wire, like every other JSON payload this daemon answers with.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent screen claims; a bitfield would need a second name for each"
)]
pub struct Verdict {
    /// The four-way state.
    pub state: State,
    /// A FREEZE rule matched (transcript viewer, model picker): publish nothing, hold the previous
    /// status.
    pub skip_state_update: bool,
    /// The screen literally shows an idle prompt box. This is the ONE screen claim strong enough
    /// to clear an authoritative hook block, which is why the tear guards exist.
    pub visible_idle: bool,
    /// The screen literally shows a live blocker form.
    pub visible_blocker: bool,
    /// The screen literally shows a live spinner.
    pub visible_working: bool,
    /// The winning rule's id, or `null` on a fallback.
    pub matched_rule_id: Option<String>,
    /// herdr's fallback-reason constant when no rule matched a known agent.
    pub fallback_reason: Option<String>,
    /// TRUE when the fed bytes end inside an OPEN synchronized update — the grid is half a frame.
    pub frame_open: bool,
    /// Bumped every time a frame opens. hostd's over-long-frame deadline is keyed on this.
    pub frame_generation: u64,
}

impl Verdict {
    /// The verdict a matching rule produces. The `visible_*` flags are honoured only when the
    /// state agrees — a `visible_idle` on a working rule claims nothing about an idle prompt.
    #[must_use]
    pub fn from_rule(rule: &Rule) -> Self {
        let state = rule.state.unwrap_or(State::Unknown);
        Self {
            state,
            skip_state_update: rule.skip_state_update,
            visible_idle: rule.visible_idle && state == State::Idle,
            visible_blocker: rule.visible_blocker && state == State::Blocked,
            visible_working: rule.visible_working && state == State::Working,
            matched_rule_id: Some(rule.id.clone()),
            fallback_reason: None,
            frame_open: false,
            frame_generation: 0,
        }
    }

    /// A KNOWN agent whose screen matched no rule: plain idle, no visible claim.
    #[must_use]
    pub fn known_agent_idle_fallback() -> Self {
        Self {
            state: State::Idle,
            fallback_reason: Some(KNOWN_AGENT_IDLE_FALLBACK_REASON.to_owned()),
            ..Self::none()
        }
    }

    /// No agent in the foreground — the screen says nothing about anyone.
    #[must_use]
    pub const fn none() -> Self {
        Self {
            state: State::Unknown,
            skip_state_update: false,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
            matched_rule_id: None,
            fallback_reason: None,
            frame_open: false,
            frame_generation: 0,
        }
    }
}

// MARK: - The bundled catalog

/// The bundled manifest TOML per agent.
///
/// Carried VERBATIM from herdr (Apache-2.0, `github.com/ogulcancelik/herdr
/// src/detect/manifests/*.toml`) so an upstream update can be pasted in unchanged. `omp` and
/// `mastracode` are hook-authority-only upstream and ship none.
///
/// They are real `.toml` files rather than string literals now: the Swift original had to embed
/// them, because a Swift package resource would not have loaded in the headless daemon.
pub const BUNDLED: &[(&str, &str)] = &[
    ("pi", include_str!("../manifests/pi.toml")),
    ("claude", include_str!("../manifests/claude.toml")),
    ("codex", include_str!("../manifests/codex.toml")),
    ("gemini", include_str!("../manifests/gemini.toml")),
    ("cursor", include_str!("../manifests/cursor.toml")),
    ("devin", include_str!("../manifests/devin.toml")),
    ("agy", include_str!("../manifests/agy.toml")),
    ("cline", include_str!("../manifests/cline.toml")),
    ("opencode", include_str!("../manifests/opencode.toml")),
    ("copilot", include_str!("../manifests/copilot.toml")),
    ("kimi", include_str!("../manifests/kimi.toml")),
    ("kiro", include_str!("../manifests/kiro.toml")),
    ("droid", include_str!("../manifests/droid.toml")),
    ("amp", include_str!("../manifests/amp.toml")),
    ("grok", include_str!("../manifests/grok.toml")),
    ("hermes", include_str!("../manifests/hermes.toml")),
    ("kilo", include_str!("../manifests/kilo.toml")),
    ("qodercli", include_str!("../manifests/qodercli.toml")),
    ("maki", include_str!("../manifests/maki.toml")),
];

/// The compiled catalog, built once per process.
///
/// A bundled manifest that fails to parse is EXCLUDED and named on stderr rather than taken as
/// fatal: one broken agent must not cost every other pane its screen tier. `the_bundled_catalog_
/// is_complete` in the test suite is what stops that silence being how a manifest rots.
static CATALOG: LazyLock<HashMap<&'static str, CompiledManifest>> = LazyLock::new(|| {
    let mut catalog = HashMap::with_capacity(BUNDLED.len());
    for &(label, toml) in BUNDLED {
        match Manifest::parse(toml).and_then(CompiledManifest::new) {
            Ok(compiled) => {
                catalog.insert(label, compiled);
            },
            Err(error) => eprintln!("screend: bundled manifest for {label} invalid: {error}"),
        }
    }
    catalog
});

/// The compiled manifest for `label`, or `None` for an agent that ships none.
#[must_use]
pub fn manifest_for(label: &str) -> Option<&'static CompiledManifest> {
    CATALOG.get(label)
}

/// The engine entry point (herdr `detect_agent_with_osc`).
///
/// An EMPTY label means no agent is in the foreground; a non-empty label with no bundled manifest
/// (`omp`, `mastracode`) gets the known-agent idle fallback, exactly as upstream does.
#[must_use]
pub fn detect(agent: &str, input: &Input) -> Verdict {
    if agent.is_empty() {
        return Verdict::none();
    }
    manifest_for(agent).map_or_else(Verdict::known_agent_idle_fallback, |manifest| {
        manifest.evaluate(input)
    })
}

/// herdr `explain_for_label` (the `agent explain --file` path): screen-only input, OSC empty.
#[must_use]
pub fn explain(agent: &str, screen: &str) -> Explain {
    let Some(manifest) = manifest_for(agent) else {
        // An agent we KNOW ships no manifest still gets the known-agent fallback; a label we do
        // not know at all is a different answer, and upstream distinguishes them.
        if KNOWN_AGENTS.contains(&agent) {
            return crate::rules::fallback_explain(agent, None, Vec::new());
        }
        return crate::rules::unknown_agent_explain(agent);
    };
    manifest.explain(agent, &Input::from_screen(screen))
}

/// Every agent label herdr knows, including the two that ship no screen manifest. Only `explain`
/// needs this: the runtime path is asked about a label hostd already identified.
pub const KNOWN_AGENTS: &[&str] = &[
    "pi",
    "claude",
    "codex",
    "gemini",
    "cursor",
    "devin",
    "agy",
    "cline",
    "omp",
    "mastracode",
    "opencode",
    "copilot",
    "kimi",
    "kiro",
    "droid",
    "amp",
    "grok",
    "hermes",
    "kilo",
    "qodercli",
    "maki",
];

// MARK: - Per-pane state

/// The two byte trackers that ride alongside a pane's grid.
///
/// They are here rather than beside the scan timer because they read the SAME bytes the grid is
/// fed, and a chunk should be walked once per side of the socket, not three times on the far side.
#[derive(Debug, Default)]
pub struct PaneDetect {
    /// Retained OSC 0/2 title and OSC 9 progress.
    pub osc: OscTracker,
    /// Whether the stream ends mid-repaint.
    pub sync: SyncFrameTracker,
}

impl PaneDetect {
    /// Folds one chunk into both trackers, in the order the scanner used to.
    pub fn observe(&mut self, bytes: &[u8]) {
        self.osc.observe(bytes);
        self.sync.observe(bytes);
    }

    /// The detection input for `screen`, carrying this pane's retained OSC evidence.
    #[must_use]
    pub fn input(&self, screen: String) -> Input {
        Input {
            screen,
            osc_title: self.osc.title().to_owned(),
            osc_progress: self.osc.progress().to_owned(),
        }
    }
}

/// herdr's `detection_text`, exact: every visible row, trailing EMPTY rows dropped, `\n`-joined
/// with one trailing `\n` — or `""` for a screen that is empty all the way up.
///
/// This used to be computed on the far side of the socket, which is the whole reason a grid's
/// worth of JSON crossed it.
#[must_use]
pub fn detection_text(lines: &[String]) -> String {
    let Some(last) = lines.iter().rposition(|line| !line.is_empty()) else {
        return String::new();
    };
    let mut out = lines[..=last].join("\n");
    out.push('\n');
    out
}

#[cfg(test)]
mod tests {
    use super::{BUNDLED, Input, KNOWN_AGENTS, State, detect, explain, manifest_for};

    #[test]
    fn the_bundled_catalog_is_complete_and_every_manifest_compiles() {
        assert_eq!(BUNDLED.len(), 19, "herdr's 19 screen-manifest agents");
        for &(label, _) in BUNDLED {
            assert!(
                manifest_for(label).is_some(),
                "{label} failed to parse or compile"
            );
        }
        // The two hook-authority-only agents are known but ship nothing.
        assert!(manifest_for("omp").is_none());
        assert!(manifest_for("mastracode").is_none());
        assert_eq!(KNOWN_AGENTS.len(), BUNDLED.len() + 2);
    }

    #[test]
    fn no_agent_means_the_screen_says_nothing() {
        let verdict = detect("", &Input::from_screen("anything at all"));
        assert_eq!(verdict.state, State::Unknown);
        assert!(verdict.matched_rule_id.is_none());
        assert!(verdict.fallback_reason.is_none());
    }

    #[test]
    fn a_known_agent_with_no_manifest_falls_back_to_idle() {
        let verdict = detect("omp", &Input::from_screen("anything"));
        assert_eq!(verdict.state, State::Idle);
        assert!(verdict.fallback_reason.is_some());
    }

    #[test]
    fn claudes_braille_title_reports_working() {
        let mut input = Input::from_screen("");
        input.osc_title = "⠋ Forging…".to_owned();
        let verdict = detect("claude", &input);
        assert_eq!(verdict.state, State::Working);
        assert!(verdict.visible_working);
    }

    #[test]
    fn claudes_rest_title_reports_idle() {
        let mut input = Input::from_screen("");
        input.osc_title = "✳ slopdesk".to_owned();
        assert_eq!(detect("claude", &input).state, State::Idle);
    }

    #[test]
    fn an_unknown_label_explains_as_unknown_and_a_manifest_less_one_does_not() {
        assert_eq!(
            explain("not-an-agent", "x").fallback_reason.as_deref(),
            Some("unknown_agent")
        );
        assert_eq!(
            explain("omp", "x").fallback_reason.as_deref(),
            Some(super::KNOWN_AGENT_IDLE_FALLBACK_REASON)
        );
    }

    #[test]
    fn explain_walks_every_rule_of_a_real_manifest() {
        let trace = explain("claude", "❯ ask me\n");
        assert!(trace.evaluated_rules.len() > 5, "claude's ladder is not one rule");
        assert_eq!(trace.agent.as_deref(), Some("claude"));
    }
}
