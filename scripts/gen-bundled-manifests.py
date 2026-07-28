#!/usr/bin/env python3
"""Regenerate Sources/SlopDeskAgentDetect/BundledAgentManifests.swift from a herdr checkout.

The Swift file carries herdr's bundled agent-detection manifests VERBATIM as raw-string
literals. This script is the only sanctioned writer: it reads `src/detect/manifests/*.toml`
from the herdr checkout and emits the whole Swift file deterministically, so an upstream
manifest sync is `gen-bundled-manifests.py && git diff` instead of hand-pasting.

Usage:
    python3 scripts/gen-bundled-manifests.py [--herdr-dir PATH] [--check]

--check exits nonzero (without writing) when the generated content differs from the
checked-in file — used by herdr-sync.sh and safe to run any time.
"""

import argparse
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = REPO_ROOT / "Sources/SlopDeskAgentDetect/BundledAgentManifests.swift"
DEFAULT_HERDR_DIR = pathlib.Path.home() / ".cache/clio-repos/github.com--ogulcancelik--herdr"

# (manifest filename stem, AgentKind case). Order is the declaration order of the Swift
# `all` array and matches herdr's bundled-manifest ordering.
AGENTS = [
    ("pi", "pi"),
    ("claude", "claude"),
    ("codex", "codex"),
    ("gemini", "gemini"),
    ("cursor", "cursor"),
    ("devin", "devin"),
    ("antigravity", "antigravity"),
    ("cline", "cline"),
    ("opencode", "openCode"),
    ("github-copilot", "githubCopilot"),
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

HEADER = """\
// Generated from herdr's bundled agent-detection manifests (Apache-2.0,
// github.com/ogulcancelik/herdr `src/detect/manifests/*.toml`) — carried VERBATIM so upstream
// rule updates can be pasted in unchanged. Do not hand-edit rule content here; sync from
// upstream instead. Embedded as raw-string literals (no resource bundle) so the headless
// daemon and every app target load them with zero deployment surface.

// Manifest TOML is carried verbatim — upstream lines stay unwrapped.
// swiftlint:disable line_length

/// The bundled manifest TOML per screen-manifest agent (herdr's exact files).
enum BundledAgentManifests {
"""


def swift_var(stem: str) -> str:
    return stem.replace("-", "") + "TOML"


def literal(stem: str, toml_text: str) -> str:
    lines = [f'    static let {swift_var(stem)} = #"""']
    lines.extend(f"    {line}" if line else "" for line in toml_text.rstrip("\n").split("\n"))
    lines.append('    """#')
    return "\n".join(lines)


def generate(herdr_dir: pathlib.Path) -> str:
    manifests_dir = herdr_dir / "src/detect/manifests"
    stems_on_disk = sorted(p.stem for p in manifests_dir.glob("*.toml"))
    expected = sorted(stem for stem, _ in AGENTS)
    if stems_on_disk != expected:
        extra = set(stems_on_disk) - set(expected)
        missing = set(expected) - set(stems_on_disk)
        sys.exit(
            "manifest set drift vs upstream — update AGENTS in this script AND AgentKind:\n"
            f"  new upstream manifests: {sorted(extra) or 'none'}\n"
            f"  removed upstream manifests: {sorted(missing) or 'none'}"
        )

    parts = [HEADER.rstrip("\n")]
    parts.append("    static let all: [(AgentKind, String)] = [")
    for stem, case in AGENTS:
        parts.append(f"        (.{case}, {swift_var(stem)}),")
    parts.append("    ]\n")
    for stem, _ in AGENTS:
        toml_text = (manifests_dir / f"{stem}.toml").read_text(encoding="utf-8")
        parts.append(literal(stem, toml_text) + "\n")
    body = "\n".join(parts)
    return body.rstrip("\n") + "\n}\n\n// swiftlint:enable line_length\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--herdr-dir", type=pathlib.Path, default=DEFAULT_HERDR_DIR)
    parser.add_argument("--check", action="store_true", help="diff only, do not write")
    args = parser.parse_args()

    if not (args.herdr_dir / "src/detect/manifests").is_dir():
        sys.exit(f"not a herdr checkout: {args.herdr_dir}")

    content = generate(args.herdr_dir)
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
    if content == current:
        print(f"OK: {OUTPUT.relative_to(REPO_ROOT)} is in sync with {args.herdr_dir}")
        return 0
    if args.check:
        print(f"DRIFT: {OUTPUT.relative_to(REPO_ROOT)} differs from upstream manifests")
        return 1
    OUTPUT.write_text(content, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
