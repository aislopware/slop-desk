//! Differential parity harness: the REAL herdr binary vs `SlopDesk`'s ported detect engine.
//!
//! Runs `herdr agent explain --file … --json` (upstream's own debug oracle, exercising its actual
//! rule engine end-to-end) next to `slopdesk-screend explain` on a deterministic generated corpus,
//! and diffs the full evaluation traces: final state, winner rule, visible flags, skip/fallback
//! reasons, and — per evaluated rule — matched flag, region byte length, and region preview. Any
//! divergence in a region resolver, gate evaluation, priority tie-break, or fallback shows up as a
//! field-level mismatch.
//!
//! ⚠️ Parity is no longer the goal everywhere: the rules in `DIVERGED_RULES` are deliberately
//! better than upstream. Divergence is scoped to the RULE, not the agent — every other rule of a
//! diverged agent stays under parity, because "we improved one rule" must not silently retire the
//! guard on the twenty we did not touch. Read that list.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use rayon::prelude::{IntoParallelRefIterator, ParallelIterator};
use serde_json::{Map, Value};

use crate::manifests::AGENTS;
use crate::rng::Rng;

/// ⚠️ DELIBERATE DIVERGENCE — these RULES are no longer under parity, by user decision
/// (2026-08-11: "không cần parity với herdr nữa, cứ làm thế nào ngon hơn herdr là được").
///
/// Scoped to the rule ID, NOT the agent. Excluding the whole `claude` label (as this harness
/// briefly did) drops the guard on every claude rule we did NOT touch — `bash_permission_prompt`,
/// `generic_permission_prompt`, `dynamic_workflow_prompt`, `model_picker_menu`,
/// `btw_overlay_working` — and those are ordinary ports with nothing else pinning them.
///
/// `live_prompt_box`: herdr's calls a mid-repaint `AskUserQuestion` dialog an IDLE prompt box with
/// `visible_idle` — its five footer needles are dead code, because a `not` gate is evaluated
/// against the rule's own region and the footer lives outside `prompt_box_body` by construction.
/// Ours vetoes on the footer via a CROSS-REGION nested gate (a capability herdr has no syntax for)
/// and on the option list, so it survives an erase-then-rewrite.
/// `legacy_no_prompt_blocker`: ours declares `visible_blocker`, so the screen tier can corroborate
/// a hook block instead of only ever contradicting it.
/// See `docs/50-agent-detection-architecture.md` §8 and `ManifestCrossRegionGateTests`.
///
/// Adding an id here needs a written reason above it; the harness is worth nothing if this set
/// grows silently.
pub const DIVERGED_RULES: [(&str, &[&str]); 1] =
    [("claude", &["live_prompt_box", "legacy_no_prompt_blocker"])];

/// Top-level keys that differ BY CONSTRUCTION once a manifest is edited at all, and carry no
/// behavioural meaning — ignored for an agent that has any diverged rule.
const VERSION_KEYS: [&str; 1] = ["manifest_version"];

/// Top-level keys that describe the WINNER. They are ignored only when a diverged rule is the one
/// that explains the difference (see [`attributable_to_diverged`]).
const OUTCOME_KEYS: [&str; 8] = [
    "state",
    "matched_rule",
    "visible_idle",
    "visible_blocker",
    "visible_working",
    "skip_state_update",
    "skipped_update_reason",
    "fallback_reason",
];

/// Keys we compare (our CLI's full output). herdr's extra keys (remote-update status etc.) are
/// outside the ported scope and ignored.
const COMPARED_KEYS: [&str; 12] = [
    "agent",
    "state",
    "manifest_source",
    "manifest_version",
    "matched_rule",
    "visible_idle",
    "visible_blocker",
    "visible_working",
    "skip_state_update",
    "skipped_update_reason",
    "fallback_reason",
    "evaluated_rules",
];

/// The per-rule evidence fields, which are where a region resolver's mistake surfaces.
const EVIDENCE_KEYS: [&str; 8] = [
    "contains",
    "regex",
    "line_regex",
    "all_count",
    "any_count",
    "not_count",
    "region_bytes",
    "region_preview",
];

/// The per-rule trace fields outside `evidence`.
const RULE_KEYS: [&str; 5] = ["id", "priority", "region", "state", "matched"];

