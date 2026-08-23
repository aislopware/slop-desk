//! The rule ladder: compile a validated manifest once, then evaluate it against a screen.
//!
//! Ported from Swift `ManifestRuleEngine`. The port is not just a translation — the Swift copy
//! matched with `NSRegularExpression`, an ICU BACKTRACKING engine, against text a foreign program
//! drew into a PTY. A pattern like `^\s*(⬡|⬢|[⠀-⣿]+)\s+\p{Alphabetic}+\w*ing\b` on an
//! adversarial line is exactly the shape that goes exponential there. The `regex` crate is a
//! finite automaton: linear in the input, with no input that can make it otherwise.

use regex::Regex;

use crate::detect::{Input, Verdict};
use crate::manifest::{Gate, Manifest, Rule, State};
use crate::region::Region;

/// herdr `DEFAULT_KNOWN_AGENT_IDLE_FALLBACK` — the reason on the known-agent no-match fallback.
pub const KNOWN_AGENT_IDLE_FALLBACK_REASON: &str = "default_known_agent_idle_fallback";

/// A manifest with its regions parsed, its needles case-folded and its patterns compiled.
/// Immutable after construction, so evaluation is freely concurrent across panes.
#[derive(Debug)]
pub struct CompiledManifest {
    manifest: Manifest,
    rules: Vec<CompiledRule>,
}

#[derive(Debug)]
struct CompiledRule {
    rule: Rule,
    region: Region,
    gate: CompiledGate,
}

#[derive(Debug)]
struct CompiledGate {
    all: Vec<Self>,
    any: Vec<Self>,
    not: Vec<Self>,
    /// Pre-lowercased needles.
    contains: Vec<String>,
    regex: Vec<Regex>,
    line_regex: Vec<Regex>,
    /// ⚠️ OURS, not herdr's: when set, this gate and everything under it evaluate against THIS
    /// region instead of the rule's. `None` = inherit.
    region: Option<Region>,
}

impl CompiledManifest {
    /// Compiles a VALIDATED manifest.
    ///
    /// # Errors
    /// The manifest's own [`crate::manifest::ValidationError`] if a region or pattern that
    /// validation accepted fails here — a defensive second net, as upstream also compiles twice.
    pub fn new(manifest: Manifest) -> Result<Self, crate::manifest::ValidationError> {
        manifest.validate()?;
        let rules = manifest
            .rules
            .iter()
            .map(|rule| {
                let spec = rule.region.trim();
                let region = Region::parse(spec).ok_or_else(|| {
                    crate::manifest::ValidationError {
                        message: format!("invalid region '{spec}'"),
                    }
                })?;
                Ok(CompiledRule {
                    rule: rule.clone(),
                    region,
                    gate: compile_gate(&rule.gate)?,
                })
            })
            .collect::<Result<Vec<_>, crate::manifest::ValidationError>>()?;
        Ok(Self { manifest, rules })
    }

    /// The manifest this was compiled from.
    #[must_use]
    pub const fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// Evaluates every rule; the highest priority match wins, first-declared wins a tie, and no
    /// match at all is the known-agent plain-idle fallback.
    #[must_use]
    pub fn evaluate(&self, input: &Input) -> Verdict {
        let mut winner: Option<&CompiledRule> = None;
        for compiled in &self.rules {
            let text = compiled.region.resolve(input);
            if !matches(&compiled.gate, text, input) {
                continue;
            }
            if winner.is_some_and(|current| current.rule.priority >= compiled.rule.priority) {
                continue;
            }
            winner = Some(compiled);
        }
        winner.map_or_else(Verdict::known_agent_idle_fallback, |winner| {
            Verdict::from_rule(&winner.rule)
        })
    }
}

