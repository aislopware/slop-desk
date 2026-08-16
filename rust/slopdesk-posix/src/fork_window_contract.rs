//! The fork-to-exec window, pinned by disassembly.
//!
//! Between `fork()` and `execve()` the child is a copy of a multi-threaded process holding locks
//! only the dead threads could release. Calling anything that takes one — the allocator, the panic
//! machinery, `std::fmt`, a `Drop` impl that frees — hangs that child forever, and a hung child is
//! a pane that never prints its first prompt. The rule is therefore NOT "avoid `for` loops"; it is
//! "emit no call that could reach malloc or panic".
//!
//! A comment cannot hold that line — on the Swift side it did not, which is why this pin exists at
//! all. So the rule is enforced against the machine code: `exec_in_forked_child`'s every `bl` must
//! be an async-signal-safe libc entry point, and nothing may be called between the `fork` and the
//! window itself.
//!
//! ## Why it lives in `slopdesk-posix` rather than in superd
//! It moved here with the window it guards (stage 28). A disassembly pin has to be compiled into
//! the same object as its subject, so wherever the `fork` goes, this follows — and the whole point
//! of collecting the unsafe code in one crate is that its proofs travel with it.
//!
//! ## This pin used to be in Swift
//! `Tests/SlopDeskHostTests/ForkExecWindowContractTests.swift` guarded the same window when hostd
//! forked its own panes. superd forks them now — through this crate — and the Swift copy of the
//! window was deleted rather than kept in parallel: one window, one language, one contract.
//!
//! ## Why the tooling is `nm` + `otool`
//! They ship with the Xcode command-line tools this repo already requires, read Mach-O natively,
//! and print the symbol names demangled enough to match on. The alternative — trusting `#[inline]`
//! attributes and code review — is what this test exists to replace.

// A failed lookup here means the pin itself is broken, and a broken pin must be loud — panicking
// IS the report. Slicing is the same story: the indices come from `position()` on the same vector.
#![expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::process::Command;

/// Everything the window is allowed to call.
///
/// All async-signal-safe (POSIX.1-2017 §2.4.3) except `_exit`, which is the failure arm and is
/// safe by construction. Adding a name here is a decision about the child's safety — take it
/// deliberately, and only for a real syscall stub.
const ALLOWED_CALLS: &[&str] = &[
    "_chdir",
    "_close",
    "_dup2",
    "_execve",
    "_exit",
    "__exit",
    "_ioctl",
    "_setsid",
    "_sigemptyset",
    "_signal",
    "_sigprocmask",
];

/// Substrings that are, on their own, proof the window is broken. A hit here means the compiler
/// emitted a call into the allocator, the panic machinery, or a destructor.
const FORBIDDEN_FRAGMENTS: &[&str] = &[
    "malloc",
    "free",
    "alloc",
    "panic",
    "unwind",
    "Unwind",
    "core3fmt",
    "drop_in_place",
    "lock",
    "mutex",
    "printf",
    "abort",
];

#[test]
fn the_window_calls_nothing_but_async_signal_safe_libc() {
    let binary = library_object();
    let symbol = single_symbol_containing("exec_in_forked_child", &binary);
    let body = disassemble(&symbol, &binary);
    assert!(
        body.len() > 20,
        "disassembly of {symbol} is {} lines — the symbol lookup found the wrong thing",
        body.len()
    );

    for line in &body {
        assert!(
            indirect_call(line).is_none(),
            "the fork-to-exec window makes an INDIRECT call (`{}`). Its target cannot be audited, so it is \
             not allowed here at all: a closure, a trait object, a non-inlined generic or a lazily-bound \
             runtime thunk reaching this window would take a lock the parent held at `fork()` and deadlock \
             the child before `execve` — a pane that opens, reports success and then stays blank forever. \
             Hoist whatever produced it into the PARENT.",
            line.trim()
        );
        let Some(target) = call_target(line) else {
            continue;
        };
        for fragment in FORBIDDEN_FRAGMENTS {
            assert!(
                !target.contains(fragment),
                "the fork-to-exec window calls `{target}`, which matches the forbidden fragment \
                 `{fragment}`. Whatever was just added to `exec_in_forked_child` allocates, formats, panics \
                 or drops — in a forked child that is a hang, not a crash, so it will look like one pane \
                 that never starts. Read the module header in pty.rs."
            );
        }
        assert!(
            ALLOWED_CALLS.contains(&target.as_str()),
            "the fork-to-exec window calls `{target}`, which is not in ALLOWED_CALLS. If it is a genuine \
             async-signal-safe syscall stub, add it there with a reason; if it is a Rust function, hoist it \
             into the PARENT before the fork instead."
        );
    }
}

