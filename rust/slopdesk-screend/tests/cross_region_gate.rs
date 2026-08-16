//! ⚠️ DIVERGES FROM herdr (2026-08-11). A nested gate may carry its OWN `region`, so a rule can
//! veto on evidence that does not live where the rule looks. herdr has no such thing: there, a
//! `not` is always evaluated against the rule's region, which is why `live_prompt_box`'s five
//! footer needles were dead code — a dialog's footer sits below the last horizontal rule, outside
//! `prompt_box_body` by construction, so the veto never saw the thing it was written to stop.
//!
//! This is the structural fix, plus the two `claude` rules it earns. It is not specific to those
//! rules, and it costs herdr parity for the `claude` manifest only (`scripts/herdr-differential.py`
//! names them in `DIVERGED_RULES`; `scripts/gen-bundled-manifests.py` refuses to overwrite a
//! manifest carrying the marker these rules are commented with).
#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use slopdesk_screend::detect::detect;
use slopdesk_screend::manifest::{Manifest, State};
use slopdesk_screend::rules::CompiledManifest;
use slopdesk_screend::{DetectionInput, Verdict};

fn compiled(rules_toml: &str) -> Result<CompiledManifest, String> {
    let text = format!("id = \"codex\"\n{rules_toml}");
    let manifest = Manifest::parse(&text).map_err(|error| error.message)?;
    CompiledManifest::new(manifest).map_err(|error| error.message)
}

fn rule_line() -> String {
    "─".repeat(20)
}

fn screen(lines: &[&str]) -> DetectionInput {
    DetectionInput::from_screen(lines.join("\n"))
}

fn claude(lines: &[String]) -> Verdict {
    detect(
        "claude",
        &DetectionInput::from_screen(lines.iter().map(String::as_str).collect::<Vec<_>>().join("\n")),
    )
}

/// The reported bug's screen: an `AskUserQuestion` dialog, whole and torn.
fn ask_user_question_body() -> Vec<String> {
    let bar = "─".repeat(60);
    [
        "  Reading docs/46-gates-env-paths.md",
        &bar,
        "←  ☐ Next step  ☐ Language  ✔ Submit  →",
        "What should I do next in this repo?",
        "❯ 1. Run make test-touched",
        "  2. Review the current diff",
        "  3. Type something.",
        &bar,
        "  4. Chat about this",
        "",
    ]
    .iter()
    .map(|line| (*line).to_owned())
    .collect()
}

// MARK: The capability

/// A gate's region overrides the rule's, for that gate only — the rule keeps looking where it
/// always looked, and its siblings are unaffected.
#[test]
fn a_nested_gate_reads_its_own_region_not_the_rules_one() {
    let manifest = compiled(
        r#"
        [[rules]]
        id = "caret_unless_footer"
        state = "idle"
        priority = 100
        region = "prompt_box_body"
        line_regex = ['^\s*❯']
        not = [
          { region = "after_last_horizontal_rule", contains = ["esc to cancel"] },
        ]
        "#,
    )
    .expect("the probe manifest is valid");

    let bar = rule_line();
    // The caret is inside `prompt_box_body`; the footer is below the LAST rule, two regions away.
    let dialog = screen(&["question?", &bar, "❯ 1. yes", "  2. no", &bar, "Esc to cancel"]);
    assert_eq!(
        manifest.evaluate(&dialog).matched_rule_id,
        None,
        "the cross-region veto sees a footer the rule's own region cannot"
    );

    // Same caret, no footer anywhere — nothing to veto with, so the rule fires.
    let bare = screen(&["done", &bar, "❯ ", &bar, "  ? for shortcuts"]);
    assert_eq!(
        manifest.evaluate(&bare).matched_rule_id.as_deref(),
        Some("caret_unless_footer")
    );
}

/// The same override on a POSITIVE gate, and nested one level deeper.
#[test]
fn a_cross_region_gate_also_works_inside_any_and_all() {
    let manifest = compiled(
        r#"
        [[rules]]
        id = "caret_with_footer"
        state = "blocked"
        priority = 100
        region = "prompt_box_body"
        line_regex = ['^\s*❯']
        all = [
          { any = [
            { region = "after_last_horizontal_rule", contains = ["esc to cancel"] },
            { region = "after_last_horizontal_rule", contains = ["enter to select"] },
          ] },
        ]
        "#,
    )
    .expect("the probe manifest is valid");

    let bar = rule_line();
    let dialog = screen(&["q?", &bar, "❯ 1. yes", &bar, "Enter to select"]);
    assert_eq!(
        manifest.evaluate(&dialog).matched_rule_id.as_deref(),
        Some("caret_with_footer")
    );

    let elsewhere = screen(&["Enter to select", &bar, "❯ 1. yes", &bar, "nothing here"]);
    assert_eq!(
        manifest.evaluate(&elsewhere).matched_rule_id,
        None,
        "the needle exists on screen but not in the gate's region — that is the whole point"
    );
}

// MARK: Validation

#[test]
fn a_bogus_region_on_a_nested_gate_rejects_the_manifest() {
    for gate in ["any", "all", "not"] {
        let toml = format!(
            r#"
            [[rules]]
            id = "bad_nested_region"
            state = "idle"
            contains = ["x"]
            {gate} = [{{ region = "bottom_recent", contains = ["y"] }}]
            "#
        );
        assert!(
            compiled(&toml).is_err(),
            "a nested {gate} gate must validate its region like a rule does"
        );
    }
}