fn compile_gate(gate: &Gate) -> Result<CompiledGate, crate::manifest::ValidationError> {
    let region = gate
        .region
        .as_deref()
        .map(|spec| {
            let trimmed = spec.trim();
            Region::parse(trimmed).ok_or_else(|| {
                crate::manifest::ValidationError {
                    message: format!("invalid gate region '{trimmed}'"),
                }
            })
        })
        .transpose()?;
    Ok(CompiledGate {
        all: gate.all.iter().map(compile_gate).collect::<Result<_, _>>()?,
        any: gate.any.iter().map(compile_gate).collect::<Result<_, _>>()?,
        not: gate.not.iter().map(compile_gate).collect::<Result<_, _>>()?,
        contains: gate.contains.iter().map(|needle| needle.to_lowercase()).collect(),
        regex: compile_patterns(&gate.regex)?,
        line_regex: compile_patterns(&gate.line_regex)?,
        region,
    })
}

fn compile_patterns(patterns: &[String]) -> Result<Vec<Regex>, crate::manifest::ValidationError> {
    patterns
        .iter()
        .map(|pattern| {
            Regex::new(pattern).map_err(|_| {
                crate::manifest::ValidationError {
                    message: format!("invalid regex '{pattern}'"),
                }
            })
        })
        .collect()
}

/// herdr `compiled_gate_matches`: contains (ALL, case-folded) → regex (ALL, whole region) →
/// `line_regex` (ALL patterns, each with ≥1 matching line) → `all` (ALL) → `any` (≥1 unless
/// empty) → `not` (ANY match vetoes).
///
/// `input` is threaded so a gate carrying its own region can re-resolve — the one thing this
/// engine does that upstream's cannot.
fn matches(gate: &CompiledGate, inherited: &str, input: &Input) -> bool {
    let text = gate.region.map_or(inherited, |region| region.resolve(input));
    if !gate.contains.is_empty() {
        let lower = text.to_lowercase();
        if !gate.contains.iter().all(|needle| lower.contains(needle.as_str())) {
            return false;
        }
    }
    if !gate.regex.iter().all(|pattern| pattern.is_match(text)) {
        return false;
    }
    if !gate.line_regex.is_empty()
        && !gate
            .line_regex
            .iter()
            .all(|pattern| text.lines().any(|line| pattern.is_match(line)))
    {
        return false;
    }
    if !gate.all.iter().all(|nested| matches(nested, text, input)) {
        return false;
    }
    if !gate.any.is_empty() && !gate.any.iter().any(|nested| matches(nested, text, input)) {
        return false;
    }
    !gate.not.iter().any(|nested| matches(nested, text, input))
}

// MARK: - Explain (the differential-parity surface)

/// One rule's evaluation trace.
///
/// `slopdesk-herdr differential` diffs these against upstream's own `agent explain --json`, so
/// every field name and every number here is a wire contract with that harness — including
/// `region_bytes`, which is what proves a region RESOLVER agrees rather than merely a verdict.
#[derive(Debug, serde::Serialize)]
pub struct EvaluatedRule {
    /// The rule's id.
    pub id: String,
    /// Its declared priority.
    pub priority: i32,
    /// Its declared region spec, verbatim.
    pub region: String,
    /// Its own matcher fields and nested-gate counts, plus the resolved region text.
    pub evidence: RuleEvidence,
    /// The state it would have produced.
    pub state: &'static str,
    /// Whether its gate matched.
    pub matched: bool,
}

/// What one rule looked at, and how much of it there was.
#[derive(Debug, serde::Serialize)]
pub struct RuleEvidence {
    /// The rule's own `contains` needles, un-folded.
    pub contains: Vec<String>,
    /// Its own `regex` patterns.
    pub regex: Vec<String>,
    /// Its own `line_regex` patterns.
    pub line_regex: Vec<String>,
    /// How many `all` arms it has.
    pub all_count: usize,
    /// How many `any` arms it has.
    pub any_count: usize,
    /// How many `not` arms it has.
    pub not_count: usize,
    /// UTF-8 byte length of the resolved region text.
    pub region_bytes: usize,
    /// The first 240 chars of that text, `...`-suffixed when truncated.
    pub region_preview: String,
}