/// Long enough to be a prompt-box rule's horizontal rule on any terminal this ships to.
const HRULE: &str = "────────────────────────────────────────";

/// Scripts that exercise the case-folding, normalisation and range decisions the rules make.
const UNICODE_SALAD: [&str; 5] = [
    "ΟΔΥΣΣΕΥΣ σ ς Σ",        // Greek incl. final sigma (case-fold divergence probe)
    "İstanbul ı I i ß ẞ ﬀ",  // Turkish dotted/dotless I, sharp s, ligature
    "é combining ñ",         // combining marks
    "日本語テキスト 🚀🎉 �", // CJK + emoji + replacement char
    "⠀⡇⣿ braille",           // braille range used by spinner rules
];

/// The filler a generated screen is padded with — terminal-ish, and deliberately dull.
const NOISE_WORDS: [&str; 8] = ["make", "test", "ok", "error", "$", "λ", "..", "run"];

/// The rules deliberately not under parity for one agent.
fn diverged_for(label: &str) -> &'static [&'static str] {
    DIVERGED_RULES
        .iter()
        .find(|(agent, _)| *agent == label)
        .map_or(&[], |(_, rules)| *rules)
}

/// Every agent label, in herdr's bundled-manifest order.
#[must_use]
pub fn agent_labels() -> Vec<&'static str> {
    AGENTS.iter().map(|(_, label)| *label).collect()
}

/// All quoted string literals in the manifest — contains needles, regex sources, alias labels.
///
/// Raw regex text doubles as fuzz material for its own rule.
#[must_use]
pub fn harvest_fragments(toml_text: &str) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    // Single-quoted first, then double-quoted, which is the order the corpus was generated in
    // when the harness was Python — the screens are indexed by position downstream, so the two
    // passes stay separate rather than becoming one alternation.
    collect_quoted(toml_text, '\'', false, &mut found);
    collect_quoted(toml_text, '"', true, &mut found);

    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut out: Vec<String> = Vec::new();
    for fragment in &found {
        let width = fragment.chars().count();
        if (1..=200).contains(&width) && seen.insert(fragment.as_str()) {
            out.push(fragment.clone());
        }
    }
    out
}

/// Every run of characters between two `quote`s on ONE line, optionally refusing a backslash.
///
/// A hand scan rather than a regex because the two passes differ only in whether a backslash may
/// appear inside — and because TOML's own quoting means a literal never spans a newline here.
fn collect_quoted(text: &str, quote: char, refuse_escape: bool, out: &mut Vec<String>) {
    for line in text.lines() {
        let mut rest = line;
        while let Some(open) = rest.find(quote) {
            let after = rest.get(open + quote.len_utf8()..).unwrap_or("");
            let Some(close) = after.find(quote) else {
                break;
            };
            let body = after.get(..close).unwrap_or("");
            if !body.is_empty() && (!refuse_escape || !body.contains('\\')) {
                out.push(body.to_owned());
            }
            rest = after.get(close + quote.len_utf8()..).unwrap_or("");
        }
    }
}

