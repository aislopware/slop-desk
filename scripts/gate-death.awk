# Finds an assignment whose command substitution runs `grep` with no `||` to catch a miss.
#
# Every gate script runs under `set -euo pipefail`, where `x=$(… | grep …)` that matches NOTHING
# exits 1 and takes the whole run with it — no message, and a log that ends early reads exactly like
# a log that passed. `check-supervisor.sh` calls this over `scripts/*.sh`.
#
# It lives in its own file rather than inline in the caller for a reason worth keeping: as shell
# text inside a `gate_deaths=$(…)` assignment, this program's own `/grep/` and `/\|\|/` literals made
# the check flag itself — the escaped `\|\|` contains no `||`, so the detector read its own source as
# an offender. A checker that cannot be written inside the thing it checks belongs beside it.
function flush() {
    if (buf ~ /grep/ && buf !~ /\|\|/) {
        printf "%s:%d: %s\n", file, start, substr(buf, 1, 100)
    }
    buf = ""
    start = 0
}
{
    if (start == 0) {
        if ($0 ~ /^[ \t]*(local |export )?[A-Za-z_][A-Za-z_0-9]*=["']?\$\(/) {
            start = FNR
            buf = $0
        } else {
            next
        }
    } else {
        buf = buf " " $0
    }
    # Close on the line that ends the substitution — optionally quoted, optionally followed by an
    # `||` guard. The line cap is only a runaway backstop for a shape this cannot parse.
    if ($0 ~ /\)["']?([ \t]*\|\|.*)?[ \t]*$/ || FNR - start > 40) {
        flush()
    }
}
END {
    if (start) {
        flush()
    }
}
