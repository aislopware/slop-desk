#!/usr/bin/env python3
"""A number meaning the same in both languages is ASKED FOR or RATCHETED, never spelled twice.

Two constants with the same name and the same value on either side of the FFI boundary are one
constant written twice. Nothing catches that: both sides compile, every test passes, and the two
copies agree right up until someone tunes one of them. Then the client draws by a threshold the host
does not enforce, and the first symptom is a wrong-length ring or a fragmented datagram, never an
error.

This repo settles it two ways, and which one is right follows from the LIFETIME of the boundary
(CLAUDE.md, "a port ships over a socket, or as a linked library"):

  * IN-PROCESS, across `CSlopDeskFFI` — Swift ASKS. The number crosses through a door and exists
    once — `Canvas.minItemSize`, `WorkspaceTopology.closedTabRingCap`,
    `VideoPacketizer.maxDatagramSize`.
  * ACROSS A SOCKET, to a sidecar — the two spellings are RATCHETED against each other by a gate in
    `check-supervisor.sh`, because a separately-shipped binary cannot link the other's constant.

A VOCABULARY is the exception both answers miss, and it gets the third: an alphabet of field bytes
that both ends must NAME, frozen on the wire, where an index-shaped door would only move the
transcription. Those pairs are ratcheted here instead, letter for letter and in both directions.

So a pair is a finding here only when it is none of the three. The allowlist below is for HOMONYMS:
names that collide by accident and describe unrelated laws, where folding them would be the bug.

## What this gate CANNOT see, named precisely

A ratchet that is trusted past its reach is worse than none, and every one of these has already let
a real pair through at least once. They are structural — each would need a different instrument, not
a bigger pattern — so they are written down rather than half-closed:

  * **Pairing is by normalised NAME.** Two spellings of one law that were never given the same name
    are invisible: `ReplayBuffer.offlineGateBytes` against `replay::OFFLINE_GATE_BYTES` pairs, and
    `HintLabelAssigner`'s bare `4096` against `link::MAX_SCAN_COLUMNS` did not, because the Swift
    side spelled it as a default ARGUMENT rather than as a named constant at all. A literal with no
    name has nothing to pair with, and that is the commonest shape a transcription takes.
  * **It fires only when the two values are EQUAL.** This is BIRTH CONTROL, not a drift check: it
    stops a second spelling being born and says nothing the day one of them moves. A pair that has
    already drifted reads here as "a different number is a different constant" and passes. The
    instrument for drift is a differential test (`docs/55` §8), and this gate cannot become one.
  * **`SWIFT_BIT` requires the `Self(rawValue: 1 << N)` form.** An `OptionSet` member written any
    other way — a computed property, a `rawValue` built by a function, a bit named through a door on
    one line and a literal on the next — is not read. The Rust side is equally shaped: only
    `pub const NAME: Self = Self(1 << N)` is seen.
  * **The enum pass needs EXPLICIT discriminants on both sides.** A Swift `enum` whose cases have no
    `= n` and a Rust `enum` relying on implicit `0, 1, 2…` both read as no cases at all, so the pair
    is skipped silently. Implicit numbering is exactly where a REORDER changes every byte.
  * **Strings are out of scope.** A label, a socket path, a default title or a sigil spelled in both
    languages is not a number and is not read here. `check-supervisor.sh` bans a few of those by
    literal; nothing generalises it.

Usage: scripts/check-shared-constants.py   (exit 1 on any finding)
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Names that collide but do NOT describe the same law. Folding either pair into one door would make
# a change to one silently move the other.
# Enums that share a name across the two languages without sharing a meaning. None yet: every pair
# found so far is one wire alphabet. An entry here needs the reason the two are unrelated.
HOMONYM_ENUMS: set[str] = set()

# WHICH ALLOWLIST ENTRIES ACTUALLY SUPPRESSED SOMETHING THIS RUN. An exemption that stops
# matching is the failure this whole script is about, one level up: a ledger that keeps being
# consulted after its subject moved. `maxDepth` was one — the split tree's depth limit, exempted
# against "the JSON reader's recursion limit" — and when `SplitNode.maxDepth` became
# `Int(slopdesk_ws_max_depth())` the entry stopped covering anything and nothing said so. Deleting
# it changed no result, which is the definition of dead. So the allowlists are checked for deadness
# on every run: an entry that suppressed nothing is a finding, exactly like the drift it permits.
USED_HOMONYMS: set[tuple[str, str]] = set()
USED_BIT_FILES: set[str] = set()

# Swift OptionSets whose members share a name with a WIRE flag set without sharing its law. A bit
# position is only a shared law when the byte crosses; a set that never leaves the client may lay
# its bits out however it likes.
#
# Empty, and checked for deadness below like the rest. It carried `CommandInterpreter.swift` on the
# grounds that `KeyChord.Modifiers` is a client-only `Int` whose ⇧⌃⌥⌘ layout agreeing with the
# wire's `InputModifiers` was convention rather than contract. True, and it stopped mattering: the
# two now agree bit for bit, so the exemption suppressed nothing. If they ever diverge the finding
# is real — and it should be read then, not waved through by a note written before the divergence.
HOMONYM_BIT_FILES: set[str] = set()

# Keyed by (Swift file, name) rather than by the bare name, and that is not tidiness. A name-keyed
# entry exempts EVERY pair sharing that name, in every file, forever — so ONE legitimate collision
# buys silence for a real transcription nobody will ever be told about. `currentSchemaVersion` was
# that entry: it named a homonym across three unrelated stores (a window-parking snapshot at 1, a
# folder-frecency file at 1, a keybinding file at 3) and quietly covered a FOURTH pair that was the
# real thing — `TreeWorkspace.currentSchemaVersion = 12` against
# `slopdesk_workspace::CURRENT_SCHEMA_VERSION = 12`, the two halves of the comparison that decides
# whether a saved workspace loads or is set aside. It has a door now
# (`slopdesk_ws_schema_version`) and the entry is gone; the three homonyms it was written for never
# needed one, because none of their values is 12 and this pass only fires on EQUAL values.
#
# Each entry's value is the reason the two laws are unrelated, which is the review.
HOMONYMS: dict[tuple[str, str], str] = {
    ("Sources/SlopDeskTransport/TransportParameters.swift", "keepaliveIntervalSeconds"): (
        "a kernel TCP keepalive probe interval on PATH 1, against the video path's "
        "application-level UDP keepalive that holds a NAT mapping open. Both happen to be 5 s."
    ),
}

# A VOCABULARY is the one shared number a door cannot dissolve. A field byte is not a law anyone
# may tune — it is a letter of the document's alphabet, frozen the moment a golden vector carries
# one, and both ends must be able to NAME it (`WorkspacePaneField.liveTitle`) rather than reach for
# it through an index that would itself be the transcription. So the pair is ratcheted instead:
# every name in the scope must exist on both sides and carry the same byte, in both directions. A
# field added to one language and not the other fails here rather than at a peer of another build.
#
# Each entry is (Swift file, Rust file, {Swift type: Rust module}).
VOCABULARIES = [
    (
        "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift",
        "rust/slopdesk-wire/src/document/fields.rs",
        {
            "WorkspaceRootField": "root",
            "WorkspaceSessionField": "session",
            "WorkspaceTabField": "tab",
            "WorkspacePaneField": "pane",
            "WorkspaceSplitNodeField": "split_node",
            "WorkspaceProjectField": "project",
        },
    ),
]

# A DERIVED gate names no constant, which is what makes it a ratchet rather than a list — and what
# makes it invisible to the "does check-supervisor.sh mention this name" test below. These pairs
# declare the gate that already compares them, so the two are not counted twice.
# Keyed by the gate's own label, which must still be there: an escape hatch pointing at a gate
# someone deleted is a suppression, not a ratchet.
DERIVED_RATCHETS = {
    ("Sources/SlopDeskScreen/ScreenProtocol.swift", "rust/slopdesk-screenwire/src/lib.rs"): (
        'same "screend reset flags"'
    ),
}

RUST_SCOPE = re.compile(r"^pub mod ([a-z_]+) \{$", re.MULTILINE)
SWIFT_SCOPE = re.compile(r"^public enum ([A-Za-z]+) \{$", re.MULTILINE)

# Decimal, hex or binary — a flag byte is written `0x10` on both sides and a decimal-only pattern
# reads neither of them, which is how four `slopdesk-screenwire` flags stayed unwatched.
NUMBER = r"(0[xX][0-9a-fA-F_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9]+)?)"

# A size is rarely written as its digits. `256 * 1024 * 1024` and `15 * 1024 * 1024` are how a
# cap is spelled where a reader has to see the megabytes, and a literal-only pattern reads NEITHER
# of them — so the loudest constants in the tree, the ones a comment calls "the 15 MiB cap", were
# the ones this gate could not see at all. The evaluator below is deliberately tiny: `int`
# literals, `*`, `+` and `<<`, no names, no parentheses, no `eval`. Anything else answers "not a
# number I can compare", which costs a pair this gate never had.
EXPRESSION = (
    r"("
    + NUMBER.replace("(", "(?:", 1)
    + r"(?:[ \t]*(?:\*|\+|<<)[ \t]*"
    + NUMBER.replace("(", "(?:", 1)
    + r")*)"
)

RUST_CONST = re.compile(
    # Indented, because a vocabulary declares its constants inside a `mod` — anchoring at column 0
    # hid every field byte in `slopdesk_wire::document::fields` from this gate until 2026-08-17.
    r"^[ \t]*pub const ([A-Z][A-Z_0-9]*): *"
    r"(?:usize|u8|u16|u32|u64|i8|i16|i32|i64|f32|f64) *= *" + EXPRESSION + r"[ \t]*;",
    re.MULTILINE,
)
SWIFT_CONST = re.compile(
    r"^\s*(?:public |private |internal |fileprivate |package )?static let "
    r"([A-Za-z][A-Za-z0-9]*)"
    r"(?: *: *[A-Za-z][A-Za-z0-9]*)? *= *" + EXPRESSION + r"[ \t]*$",
    re.MULTILINE,
)

# An enum's discriminants are the same kind of alphabet as a field byte, and drift the same way: a
# verb byte that moved in one language is a request the other end answers as a DIFFERENT verb. These
# pair by NAME rather than by a declared list, because a wire enum is spelled the same in both
# languages — so any enum both sides declare, sharing any case, must agree about every case.
RUST_ENUM = re.compile(r"^pub enum ([A-Za-z][A-Za-z0-9]*)[^\n]*\{$", re.MULTILINE)
SWIFT_ENUM = re.compile(
    r"^(?:public |internal |private )?enum ([A-Za-z][A-Za-z0-9]*)[^\n]*\{$", re.MULTILINE
)
RUST_CASE = re.compile(r"^\s*([A-Z][A-Za-z0-9]*) = " + NUMBER + r",\s*$", re.MULTILINE)

# An OptionSet's bit POSITIONS are the third alphabet: `1 << 6` on both sides, spelled as an
# expression rather than a literal, so neither of the patterns above reads one.
RUST_BIT = re.compile(
    r"^\s*pub const ([A-Z][A-Z_0-9]*): *Self *= *Self\(1 *<< *([0-9]+)\);", re.MULTILINE
)
SWIFT_BIT = re.compile(
    r"^\s*(?:public |private |internal )?static let ([A-Za-z][A-Za-z0-9]*)"
    r" *(?::[^=\n]+)?= *(?:Self|[A-Za-z][A-Za-z0-9]*)\(rawValue: *1 *<< *([0-9]+)\)",
    re.MULTILINE,
)
SWIFT_CASE = re.compile(r"^\s*case ([a-z][A-Za-z0-9]*) = " + NUMBER + r"\s*$", re.MULTILINE)


def tracked(pattern: str) -> list[Path]:
    """Every git-tracked file matching a pathspec, so an untracked scratch file is not audited."""
    out = subprocess.run(
        ["git", "ls-files", pattern], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return [ROOT / line for line in out.stdout.split()]


def literal(text: str) -> float:
    """A literal's value, in whichever of the three notations it was written."""
    plain = text.replace("_", "")
    return float(int(plain, 0)) if plain[:2].lower() in {"0x", "0b"} else float(plain)