/// Deterministic screen corpus around one agent's manifest vocabulary.
#[must_use]
pub fn screens_for_agent(fragments: &[String], rng: &mut Rng) -> Vec<String> {
    let mut screens: Vec<String> = Vec::new();
    for fragment in fragments {
        screens.push(fragment.clone());
        let (before, after) = (noise(rng), noise(rng));
        screens.push(format!("{before}\n{fragment}\n{after}"));
        screens.push(fragment.to_uppercase());
        screens.push(format!("prefix {fragment} suffix"));
    }
    let fallback = vec!["fallback".to_owned()];
    let pool: &[String] = if fragments.is_empty() {
        &fallback
    } else {
        fragments
    };

    for _ in 0..12 {
        let first = rng.choice(pool).cloned().unwrap_or_default();
        let second = rng.choice(pool).cloned().unwrap_or_default();
        let filler = noise(rng);
        screens.push(format!("{first}\n{filler}\n{second}"));
    }
    for fragment in pool.iter().take(6) {
        screens.push(format!(
            "{}\n{HRULE}\n{fragment}\n{HRULE}\n{}",
            noise(rng),
            noise(rng)
        )); // prompt box
        screens.push(format!("{fragment}\n{HRULE}\n› {}", noise(rng))); // codex prompt
        screens.push(format!("• {}\n✗ failed\n› {fragment}\n✓ done", noise(rng))); // codex markers
        screens.push(format!("✳ Cooking…\n⡇ {fragment}")); // claude chrome
    }
    for fragment in pool.iter().take(4) {
        screens.push(format!("{fragment}\n"));
        screens.push(format!("{fragment}\n\n\n"));
        screens.push(if fragment.contains(' ') {
            fragment.replace(' ', "\r\n")
        } else {
            format!("{fragment}\r")
        });
        screens.push(format!("line one\r\n{fragment}\r\nline three\r"));
    }
    screens.extend(UNICODE_SALAD.iter().map(|line| (*line).to_owned()));
    screens.push(UNICODE_SALAD.join("\n"));
    screens.push(String::new());
    screens.push("\n\n\n".to_owned());
    screens.push("x".repeat(1500));
    screens.push((0..300).map(|_| noise(rng)).collect::<Vec<String>>().join("\n"));
    for _ in 0..8 {
        let lines = rng.between(1, 20);
        screens.push((0..lines).map(|_| noise(rng)).collect::<Vec<String>>().join("\n"));
    }
    screens
}

/// One to eight filler words.
fn noise(rng: &mut Rng) -> String {
    let words = rng.between(1, 8);
    (0..words)
        .map(|_| rng.choice(&NOISE_WORDS).copied().unwrap_or("ok"))
        .collect::<Vec<&str>>()
        .join(" ")
}

/// The comparable shape of one engine's answer: our keys, in our order, everything else dropped.
#[must_use]
pub fn project(doc: &Value) -> Value {
    let mut out = Map::new();
    for key in COMPARED_KEYS {
        out.insert(key.to_owned(), doc.get(key).cloned().unwrap_or(Value::Null));
    }
    let rules: Vec<Value> = doc
        .get("evaluated_rules")
        .and_then(Value::as_array)
        .map(|rules| {
            rules
                .iter()
                .map(|rule| {
                    let mut projected = Map::new();
                    for key in RULE_KEYS {
                        projected.insert(key.to_owned(), rule.get(key).cloned().unwrap_or(Value::Null));
                    }
                    let evidence = rule.get("evidence");
                    let mut fields = Map::new();
                    for key in EVIDENCE_KEYS {
                        fields.insert(
                            key.to_owned(),
                            evidence
                                .and_then(|held| held.get(key))
                                .cloned()
                                .unwrap_or(Value::Null),
                        );
                    }
                    projected.insert("evidence".to_owned(), Value::Object(fields));
                    Value::Object(projected)
                })
                .collect()
        })
        .unwrap_or_default();
    out.insert("evaluated_rules".to_owned(), Value::Array(rules));
    Value::Object(out)
}

