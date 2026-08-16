#!/usr/bin/env python3
"""Repo-wide invariant ratchets — the ones CLAUDE.md states and nothing else enforced.

Why this file is Python and its neighbours are bash
---------------------------------------------------
Every gate here is "this token must not appear in code", and in shell that reads as a `grep`.
Three different bugs came out of that in one afternoon, all of them silent:

* `repo_files … | xargs grep -ln` PRINTS the offending file and still exits non-zero, because
  `xargs` splits 742 paths into batches and reports the LAST batch's status. `if hit=$(…)` is
  then false and the gate says nothing — a violation found and discarded.
* A `grep` for `pkill` matched the gate's own failure MESSAGE, so the check reported itself and
  could never be made to pass.
* Stripping comments with `sed -E 's,//.*,,'` also mangles `https://…` inside a string literal.

None of the three is a shell-scripting mistake so much as the shape of the tool: a pipeline hides
status, and a regex has no idea what a comment is. Both failures look exactly like success. The
gates below carry a tokenizer instead, and each is a function whose name says what it protects.

Run directly, or through `make lint-supervisor`, which folds the exit status into its own count.
`--list` prints the gates without running them.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

#: A failing gate returns the sites it found and the sentence that says why they are wrong.
Report = tuple[list[str], str] | None


def repo_files(*patterns: str) -> list[Path]:
    """Tracked files plus untracked-but-not-ignored ones, the way the other gates see the tree.

    `--others --exclude-standard` is not decoration: most of `rust/` is untracked while the port
    lands, and a gate reading only the index would be blind to it.
    """
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", *patterns],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    )
    return [REPO / line for line in out.stdout.split("\n") if line]


_C_TOKENS = re.compile(
    r"""
      (?P<raw>r\#*"(?:[^"]|"(?!\#))*"\#*)   # Rust raw string, r"…" / r#"…"#
    | (?P<str>"(?:\\.|[^"\\\n])*")          # ordinary string literal
    | (?P<char>'(?:\\.|[^'\\\n])')          # character literal
    | (?P<block>/\*.*?\*/)                  # /* … */
    | (?P<line>//[^\n]*)                    # // …
    """,
    re.VERBOSE | re.DOTALL,
)


def strip_comments(source: str, kind: str) -> str:
    """Blank out comments, keeping line numbering intact so a report can still cite a line.

    String literals survive: a gate banning a token would otherwise miss it whenever a neighbouring
    string happened to contain a slash pair, and one reading `//` would fire on every URL.
    """
    if kind == "shell":
        kept = ("" if line.lstrip().startswith("#") else line for line in source.split("\n"))
        return "\n".join(kept)

    def blank(match: re.Match[str]) -> str:
        text = match.group(0)
        if match.lastgroup in {"raw", "str", "char"}:
            return text
        return "\n" * text.count("\n")  # keep the newlines so line numbers survive

    return _C_TOKENS.sub(blank, source)


def hits(paths: list[Path], kind: str, pattern: str) -> list[str]:
    """Every `path:line: text` where the pattern matches real code rather than a comment."""
    rx = re.compile(pattern)
    found: list[str] = []
    for path in paths:
        try:
            source = path.read_text(errors="ignore")
        except OSError:
            continue
        for number, line in enumerate(strip_comments(source, kind).split("\n"), 1):
            if line.strip() and rx.search(line):
                found.append(f"{path.relative_to(REPO)}:{number}: {line.strip()}")
    return found


# --------------------------------------------------------------------------------------------- #
# The gates. Each returns None when it holds.
# --------------------------------------------------------------------------------------------- #

#: Files allowed to import a crypto framework, each with the reason it is not what the rule bans.
#: An allowlist rather than excluding `Tests/` wholesale: a hash over a PINNED ARTIFACT is
#: supply-chain integrity and always will be, while a hash over a credential is the thing the rule
#: exists to stop — and both would live under `Tests/`.
CRYPTO_ALLOWED = {
    "Tests/SlopDeskHostTests/VendoredToolsTests.swift": (
        "SHA-256 of a COMMITTED jar against its tools.lock pin — integrity, not an auth path"
    ),
}


def no_app_layer_crypto() -> Report:
    """CLAUDE.md: "No app-layer crypto or auth — security is the WireGuard mesh."

    The way that rule dies is one import, for one hash, in one file, six months before anyone
    reads the sentence that forbids it.
    """
    stale = [name for name in CRYPTO_ALLOWED if not (REPO / name).exists()]
    if stale:
        return stale, "a crypto allowlist entry names a file that does not exist"

    swift = repo_files("Sources/*.swift", "Apps/*.swift", "Tests/*.swift")
    found = [
        line
        for line in hits(swift, "swift", r"^\s*import\s+(CryptoKit|CommonCrypto)\b")
        if line.split(":", 1)[0] not in CRYPTO_ALLOWED
    ]
    if not found:
        return None
    return found, "app-layer crypto reached the tree — security here is the WireGuard mesh"


def no_swiftpm_build_plugin() -> Report:
    """CLAUDE.md: "cargo never runs inside `swift build`."

    A SwiftPM `.plugin`/`buildTool` in the manifest is exactly the shape that rule forbids, and it
    would arrive looking like a convenience.
    """
    found = hits([REPO / "Package.swift"], "swift", r"\.plugin\(|buildTool\(|\.buildTool\b")
    if not found:
        return None
    return found, "Package.swift declares a build plugin — the FFI artifact is built by 'make ffi'"


def no_fused_multiply_add() -> Report:
    """CLAUDE.md: keep `a * b + c` as two roundings — the golden corpus pins the bit patterns.

    The METHOD form only. `gf256::mul_add` and `slopdesk_gfsimd::mul_add` are Galois-field region
    ops over `u8` with nothing to do with float rounding; a path call is never a float fusion.
    """
    swift = repo_files("Sources/*.swift", "Tests/*.swift", "Apps/*.swift")
    rust = [p for p in repo_files("rust/*.rs") if "/target/" not in str(p)]
    found = hits(swift, "swift", r"\.addingProduct\(|(?<![\w.])fma\(")
    found += hits(rust, "rust", r"\.mul_add\(")
    if not found:
        return None
    return found, "a fused multiply-add reached the tree — FMA rounds once, the wire rounds twice"


def every_script_sets_pipefail() -> Report:
    """Without `pipefail` a pipeline reports the LAST command's status.

    Every gate in this repo is a pipeline somewhere, so a script missing it is a gate that cannot
    fail. The check reads the WORD, not a flag spelling: two scripts say `set -uo pipefail`
    deliberately, and a first draft matching `set -euo pipefail` called both of them broken.
    """
    scripts = [
        p for p in repo_files("*.sh") if not str(p.relative_to(REPO)).startswith("ThirdParty/")
    ]
    missing = [
        str(p.relative_to(REPO))
        for p in scripts
        if not re.search(r"(?m)^\s*set\s+[^\n]*pipefail", p.read_text(errors="ignore"))
    ]
    if not missing:
        return None
    return missing, "a shell script does not set pipefail — a death inside a pipe would read green"


_LOCATE_CALL = re.compile(
    r"RustServicePaths\.locate(?:Beside)?\(\s*(?:\"(?P<literal>slopdesk-[a-z]+)\"|(?P<symbol>\w+))",
)
_BINARY_NAME_CONSTANT = re.compile(r"""\bbinaryName\s*=\s*"(slopdesk-[a-z]+)\"""")


