#!/usr/bin/env python3
"""Differential parity harness: the REAL herdr binary vs SlopDesk's ported detect engine.

Runs `herdr agent explain --file … --json` (upstream's own debug oracle, exercising its
actual rule engine end-to-end) next to `.build/debug/slopdesk-detect-explain` on a
deterministic generated corpus, and diffs the full evaluation traces: final state, winner
rule, visible flags, skip/fallback reasons, and — per evaluated rule — matched flag,
region byte length, and region preview. Any divergence in a region resolver, gate
evaluation, priority tie-break, or fallback shows up as a field-level mismatch.

Prereqs (see scripts/herdr-sync.sh for the build recipe):
    herdr checkout with target/release/herdr built
    swift build   (for slopdesk-detect-explain)

Usage:
    python3 scripts/herdr-differential.py [--herdr-dir PATH] [--seed N] [--jobs N]

Exit 0 = full parity on the corpus; exit 1 = mismatches (details printed).

⚠️ Parity is no longer the goal everywhere: the rules in DIVERGED_RULES are deliberately better
than upstream. Divergence is scoped to the RULE, not the agent — every other rule of a diverged
agent stays under parity, because "we improved one rule" must not silently retire the guard on the
twenty we did not touch. Read that list.
"""

import argparse
import concurrent.futures
import json
import pathlib
import random
import re
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_HERDR_DIR = pathlib.Path.home() / ".cache/clio-repos/github.com--ogulcancelik--herdr"
SWIFT_BIN = REPO_ROOT / ".build/debug/slopdesk-detect-explain"

AGENT_LABELS = [
    "pi",
    "claude",
    "codex",
    "gemini",
    "cursor",
    "devin",
    "agy",
    "cline",
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
]
# ⚠️ DELIBERATE DIVERGENCE — these RULES are no longer under parity, by user decision
# (2026-08-11: "không cần parity với herdr nữa, cứ làm thế nào ngon hơn herdr là được").
#
# Scoped to the rule ID, NOT the agent. Excluding the whole `claude` label (as this harness briefly
# did) drops the guard on every claude rule we did NOT touch — `bash_permission_prompt`,
# `generic_permission_prompt`, `dynamic_workflow_prompt`, `model_picker_menu`,
# `btw_overlay_working` — and those are ordinary ports with nothing else pinning them.
#
# `live_prompt_box`: herdr's calls a mid-repaint `AskUserQuestion` dialog an IDLE prompt box with
# `visible_idle` — its five footer needles are dead code, because a `not` gate is evaluated against
# the rule's own region and the footer lives outside `prompt_box_body` by construction. Ours vetoes
# on the footer via a CROSS-REGION nested gate (a capability herdr has no syntax for) and on the
# option list, so it survives an erase-then-rewrite.
# `legacy_no_prompt_blocker`: ours declares `visible_blocker`, so the screen tier can corroborate a
# hook block instead of only ever contradicting it.
# See `docs/50-agent-detection-architecture.md` §8 and `ManifestCrossRegionGateTests`.
#
# Adding an id here needs a written reason above it; the harness is worth nothing if this set grows
# silently.
DIVERGED_RULES = {"claude": {"live_prompt_box", "legacy_no_prompt_blocker"}}

# Top-level keys that differ BY CONSTRUCTION once a manifest is edited at all, and carry no
# behavioural meaning — ignored for an agent that has any diverged rule.
VERSION_KEYS = {"manifest_version"}

# Top-level keys that describe the WINNER. They are ignored only when a diverged rule is the one
# that explains the difference (see `attributable_to_diverged`).
OUTCOME_KEYS = {
    "state",
    "matched_rule",
    "visible_idle",
    "visible_blocker",
    "visible_working",
    "skip_state_update",
    "skipped_update_reason",
    "fallback_reason",
}

