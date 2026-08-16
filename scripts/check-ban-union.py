#!/usr/bin/env python3
"""`DELETED_SWIFT_UNION` really is the union of every ban that filters through it.

`check-supervisor.sh` walks `Sources/` ONCE for twenty-one "this Swift must stay deleted" bans:
a union grep collects the candidate files, and each ban then re-greps only those. That is only sound
while the union is a SUPERSET of every ban. Drop one ban's pattern out of it and that ban stops
seeing its own violation — and it reports success, because an empty candidate list is exactly what
passing looks like.

That is the failure mode `check-supervisor.sh` already has a section about ("No gate may die
quietly"): a check that cannot fail is worse than a check that is missing, because the log says it
ran. So the union is verified rather than trusted, the way the FFI door allowlist is.

The check is textual on purpose. Deciding regex-superset in general is not something to attempt in
a lint gate; every ban here is spliced into the union verbatim as `(pattern)`, so verbatim
containment is both the rule and the whole story. A ban written some other way fails this and should
— it means the splice convention was broken, which is when the reasoning above stops holding.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

GATE = Path("scripts/check-supervisor.sh")
UNION = re.compile(r"^DELETED_SWIFT_UNION='(.*)'$", re.MULTILINE)
BAN = re.compile(r"^\s*[a-z_]+=\$\(among_deleted '(.*)'\)$", re.MULTILINE)


def main() -> int:
    if not GATE.exists():
        print(f"check-ban-union: FAIL — {GATE} is missing", file=sys.stderr)
        return 1

    text = GATE.read_text(encoding="utf-8", errors="ignore")

    union_match = UNION.search(text)
    if not union_match:
        print(
            "check-ban-union: FAIL — no DELETED_SWIFT_UNION in the gate. If the one-walk "
            "filter was removed, remove this check with it; if it was renamed, rename it here.",
            file=sys.stderr,
        )
        return 1
    union = union_match.group(1)

    bans = BAN.findall(text)
    if not bans:
        print(
            "check-ban-union: FAIL — the union exists but nothing filters through it, so the walk "
            "is dead weight and the bans are somewhere else.",
            file=sys.stderr,
        )
        return 1

    missing = [ban for ban in bans if f"({ban})" not in union]
    if missing:
        print(
            "check-ban-union: FAIL — these bans filter through a union that does not contain them, "
            "so each one PASSES on a file it should catch:",
            file=sys.stderr,
        )
        for ban in missing:
            print(f"  {ban}", file=sys.stderr)
        print(
            "\nSplice each into DELETED_SWIFT_UNION as `(pattern)`, joined by `|`.",
            file=sys.stderr,
        )
        return 1

    print(f"check-ban-union: {len(bans)} bans, all spliced into the one tree walk.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