def numeric(text: str) -> float | None:
    """What a constant's right-hand side is WORTH, or `None` when this evaluator cannot say.

    `int` literals joined by `*`, `+` and `<<`, folded left to right with `*` before `+`. Not
    `eval`: this reads files nobody reviewed as code, and a gate that executes its input to compare
    two numbers has traded the bug it catches for a worse one.

    A `<<` mixed with either arithmetic operator answers `None` rather than a value, and that
    refusal is the one judgement in here. Rust binds `*` and `+` TIGHTER than `<<`; Swift binds
    `<<` tighter than both. So `1 << 2 + 3` is 32 in Rust and 7 in Swift, and any answer this
    function gave would be right about one language and wrong about the other — which is the exact
    class of silent disagreement it exists to report. No constant in the tree is written that way;
    the day one is, the honest reading is that it should not be.
    """
    parts = re.split(r"[ \t]*(\*|\+|<<)[ \t]*", text.strip())
    operators = parts[1::2]
    try:
        values = [literal(part) for part in parts[0::2]]
    except ValueError:
        return None
    if not values:
        return None
    if "<<" in operators and any(op != "<<" for op in operators):
        return None
    if "<<" in operators:
        shifted = values[0]
        for places in values[1:]:
            if shifted != int(shifted) or places != int(places) or not 0 <= places < 64:
                return None
            shifted = float(int(shifted) << int(places))
        return shifted
    # `*` binds tighter than `+` in both languages, so the products are folded first and summed.
    terms = [values[0]]
    for operator, value in zip(operators, values[1:], strict=True):
        if operator == "*":
            terms[-1] *= value
        else:
            terms.append(value)
    return sum(terms)


