//! Where a daemon line goes: standard error, prefixed with the program's own name.
//!
//! ## One type, two traits, because it is one decision
//! [`slopdesk_hostserver::HostObserver`] is what the composition's ladders say, and
//! [`slopdesk_hostsession::SessionLog`] is what one pane says. They were two closures over the same
//! `log` in the Swift `main`, and splitting them into two types here would put the daemon's name in
//! two places and let one of them drift.
//!
//! ## Why stderr and not a file
//! Because hostd runs under superd, under launchd, and both already capture stderr into the place a
//! person looks — so a log file here would be a SECOND place, out of step with every other daemon
//! in the tree. A host that wants a file redirects one.
//!
//! ## The connection count is a line, not a metric
//! [`HostObserver::connection_count`] fires only when a ladder actually moved a registration, which
//! is what makes printing it honest: every line is a real change, so a log with no lines is a host
//! nothing happened to rather than one that stopped counting.
//!
//! ## Three lines a reader looks for, spelled once
//! The count, the bound port and the refusal are the three facts anyone asks this daemon about, and
//! they are the three a person greps for after `just host`. They are constants rather than inline
//! literals because two of the three are formatted in `main`, next to the listener, and a fact
//! worded in two files is a fact that ends up worded two ways.
//!
//! There is deliberately no PARSER here and no crate that owns one. `docs/60` F.8.5 DESIGNED a
//! supervisor that read these lines back to drive a menu bar, and never landed it; F.9 deleted the
//! menu bar and made the
//! CLI the only way to drive the host, and a CLI asks the daemon rather than reading over its
//! shoulder. Anything that needs these facts as DATA should grow a verb on hostd, not a regex.

use std::io::Write as _;

use slopdesk_hostserver::channel::HostObserver;
use slopdesk_hostsession::SessionLog;

/// Said with a decimal count after it, on every real change in the client count.
///
/// "Holding panes" is the distinction that matters and it is not decoration: this is
/// `Sessions::connection_count`, the connections holding at least one pane. It is deliberately NOT
/// `Host::peer_count`, which counts every open link including one that subscribed and took no
/// channel.
pub const CLIENTS_PREFIX: &str = "clients holding panes: ";

/// Said once, with the port that was actually BOUND, after the listener is up.
///
/// The port matters as much as the readiness: `--port 0` mints one, so the number hostd was asked
/// for is not always the number a client must dial.
pub const LISTENING_PREFIX: &str = "listening on 0.0.0.0:";

/// Said with a reason, immediately before a non-zero exit.
///
/// Both preflight deaths wear it — the listener that cannot bind and the superd that cannot be
/// reached — so "why did the host not come up" has exactly one thing to grep for.
pub const FAILED_PREFIX: &str = "failed to start: ";

/// The daemon's log, as both halves of the tree ask for one.
#[derive(Debug)]
pub struct Stderr {
    program: String,
}

impl Stderr {
    /// A log prefixed with `program` — whatever this daemon was invoked as, which is what a person
    /// greps for.
    #[must_use]
    pub fn named(program: &str) -> Self {
        Self {
            program: program.to_owned(),
        }
    }

    /// One line, prefixed and terminated.
    ///
    /// ONE `write_all` of ONE buffer, deliberately: two writes can interleave with another thread's
    /// between them, and a log whose lines splice is worse than no log. The result is dropped
    /// because there is no recovery from a failed write to stderr that is not itself a write to
    /// stderr.
    pub fn say(&self, line: &str) {
        let _ignored = std::io::stderr().write_all(self.rendered(line).as_bytes());
    }

    /// The exact bytes [`Stderr::say`] writes.
    ///
    /// Split out so the supervision contract can be tested against what goes down the pipe rather
    /// than against a literal retyped in a test — a literal would keep passing through the one
    /// change that matters, which is somebody editing this function.
    fn rendered(&self, line: &str) -> String {
        let mut rendered = String::with_capacity(self.program.len() + line.len() + 3);
        rendered.push_str(&self.program);
        rendered.push_str(": ");
        rendered.push_str(line);
        rendered.push('\n');
        rendered
    }
}

impl HostObserver for Stderr {
    fn connection_count(&self, count: usize) {
        self.say(&format!("{CLIENTS_PREFIX}{count}"));
    }

    fn log(&self, line: &str) {
        self.say(line);
    }
}

impl SessionLog for Stderr {
    fn line(&self, message: &str) {
        self.say(message);
    }
}

#[cfg(test)]
mod tests {
    use super::{CLIENTS_PREFIX, FAILED_PREFIX, LISTENING_PREFIX, Stderr};

    /// The rendered shape, byte for byte: program, `": "`, the line, one newline and nothing else.
    ///
    /// `rendered` is what `say` hands to `write_all`, so this pins the thing a reader greps and the
    /// thing an operator's `grep -c` counts. A second write, a missing terminator or a stray space
    /// all fail here rather than in a log nobody reads until it matters.
    #[test]
    fn a_line_is_the_program_then_the_line_then_one_newline() {
        let log = Stderr::named("slopdesk-hostd");
        assert_eq!(log.rendered("up"), "slopdesk-hostd: up\n");
        assert_eq!(log.rendered(""), "slopdesk-hostd: \n");
    }

    /// The three greppable lines, rendered the way `main` and [`HostObserver`] render them.
    ///
    /// [`HostObserver`]: slopdesk_hostserver::channel::HostObserver
    #[test]
    fn the_three_facts_render_the_way_a_reader_greps_them() {
        let log = Stderr::named("slopdesk-hostd");
        assert_eq!(
            log.rendered(&format!("{CLIENTS_PREFIX}7")),
            "slopdesk-hostd: clients holding panes: 7\n"
        );
        assert_eq!(
            log.rendered(&format!("{LISTENING_PREFIX}7654 (mode=shell)")),
            "slopdesk-hostd: listening on 0.0.0.0:7654 (mode=shell)\n"
        );
        assert_eq!(
            log.rendered(&format!("{FAILED_PREFIX}Address already in use")),
            "slopdesk-hostd: failed to start: Address already in use\n"
        );
    }
}