/// The winning rule, as `explain` reports it.
#[derive(Debug, serde::Serialize)]
pub struct MatchedRule {
    /// The rule's id.
    pub id: String,
    /// Its priority.
    pub priority: i32,
    /// Its region spec.
    pub region: String,
    /// The state it produced.
    pub state: &'static str,
}

/// A whole evaluation trace (herdr `DetectionExplain`). Not on any hot path.
#[derive(Debug, serde::Serialize)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "upstream's JSON shape, field for field"
)]
pub struct Explain {
    /// The agent label asked about.
    pub agent: Option<String>,
    /// The final state.
    pub state: &'static str,
    /// `"bundled"` when a bundled manifest evaluated.
    pub manifest_source: Option<String>,
    /// That manifest's declared version.
    pub manifest_version: Option<String>,
    /// The winner, if any.
    pub matched_rule: Option<MatchedRule>,
    /// The winner's `visible_idle`, honoured only when the state agrees.
    pub visible_idle: bool,
    /// The winner's `visible_blocker`, honoured only when the state agrees.
    pub visible_blocker: bool,
    /// The winner's `visible_working`, honoured only when the state agrees.
    pub visible_working: bool,
    /// Whether the winner is a freeze rule.
    pub skip_state_update: bool,
    /// `matched_rule:<id>` when it is.
    pub skipped_update_reason: Option<String>,
    /// Why no rule decided, when none did.
    pub fallback_reason: Option<String>,
    /// Every rule, in declaration order.
    pub evaluated_rules: Vec<EvaluatedRule>,
}

impl CompiledManifest {
    /// [`CompiledManifest::evaluate`] with the full per-rule trace.
    #[must_use]
    pub fn explain(&self, agent: &str, input: &Input) -> Explain {
        let mut winner: Option<&CompiledRule> = None;
        let mut evaluated = Vec::with_capacity(self.rules.len());
        for compiled in &self.rules {
            let text = compiled.region.resolve(input);
            let matched = matches(&compiled.gate, text, input);
            let rule = &compiled.rule;
            evaluated.push(EvaluatedRule {
                id: rule.id.clone(),
                priority: rule.priority,
                region: rule.region.clone(),
                evidence: RuleEvidence {
                    contains: rule.gate.contains.clone(),
                    regex: rule.gate.regex.clone(),
                    line_regex: rule.gate.line_regex.clone(),
                    all_count: rule.gate.all.len(),
                    any_count: rule.gate.any.len(),
                    not_count: rule.gate.not.len(),
                    region_bytes: text.len(),
                    region_preview: bounded_preview(text),
                },
                state: rule.state.unwrap_or(State::Unknown).label(),
                matched,
            });
            if !matched {
                continue;
            }
            if winner.is_some_and(|current| current.rule.priority >= compiled.rule.priority) {
                continue;
            }
            winner = Some(compiled);
        }

        let Some(winner) = winner else {
            return fallback_explain(agent, Some(&self.manifest), evaluated);
        };
        let verdict = Verdict::from_rule(&winner.rule);
        Explain {
            agent: Some(agent.to_owned()),
            state: verdict.state.label(),
            manifest_source: Some("bundled".to_owned()),
            manifest_version: self.manifest.version.clone(),
            matched_rule: Some(MatchedRule {
                id: winner.rule.id.clone(),
                priority: winner.rule.priority,
                region: winner.rule.region.clone(),
                state: verdict.state.label(),
            }),
            visible_idle: verdict.visible_idle,
            visible_blocker: verdict.visible_blocker,
            visible_working: verdict.visible_working,
            skip_state_update: verdict.skip_state_update,
            skipped_update_reason: verdict
                .skip_state_update
                .then(|| format!("matched_rule:{}", winner.rule.id)),
            fallback_reason: None,
            evaluated_rules: evaluated,
        }
    }
}