MANIFEST_FILES = {
    "pi": "pi",
    "claude": "claude",
    "codex": "codex",
    "gemini": "gemini",
    "cursor": "cursor",
    "devin": "devin",
    "agy": "antigravity",
    "cline": "cline",
    "opencode": "opencode",
    "copilot": "github-copilot",
    "kimi": "kimi",
    "kiro": "kiro",
    "droid": "droid",
    "amp": "amp",
    "grok": "grok",
    "hermes": "hermes",
    "kilo": "kilo",
    "qodercli": "qodercli",
    "maki": "maki",
}

# Keys we compare (our CLI's full output). herdr's extra keys (remote-update status etc.)
# are outside the ported scope and ignored.
COMPARED_KEYS = [
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
]
EVIDENCE_KEYS = [
    "contains",
    "regex",
    "line_regex",
    "all_count",
    "any_count",
    "not_count",
    "region_bytes",
    "region_preview",
]

HRULE = "─" * 40
UNICODE_SALAD = [
    "ΟΔΥΣΣΕΥΣ σ ς Σ",  # Greek incl. final sigma (case-fold divergence probe)
    "İstanbul ı I i ß ẞ ﬀ",  # Turkish dotted/dotless I, sharp s, ligature
    "é combining ñ",  # combining marks
    "日本語テキスト 🚀🎉 �",  # CJK + emoji + replacement char
    "⠀⡇⣿ braille",  # braille range used by spinner rules
]


def harvest_fragments(toml_text):
    """All quoted string literals in the manifest — contains needles, regex sources,
    alias labels. Raw regex text doubles as fuzz material for its own rule."""
    frags = re.findall(r"'([^']+)'", toml_text) + re.findall(r'"([^"\\]+)"', toml_text)
    seen, out = set(), []
    for frag in frags:
        if 1 <= len(frag) <= 200 and frag not in seen:
            seen.add(frag)
            out.append(frag)
    return out


def screens_for_agent(fragments, rng):
    """Deterministic screen corpus around one agent's manifest vocabulary."""
    noise = lambda: " ".join(  # noqa: E731 — tiny local helper
        rng.choice(["make", "test", "ok", "error", "$", "λ", "..", "run"])
        for _ in range(rng.randint(1, 8))
    )
    screens = []
    for frag in fragments:
        screens.append(frag)
        screens.append(f"{noise()}\n{frag}\n{noise()}")
        screens.append(frag.upper())
        screens.append(f"prefix {frag} suffix")
    pool = fragments or ["fallback"]
    for _ in range(12):
        a, b = rng.choice(pool), rng.choice(pool)
        screens.append(f"{a}\n{noise()}\n{b}")
    for frag in pool[:6]:
        screens.append(f"{noise()}\n{HRULE}\n{frag}\n{HRULE}\n{noise()}")  # prompt box
        screens.append(f"{frag}\n{HRULE}\n› {noise()}")  # codex prompt
        screens.append(f"• {noise()}\n✗ failed\n› {frag}\n✓ done")  # codex markers
        screens.append(f"✳ Cooking…\n⡇ {frag}")  # claude chrome
    for frag in pool[:4]:
        screens.append(frag + "\n")
        screens.append(frag + "\n\n\n")
        screens.append(frag.replace(" ", "\r\n") if " " in frag else frag + "\r")
        screens.append(f"line one\r\n{frag}\r\nline three\r")
    screens.extend(UNICODE_SALAD)
    screens.append("\n".join(UNICODE_SALAD))
    screens.append("")
    screens.append("\n\n\n")
    screens.append("x" * 1500)
    screens.append("\n".join(noise() for _ in range(300)))
    screens.extend("\n".join(noise() for _ in range(rng.randint(1, 20))) for _ in range(8))
    return screens


