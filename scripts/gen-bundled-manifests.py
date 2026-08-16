#!/usr/bin/env python3
"""Re-sync rust/slopdesk-screend/manifests/*.toml from a herdr checkout.

screend carries herdr's bundled agent-detection manifests VERBATIM, as the TOML files they
already are — `include_str!`d into the binary by `src/detect.rs`, so the daemon has no
resource bundle and no deployment surface. This script is the only sanctioned writer: it
copies `src/detect/manifests/*.toml` across under the label each manifest is addressed by,
so an upstream sync is `gen-bundled-manifests.py && git diff` instead of hand-pasting.

(It used to GENERATE a Swift file of raw-string literals, because the rule ladder was in
Swift and TOML had to become source. The ladder moved to screend — docs/52 — and the
manifests went back to being files.)

Usage:
    python3 scripts/gen-bundled-manifests.py [--herdr-dir PATH] [--check]

--check exits nonzero (without writing) when a checked-in manifest differs from upstream —
used by herdr-sync.sh and safe to run any time.
"""

import argparse
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "rust/slopdesk-screend/manifests"
DEFAULT_HERDR_DIR = pathlib.Path.home() / ".cache/clio-repos/github.com--ogulcancelik--herdr"

# (upstream manifest filename stem, the agent LABEL we file it under). The two differ for
# exactly the agents whose canonical label is not their upstream filename; everything else is
# the identity. Order is herdr's bundled-manifest ordering.
AGENTS = [
    ("pi", "pi"),
    ("claude", "claude"),
    ("codex", "codex"),
    ("gemini", "gemini"),
    ("cursor", "cursor"),
    ("devin", "devin"),
    ("antigravity", "agy"),
    ("cline", "cline"),
    ("opencode", "opencode"),
    ("github-copilot", "copilot"),
    ("kimi", "kimi"),
    ("kiro", "kiro"),
    ("droid", "droid"),
    ("amp", "amp"),
    ("grok", "grok"),
    ("hermes", "hermes"),
    ("kilo", "kilo"),
    ("qodercli", "qodercli"),
    ("maki", "maki"),
]

# The in-file mark a deliberately-improved manifest carries. Keyed on the FILE rather than on a
# list here, so the reason and the exemption cannot drift apart: the comment that earns the
# exemption is the one a reader finds at the rule.
DIVERGENCE_MARKER = "DIVERGES FROM herdr"


def sync(herdr_dir: pathlib.Path, *, check_only: bool) -> int:
    manifests_dir = herdr_dir / "src/detect/manifests"
    stems_on_disk = sorted(p.stem for p in manifests_dir.glob("*.toml"))
    expected = sorted(stem for stem, _ in AGENTS)
    if stems_on_disk != expected:
        extra = set(stems_on_disk) - set(expected)
        missing = set(expected) - set(stems_on_disk)
        sys.exit(
            "manifest set drift vs upstream — update AGENTS in this script, `BUNDLED` +\n"
            "`KNOWN_AGENTS` in rust/slopdesk-screend/src/detect.rs, AND AgentKind:\n"
            f"  new upstream manifests: {sorted(extra) or 'none'}\n"
            f"  removed upstream manifests: {sorted(missing) or 'none'}"
        )

    drifted = []
    diverged = []
    for stem, label in AGENTS:
        upstream = (manifests_dir / f"{stem}.toml").read_text(encoding="utf-8")
        target = OUTPUT_DIR / f"{label}.toml"
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current == upstream:
            continue
        # A manifest we deliberately made BETTER than upstream is never overwritten. `herdr-sync`
        # runs this writer unattended, and a blind copy would silently delete the divergence —
        # after which the differential would report perfect parity, because both engines would
        # again be running upstream's rule. Merge those by hand (`DIVERGED_RULES` in
        # herdr-differential.py names them, and the manifest itself says why, inline).
        if DIVERGENCE_MARKER in current:
            diverged.append(label)
            continue
        drifted.append(label)
        if not check_only:
            target.write_text(upstream, encoding="utf-8")

    relative = OUTPUT_DIR.relative_to(REPO_ROOT)
    stem_of = {label: stem for stem, label in AGENTS}
    for label in diverged:
        upstream_path = manifests_dir / f"{stem_of[label]}.toml"
        ours = OUTPUT_DIR / f"{label}.toml"
        print(
            f"HELD: {relative}/{label}.toml carries a deliberate divergence — not overwritten.\n"
            f"      Re-apply upstream by hand: diff -u {upstream_path} {ours}"
        )
    if not drifted:
        print(f"OK: {relative}/ is in sync with {herdr_dir}")
        return 0
    if check_only:
        print(f"DRIFT: {relative}/ differs from upstream — {', '.join(drifted)}")
        return 1
    print(f"wrote {len(drifted)} manifest(s) under {relative}/: {', '.join(drifted)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--herdr-dir", type=pathlib.Path, default=DEFAULT_HERDR_DIR)
    parser.add_argument("--check", action="store_true", help="diff only, do not write")
    args = parser.parse_args()

    if not (args.herdr_dir / "src/detect/manifests").is_dir():
        sys.exit(f"not a herdr checkout: {args.herdr_dir}")
    return sync(args.herdr_dir, check_only=args.check)


if __name__ == "__main__":
    sys.exit(main())