/// The parent's side of the same contract: `fork` must be followed by the branch into the window
/// and nothing else. A call in between runs in BOTH processes — including the child.
#[test]
fn nothing_runs_between_the_fork_and_the_window() {
    let binary = library_object();
    let symbol = single_function_symbol("3pty9spawn_pty", &binary);
    let body = disassemble(&symbol, &binary);

    let fork = body
        .iter()
        .position(|line| call_target(line).is_some_and(|target| target == "_fork"))
        .expect("no call to `fork` in spawn_pty — the fork moved, so this test guards nothing");
    let window = body
        .iter()
        .position(|line| call_target(line).is_some_and(|target| target.contains("exec_in_forked_child")))
        .expect("no call to `exec_in_forked_child` in spawn_pty — the window moved out of spawn_pty");
    assert!(
        fork < window,
        "the window is called before the fork, which cannot be right"
    );

    // Walk the CHILD's path, not the linear disassembly: `cbz w0, <addr>` after the fork jumps to
    // the child block, and the parent's error handling sits between the two in address order. Only
    // the child block is under contract — asserting over the linear range would fail on the
    // parent's own (perfectly legal) calls.
    let branch = body[fork..window]
        .iter()
        .find_map(|line| line.split("cbz").nth(1))
        .and_then(|rest| rest.split(", ").nth(1))
        .and_then(|target| parse_address(target.trim()))
        .expect("no `cbz` after the fork — the `if child == 0` test is not a branch any more");
    let child_block = body
        .iter()
        .position(|line| address_of(line) == Some(branch))
        .expect("the `cbz` after the fork targets an address outside spawn_pty");

    for line in &body[child_block..window] {
        assert!(
            call_target(line).is_none() && indirect_call(line).is_none(),
            "`{}` sits between the fork and the window, on the CHILD's path. It runs in a process that may \
             not allocate or take a lock. Compute it in the parent, before the fork, and pass the result in.",
            line.trim()
        );
    }
}

// MARK: Mach-O plumbing

/// The object file holding the crate's own code.
///
/// An integration test links the library, so `current_exe()` contains the symbols — but it also
/// contains the test harness, `std`, and every dependency, and a stale copy from an earlier build
/// would still be there. The freshly-linked test binary is the honest target.
fn library_object() -> String {
    let exe = std::env::current_exe().expect("no current_exe");
    exe.to_string_lossy().into_owned()
}

/// The one symbol whose name contains `fragment`. Ambiguity is a failure, not a coin flip: a
/// duplicated window would let this pin disassemble one copy and silently stop guarding the other.
fn single_symbol_containing(fragment: &str, binary: &str) -> String {
    single_symbol(binary, fragment, |symbol| symbol.contains(fragment))
}

/// The symbol of the plain Rust function whose mangled path ENDS at `path` (e.g.
/// `"3pty9spawn_pty"`), under either mangling scheme.
///
/// `contains` is not enough for a function that has closures or generic instantiations: those spell
/// the same path and then keep going (`…9spawn_ptys_0`, `…9spawn_pty0`), so a substring match finds
/// thirteen symbols and this pin refuses to choose. What distinguishes the function ITSELF is what
/// follows the path — nothing at all under `v0`, and only the disambiguating hash under `legacy`:
///
/// - `v0`     — `__RNvNtCs<hash>_14slopdesk_posix3pty9spawn_pty`
/// - `legacy` — `__ZN14slopdesk_posix3pty9spawn_pty17h<16 hex>E`
///
/// Both are accepted because the scheme is the COMPILER's choice, not this crate's: rustc 1.97
/// switched the default to `v0`, which silently emptied a `contains("pty9spawn_pty17")` match and
/// failed this pin on a toolchain bump that changed no code. A pin may fail because the window
/// broke; it must not fail because the name of the window changed spelling.
fn single_function_symbol(path: &str, binary: &str) -> String {
    single_symbol(binary, path, |symbol| {
        let Some(tail) = symbol.split_once(path).map(|(_, tail)| tail) else {
            return false;
        };
        tail.is_empty()
            || (tail.starts_with("17h") && tail.ends_with('E') && tail.len() == "17h".len() + 16 + "E".len())
    })
}

