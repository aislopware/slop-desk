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

use std::io::Write as _;

use slopdesk_hostserver::channel::HostObserver;
use slopdesk_hostsession::SessionLog;

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
        let mut rendered = String::with_capacity(self.program.len() + line.len() + 3);
        rendered.push_str(&self.program);
        rendered.push_str(": ");
        rendered.push_str(line);
        rendered.push('\n');
        let _ignored = std::io::stderr().write_all(rendered.as_bytes());
    }
}

impl HostObserver for Stderr {
    fn connection_count(&self, count: usize) {
        self.say(&format!("clients holding panes: {count}"));
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