def the_release_ships_every_sidecar_the_host_needs() -> Report:
    """A daemon hostd resolves at runtime and the tarball omits is a feature that cannot run.

    This gate exists because the tarball was three binaries — `slopdesk`, `slopdesk-hostd`,
    `slopdesk-ctl` — while hostd resolved eight more, superd among them. superd forks every PTY
    master, so a `brew install` produced a host that could not open a single pane, and no gate
    could see it: the release path is exercised by TAGGING, and a change that moves an
    implementation out of the Swift graph is invisible to everything that is not a release.

    Derived from the call sites, not from a list: every `RustServicePaths.locate`/`locateBeside`
    names the binary it wants, so a seventh daemon is covered the day someone writes the lookup.
    Two names cannot be found that way and are added explicitly rather than left to an
    approximation that would quietly drop them — `slopdesk-superd`, which hostd reaches by SOCKET
    and never by path, and `slopdesk-hook`, which `slopdesk-agenthooks` copies from its own
    directory (`rust/slopdesk-hook/src/bin/agenthooks.rs`, `executable.parent()/RELAY_NAME`).

    The shipped set is read from the tool ARRAYS, not from the file: a first draft grepped
    `package-release.sh` whole, which the comment above those arrays — it names every daemon —
    satisfied on its own. A gate a comment can pass is not a gate.
    """
    wanted: set[str] = {"slopdesk-superd", "slopdesk-hook"}
    for path in repo_files("Sources/*.swift"):
        source = path.read_text(errors="ignore")
        constants = _BINARY_NAME_CONSTANT.findall(source)
        for match in _LOCATE_CALL.finditer(source):
            if literal := match.group("literal"):
                wanted.add(literal)
            elif match.group("symbol") == "binaryName":
                wanted.update(constants)

    packaging = (REPO / "scripts/package-release.sh").read_text(errors="ignore")
    arrays = re.findall(
        r"^(?:SPM_TOOLS|RUST_ROOT_TOOLS|RUST_CRATE_TOOLS)=\((.*?)\)",
        packaging,
        re.MULTILINE | re.DOTALL,
    )
    if not arrays:
        blind = "the release tool arrays are gone — this gate is blind"
        return ["scripts/package-release.sh"], blind
    shipped = {name for body in arrays for name in re.findall(r"\bslopdesk-[a-z]+\b", body)}
    missing = sorted(wanted - shipped)
    if not missing:
        return None
    return missing, "the host resolves a sidecar the release tarball does not ship"


