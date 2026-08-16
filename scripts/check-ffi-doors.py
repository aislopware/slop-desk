#!/usr/bin/env python3
"""Every door in the FFI header is called from Swift, or is named here as a deliberate face.

A linked port has a failure mode a socket port does not, and `build-ffi.sh --check` catches one of
them: an artifact older than its sources. This catches the other, which is quieter — a door that
NOTHING calls. It costs nothing at runtime and everything at read time: the next person to touch
`slopdesk_replay_result_count` has to work out whether it is the way to ask, a second way to ask,
or a way nobody asks. The audit that found the first four had to answer that question by hand four
times.

The rule is not "delete every uncalled door". It is "an uncalled door is a DECISION, written down".
Three shapes, and the allowlist below says which each one is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HEADER = Path("rust/slopdesk-ffi/include/slopdesk_ffi.h")
SWIFT_ROOTS = ("Sources", "Tests", "Apps")
DOOR = re.compile(r"\b(slopdesk_[a-z0-9_]+)\b")
DECLARED = re.compile(r"\b(slopdesk_[a-z0-9_]+)\s*\(")

# A door with no Swift caller, and the reason it stays. Deleting one of these is a design change,
# not a cleanup — the reason is the review, so a bare name added here is the failure this file
# exists to prevent.
DELIBERATE: dict[str, str] = {
    "slopdesk_swipe_nav_config_free": (
        "the destructor for a handle whose only shipped owner is a process-lifetime `static let`. "
        "A constructor whose ABI offers no destructor is what makes the NEXT owner — one that is "
        "per-window rather than per-process — leak for real."
    ),
    "slopdesk_zoom_reset_policy_free": (
        "same as slopdesk_swipe_nav_config_free: PinchZeroPolicy parses once into a `static let` "
        "and never frees it, which is a singleton and not a leak."
    ),
}

GUIDANCE = """
Each is one of three things, and the fix differs:
  · a SECOND way to ask something a live door already answers — delete it, and say in its
    place what the one way is (see slopdesk_replay_result_count in replay.rs);
  · a hook held open for a test in the other language — delete it and assert natively, which
    is the cross-language mirror fixture the one-implementation rule bans;
  · a deliberate face — add it to DELIBERATE in scripts/check-ffi-doors.py WITH the reason,
    which is the review.
"""

STALE_GUIDANCE = "\nDrop it from the allowlist — an unfulfilled exemption is itself the bug."


def read(path: Path) -> str:
    """The file's text, tolerating whatever encoding a vendored header arrived in."""
    return path.read_text(encoding="utf-8", errors="ignore")


def swift_text() -> str:
    """Every Swift source in the tree, concatenated — the call sites to match doors against."""
    return "\n".join(read(path) for root in SWIFT_ROOTS for path in Path(root).rglob("*.swift"))


def complain(headline: str, names: list[str], guidance: str) -> int:
    print(f"check-ffi-doors: FAIL — {headline}", file=sys.stderr)
    for name in names:
        print(f"  {name}", file=sys.stderr)
    print(guidance, file=sys.stderr)
    return 1


def main() -> int:
    if not HEADER.exists():
        print(f"check-ffi-doors: FAIL — {HEADER} is missing", file=sys.stderr)
        return 1

    doors = sorted(set(DECLARED.findall(read(HEADER))))
    if not doors:
        print("check-ffi-doors: FAIL — no doors parsed out of the header", file=sys.stderr)
        return 1

    called = set(DOOR.findall(swift_text()))
    uncalled = [door for door in doors if door not in called]

    unexplained = [door for door in uncalled if door not in DELIBERATE]
    if unexplained:
        return complain(
            "these doors are exported and NOTHING in Swift calls them:", unexplained, GUIDANCE
        )

    # An allowlist entry for a door that IS called, or that no longer exists, is stale — the same
    # unfulfilled-expectation rule clippy's `#[expect]` carries.
    stale = [door for door in DELIBERATE if door not in doors or door in called]
    if stale:
        return complain(
            "DELIBERATE names a door that is now called, or is gone:", stale, STALE_GUIDANCE
        )

    print(
        f"check-ffi-doors: {len(doors)} doors, {len(doors) - len(uncalled)} called from Swift, "
        f"{len(uncalled)} deliberate — none dead."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
