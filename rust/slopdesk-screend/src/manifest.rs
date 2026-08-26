//! One agent's detection manifest: the TOML schema, and the validation that rejects a bad one
//! WHOLE rather than dropping a rule.
//!
//! Ported from Swift `AgentManifest` + `TOMLSubsetParser`. The parser went with it: hand-writing
//! a TOML subset was only ever a consequence of Swift having no TOML in its standard library,
//! and a hand-rolled subset is a place for a manifest to mean something slightly different from
//! what upstream's `toml` crate reads in the same file. This end reads them with that crate.

use serde::Deserialize;

use crate::region::Region;

/// `top_non_empty_lines(n)` requires a manifest declaring at least this engine version.
pub const TOP_NON_EMPTY_LINES_ENGINE_VERSION: u32 = 3;
/// A gate naming its OWN region requires at least this engine version — engine 2 ignores the
/// key silently, and silently ignoring a VETO is how a rule fires on the screen it was written
/// to skip.
pub const GATE_REGION_ENGINE_VERSION: u32 = 3;

/// Limits, herdr's constants exactly.
pub const MAX_RULES_PER_MANIFEST: usize = 128;
/// Deepest nesting of `all`/`any`/`not` gates.
pub const MAX_GATE_DEPTH: usize = 8;
/// Gates in one manifest, counted across every rule.
pub const MAX_TOTAL_GATES: usize = 512;
/// `contains` + `regex` + `line_regex` entries in ONE gate.
pub const MAX_MATCHERS_PER_GATE: usize = 32;
/// The same, summed over the manifest.
pub const MAX_TOTAL_MATCHERS: usize = 1024;
/// Characters (not bytes) in one matcher.
pub const MAX_MATCHER_CHARS: usize = 512;

/// The four-way state a rule resolves to (herdr `AgentState`).
///
/// The wire crate's, because the state a rule resolves to is the state that CROSSES — a client
/// reading a verdict needs the same four names, and its `lowercase` serde spelling is the TOML
/// spelling too, so one derive serves the manifest this module parses and the reply screend
/// answers with. Re-exported rather than imported at every use site: this module is where the
/// schema is, and the schema still names it.
pub use slopdesk_screenwire::State;

/// Anything that makes a manifest unusable. One variant, because the caller's only choice is to
/// reject the file — a partially-loaded rule ladder is a ladder with a rung missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationError {
    /// Human-readable reason, logged and shown by the gate scripts.
    pub message: String,
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ValidationError {}

fn invalid(message: impl Into<String>) -> ValidationError {
    ValidationError {
        message: message.into(),
    }
}

/// One nested gate. A rule's own matcher fields form its implicit top-level gate.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Gate {
    /// Every nested gate must match.
    #[serde(default)]
    pub all: Vec<Self>,
    /// At least one nested gate must match (an empty list is no constraint).
    #[serde(default)]
    pub any: Vec<Self>,
    /// Any nested gate matching VETOES this gate.
    #[serde(default)]
    pub not: Vec<Self>,
    /// Case-folded substrings; ALL must be present.
    #[serde(default)]
    pub contains: Vec<String>,
    /// Patterns matched against the whole region; ALL must match.
    #[serde(default)]
    pub regex: Vec<String>,
    /// Patterns matched per line; each must match at least one line.
    #[serde(default)]
    pub line_regex: Vec<String>,
    /// ⚠️ OURS, not herdr's (2026-08-11). When set, this gate and everything under it evaluate
    /// against THIS region instead of the rule's. `None` = inherit, which is what every ported
    /// rule still does. `docs/50` §9 has the whole argument.
    #[serde(default)]
    pub region: Option<String>,
}

impl Gate {
    /// A gate that can only ever veto is not evidence — every `all`/`any` arm needs one of these.
    #[must_use]
    pub const fn has_positive_matcher(&self) -> bool {
        !self.contains.is_empty()
            || !self.regex.is_empty()
            || !self.line_regex.is_empty()
            || !self.all.is_empty()
            || !self.any.is_empty()
    }

    /// A `not` arm may be built purely of nested `not`s, but never be totally empty.
    #[must_use]
    pub const fn has_any_matcher(&self) -> bool {
        self.has_positive_matcher() || !self.not.is_empty()
    }