# Where the Swift tree ENDS, which `scripts/check-ffi-doors.py` had to answer too — and answered
# differently, so a door counted a caller in `Apps/` that this gate could not see a constant in. The
# roots agree now.
#
# A TEST is deliberately not audited, and that is a different question from the doors'. A door
# called only from a test is still a door somebody reaches; a NUMBER spelled in a test is usually
# the pin itself — the whole point of `XCTAssertEqual(field, 7)` is that 7 is written down where a
# refactor cannot move it. Auditing those would report every golden expectation in the tree as a
# transcription of the constant it exists to hold still. That is why the exclusion is a `Tests`
# PATH COMPONENT and not the single top-level `Tests/` root: the iOS suite lives at
# `Apps/ClientApp-iOS/Tests/`, inside a root this gate does audit.
SWIFT_TREE = ("Sources/*.swift", "Apps/*.swift", "ThirdParty/ghostty/integration/*.swift")


def swift_sources() -> list[Path]:
    """Every git-tracked Swift file this gate audits, across all of the roots above, tests aside."""
    return [
        path
        for root in SWIFT_TREE
        for path in tracked(root)
        if "Tests" not in path.relative_to(ROOT).parts
    ]


def scopes(
    text: str, opener: re.Pattern[str], const: re.Pattern[str]
) -> dict[str, dict[str, float]]:
    """Each `mod`/`enum` in `text`, mapped to the constants declared before the next one opens."""
    starts = [(m.group(1), m.end()) for m in opener.finditer(text)]
    if not starts:
        return {}
    ends = [start for _, start in starts[1:]] + [len(text)]
    bounds = [(name, at, end) for (name, at), end in zip(starts, ends, strict=True)]
    return {
        name: {
            n.replace("_", "").lower(): value
            for n, v in const.findall(text[at:end])
            if (value := numeric(v)) is not None
        }
        for name, at, end in bounds
    }