/// A gate region is an ENGINE-3 key. An engine that predates it ignores the key silently, and
/// silently ignoring a VETO is how a rule fires on the screen it was written to skip — so a
/// manifest that uses one must declare an engine that honours it. (`claude` does; the guard is
/// what keeps the next manifest honest.)
#[test]
fn a_gate_region_requires_an_engine_that_honours_it() {
    let body = |floor: &str| {
        format!(
            r#"
            id = "probe"
            version = "1"
            min_engine_version = {floor}
            [[rules]]
            id = "r"
            state = "blocked"
            region = "prompt_box_body"
            contains = ["needle"]
            not = [
              {{ region = "after_last_horizontal_rule", contains = ["esc to cancel"] }},
            ]
            "#
        )
    };
    let rejected = Manifest::parse(&body("2")).expect_err("engine 2 cannot honour a gate region");
    assert!(
        rejected.message.contains("gate region"),
        "unexpected: {}",
        rejected.message
    );
    assert!(Manifest::parse(&body("3")).is_ok());
    // …and with no declared floor at all the manifest takes the running engine, as before.
    let floorless = body("3").replace("min_engine_version = 3\n", "");
    assert!(Manifest::parse(&floorless).is_ok());
}

/// A RULE's `region` belongs to the rule. Copying it onto the rule's root gate as an "override"
/// changes no verdict, but it re-resolves the region text on every evaluation and makes every rule
/// in every manifest look like it uses the cross-region feature.
#[test]
fn a_rule_region_is_not_copied_onto_its_root_gate() {
    let manifest = Manifest::parse(
        r#"
        id = "probe"
        version = "1"
        [[rules]]
        id = "r"
        state = "idle"
        region = "prompt_box_body"
        contains = ["needle"]
        "#,
    )
    .expect("the probe manifest is valid");
    let rule = manifest.rules.first().expect("one rule");
    assert_eq!(rule.region.as_str(), "prompt_box_body");
    assert_eq!(
        rule.gate.region, None,
        "the root gate inherits; it does not override"
    );
}

// MARK: The bundled claude manifest, which is why this exists

/// Whole or torn, the dialog must never read as an idle prompt box — the one verdict strong enough
/// to lower a hand nobody lowered.
#[test]
fn the_claude_dialog_never_reads_as_an_idle_prompt_box() {
    let mut whole_lines = ask_user_question_body();
    whole_lines.push("Enter to select · Tab/Arrow keys to navigate · Esc to cancel".to_owned());

    // Whole: the footer is present, and the cross-region veto is what stops the caret.
    let whole = claude(&whole_lines);
    assert_eq!(whole.state, State::Blocked);
    assert_eq!(whole.matched_rule_id.as_deref(), Some("live_blocked_form"));

    // Torn: the repaint erased the footer before rewriting it, so the cross-region veto has
    // nothing left to find — the OPTION LIST veto is what covers this one.
    let torn = claude(&ask_user_question_body());
    assert_ne!(torn.matched_rule_id.as_deref(), Some("live_prompt_box"));
    assert!(
        !torn.visible_idle,
        "nothing here is strong enough to lower a hand"
    );
}

/// ⚠️ DIVERGES FROM herdr (2026-08-11). Upstream omits `visible_blocker` on
/// `legacy_no_prompt_blocker` — alone among its blocked rules. A pane blocked through THAT rule
/// therefore carried a different visibility than one blocked through any other, so a screen that
/// alternated between them flipped the flag and published a type-27 saying something had changed
/// when only the matching rule had. It also cost the 800 ms stable-blocker refresh. A blocker the
/// human can see is a visible blocker; every blocked rule now agrees.
#[test]
fn every_blocked_rule_in_the_claude_manifest_is_a_visible_blocker() {
    let manifest = slopdesk_screend::detect::manifest_for("claude").expect("claude is bundled");
    let inconsistent: Vec<&str> = manifest
        .manifest()
        .rules
        .iter()
        .filter(|rule| rule.state == Some(State::Blocked) && !rule.visible_blocker)
        .map(|rule| rule.id.as_str())
        .collect();
    assert!(
        inconsistent.is_empty(),
        "a blocked rule that is not a visible blocker flaps the flag: {inconsistent:?}"
    );
}

/// …and the rule the option-list veto guards still fires for the thing it was written for. A human
/// typing at a real prompt box is `visible_idle`, which is what drives the settled-idle mark.
#[test]
fn a_real_idle_prompt_box_is_still_a_visible_idle() {
    let bar = "─".repeat(60);
    for typed in ["", "make test", "1. this looks like an option but is not"] {
        let lines: Vec<String> = vec![
            "  Done.".to_owned(),
            bar.clone(),
            format!("❯ {typed}"),
            bar.clone(),
            "  ? for shortcuts".to_owned(),
            String::new(),
        ];
        let result = claude(&lines);
        assert_eq!(result.state, State::Idle, "typed: {typed}");
        assert!(result.visible_idle, "typed: {typed}");
        assert_eq!(
            result.matched_rule_id.as_deref(),
            Some("live_prompt_box"),
            "typed: {typed}"
        );
    }
}