def a_script_with_a_shebang_is_executable() -> Report:
    """A shebang is a promise that `scripts/foo.sh --flag` works; the mode bit is what keeps it.

    Four scripts had lost the bit and nothing noticed, because the Makefile invokes every one of
    them as `bash scripts/foo.sh` — the one spelling that works either way. What breaks is the
    spelling the scripts and `docs/46` tell a human to type (`scripts/restart-hostd.sh --status`),
    which is exactly the path no gate walks. So the shebang is the declaration and this is its
    check: `#!` on line one, no `x` bit, is a documented entry point that answers "permission
    denied". Derived from the file itself, so a new script is covered the day it is written.
    """
    scripts = [
        p
        for p in [*repo_files("*.sh"), *repo_files("*.py"), *repo_files("*.awk")]
        if not str(p.relative_to(REPO)).startswith("ThirdParty/")
    ]
    found = [
        str(p.relative_to(REPO))
        for p in scripts
        if p.read_bytes()[:2] == b"#!" and not os.access(p, os.X_OK)
    ]
    if not found:
        return None
    return found, "a script declares a shebang but is not executable — running it by name fails"


def pkill_never_reaches_the_developers_host() -> Report:
    """CLAUDE.md: "Never `pkill` the host — `make host-restart` replays hostd's recorded launch."

    The harnesses under `scripts/` DO kill hosts, and must: each spawns its own on a private port
    and reaps it. What is banned is the UNQUALIFIED form, which reaches the developer's running
    hostd as readily as the harness's own. So the question is not "does this script say pkill" but
    "does a pkill naming hostd carry the qualifier that scopes it to a host this script started".
    """
    shells = [*repo_files("scripts/*.sh"), REPO / "Makefile"]
    found = [
        line
        for line in hits(shells, "shell", r"pkill\s+-f")
        if "slopdesk-hostd" in line and "--port" not in line and "DerivedData" not in line
    ]
    if not found:
        return None
    return found, "an unqualified pkill names slopdesk-hostd — it would reap the running host"


def shell_quoting_has_one_owner() -> Report:
    """POSIX `'…'` quoting was written eight times; it lives once, behind `slopdesk_ws_shell_quote`.

    This gate existed in `check-supervisor.sh` and could not fail: it piped 742 paths into
    `xargs grep -ln`, which prints the offender and still exits non-zero when the final batch is
    clean — so the surrounding `if hit=$(…)` was false exactly when there was something to report.
    """
    found = hits(repo_files("Sources/*.swift"), "swift", r"replacingOccurrences\(of: \"'\"")
    if not found:
        return None
    return found, "a site quotes a shell word itself — every one asks slopdesk_ws_shell_quote"