def vocabulary_findings() -> list[str]:
    """Every way a declared alphabet stopped meaning the same thing letter for letter."""
    out: list[str] = []
    for swift_file, rust_file, pairs in VOCABULARIES:
        swift = scopes((ROOT / swift_file).read_text(), SWIFT_SCOPE, SWIFT_CONST)
        rust = scopes((ROOT / rust_file).read_text(), RUST_SCOPE, RUST_CONST)
        for swift_scope, rust_scope in pairs.items():
            here, there = swift.get(swift_scope, {}), rust.get(rust_scope, {})
            if not here or not there:
                out.append(f"  {swift_file}: `{swift_scope}` and `{rust_scope}` no longer pair up")
                continue
            for name in sorted(set(here) | set(there)):
                if name not in here:
                    out.append(
                        f"  {swift_file}: `{swift_scope}` is missing `{name}`, "
                        f"which {rust_scope} declares"
                    )
                elif name not in there:
                    out.append(
                        f"  {rust_file}: `{rust_scope}` is missing `{name}`, "
                        f"which {swift_scope} declares"
                    )
                elif here[name] != there[name]:
                    out.append(
                        f"  {swift_file}: `{swift_scope}.{name} = {here[name]:g}` against "
                        f"`{rust_scope}::{name} = {there[name]:g}`"
                    )
    return out