/// herdr `fallback_explain` for a known agent: plain idle, no visible flags.
#[must_use]
pub fn fallback_explain(
    agent: &str,
    manifest: Option<&Manifest>,
    evaluated_rules: Vec<EvaluatedRule>,
) -> Explain {
    Explain {
        agent: Some(agent.to_owned()),
        state: State::Idle.label(),
        manifest_source: manifest.map(|_| "bundled".to_owned()),
        manifest_version: manifest.and_then(|manifest| manifest.version.clone()),
        matched_rule: None,
        visible_idle: false,
        visible_blocker: false,
        visible_working: false,
        skip_state_update: false,
        skipped_update_reason: None,
        fallback_reason: Some(KNOWN_AGENT_IDLE_FALLBACK_REASON.to_owned()),
        evaluated_rules,
    }
}

/// herdr `explain_for_label` for a label the engine does not know.
#[must_use]
pub fn unknown_agent_explain(label: &str) -> Explain {
    Explain {
        agent: Some(label.to_owned()),
        state: State::Unknown.label(),
        manifest_source: None,
        manifest_version: None,
        matched_rule: None,
        visible_idle: false,
        visible_blocker: false,
        visible_working: false,
        skip_state_update: false,
        skipped_update_reason: None,
        fallback_reason: Some("unknown_agent".to_owned()),
        evaluated_rules: Vec::new(),
    }
}