#: The docs `CLAUDE.md` sends a reader to before touching anything, plus the two front doors. These
#: must not lie. Every OTHER document — `docs/19`, the `27` to `31` handoffs, `docs/40`, and all of
#: `docs/ui-shell/` — is a record of a plan as it stood, and a path that was real then is not a
#: defect now. 476 stale citations live in those; 5 lived here, which is the whole argument for
#: drawing the line where CLAUDE.md already draws it.
LIVE_DOCS = (
    "CLAUDE.md",
    "README.md",
    "Makefile",
    "docs/00-overview.md",
    "docs/20-wire-protocol.md",
    "docs/45-multi-client-state-sync.md",
    "docs/46-gates-env-paths.md",
    "docs/47-simulator-panel.md",
    "docs/48-android-panel.md",
    "docs/49-release-pipeline.md",
    "docs/50-agent-detection-architecture.md",
    "docs/51-process-supervision.md",
    "docs/52-screen-engine.md",
    "docs/53-file-drop-service.md",
    "docs/54-inspector.md",
    "docs/55-ffi-boundary.md",
)

_PATH_SPAN = re.compile(r"`([^`\s]+)`")
_PATH_ROOTS = (
    "Sources/",
    "Tests/",
    "Apps/",
    "rust/",
    "scripts/",
    "docs/",
    "golden/",
    "ThirdParty/",
)
_LINE_SUFFIX = re.compile(r":[\d,+-]+$")
_DOC_NUMBER = re.compile(r"^docs/(\d+)$")
#: A citation whose whole point is that the file is gone. `docs/51` has a "What this deleted"
#: section; flagging it would be the gate arguing with the document's subject.
_DELETION_HEADINGS = ("What this deleted", "Deleted", "Removed")


def live_docs_cite_files_that_exist() -> Report:
    """A doc a reader is SENT to must not name a path that is not there.

    The failure is not tidiness. `docs/45` claimed a mitigation —
    "`…/HostOutputSnifferGoldenGuardTests.swift` asserts the frozen vector still round-trips" —
    for a test that had moved to Rust with the sniffer. A reader checking whether the blind spot
    was covered would grep, find nothing, and conclude it was not.
    """
    found: list[str] = []
    for name in LIVE_DOCS:
        path = REPO / name
        if not path.exists():
            found.append(f"{name}: the live-doc list names a file that does not exist")
            continue
        deleting = False
        for number, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
            if line.startswith("#"):
                deleting = any(h in line for h in _DELETION_HEADINGS)
            if deleting:
                continue
            for span in _PATH_SPAN.findall(line):
                cited = span.strip("(").rstrip(".,:;)")
                if not cited.startswith(_PATH_ROOTS) or any(c in cited for c in "*{}…"):
                    continue
                cited = _LINE_SUFFIX.sub("", cited).split("#")[0].split("§")[0]
                numbered = _DOC_NUMBER.match(cited)
                if numbered:  # `docs/51` is how this repo cites doc 51, not a path
                    if not list((REPO / "docs").glob(f"{numbered.group(1)}-*.md")):
                        found.append(f"{name}:{number}: {cited}")
                elif not (REPO / cited).exists():
                    found.append(f"{name}:{number}: {cited}")
    if not found:
        return None
    return found, "a doc CLAUDE.md sends readers to cites a path that is not in the tree"


GATES = [
    live_docs_cite_files_that_exist,
    no_app_layer_crypto,
    no_swiftpm_build_plugin,
    no_fused_multiply_add,
    every_script_sets_pipefail,
    a_script_with_a_shebang_is_executable,
    the_release_ships_every_sidecar_the_host_needs,
    pkill_never_reaches_the_developers_host,
    shell_quoting_has_one_owner,
]


def main() -> int:
    """Run every gate, report each failure with its sites, and answer with the exit status."""
    if "--list" in sys.argv:
        for gate in GATES:
            summary = (gate.__doc__ or "").strip().split("\n")[0]
            print(f"{gate.__name__}: {summary}")
        return 0

    broken = 0
    for gate in GATES:
        report = gate()
        if report is None:
            continue
        broken += 1
        sites, message = report
        for site in sites:
            print(site, file=sys.stderr)
        print(f"check-invariants: FAIL — {message}", file=sys.stderr)

    if broken:
        print(f"check-invariants: {broken} of {len(GATES)} invariants broken.", file=sys.stderr)
        return 1
    print(f"check-invariants: {len(GATES)} invariants hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
