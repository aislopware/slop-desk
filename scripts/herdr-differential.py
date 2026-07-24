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
    for _ in range(8):
        screens.append("\n".join(noise() for _ in range(rng.randint(1, 20))))
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
    )
    swift_raw = subprocess.run(
        [str(SWIFT_BIN), "--file", str(case_path), "--agent", label],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if herdr_raw.returncode != 0 or swift_raw.returncode != 0:
        return f"nonzero exit (herdr={herdr_raw.returncode} swift={swift_raw.returncode})\n{herdr_raw.stderr}{swift_raw.stderr}"
    herdr_doc = json.loads(herdr_raw.stdout)
    swift_doc = json.loads(swift_raw.stdout)
    source = herdr_doc.get("manifest_source")
    if source is not None and source != "bundled":
        return f"herdr used non-bundled manifest source {source!r} — sandbox leak, results invalid"
    left, right = project(herdr_doc), project(swift_doc)
    if left == right:
        return None
    detail = []
    for key in COMPARED_KEYS:
        if left[key] != right[key]:
            if key == "evaluated_rules":
                for l_rule, r_rule in zip(left[key], right[key]):
                    if l_rule != r_rule:
                        detail.append(
                            f"  rule {l_rule['id']}:\n    herdr: {json.dumps(l_rule, ensure_ascii=False)}\n    swift: {json.dumps(r_rule, ensure_ascii=False)}"
                        )
                if len(left[key]) != len(right[key]):
                    detail.append(f"  rule count: herdr={len(left[key])} swift={len(right[key])}")
            else:
                detail.append(
                    f"  {key}: herdr={json.dumps(left[key], ensure_ascii=False)} swift={json.dumps(right[key], ensure_ascii=False)}"
                )
    return "\n".join(detail)


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

        cases = []  # (case_path, label, screen_repr)
        case_id = 0
        for label in AGENT_LABELS:
            toml_text = (
                args.herdr_dir / "src/detect/manifests" / f"{MANIFEST_FILES[label]}.toml"
            ).read_text()
            for screen in screens_for_agent(harvest_fragments(toml_text), rng):
                others = rng.sample([other for other in AGENT_LABELS if other != label], 2)
                case_path = tmp_path / f"case-{case_id}.txt"
                case_path.write_text(screen, encoding="utf-8")
                case_id += 1
                for target in [label, *others]:
                    cases.append((case_path, target, screen))
        # Unknown-label handling parity.
        probe = tmp_path / "case-unknown.txt"
        probe.write_text("plain shell prompt $\n", encoding="utf-8")
        cases.append((probe, "not-an-agent", "plain shell prompt $\n"))

        print(f"{case_id} screens × own+2 agents = {len(cases)} differential cases")
        mismatches = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {
                pool.submit(run_case, herdr_bin, env, path, label): (path, label, screen)
                for path, label, screen in cases
            }
            done = 0
            for future in concurrent.futures.as_completed(futures):
                done += 1
                if done % 1000 == 0:
                    print(f"  {done}/{len(cases)}…")
                result = future.result()
                if result is not None:
                    mismatches.append((futures[future], result))

    if not mismatches:
        print(f"PARITY OK: {len(cases)} cases, herdr ≡ slopdesk on every compared field")
        return 0
    print(f"MISMATCH: {len(mismatches)}/{len(cases)} cases diverged")
    for (path, label, screen), detail in mismatches[: args.max_report]:
        print(f"\n=== agent={label} screen={screen[:120]!r}")
        print(detail)
    if len(mismatches) > args.max_report:
        print(f"\n… and {len(mismatches) - args.max_report} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