    const fn matcher_count(&self) -> usize {
        self.contains.len() + self.regex.len() + self.line_regex.len()
    }

    fn matchers(&self) -> impl Iterator<Item = &String> {
        self.contains.iter().chain(&self.regex).chain(&self.line_regex)
    }

    fn patterns(&self) -> impl Iterator<Item = &String> {
        self.regex.iter().chain(&self.line_regex)
    }
}

/// One rule: a gate, plus what a match MEANS.
///
/// Deserialised through [`RawRule`] rather than with `#[serde(flatten)]`, because flattening is
/// mutually exclusive with `deny_unknown_fields` — and strictness is the point: an unknown rule
/// key is a manifest that means something the engine will not do.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(from = "RawRule")]
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent claims a manifest makes; packing them would need a second name each"
)]
pub struct Rule {
    /// Stable identifier, reported as the winner and named by `DIVERGED_RULES`.
    pub id: String,
    /// The verdict on a match. Absent means [`State::Unknown`].
    pub state: Option<State>,
    /// Higher wins; first-declared wins a tie.
    pub priority: i32,
    /// Which slice of the screen the gate reads.
    pub region: String,
    /// The screen literally shows an idle prompt box.
    pub visible_idle: bool,
    /// The screen literally shows a live blocker form.
    pub visible_blocker: bool,
    /// The screen literally shows a live spinner.
    pub visible_working: bool,
    /// A FREEZE rule: publish nothing and let the machine hold its previous status.
    pub skip_state_update: bool,
    /// The rule's own matcher fields, which are its implicit top-level gate.
    ///
    /// ⚠️ `region` is deliberately NOT copied down here — it belongs to the RULE and is
    /// INHERITED. Stamping the root gate with an override identical to what it already has
    /// would re-resolve the region text on every evaluation and make every rule look like it
    /// uses the cross-region feature.
    pub gate: Gate,
}

/// The rule table exactly as it appears in TOML: the rule's own keys and its gate's, side by
/// side and all rejected-if-unknown.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
#[expect(clippy::struct_excessive_bools, reason = "the TOML keys, one field each")]
struct RawRule {
    id: String,
    #[serde(default)]
    state: Option<State>,
    #[serde(default)]
    priority: i32,
    #[serde(default = "default_region")]
    region: String,
    #[serde(default)]
    visible_idle: bool,
    #[serde(default)]
    visible_blocker: bool,
    #[serde(default)]
    visible_working: bool,
    #[serde(default)]
    skip_state_update: bool,
    #[serde(default)]
    all: Vec<Gate>,
    #[serde(default)]
    any: Vec<Gate>,
    #[serde(default)]
    not: Vec<Gate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

impl From<RawRule> for Rule {
    fn from(raw: RawRule) -> Self {
        Self {
            id: raw.id,
            state: raw.state,
            priority: raw.priority,
            region: raw.region,
            visible_idle: raw.visible_idle,
            visible_blocker: raw.visible_blocker,
            visible_working: raw.visible_working,
            skip_state_update: raw.skip_state_update,
            gate: Gate {
                all: raw.all,
                any: raw.any,
                not: raw.not,
                contains: raw.contains,
                regex: raw.regex,
                line_regex: raw.line_regex,
                region: None,
            },
        }
    }
}

fn default_region() -> String {
    "whole_recent".to_owned()
}

/// One agent's parsed, validated manifest.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// The agent label this manifest detects.
    pub id: String,
    /// Dotted-numeric manifest version, reported by `explain`.
    #[serde(default)]
    pub version: Option<String>,
    /// The engine version the manifest requires. Absent = no requirement.
    #[serde(default)]
    pub min_engine_version: Option<u32>,
    /// Upstream's edit stamp. Parsed only so an unknown-field check cannot reject it.
    #[serde(default)]
    pub updated_at: Option<String>,
    /// Alternate labels upstream recognises. Carried for fidelity; lookup is by [`Manifest::id`].
    #[serde(default)]
    pub aliases: Vec<String>,
    /// The rule ladder, in declaration order (which is the tie-break).
    #[serde(default)]
    pub rules: Vec<Rule>,
}

