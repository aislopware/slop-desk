//! Thin stdin adapter around [`slopdesk_hook::relay`]. All decisions live in
//! the library so they are testable without a process boundary; this file only
//! wires the real environment and stdin in, and pins the exit code to 0.

use std::io::Write as _;

use slopdesk_hook::{Config, relay};

fn main() {
    // `--version` FIRST, and it is the only argument this binary understands.
    //
    // The relay is forked twice per tool call and its whole cost is startup, so an argv branch here
    // is not free and was not added lightly. What buys it: `package-release.sh` asks every shipped
    // binary its version and refuses to package on a disagreement with `scripts/tool-stamps.pin`.
    // A gate with one exemption is a gate someone has to remember the shape of, and the exempt tool
    // would have been THIS one — the binary that gets copied to a SECOND place on disk by
    // `slopdesk-agenthooks install`, where "which build is that" is hardest to answer any other
    // way. One `nth(1)` against a read of stdin and a socket write is noise.
    //
    // Written through an explicit handle rather than `println!`: this crate bans the print macros
    // so that nothing on the relay path can ever put a stray line into the agent's turn, and that
    // ban is worth more than the two characters an exemption would save.
    //
    // The SECOND whitespace-separated field of the FIRST line is the version, as everywhere else.
    let flag = std::env::args_os().nth(1);
    if flag.is_some_and(|argument| argument == "--version") {
        let mut out = std::io::stdout().lock();
        let _unused = writeln!(out, "slopdesk-hook {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    // Every outcome — no socket, dead host, delivered — exits 0. Claude Code
    // surfaces a non-zero hook as a broken turn, and there is nothing the user
    // could do about a host that is not listening.
    let _ = relay(&Config::from_env(), std::io::stdin().lock());
}