def enum_findings() -> list[str]:
    """Every wire enum whose two spellings stopped agreeing, case for case."""
    rust: dict[str, list[tuple[str, dict[str, float]]]] = {}
    for path in tracked("rust/*.rs"):
        text = path.read_text()
        for name, cases in scopes(text, RUST_ENUM, RUST_CASE).items():
            if cases:
                rust.setdefault(name, []).append((str(path.relative_to(ROOT)), cases))

    out: list[str] = []
    for path in swift_sources():
        here_file = str(path.relative_to(ROOT))
        for name, here in scopes(path.read_text(), SWIFT_ENUM, SWIFT_CASE).items():
            if not here or name in HOMONYM_ENUMS:
                continue
            for there_file, there in rust.get(name, []):
                if not set(here) & set(there):
                    continue  # same name, no case in common: not the same alphabet
                for case in sorted(set(here) | set(there)):
                    if case not in here:
                        out.append(f"  {here_file}: `{name}` is missing `{case}`, in {there_file}")
                    elif case not in there:
                        out.append(f"  {there_file}: `{name}` is missing `{case}`, in {here_file}")
                    elif here[case] != there[case]:
                        out.append(
                            f"  {here_file}: `{name}.{case} = {here[case]:g}` against "
                            f"`{there[case]:g}` in {there_file}"
                        )
    return out


def bit_findings() -> list[str]:
    """Every wire flag whose bit moved in one language and not the other."""
    rust: dict[str, list[tuple[str, str, int]]] = {}
    for path in tracked("rust/*.rs"):
        for name, bit in RUST_BIT.findall(path.read_text()):
            key = name.replace("_", "").lower()
            rust.setdefault(key, []).append((str(path.relative_to(ROOT)), name, int(bit)))

    out: list[str] = []
    for path in swift_sources():
        here_file = str(path.relative_to(ROOT))
        for name, bit in SWIFT_BIT.findall(path.read_text()):
            for there_file, there_name, there_bit in rust.get(name.lower(), []):
                if int(bit) != there_bit:
                    if here_file in HOMONYM_BIT_FILES:
                        USED_BIT_FILES.add(here_file)
                        continue
                    out.append(
                        f"  {here_file}: `{name} = 1 << {bit}` against "
                        f"`{there_name} = 1 << {there_bit}` in {there_file}"
                    )
    return out