def project(doc):
    out = {key: doc.get(key) for key in COMPARED_KEYS}
    out["evaluated_rules"] = [
        {
            "id": rule.get("id"),
            "priority": rule.get("priority"),
            "region": rule.get("region"),
            "state": rule.get("state"),
            "matched": rule.get("matched"),
            "evidence": {key: rule.get("evidence", {}).get(key) for key in EVIDENCE_KEYS},
        }
        for rule in doc.get("evaluated_rules", [])
    ]
    return out


def run_case(herdr_bin, env, case_path, label):
    herdr_raw = subprocess.run(
        [str(herdr_bin), "agent", "explain", "--file", str(case_path), "--agent", label, "--json"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        check=False,
    )
    swift_raw = subprocess.run(
        [str(SWIFT_BIN), "--file", str(case_path), "--agent", label],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if herdr_raw.returncode != 0 or swift_raw.returncode != 0:
        codes = f"herdr={herdr_raw.returncode} swift={swift_raw.returncode}"
        return f"nonzero exit ({codes})\n{herdr_raw.stderr}{swift_raw.stderr}"
    herdr_doc = json.loads(herdr_raw.stdout)
    swift_doc = json.loads(swift_raw.stdout)
    source = herdr_doc.get("manifest_source")
    if source is not None and source != "bundled":
        return f"herdr used non-bundled manifest source {source!r} — sandbox leak, results invalid"
    left, right = project(herdr_doc), project(swift_doc)
    return diff(left, right, label)


def rules_by_id(projected):
    """The evaluated-rule trace keyed by id (both engines walk the same manifest rule list, but
    keying by id rather than position keeps one extra/missing rule from smearing the whole diff)."""
    return {rule["id"]: rule for rule in projected["evaluated_rules"] if rule.get("id")}


def winner_id(projected):
    """The winning rule's id. herdr reports `matched_rule` as the whole rule object on a hit and
    as null on a fallback, so this normalises both shapes to an id or None."""
    winner = projected.get("matched_rule")
    if isinstance(winner, dict):
        return winner.get("id")
    return winner


def attributable_to_diverged(left, right, diverged):
    """TRUE when a DIVERGED rule is what explains an outcome difference: it won on either side, or
    it matched on one side and not the other. A difference the diverged rules cannot account for is
    a real regression somewhere else in the manifest, and must still fail."""
    if winner_id(left) in diverged or winner_id(right) in diverged:
        return True
    l_rules, r_rules = rules_by_id(left), rules_by_id(right)
    return any(
        l_rules.get(rule_id, {}).get("matched") != r_rules.get(rule_id, {}).get("matched")
        for rule_id in diverged
    )


def diff(left, right, label):
    """The field-level diff, minus whatever DIVERGED_RULES licenses. Returns None on parity."""
    diverged = DIVERGED_RULES.get(label, set())
    excused_keys = set()
    if diverged:
        excused_keys |= VERSION_KEYS
        if attributable_to_diverged(left, right, diverged):
            excused_keys |= OUTCOME_KEYS

    detail = []
    for key in COMPARED_KEYS:
        if key in excused_keys or left[key] == right[key]:
            continue
        if key != "evaluated_rules":
            l_json = json.dumps(left[key], ensure_ascii=False)
            r_json = json.dumps(right[key], ensure_ascii=False)
            detail.append(f"  {key}: herdr={l_json} swift={r_json}")
            continue
        l_rules, r_rules = rules_by_id(left), rules_by_id(right)
        for rule_id in sorted(set(l_rules) | set(r_rules)):
            if rule_id in diverged:
                continue  # this rule is deliberately not herdr's — see DIVERGED_RULES
            l_rule, r_rule = l_rules.get(rule_id), r_rules.get(rule_id)
            if l_rule == r_rule:
                continue
            l_json = json.dumps(l_rule, ensure_ascii=False)
            r_json = json.dumps(r_rule, ensure_ascii=False)
            detail.append(f"  rule {rule_id}:\n    herdr: {l_json}\n    swift: {r_json}")
        # A rule EVALUATED on one side only is a divergence in the ladder itself, unless it is one
        # of ours. (Count, not just membership: the ladder short-circuits, so a length gap is real.)
        l_ids = [r for r in l_rules if r not in diverged]
        r_ids = [r for r in r_rules if r not in diverged]
        if len(l_ids) != len(r_ids):
            detail.append(f"  rule count: herdr={len(l_ids)} swift={len(r_ids)}")
    return "\n".join(detail) or None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--herdr-dir", type=pathlib.Path, default=DEFAULT_HERDR_DIR)
    parser.add_argument("--seed", type=int, default=20260724)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--max-report", type=int, default=12)
    args = parser.parse_args()

    herdr_bin = args.herdr_dir / "target/release/herdr"
    if not herdr_bin.exists():
        sys.exit(
            f"missing herdr oracle at {herdr_bin} — see scripts/herdr-sync.sh for the build recipe"
        )
    if not SWIFT_BIN.exists():
        sys.exit(f"missing {SWIFT_BIN} — run `swift build` first")

    pin_path = REPO_ROOT / "scripts/herdr.pin"
    head = subprocess.run(
        ["git", "-C", str(args.herdr_dir), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    pin = pin_path.read_text().strip() if pin_path.exists() else "(no pin)"
    if head != pin:
        print(f"note: herdr checkout {head[:12]} != pinned {pin[:12]} (fine during a sync run)")

    rng = random.Random(args.seed)
    with tempfile.TemporaryDirectory(prefix="herdr-diff-") as tmp:
        tmp_path = pathlib.Path(tmp)
        (tmp_path / "iso/config").mkdir(parents=True)
        (tmp_path / "iso/state").mkdir(parents=True)
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(tmp_path / "iso"),
            "XDG_CONFIG_HOME": str(tmp_path / "iso/config"),
            "XDG_STATE_HOME": str(tmp_path / "iso/state"),
        }

        tested = list(AGENT_LABELS)
        for label, rules in sorted(DIVERGED_RULES.items()):
            print(f"⚠️  {label}: rules NOT under parity (deliberate): {', '.join(sorted(rules))}")

        cases = []  # (case_path, label, screen_repr)
        case_id = 0
        for label in AGENT_LABELS:
            toml_text = (
                args.herdr_dir / "src/detect/manifests" / f"{MANIFEST_FILES[label]}.toml"
            ).read_text()
            for screen in screens_for_agent(harvest_fragments(toml_text), rng):
                others = rng.sample([other for other in tested if other != label], 2)
                own = [label]
                case_path = tmp_path / f"case-{case_id}.txt"
                case_path.write_text(screen, encoding="utf-8")
                case_id += 1
                cases.extend((case_path, target, screen) for target in [*own, *others])
        # Unknown-label handling parity.
        probe = tmp_path / "case-unknown.txt"
        probe.write_text("plain shell prompt $\n", encoding="utf-8")
        cases.append((probe, "not-an-agent", "plain shell prompt $\n"))

        print(f"{case_id} screens × up to own+2 agents = {len(cases)} differential cases")
        mismatches = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {
                pool.submit(run_case, herdr_bin, env, path, label): (path, label, screen)
                for path, label, screen in cases
            }
            for done, future in enumerate(concurrent.futures.as_completed(futures), start=1):
                if done % 1000 == 0:
                    print(f"  {done}/{len(cases)}…")
                result = future.result()
                if result is not None:
                    mismatches.append((futures[future], result))

    if not mismatches:
        print(f"PARITY OK: {len(cases)} cases, herdr ≡ slopdesk on every compared field")
        return 0
    print(f"MISMATCH: {len(mismatches)}/{len(cases)} cases diverged")
    for (_path, label, screen), detail in mismatches[: args.max_report]:
        print(f"\n=== agent={label} screen={screen[:120]!r}")
        print(detail)
    if len(mismatches) > args.max_report:
        print(f"\n… and {len(mismatches) - args.max_report} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