/// The single symbol in `binary` accepted by `accept`; `described_as` names it in the failure.
fn single_symbol(binary: &str, described_as: &str, accept: impl Fn(&str) -> bool) -> String {
    let output = Command::new("nm")
        .arg(binary)
        .output()
        .expect("nm is not runnable");
    let text = String::from_utf8_lossy(&output.stdout);
    let mut matches: Vec<String> = text
        .lines()
        .filter_map(|line| line.split_whitespace().nth(2))
        .filter(|symbol| accept(symbol))
        .map(str::to_owned)
        .collect();
    matches.sort_unstable();
    matches.dedup();
    assert_eq!(
        matches.len(),
        1,
        "expected exactly one symbol for `{described_as}` in {binary}, found {matches:?}"
    );
    matches.swap_remove(0)
}

/// The instructions of exactly one function.
///
/// `otool -p` starts at the symbol and then keeps going through the rest of the section, so the
/// listing is cut at the next symbol label — without that, this reads the whole binary and every
/// assertion below becomes vacuous.
fn disassemble(symbol: &str, binary: &str) -> Vec<String> {
    let output = Command::new("otool")
        .args(["-tvV", "-p", symbol, binary])
        .output()
        .expect("otool is not runnable");
    let text = String::from_utf8_lossy(&output.stdout);
    let mut lines = Vec::new();
    let mut started = false;
    for line in text.lines() {
        let is_label = line.ends_with(':') && !line.starts_with(char::is_whitespace);
        if is_label {
            if started {
                break;
            }
            started = line.contains(symbol);
            continue;
        }
        if started {
            lines.push(line.to_owned());
        }
    }
    lines
}

/// The address a disassembly line sits at. Lines are `0000000100030be0\tbl\t…`.
fn address_of(line: &str) -> Option<u64> {
    u64::from_str_radix(line.split_whitespace().next()?, 16).ok()
}

/// `0x100030c00` → the number. Branch targets carry the prefix; line addresses do not.
fn parse_address(text: &str) -> Option<u64> {
    u64::from_str_radix(text.strip_prefix("0x")?, 16).ok()
}

/// The register an INDIRECT call branches through, or `None` for anything else.
///
/// The whole `blr` family, PAC-authenticated spellings included (`blraa`, `blrab`, `blraaz`,
/// `blrabz`): what matters is that the target is in a register, so no allowlist can be applied to
/// it. [`call_target`] cannot see these — it matches on the literal `bl` mnemonic, which never
/// equals `blr` — and their absence was asserted by the Swift test this file replaced. Losing that
/// assertion is how an unauditable call gets into the pre-`execve` window with CI fully green.
fn indirect_call(line: &str) -> Option<String> {
    let mut fields = line.split_whitespace();
    let _address = fields.next()?;
    let mnemonic = fields.next()?;
    if !mnemonic.starts_with("blr") {
        return None;
    }
    Some(fields.next().unwrap_or("").to_owned())
}

/// The callee of a `bl`, or `None` for anything else.
///
/// Two spellings appear: `bl <addr> ; symbol stub for: _close` for a libc import, and
/// `bl <mangled>` for a direct call within the image.
fn call_target(line: &str) -> Option<String> {
    let after = line.split_once("\tbl\t").or_else(|| line.split_once(" bl "))?.1;
    if let Some((_ignored, stub)) = after.split_once("symbol stub for: ") {
        return Some(stub.trim().to_owned());
    }
    let direct = after.split(';').next()?.trim();
    if direct.starts_with("0x") {
        // A branch to a bare address with no symbol — the linker resolved it locally. Report it so
        // the allowlist rejects it rather than the test silently skipping it.
        return Some(direct.to_owned());
    }
    Some(direct.to_owned())
}