def main() -> int:
    rust: dict[str, list[tuple[Path, str, float]]] = {}
    for path in tracked("rust/*.rs"):
        for name, value in RUST_CONST.findall(path.read_text()):
            worth = numeric(value)
            if worth is None:
                continue
            rust.setdefault(name.replace("_", "").lower(), []).append((path, name, worth))

    # A name a supervisor gate already compares is ratcheted, which is the sidecar answer.
    ratcheted = (ROOT / "scripts" / "check-supervisor.sh").read_text()

    vocabulary = {ROOT / swift for swift, _, _ in VOCABULARIES}

    findings: list[str] = []
    for path in swift_sources():
        if path in vocabulary:
            continue  # ratcheted letter for letter below, which is stricter than this pass
        here_file = str(path.relative_to(ROOT))
        for name, value in SWIFT_CONST.findall(path.read_text()):
            worth = numeric(value)
            if worth is None:
                continue
            for rust_path, rust_name, rust_value in rust.get(name.lower(), []):
                if worth != rust_value:
                    continue  # a different number is a different constant, or a gate's business
                if name in ratcheted or rust_name in ratcheted:
                    continue
                pair = (here_file, str(rust_path.relative_to(ROOT)))
                if DERIVED_RATCHETS.get(pair, "\0") in ratcheted:
                    continue
                # LAST, not first: an entry only counts as USED when it is the sole reason a real
                # pair was let through. Checked before the ratchets it would have suppressed a pair
                # something else already covers, and then looked alive forever.
                if (here_file, name) in HOMONYMS:
                    USED_HOMONYMS.add((here_file, name))
                    continue
                findings.append(
                    f"  {here_file}: `{name} = {value}` restates "
                    f"`{rust_name}` in {rust_path.relative_to(ROOT)}"
                )

    if findings:
        print("check-shared-constants: FAIL — a constant is spelled in both languages\n")
        print("\n".join(sorted(findings)))
        print(
            "\nAsk for it through a `CSlopDeskFFI` door (see `slopdesk_ws_min_weight` for the\n"
            "shape), or — if the two ends are separate BINARIES — ratchet the pair in\n"
            "scripts/check-supervisor.sh. A genuine name collision goes in this script's HOMONYMS\n"
            "with the reason the two laws are unrelated."
        )
        return 1

    drifted = vocabulary_findings() + enum_findings() + bit_findings()

    dead = [
        f"  HOMONYMS: `{name}` in {file} suppressed nothing"
        for file, name in sorted(set(HOMONYMS) - USED_HOMONYMS)
    ] + [
        f"  HOMONYM_BIT_FILES: `{f}` suppressed nothing"
        for f in sorted(HOMONYM_BIT_FILES - USED_BIT_FILES)
    ]
    if dead:
        print("check-shared-constants: FAIL — an allowlist entry is dead\n")
        print("\n".join(dead))
        print(
            "\nThe names it exempts no longer collide, so it exempts nothing and would silently\n"
            "wave through a REAL collision the day one comes back under that name. Delete the\n"
            "entry. If you believe the pair still exists, the belief is what is out of date."
        )
        return 1
    if drifted:
        print("check-shared-constants: FAIL — a shared alphabet drifted\n")
        print("\n".join(drifted))
        print(
            "\nA field byte is frozen on the wire and NAMED on both sides, so the two spellings\n"
            "are ratcheted rather than folded into a door. Add the letter to both, or give it the\n"
            "same byte on both — a mis-numbered field decodes cleanly into the wrong meaning."
        )
        return 1

    print(
        "check-shared-constants: every shared number is asked for or ratcheted, and the field\n"
        "vocabulary, the wire enums and the flag bits agree letter for letter."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