impl Manifest {
    /// Parses and validates one manifest document.
    ///
    /// Strict at every level: an unknown key, a wrong type, an invalid region, an uncompilable
    /// pattern or an exceeded limit rejects the WHOLE manifest. A rule ladder is a precedence
    /// order — dropping the rung that failed to parse silently promotes the one below it.
    ///
    /// # Errors
    /// [`ValidationError`] with the first problem found.
    pub fn parse(text: &str) -> Result<Self, ValidationError> {
        let manifest: Self = toml::from_str(text).map_err(|error| invalid(error.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// herdr `ManifestVersion::parse`: every `.`-separated segment non-empty and all digits.
    #[must_use]
    pub fn is_valid_version(text: &str) -> bool {
        let trimmed = text.trim();
        !trimmed.is_empty()
            && trimmed
                .split('.')
                .all(|segment| !segment.is_empty() && segment.parse::<u64>().is_ok())
    }

    /// herdr `validate_manifest`, exact.
    ///
    /// # Errors
    /// [`ValidationError`] with the first problem found.
    pub fn validate(&self) -> Result<(), ValidationError> {
        if let Some(version) = &self.version
            && !Self::is_valid_version(version)
        {
            return Err(invalid("invalid version"));
        }
        if self.rules.is_empty() {
            return Err(invalid("manifest has no rules"));
        }
        if self.rules.len() > MAX_RULES_PER_MANIFEST {
            return Err(invalid("too many rules"));
        }
        let mut budget = Budget::default();
        for rule in &self.rules {
            self.validate_rule(rule, &mut budget)?;
        }
        Ok(())
    }

    fn validate_rule(&self, rule: &Rule, budget: &mut Budget) -> Result<(), ValidationError> {
        if rule.id.trim().is_empty() {
            return Err(invalid("rule with empty id"));
        }
        if rule.skip_state_update {
            if rule.state != Some(State::Unknown) {
                return Err(invalid("skip_state_update rule must declare state = \"unknown\""));
            }
            if rule.visible_idle || rule.visible_blocker || rule.visible_working {
                return Err(invalid("skip_state_update rule must not set visible flags"));
            }
        }
        let spec = rule.region.trim();
        if Region::parse(spec).is_none() {
            return Err(invalid(format!("invalid region '{spec}'")));
        }
        if Region::is_top_non_empty_lines(spec)
            && self
                .min_engine_version
                .is_some_and(|declared| declared < TOP_NON_EMPTY_LINES_ENGINE_VERSION)
        {
            return Err(invalid("top_non_empty_lines requires min_engine_version >= 3"));
        }
        if !rule.gate.has_positive_matcher() {
            return Err(invalid(format!(
                "rule '{}' must contain a positive matcher",
                rule.id
            )));
        }
        self.validate_gate(&rule.gate, 0, budget)
    }

    /// One gate and everything under it.
    ///
    /// Upstream writes this twice — once for positive arms, once for `not` arms — because the two
    /// differ in what an EMPTY nested gate may be. That difference is a predicate applied at the
    /// two recursion sites below (`has_positive_matcher` vs `has_any_matcher`), so the body that
    /// counts gates, matchers and depth is written once.
    fn validate_gate(&self, gate: &Gate, depth: usize, budget: &mut Budget) -> Result<(), ValidationError> {
        if depth > MAX_GATE_DEPTH {
            return Err(invalid("gate nesting too deep"));
        }
        self.validate_gate_region(gate)?;
        budget.gates += 1;
        if budget.gates > MAX_TOTAL_GATES {
            return Err(invalid("too many gates"));
        }
        let count = gate.matcher_count();
        if count > MAX_MATCHERS_PER_GATE {
            return Err(invalid("too many matchers in one gate"));
        }
        budget.matchers += count;
        if budget.matchers > MAX_TOTAL_MATCHERS {
            return Err(invalid("too many matchers"));
        }
        for matcher in gate.matchers() {
            if matcher.chars().count() > MAX_MATCHER_CHARS {
                return Err(invalid("matcher too long"));
            }
        }
        for pattern in gate.patterns() {
            if regex::Regex::new(pattern).is_err() {
                return Err(invalid(format!("invalid regex '{pattern}'")));
            }
        }
        for nested in gate.all.iter().chain(&gate.any) {
            if !nested.has_positive_matcher() {
                return Err(invalid("nested gate must contain a positive matcher"));
            }
            self.validate_gate(nested, depth + 1, budget)?;
        }
        for nested in &gate.not {
            if !nested.has_any_matcher() {
                return Err(invalid("not-gate must contain a matcher"));
            }
            self.validate_gate(nested, depth + 1, budget)?;
        }
        Ok(())
    }

    /// A gate naming its own region must name a REAL one — same strictness as a rule's, so a
    /// typo rejects the manifest instead of quietly inheriting and under-matching — and the
    /// manifest must declare an engine that honours the key.
    fn validate_gate_region(&self, gate: &Gate) -> Result<(), ValidationError> {
        let Some(spec) = gate.region.as_deref().map(str::trim) else {
            return Ok(());
        };
        if Region::parse(spec).is_none() {
            return Err(invalid(format!("invalid gate region '{spec}'")));
        }
        if self
            .min_engine_version
            .is_some_and(|declared| declared < GATE_REGION_ENGINE_VERSION)
        {
            return Err(invalid("gate region requires min_engine_version >= 3"));
        }
        if Region::is_top_non_empty_lines(spec)
            && self
                .min_engine_version
                .is_some_and(|declared| declared < TOP_NON_EMPTY_LINES_ENGINE_VERSION)
        {
            return Err(invalid("top_non_empty_lines requires min_engine_version >= 3"));
        }
        Ok(())
    }
}

/// Manifest-wide counters the limits are checked against.
#[derive(Debug, Default)]
struct Budget {
    gates: usize,
    matchers: usize,
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::*;

    const HEAD: &str = "id = \"codex\"\n";

    #[test]
    fn a_minimal_manifest_parses() {
        let manifest = Manifest::parse(&format!(
            "{HEAD}[[rules]]\nid = \"r\"\nstate = \"working\"\ncontains = [\"x\"]\n"
        ))
        .expect("valid");
        assert_eq!(manifest.id, "codex");
        assert_eq!(manifest.rules.len(), 1);
        assert_eq!(manifest.rules[0].state, Some(State::Working));
        // The default region, applied where the file said nothing.
        assert_eq!(manifest.rules[0].region, "whole_recent");
        assert_eq!(manifest.rules[0].priority, 0);
    }

    #[test]
    fn an_unknown_key_rejects_the_whole_manifest() {
        for body in [
            "wat = 1\n[[rules]]\nid = \"r\"\ncontains = [\"x\"]\n",
            "[[rules]]\nid = \"r\"\nwat = 1\ncontains = [\"x\"]\n",
            "[[rules]]\nid = \"r\"\ncontains = [\"x\"]\nnot = [{ wat = 1 }]\n",
        ] {
            assert!(Manifest::parse(&format!("{HEAD}{body}")).is_err(), "{body}");
        }
    }

    #[test]
    fn a_rule_needs_evidence_not_just_a_veto() {
        assert!(
            Manifest::parse(&format!(
                "{HEAD}[[rules]]\nid = \"r\"\nnot = [{{ contains = [\"x\"] }}]\n"
            ))
            .is_err()
        );
        // …but a `not` arm may itself be built purely of nested `not`s.
        assert!(
            Manifest::parse(&format!(
                "{HEAD}[[rules]]\nid = \"r\"\ncontains = [\"y\"]\nnot = [{{ not = [{{ contains = [\"x\"] \
                 }}] }}]\n"
            ))
            .is_ok()
        );
    }

    #[test]
    fn a_freeze_rule_must_declare_unknown_and_no_visible_flags() {
        let ok = format!(
            "{HEAD}[[rules]]\nid = \"r\"\nstate = \"unknown\"\nskip_state_update = true\ncontains = \
             [\"x\"]\n"
        );
        assert!(Manifest::parse(&ok).is_ok());
        let wrong_state = format!(
            "{HEAD}[[rules]]\nid = \"r\"\nstate = \"idle\"\nskip_state_update = true\ncontains = [\"x\"]\n"
        );
        assert!(Manifest::parse(&wrong_state).is_err());
        let visible = format!(
            "{HEAD}[[rules]]\nid = \"r\"\nstate = \"unknown\"\nskip_state_update = true\nvisible_idle = \
             true\ncontains = [\"x\"]\n"
        );
        assert!(Manifest::parse(&visible).is_err());
    }

    #[test]
    fn an_invalid_region_or_regex_rejects_the_manifest() {
        assert!(
            Manifest::parse(&format!(
                "{HEAD}[[rules]]\nid = \"r\"\nregion = \"nope\"\ncontains = [\"x\"]\n"
            ))
            .is_err()
        );
        assert!(Manifest::parse(&format!("{HEAD}[[rules]]\nid = \"r\"\nregex = [\"(\"]\n")).is_err());
    }

    #[test]
    fn a_gate_region_is_validated_and_gated_on_engine_three() {
        let body = "[[rules]]\nid = \"r\"\ncontains = [\"x\"]\nnot = [{ region = \
                    \"after_last_horizontal_rule\", contains = [\"esc\"] }]\n";
        assert!(Manifest::parse(&format!("{HEAD}min_engine_version = 3\n{body}")).is_ok());
        // Engine 2 would IGNORE the key, so a manifest that needs it must say so.
        assert!(Manifest::parse(&format!("{HEAD}min_engine_version = 2\n{body}")).is_err());
        // A typo'd region is a rejection, not a silent inherit.
        let typo = "[[rules]]\nid = \"r\"\ncontains = [\"x\"]\nnot = [{ region = \"nope\", contains = \
                    [\"esc\"] }]\n";
        assert!(Manifest::parse(&format!("{HEAD}min_engine_version = 3\n{typo}")).is_err());
    }

    #[test]
    fn top_non_empty_lines_needs_engine_three_on_a_rule_and_on_a_gate() {
        let rule = "[[rules]]\nid = \"r\"\nregion = \"top_non_empty_lines(2)\"\ncontains = [\"x\"]\n";
        assert!(Manifest::parse(&format!("{HEAD}min_engine_version = 3\n{rule}")).is_ok());
        assert!(Manifest::parse(&format!("{HEAD}min_engine_version = 1\n{rule}")).is_err());
        // No declaration at all = no requirement, exactly as upstream.
        assert!(Manifest::parse(&format!("{HEAD}{rule}")).is_ok());
    }

    #[test]
    fn the_limits_are_enforced() {
        let deep = (0..MAX_GATE_DEPTH + 2).fold("contains = [\"x\"]".to_owned(), |inner, _| {
            format!("all = [{{ {inner} }}]")
        });
        assert!(Manifest::parse(&format!("{HEAD}[[rules]]\nid = \"r\"\n{deep}\n")).is_err());

        let long = "y".repeat(MAX_MATCHER_CHARS + 1);
        assert!(Manifest::parse(&format!("{HEAD}[[rules]]\nid = \"r\"\ncontains = [\"{long}\"]\n")).is_err());

        let wide: Vec<String> = (0..=MAX_MATCHERS_PER_GATE)
            .map(|index| format!("\"n{index}\""))
            .collect();
        assert!(
            Manifest::parse(&format!(
                "{HEAD}[[rules]]\nid = \"r\"\ncontains = [{}]\n",
                wide.join(", ")
            ))
            .is_err()
        );

        let mut rules = String::new();
        for index in 0..=MAX_RULES_PER_MANIFEST {
            rules.push_str("[[rules]]\nid = \"r");
            rules.push_str(&index.to_string());
            rules.push_str("\"\ncontains = [\"x\"]\n");
        }
        assert!(Manifest::parse(&format!("{HEAD}{rules}")).is_err());
    }

    #[test]
    fn an_empty_manifest_is_not_a_manifest() {
        assert!(Manifest::parse(HEAD).is_err());
        assert!(Manifest::parse(&format!("{HEAD}[[rules]]\nid = \"  \"\ncontains = [\"x\"]\n")).is_err());
    }

    #[test]
    fn a_version_must_be_dotted_numeric() {
        assert!(Manifest::is_valid_version("2026.08.11.1"));
        assert!(Manifest::is_valid_version("1"));
        assert!(!Manifest::is_valid_version(""));
        assert!(!Manifest::is_valid_version("1."));
        assert!(!Manifest::is_valid_version("1.x"));
        assert!(
            Manifest::parse(&format!(
                "{HEAD}version = \"1.x\"\n[[rules]]\nid = \"r\"\ncontains = [\"x\"]\n"
            ))
            .is_err()
        );
    }
}