/// The evaluated-rule trace keyed by id.
///
/// Both engines walk the same manifest rule list, but keying by id rather than position keeps one
/// extra or missing rule from smearing the whole diff.
fn rules_by_id(projected: &Value) -> BTreeMap<&str, &Value> {
    projected
        .get("evaluated_rules")
        .and_then(Value::as_array)
        .map(|rules| {
            rules
                .iter()
                .filter_map(|rule| {
                    let id = rule
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|id| !id.is_empty())?;
                    Some((id, rule))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The winning rule's id.
///
/// herdr reports `matched_rule` as the whole rule object on a hit and as null on a fallback, so
/// this normalises both shapes to an id or `None`.
fn winner_id(projected: &Value) -> Option<&str> {
    match projected.get("matched_rule") {
        Some(Value::Object(_)) => {
            projected
                .get("matched_rule")
                .and_then(|winner| winner.get("id"))
                .and_then(Value::as_str)
        },
        Some(Value::String(id)) => Some(id.as_str()),
        _ => None,
    }
}

/// TRUE when a DIVERGED rule is what explains an outcome difference.
///
/// It won on either side, or it matched on one side and not the other. A difference the diverged
/// rules cannot account for is a real regression somewhere else in the manifest, and must still
/// fail.
fn attributable_to_diverged(left: &Value, right: &Value, diverged: &[&str]) -> bool {
    let won = |side: &Value| winner_id(side).is_some_and(|id| diverged.contains(&id));
    if won(left) || won(right) {
        return true;
    }
    let (mine, yours) = (rules_by_id(left), rules_by_id(right));
    diverged.iter().any(|rule_id| {
        let matched =
            |side: &BTreeMap<&str, &Value>| side.get(rule_id).and_then(|rule| rule.get("matched")).cloned();
        matched(&mine) != matched(&yours)
    })
}

/// The field-level diff, minus whatever [`DIVERGED_RULES`] licenses. `None` on parity.
#[must_use]
pub fn diff(left: &Value, right: &Value, label: &str) -> Option<String> {
    let diverged = diverged_for(label);
    let mut excused: BTreeSet<&str> = BTreeSet::new();
    if !diverged.is_empty() {
        excused.extend(VERSION_KEYS);
        if attributable_to_diverged(left, right, diverged) {
            excused.extend(OUTCOME_KEYS);
        }
    }

    let null = Value::Null;
    let mut detail: Vec<String> = Vec::new();
    for key in COMPARED_KEYS {
        let mine = left.get(key).unwrap_or(&null);
        let yours = right.get(key).unwrap_or(&null);
        if excused.contains(key) || mine == yours {
            continue;
        }
        if key != "evaluated_rules" {
            detail.push(format!("  {key}: herdr={mine} slopdesk={yours}"));
            continue;
        }
        let (mine, yours) = (rules_by_id(left), rules_by_id(right));
        let every: BTreeSet<&str> = mine.keys().chain(yours.keys()).copied().collect();
        for rule_id in every {
            if diverged.contains(&rule_id) {
                continue; // this rule is deliberately not herdr's — see DIVERGED_RULES
            }
            let (mine, yours) = (mine.get(rule_id), yours.get(rule_id));
            if mine == yours {
                continue;
            }
            let render = |rule: Option<&&Value>| rule.map_or_else(|| "null".to_owned(), ToString::to_string);
            detail.push(format!(
                "  rule {rule_id}:\n    herdr: {}\n    slopdesk: {}",
                render(mine),
                render(yours)
            ));
        }
        // A rule EVALUATED on one side only is a divergence in the ladder itself, unless it is one
        // of ours. (Count, not just membership: the ladder short-circuits, so a length gap is real.)
        let live = |side: &BTreeMap<&str, &Value>| side.keys().filter(|id| !diverged.contains(*id)).count();
        let (mine, yours) = (live(&mine), live(&yours));
        if mine != yours {
            detail.push(format!("  rule count: herdr={mine} slopdesk={yours}"));
        }
    }
    if detail.is_empty() {
        None
    } else {
        Some(detail.join("\n"))
    }
}

/// Everything the harness needs that is not the tree.
#[derive(Debug)]
pub struct Options {
    /// The herdr checkout — its manifests are the corpus vocabulary, its binary is the oracle.
    pub herdr_dir: PathBuf,
    /// `herdr`, built release.
    pub herdr_bin: PathBuf,
    /// `slopdesk-screend`, whose `explain` subcommand is the ported engine's own oracle.
    pub port_bin: PathBuf,
    /// The seed the whole corpus is a function of.
    pub seed: u64,
    /// How many cases to have in flight.
    pub jobs: usize,
    /// How many mismatches to print in full.
    pub max_report: usize,
}

/// One case that disagreed, and how.
#[derive(Debug)]
pub struct Mismatch {
    /// The agent the case was explained as.
    pub label: String,
    /// The screen text, for the report's `screen=…` line.
    pub screen: String,
    /// The field-level detail.
    pub detail: String,
}

/// What a whole run found.
#[derive(Debug)]
pub struct Report {
    /// Distinct screens generated.
    pub screens: usize,
    /// Screens × agents actually run.
    pub cases: usize,
    /// The disagreements, in corpus order.
    pub mismatches: Vec<Mismatch>,
}

/// One case: which screen, explained as which agent.
#[derive(Debug)]
struct Case {
    screen: usize,
    label: &'static str,
}

/// Run the corpus through both engines.
///
/// # Errors
/// When either oracle is missing, when a manifest cannot be read, or when the scratch directory
/// cannot be made.
pub fn run(options: &Options, progress: &(dyn Fn(String) + Sync)) -> Result<Report, String> {
    if !options.herdr_bin.exists() {
        return Err(format!(
            "missing herdr oracle at {} — see docs/46-gates-env-paths.md for the build recipe",
            options.herdr_bin.display()
        ));
    }
    if !options.port_bin.exists() {
        return Err(format!(
            "missing {} — run `just screend` first",
            options.port_bin.display()
        ));
    }

    let scratch = std::env::temp_dir().join(format!("slopdesk-herdr-diff-{}", std::process::id()));
    let _ = fs::remove_dir_all(&scratch);
    for leaf in ["iso/config", "iso/state"] {
        fs::create_dir_all(scratch.join(leaf))
            .map_err(|error| format!("cannot make {}: {error}", scratch.display()))?;
    }
    let outcome = walk(options, &scratch, progress);
    let _ = fs::remove_dir_all(&scratch);
    outcome
}

/// The body of [`run`], so the scratch directory is removed on either exit.
fn walk(options: &Options, scratch: &Path, progress: &(dyn Fn(String) + Sync)) -> Result<Report, String> {
    let labels = agent_labels();
    for (label, rules) in DIVERGED_RULES {
        progress(format!(
            "⚠️  {label}: rules NOT under parity (deliberate): {}",
            rules.join(", ")
        ));
    }

    let mut rng = Rng::new(options.seed);
    let mut screens: Vec<String> = Vec::new();
    let mut cases: Vec<Case> = Vec::new();
    for (stem, label) in AGENTS {
        let manifest = options
            .herdr_dir
            .join("src/detect/manifests")
            .join(format!("{stem}.toml"));
        let toml_text = fs::read_to_string(&manifest)
            .map_err(|error| format!("cannot read {}: {error}", manifest.display()))?;
        let fragments = harvest_fragments(&toml_text);
        for screen in screens_for_agent(&fragments, &mut rng) {
            let others: Vec<&'static str> = {
                let pool: Vec<&'static str> =
                    labels.iter().copied().filter(|other| *other != label).collect();
                rng.sample(&pool, 2)
            };
            let at = screens.len();
            screens.push(screen);
            cases.push(Case { screen: at, label });
            cases.extend(others.into_iter().map(|other| {
                Case {
                    screen: at,
                    label: other,
                }
            }));
        }
    }
    // Unknown-label handling parity.
    let probe = screens.len();
    screens.push("plain shell prompt $\n".to_owned());
    cases.push(Case {
        screen: probe,
        label: "not-an-agent",
    });

    for (at, screen) in screens.iter().enumerate() {
        let path = scratch.join(format!("case-{at}.txt"));
        fs::write(&path, screen).map_err(|error| format!("cannot write {}: {error}", path.display()))?;
    }
    progress(format!(
        "{} screens × up to own+2 agents = {} differential cases",
        screens.len(),
        cases.len()
    ));

    let iso = scratch.join("iso");
    let env: Vec<(&str, String)> = vec![
        ("PATH", "/usr/bin:/bin".to_owned()),
        ("HOME", iso.display().to_string()),
        ("XDG_CONFIG_HOME", iso.join("config").display().to_string()),
        ("XDG_STATE_HOME", iso.join("state").display().to_string()),
    ];

    let done = AtomicUsize::new(0);
    let total = cases.len();
    let judge = |case: &Case| -> Option<Mismatch> {
        let path = scratch.join(format!("case-{}.txt", case.screen));
        let verdict = run_case(options, &env, &path, case.label);
        let seen = done.fetch_add(1, Ordering::Relaxed) + 1;
        if seen.is_multiple_of(1000) {
            progress(format!("  {seen}/{total}…"));
        }
        verdict.map(|detail| {
            Mismatch {
                label: case.label.to_owned(),
                screen: screens.get(case.screen).cloned().unwrap_or_default(),
                detail,
            }
        })
    };

    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(options.jobs.max(1))
        .build()
        .map_err(|error| format!("cannot start {} workers: {error}", options.jobs))?;
    // `par_iter` keeps the results in CORPUS order, which the Python's `as_completed` did not:
    // the first twelve mismatches printed are now the same twelve on every run.
    let mismatches: Vec<Mismatch> = pool.install(|| cases.par_iter().filter_map(judge).collect());

    Ok(Report {
        screens: screens.len(),
        cases: total,
        mismatches,
    })
}

/// One screen through both engines.
fn run_case(options: &Options, env: &[(&str, String)], case_path: &Path, label: &str) -> Option<String> {
    let mut upstream = Command::new(&options.herdr_bin);
    upstream
        .args(["agent", "explain", "--file"])
        .arg(case_path)
        .args(["--agent", label, "--json"])
        .env_clear();
    for (name, value) in env {
        upstream.env(name, value);
    }
    let herdr_raw = upstream.output();
    let port_raw = Command::new(&options.port_bin)
        .arg("explain")
        .arg("--file")
        .arg(case_path)
        .args(["--agent", label])
        .output();

    let (herdr_raw, port_raw) = match (herdr_raw, port_raw) {
        (Ok(mine), Ok(yours)) => (mine, yours),
        (mine, yours) => {
            let render = |result: &std::io::Result<std::process::Output>| {
                result
                    .as_ref()
                    .err()
                    .map_or_else(String::new, ToString::to_string)
            };
            return Some(format!("could not spawn: {}{}", render(&mine), render(&yours)));
        },
    };
    if !herdr_raw.status.success() || !port_raw.status.success() {
        return Some(format!(
            "nonzero exit (herdr={} slopdesk={})\n{}{}",
            herdr_raw.status,
            port_raw.status,
            String::from_utf8_lossy(&herdr_raw.stderr),
            String::from_utf8_lossy(&port_raw.stderr)
        ));
    }
    let herdr_doc: Value = match serde_json::from_slice(&herdr_raw.stdout) {
        Ok(doc) => doc,
        Err(error) => return Some(format!("herdr emitted unreadable JSON: {error}")),
    };
    let port_doc: Value = match serde_json::from_slice(&port_raw.stdout) {
        Ok(doc) => doc,
        Err(error) => return Some(format!("slopdesk emitted unreadable JSON: {error}")),
    };
    // A herdr that reached a real user config would be answering from a manifest this tree has
    // never seen, and every field it disagreed on would be noise.
    let source = herdr_doc.get("manifest_source").and_then(Value::as_str);
    if let Some(source) = source.filter(|held| *held != "bundled") {
        return Some(format!(
            "herdr used non-bundled manifest source {source:?} — sandbox leak, results invalid"
        ));
    }
    diff(&project(&herdr_doc), &project(&port_doc), label)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::{diff, harvest_fragments, project, screens_for_agent};
    use crate::rng::Rng;

    fn engine(state: &str, winner: &Value, rules: &Value) -> Value {
        json!({
            "agent": "claude",
            "state": state,
            "manifest_source": "bundled",
            "manifest_version": "2026.08.11.1",
            "matched_rule": winner.clone(),
            "visible_idle": false,
            "visible_blocker": false,
            "visible_working": false,
            "skip_state_update": false,
            "skipped_update_reason": Value::Null,
            "fallback_reason": Value::Null,
            "evaluated_rules": rules.clone(),
        })
    }

    fn rule(id: &str, matched: bool) -> Value {
        json!({
            "id": id,
            "priority": 900,
            "region": "whole_recent",
            "state": "idle",
            "matched": matched,
            "evidence": {
                "contains": [], "regex": [], "line_regex": [],
                "all_count": 0, "any_count": 0, "not_count": 0,
                "region_bytes": 4, "region_preview": "hi\n",
            },
        })
    }

    #[test]
    fn identical_traces_are_parity() {
        let doc = engine("idle", &Value::Null, &json!([rule("a", false)]));
        assert!(diff(&project(&doc), &project(&doc), "claude").is_none());
    }

    /// The whole point: a rule NOT in `DIVERGED_RULES` still has to agree, even for an agent that
    /// has diverged rules.
    #[test]
    fn an_untouched_rule_of_a_diverged_agent_still_fails() {
        let mine = engine(
            "idle",
            &Value::Null,
            &json!([rule("bash_permission_prompt", false)]),
        );
        let yours = engine(
            "idle",
            &Value::Null,
            &json!([rule("bash_permission_prompt", true)]),
        );
        let detail = diff(&project(&mine), &project(&yours), "claude").expect("must not be excused");
        assert!(detail.contains("bash_permission_prompt"), "{detail}");
    }

    #[test]
    fn a_diverged_rule_is_excused_and_so_is_the_outcome_it_explains() {
        let mine = engine("idle", &Value::Null, &json!([rule("live_prompt_box", true)]));
        let yours = engine(
            "working",
            &json!("live_prompt_box"),
            &json!([rule("live_prompt_box", false)]),
        );
        assert!(diff(&project(&mine), &project(&yours), "claude").is_none());
        // …but not for an agent that has no diverged rules at all.
        assert!(diff(&project(&mine), &project(&yours), "codex").is_some());
    }

    /// A state difference a diverged rule cannot account for is still a regression.
    #[test]
    fn an_unattributable_outcome_difference_is_not_excused() {
        let rules = json!([rule("live_prompt_box", false), rule("osc_title_idle", false)]);
        let mine = engine("idle", &Value::Null, &rules);
        let yours = engine("working", &Value::Null, &rules);
        let detail = diff(&project(&mine), &project(&yours), "claude").expect("must not be excused");
        assert!(detail.contains("state:"), "{detail}");
    }

    /// The ladder short-circuiting one rule earlier is a real divergence even when every rule
    /// they DO share agrees.
    #[test]
    fn a_ladder_that_stopped_early_is_a_rule_count_gap() {
        let mine = engine("idle", &Value::Null, &json!([rule("a", false), rule("b", false)]));
        let yours = engine("idle", &Value::Null, &json!([rule("a", false)]));
        let detail = diff(&project(&mine), &project(&yours), "codex").expect("count gap");
        assert!(detail.contains("rule count: herdr=2 slopdesk=1"), "{detail}");
    }

    /// herdr answers `matched_rule` as a whole object; ours answers a bare id. Both normalise.
    #[test]
    fn the_two_matched_rule_shapes_both_resolve_to_an_id() {
        let object = engine(
            "idle",
            &json!({"id": "live_prompt_box"}),
            &json!([rule("live_prompt_box", true)]),
        );
        let bare = engine(
            "working",
            &json!("live_prompt_box"),
            &json!([rule("live_prompt_box", true)]),
        );
        assert!(diff(&project(&object), &project(&bare), "claude").is_none());
    }

    #[test]
    fn fragments_come_out_of_both_quote_styles_deduped() {
        let toml = "contains = ['esc to cancel', 'esc to cancel']\nregex = \"^\\\\s*❯\"\nempty = ''\n";
        let found = harvest_fragments(toml);
        assert_eq!(found, vec!["esc to cancel".to_owned()], "{found:?}");

        // A double-quoted literal WITHOUT a backslash is harvested; one with is not, because its
        // escapes would arrive at the engine as fuzz rather than as the needle they encode.
        let plain = harvest_fragments("a = \"do you want to proceed?\"\n");
        assert_eq!(plain, vec!["do you want to proceed?".to_owned()]);
    }

    #[test]
    fn a_seed_fixes_the_whole_corpus() {
        let fragments = vec!["esc to cancel".to_owned(), "⡇ working".to_owned()];
        let first = screens_for_agent(&fragments, &mut Rng::new(20_260_724));
        let second = screens_for_agent(&fragments, &mut Rng::new(20_260_724));
        assert_eq!(first, second);
        assert_ne!(first, screens_for_agent(&fragments, &mut Rng::new(1)));
        // The fixed tail is always there: the empty screen, the blank-lines screen, the long one.
        assert!(first.iter().any(String::is_empty));
        assert!(first.iter().any(|screen| screen.len() == 1500));
    }

    /// An agent whose manifest yields nothing quotable still gets a corpus.
    #[test]
    fn an_empty_manifest_still_generates_screens() {
        let screens = screens_for_agent(&[], &mut Rng::new(5));
        assert!(screens.len() > 20);
        assert!(screens.iter().any(|screen| screen.contains("fallback")));
    }
}
