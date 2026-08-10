//! Thin stdin adapter around [`slopdesk_hook::relay`]. All decisions live in
//! the library so they are testable without a process boundary; this file only
//! wires the real environment and stdin in, and pins the exit code to 0.

use slopdesk_hook::{Config, relay};

fn main() {
    // Every outcome — no socket, dead host, delivered — exits 0. Claude Code
    // surfaces a non-zero hook as a broken turn, and there is nothing the user
    // could do about a host that is not listening.
    let _ = relay(&Config::from_env(), std::io::stdin().lock());
}