/// herdr `bounded_preview`: the first 240 `char`s, with `...` appended when truncated.
fn bounded_preview(text: &str) -> String {
    const MAX_CHARS: usize = 240;
    let mut preview: String = text.chars().take(MAX_CHARS).collect();
    if text.chars().nth(MAX_CHARS).is_some() {
        preview.push_str("...");
    }
    preview
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::*;

    fn compiled(rules_toml: &str) -> CompiledManifest {
        let manifest = Manifest::parse(&format!("id = \"codex\"\nmin_engine_version = 3\n{rules_toml}"))
            .expect("valid manifest");
        CompiledManifest::new(manifest).expect("compiles")
    }

    fn screen(text: &str) -> Input {
        Input {
            screen: text.to_owned(),
            osc_title: String::new(),
            osc_progress: String::new(),
        }
    }

    #[test]
    fn the_highest_priority_match_wins_and_declaration_order_breaks_a_tie() {
        let manifest = compiled(
            "[[rules]]\nid = \"low\"\nstate = \"idle\"\npriority = 1\ncontains = [\"match\"]\n[[rules]]\nid \
             = \"high\"\nstate = \"working\"\npriority = 9\ncontains = [\"match\"]\n[[rules]]\nid = \
             \"tie\"\nstate = \"blocked\"\npriority = 9\ncontains = [\"match\"]\n",
        );
        let verdict = manifest.evaluate(&screen("match"));
        assert_eq!(verdict.matched_rule_id.as_deref(), Some("high"));
        assert_eq!(verdict.state, State::Working);
    }

    #[test]
    fn contains_is_case_folded_and_regex_is_not() {
        let manifest =
            compiled("[[rules]]\nid = \"c\"\nstate = \"idle\"\ncontains = [\"Esc To Interrupt\"]\n");
        assert!(
            manifest
                .evaluate(&screen("… esc to interrupt)"))
                .matched_rule_id
                .is_some()
        );
        let cased = compiled("[[rules]]\nid = \"r\"\nstate = \"idle\"\nregex = [\"Working\"]\n");
        assert!(cased.evaluate(&screen("working")).matched_rule_id.is_none());
    }

    #[test]
    fn line_regex_needs_one_matching_line_per_pattern() {
        let manifest =
            compiled("[[rules]]\nid = \"r\"\nstate = \"blocked\"\nline_regex = ['^\\s*❯', '^\\s*2\\.']\n");
        assert!(
            manifest
                .evaluate(&screen("❯ 1. yes\n  2. no"))
                .matched_rule_id
                .is_some()
        );
        // Both patterns must land, even if one line satisfies neither.
        assert!(manifest.evaluate(&screen("❯ 1. yes")).matched_rule_id.is_none());
    }

    #[test]
    fn a_not_arm_vetoes() {
        let manifest = compiled(
            "[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"prompt\"]\nnot = [{ contains = \
             [\"blocked\"] }]\n",
        );
        assert!(manifest.evaluate(&screen("a prompt")).matched_rule_id.is_some());
        assert!(
            manifest
                .evaluate(&screen("a prompt, blocked"))
                .matched_rule_id
                .is_none()
        );
    }

    #[test]
    fn an_empty_any_is_no_constraint_but_a_populated_one_needs_a_hit() {
        let manifest = compiled(
            "[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"x\"]\nany = [{ contains = [\"a\"] }, { \
             contains = [\"b\"] }]\n",
        );
        assert!(manifest.evaluate(&screen("x a")).matched_rule_id.is_some());
        assert!(manifest.evaluate(&screen("x b")).matched_rule_id.is_some());
        assert!(manifest.evaluate(&screen("x c")).matched_rule_id.is_none());
    }

    #[test]
    fn the_visible_flags_are_honoured_only_when_the_state_agrees() {
        let manifest = compiled(
            "[[rules]]\nid = \"r\"\nstate = \"working\"\nvisible_idle = true\nvisible_working = \
             true\ncontains = [\"x\"]\n",
        );
        let verdict = manifest.evaluate(&screen("x"));
        assert!(verdict.visible_working);
        assert!(
            !verdict.visible_idle,
            "an idle flag on a working rule claims nothing"
        );
    }

    #[test]
    fn no_match_is_the_known_agent_idle_fallback() {
        let manifest = compiled("[[rules]]\nid = \"r\"\nstate = \"working\"\ncontains = [\"x\"]\n");
        let verdict = manifest.evaluate(&screen("nothing here"));
        assert_eq!(verdict.state, State::Idle);
        assert!(verdict.matched_rule_id.is_none());
        assert_eq!(
            verdict.fallback_reason.as_deref(),
            Some(KNOWN_AGENT_IDLE_FALLBACK_REASON)
        );
    }

    #[test]
    fn a_gate_may_read_its_own_region() {
        // The veto lives BELOW the last rule; the rule's own region is the box body ABOVE it.
        // Upstream cannot express this, and the veto it wrote was therefore dead code.
        let manifest = compiled(
            "[[rules]]\nid = \"caret\"\nstate = \"idle\"\nregion = \"prompt_box_body\"\nline_regex = \
             ['^\\s*❯']\nnot = [{ region = \"after_last_horizontal_rule\", contains = [\"esc to cancel\"] \
             }]\n",
        );
        let dialog = "───\n❯ 1. yes\n───\nesc to cancel\n";
        assert!(manifest.evaluate(&screen(dialog)).matched_rule_id.is_none());
        let bare = "───\n❯ ask me\n───\n";
        assert_eq!(
            manifest.evaluate(&screen(bare)).matched_rule_id.as_deref(),
            Some("caret")
        );
    }

    #[test]
    fn explain_reports_every_rule_with_its_region_size() {
        let manifest = compiled(
            "[[rules]]\nid = \"a\"\nstate = \"idle\"\ncontains = [\"x\"]\n[[rules]]\nid = \"b\"\nstate = \
             \"working\"\nregion = \"osc_title\"\ncontains = [\"y\"]\n",
        );
        let explain = manifest.explain("codex", &screen("xx"));
        assert_eq!(explain.evaluated_rules.len(), 2);
        assert_eq!(explain.evaluated_rules[0].evidence.region_bytes, 2);
        assert!(explain.evaluated_rules[0].matched);
        // The OSC rule read an empty title, not the screen.
        assert_eq!(explain.evaluated_rules[1].evidence.region_bytes, 0);
        assert!(!explain.evaluated_rules[1].matched);
        assert_eq!(explain.matched_rule.map(|rule| rule.id), Some("a".to_owned()));
    }

    #[test]
    fn a_preview_is_bounded_at_240_chars() {
        assert_eq!(bounded_preview("abc"), "abc");
        let long = "é".repeat(300);
        let preview = bounded_preview(&long);
        assert_eq!(preview.chars().count(), 243);
        assert!(preview.ends_with("..."));
        // Exactly 240 is not truncated.
        assert_eq!(bounded_preview(&"a".repeat(240)).len(), 240);
    }
}
