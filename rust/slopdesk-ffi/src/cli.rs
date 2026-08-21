//! What the `slopdesk` CLI asks: its flags, its completion scripts, its config file, its tables.
//!
//! `rust/slopdesk-cli` owns all four. This is the door. The crate was written for this port and
//! then left unlinked for two days, on a rule — "a port ships over a socket, never FFI" — that has
//! since been struck: the CLI is a process that starts, does one thing and exits, so its logic is
//! in-process by necessity and lifetime-coupled to its caller, which is exactly what a linked
//! library is for.
//!
//! ## Everything crosses by value, because a CLI has no accumulator
//! There is no state here that outlives a call. A parse is a function of its argv, a script is a
//! function of its shell, a table is a function of its rows. So every entry point is the pure
//! convention: inputs as `(ptr, len)`, the answer written into a lent buffer.
//!
//! ## The rows cross as JSON TEXT, not as records
//! They arrive at the near side as JSON — the control socket answers NDJSON — and they leave as
//! JSON or as a table. Decoding them into a flat record type on the way through would mean writing
//! a schema for six different lists and re-encoding it on both sides. The crate already parses
//! JSON, for the reason its own manifest gives: these rows carry pane titles and cwd paths a
//! foreign program drew into a PTY, and hand-rolling an unescaper for that is the classic place to
//! be wrong.
//!
//! ## The keybind grammar is asked back
//! `config validate` checks a file against the grammar the app actually honours, and that grammar
//! is a Swift parser this crate has no business depending on. So it crosses as a callback with its
//! context, the way the mux reap's admitted-lane question does.

use std::ffi::c_uchar;

use slopdesk_cli::args::{Invocation, OutputFormat, ParseError};
use slopdesk_cli::completions::Shell;
use slopdesk_cli::config::{ValidationError, default_path, resolve_path, validate};
use slopdesk_cli::formatting::{TableKind, render_json_text, table, table_from_json};
use slopdesk_cli::version::summary;
use slopdesk_cli::vocabulary::{planned_names, ready_names, usage};

use crate::host_state::SlopDeskByteSpan;
use crate::{TextArena, borrow, deliver, records_of};

/// Aligned column tables, honouring `--no-headers`.
pub const SLOPDESK_CLI_TEXT: u32 = 0;
/// Compact, key-sorted JSON, for scripting.
pub const SLOPDESK_CLI_JSON: u32 = 1;

/// The parse succeeded.
pub const SLOPDESK_CLI_OK: u32 = 0;
/// A flag the parser does not know, seen before any subcommand.
pub const SLOPDESK_CLI_UNKNOWN_FLAG: u32 = 1;
/// A flag that takes a value, with nothing after it.
pub const SLOPDESK_CLI_MISSING_VALUE: u32 = 2;
/// A flag whose value did not parse.
pub const SLOPDESK_CLI_INVALID_VALUE: u32 = 3;

/// bash, via `complete -F`.
pub const SLOPDESK_SHELL_BASH: u32 = 0;
/// zsh, via `compdef` and `_describe`.
pub const SLOPDESK_SHELL_ZSH: u32 = 1;
/// fish, via one `complete -c` line per subcommand.
pub const SLOPDESK_SHELL_FISH: u32 = 2;
/// elvish, via `edit:completion:arg-completer`.
pub const SLOPDESK_SHELL_ELVISH: u32 = 3;
/// PowerShell, via `Register-ArgumentCompleter -Native`.
pub const SLOPDESK_SHELL_POWERSHELL: u32 = 4;

/// `windows` — id, title, tabs, focused.
pub const SLOPDESK_CLI_TABLE_WINDOWS: u32 = 0;
/// `tabs` — id, window, title, panes, focused, badge.
pub const SLOPDESK_CLI_TABLE_TABS: u32 = 1;
/// `panes` — id, tab, title, kind, focused, cwd.
pub const SLOPDESK_CLI_TABLE_PANES: u32 = 2;
/// `font list` — family, monospace, scope.
pub const SLOPDESK_CLI_TABLE_FONTS: u32 = 3;
/// `keybind list` — action, keys.
pub const SLOPDESK_CLI_TABLE_KEYBINDS: u32 = 4;
/// `config show` — key, value.
pub const SLOPDESK_CLI_TABLE_CONFIG: u32 = 5;

/// How much a variable-length answer needs: how many records, and how many bytes of text.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskCliShape {
    /// How many records the answer has.
    pub count: usize,
    /// How many bytes their text needs.
    pub arena_len: usize,
}

/// One fully-parsed `slopdesk` invocation, flat.
///
/// The token spans live in the caller's span array: the first `rest_count` are the residual
/// arguments, the `exec_count` after them are the `-e` command. Two lists in one array because they
/// are never both long and the shape call already reports one count.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskCliInvocation {
    /// The subcommand. Empty means a bare invocation.
    pub subcommand: SlopDeskByteSpan,
    /// `--socket PATH`, meaningful only when `has_socket`.
    pub socket_path: SlopDeskByteSpan,
    /// `--config-file PATH`, meaningful only when `has_config`.
    pub config_file: SlopDeskByteSpan,
    /// The flag a parse error names, meaningful only when `error` is not `SLOPDESK_CLI_OK`.
    pub error_flag: SlopDeskByteSpan,
    /// The value a parse error rejected, meaningful only for `SLOPDESK_CLI_INVALID_VALUE`.
    pub error_value: SlopDeskByteSpan,
    /// `--timeout <ms>`.
    pub timeout_ms: i64,
    /// How many of the leading token spans are residual arguments.
    pub rest_count: usize,
    /// How many spans after those are the `-e` command.
    pub exec_count: usize,
    /// `SLOPDESK_CLI_TEXT` or `SLOPDESK_CLI_JSON`.
    pub format: u32,
    /// Why the parse failed, or `SLOPDESK_CLI_OK`.
    pub error: u32,
    /// Whether `--socket` was given.
    pub has_socket: bool,
    /// Whether `--config-file` was given.
    pub has_config: bool,
    /// Whether `-e` was given. Distinguishes an absent command from an empty one.
    pub has_exec: bool,
    /// `--no-headers`.
    pub no_headers: bool,
    /// `-y` / `--yes`.
    pub assume_yes: bool,
    /// `-h` / `--help`.
    pub wants_help: bool,
    /// Whether this invocation launches the client GUI.
    pub launch_gui: bool,
}

/// One config-file syntax problem.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskCliConfigError {
    /// What is wrong with the line, phrased for a user reading a terminal.
    pub message: SlopDeskByteSpan,
    /// The 1-based line number.
    pub line: usize,
}

/// The output format a code names. An unknown code reads as text, the default.
const fn format_of(code: u32) -> OutputFormat {
    if code == SLOPDESK_CLI_JSON {
        OutputFormat::Json
    } else {
        OutputFormat::Text
    }
}

/// The code a format crosses as.
const fn format_code(format: OutputFormat) -> u32 {
    match format {
        OutputFormat::Text => SLOPDESK_CLI_TEXT,
        OutputFormat::Json => SLOPDESK_CLI_JSON,
    }
}

/// The shell a code names.
const fn shell_of(code: u32) -> Option<Shell> {
    match code {
        SLOPDESK_SHELL_BASH => Some(Shell::Bash),
        SLOPDESK_SHELL_ZSH => Some(Shell::Zsh),
        SLOPDESK_SHELL_FISH => Some(Shell::Fish),
        SLOPDESK_SHELL_ELVISH => Some(Shell::Elvish),
        SLOPDESK_SHELL_POWERSHELL => Some(Shell::PowerShell),
        _ => None,
    }
}

/// The code a shell crosses as.
const fn shell_code(shell: Shell) -> u32 {
    match shell {
        Shell::Bash => SLOPDESK_SHELL_BASH,
        Shell::Zsh => SLOPDESK_SHELL_ZSH,
        Shell::Fish => SLOPDESK_SHELL_FISH,
        Shell::Elvish => SLOPDESK_SHELL_ELVISH,
        Shell::PowerShell => SLOPDESK_SHELL_POWERSHELL,
    }
}

/// The list a table kind names. An unknown kind reads as the two-column config table, which shows
/// whatever the rows carry under `key` and `value` rather than inventing columns.
const fn table_of(code: u32) -> TableKind {
    match code {
        SLOPDESK_CLI_TABLE_WINDOWS => TableKind::Windows,
        SLOPDESK_CLI_TABLE_TABS => TableKind::Tabs,
        SLOPDESK_CLI_TABLE_PANES => TableKind::Panes,
        SLOPDESK_CLI_TABLE_FONTS => TableKind::Fonts,
        SLOPDESK_CLI_TABLE_KEYBINDS => TableKind::Keybinds,
        _ => TableKind::Config,
    }
}

/// The caller's argument list, as owned strings. Bytes that are not UTF-8 read lossily: an argv is
/// whatever a shell handed the process, and refusing one would be a decision this door may not
/// make.
///
/// # Safety
/// `spans` must describe `count` live entries, and `pool` must be live for `pool_len` bytes.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's argument list IS the boundary this module documents"
)]
unsafe fn arguments(
    spans: *const SlopDeskByteSpan,
    count: usize,
    pool: *const c_uchar,
    pool_len: usize,
) -> Vec<String> {
    // SAFETY: the caller's obligations, discharged by Swift's `withUnsafeBufferPointer`.
    let (spans, bytes) = unsafe { (records_of(spans, count), borrow(pool, pool_len)) };
    spans
        .iter()
        .map(|span| {
            let start = span.offset as usize;
            let end = start.saturating_add(span.length as usize);
            String::from_utf8_lossy(bytes.get(start..end).unwrap_or_default()).into_owned()
        })
        .collect()
}

/// Copies one string into the caller's buffer, answering the bytes it needed.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "writing the answer into the caller's buffer is the other half of the boundary"
)]
const unsafe fn text(answer: &str, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Writes a record list and its arena into the caller's buffers if both fit, answering the shape
/// either way. The two-call shape every variable-length answer on this door uses.
///
/// # Safety
/// The output pointers must be null, or writable for their stated capacities.
#[expect(
    unsafe_code,
    reason = "writing the answer into the caller's buffers is the other half of the boundary"
)]
const unsafe fn spill<T: Copy>(
    records: &[T],
    pool: &TextArena,
    out: *mut T,
    cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    let shape = SlopDeskCliShape {
        count: records.len(),
        arena_len: pool.0.len(),
    };
    if cap < shape.count || arena_cap < shape.arena_len {
        return shape;
    }
    // An empty half is written by NOT writing it: a parse with no residual tokens still has a
    // subcommand in its arena, so the two halves are lent and filled independently.
    if !out.is_null() && shape.count > 0 {
        // SAFETY: the buffer is non-null and large enough, by the check above and the caller's
        // obligation that it is writable for `cap` records.
        unsafe { std::ptr::copy_nonoverlapping(records.as_ptr(), out, shape.count) };
    }
    if !arena.is_null() && shape.arena_len > 0 {
        // SAFETY: the buffer is non-null and large enough, by the check above and the caller's
        // obligation that it is writable for `arena_cap` bytes.
        unsafe { std::ptr::copy_nonoverlapping(pool.0.as_ptr(), arena, shape.arena_len) };
    }
    shape
}

/// The default IPC wait, in milliseconds.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_cli_default_timeout_ms() -> i64 {
    slopdesk_cli::args::DEFAULT_TIMEOUT_MS
}

/// The env var that overrides the config-file location.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn slopdesk_cli_config_env_key(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(slopdesk_cli::config::CONFIG_FILE_ENV_KEY, out, cap) }
}

/// The env var carrying an optional short build or commit hash.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn slopdesk_cli_build_hash_env_key(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(slopdesk_cli::version::BUILD_HASH_ENV_KEY, out, cap) }
}

/// Parses the global flags and the subcommand out of an argument list, `args[0]` included and
/// skipped. Answers the shape the token spans and the arena need; call again with both lent to
/// receive them.
///
/// The record is filled on BOTH calls — it is fixed-size, so there is nothing to size — but its
/// spans only name bytes once the arena has been written.
///
/// # Safety
/// The input pair must describe live memory for the call; the output pointers must be null or
/// writable for their stated capacities.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_parse(
    args: *const SlopDeskByteSpan,
    args_count: usize,
    args_pool: *const c_uchar,
    args_pool_len: usize,
    out_record: *mut SlopDeskCliInvocation,
    out_tokens: *mut SlopDeskByteSpan,
    tokens_cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    // SAFETY: the caller's obligation on the argument list.
    let command_line = unsafe { arguments(args, args_count, args_pool, args_pool_len) };
    let mut pool = TextArena::default();
    let mut tokens: Vec<SlopDeskByteSpan> = Vec::new();
    let mut record = SlopDeskCliInvocation {
        timeout_ms: slopdesk_cli::args::DEFAULT_TIMEOUT_MS,
        ..SlopDeskCliInvocation::default()
    };
    match slopdesk_cli::args::parse(&command_line) {
        Ok(invocation) => flatten(&invocation, &mut record, &mut tokens, &mut pool),
        Err(error) => note(&error, &mut record, &mut pool),
    }
    if !out_record.is_null() {
        // SAFETY: the caller's obligation that this points at one writable record.
        unsafe { *out_record = record };
    }
    // SAFETY: the caller's obligations on the output buffers.
    unsafe { spill(&tokens, &pool, out_tokens, tokens_cap, out_arena, arena_cap) }
}

/// Flattens a parsed invocation into the record, its tokens and its arena.
fn flatten(
    invocation: &Invocation,
    record: &mut SlopDeskCliInvocation,
    tokens: &mut Vec<SlopDeskByteSpan>,
    pool: &mut TextArena,
) {
    record.subcommand = span(pool.intern(invocation.subcommand.as_bytes()));
    record.format = format_code(invocation.format);
    record.no_headers = invocation.no_headers;
    record.timeout_ms = invocation.timeout_ms;
    record.assume_yes = invocation.assume_yes;
    record.wants_help = invocation.wants_help;
    record.launch_gui = invocation.launch_gui;
    if let Some(path) = invocation.socket_path.as_ref() {
        record.has_socket = true;
        record.socket_path = span(pool.intern(path.as_bytes()));
    }
    if let Some(path) = invocation.config_file.as_ref() {
        record.has_config = true;
        record.config_file = span(pool.intern(path.as_bytes()));
    }
    for token in &invocation.rest {
        tokens.push(span(pool.intern(token.as_bytes())));
    }
    record.rest_count = invocation.rest.len();
    if let Some(command) = invocation.exec_command.as_ref() {
        record.has_exec = true;
        for token in command {
            tokens.push(span(pool.intern(token.as_bytes())));
        }
        record.exec_count = command.len();
    }
}

/// Notes a parse failure into the record and its arena.
fn note(error: &ParseError, record: &mut SlopDeskCliInvocation, pool: &mut TextArena) {
    match error {
        ParseError::UnknownFlag(flag) => {
            record.error = SLOPDESK_CLI_UNKNOWN_FLAG;
            record.error_flag = span(pool.intern(flag.as_bytes()));
        },
        ParseError::MissingValue(flag) => {
            record.error = SLOPDESK_CLI_MISSING_VALUE;
            record.error_flag = span(pool.intern(flag.as_bytes()));
        },
        ParseError::InvalidValue { flag, value } => {
            record.error = SLOPDESK_CLI_INVALID_VALUE;
            record.error_flag = span(pool.intern(flag.as_bytes()));
            record.error_value = span(pool.intern(value.as_bytes()));
        },
    }
}

/// The span an arena run crosses as.
const fn span(run: (u32, u32)) -> SlopDeskByteSpan {
    SlopDeskByteSpan {
        offset: run.0,
        length: run.1,
    }
}

/// The shell a name on the command line means, case-insensitively, with `pwsh` aliasing
/// `powershell`. Answers whether the name is one; the code is written through `out_shell`.
///
/// # Safety
/// The input pair must be live for the call, and `out_shell` must be null or point to one writable
/// `uint32_t`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_shell(
    name: *const c_uchar,
    name_len: usize,
    out_shell: *mut u32,
) -> bool {
    // SAFETY: the caller's obligation on the name.
    let raw = String::from_utf8_lossy(unsafe { borrow(name, name_len) }).into_owned();
    let Some(shell) = Shell::parse(&raw) else {
        return false;
    };
    if !out_shell.is_null() {
        // SAFETY: the caller's obligation that this points at one writable u32.
        unsafe { *out_shell = shell_code(shell) };
    }
    true
}

// The code-to-NAME direction has no door: Swift's `CLICompletions.Shell` is a `String`-raw enum
// whose cases ARE the CLI tokens, so its `rawValue` is that answer already. What has to be shared
// is the PARSE — which spellings a user may type, `pwsh` among them — and `slopdesk_cli_shell`
// above is it; a name the enum could produce but the parser would reject fails `init?(argument:)`
// on the spot.

/// The completion script for a shell, terminated by a trailing newline.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_completion_script(shell: u32, out: *mut c_uchar, cap: usize) -> usize {
    let Some(shell) = shell_of(shell) else {
        return 0;
    };
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&slopdesk_cli::completions::script(shell), out, cap) }
}

/// The subcommand surface the completions offer, in table order: the RUNNABLE verbs only.
///
/// The filter is the point. Six designed-but-unimplemented verbs used to cross this door, so every
/// shell offered `open`, `import`, `export`, `features`, `state:claude` and `ipc`, and every one of
/// them exited 2 with "not available yet" the moment a user accepted the completion. Availability
/// now lives beside the name in the crate's table, and this door can only see the half that runs.
///
/// # Safety
/// The output pointers must be null, or writable for their stated capacities.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_subcommands(
    out: *mut SlopDeskByteSpan,
    cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    // SAFETY: the caller's obligations on the output buffers.
    unsafe { names(&ready_names(), out, cap, out_arena, arena_cap) }
}

/// The verbs the vocabulary DOCUMENTS but does not implement, in table order.
///
/// The near side asks this for exactly one reason: to tell a user who typed `ipc` that it is
/// planned, apart from a user who typed `opne` and made a mistake. Nothing may offer this list for
/// completion — that is what `slopdesk_cli_subcommands` is for, and the two are disjoint by
/// construction because one table produces both.
///
/// # Safety
/// The output pointers must be null, or writable for their stated capacities.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_planned_subcommands(
    out: *mut SlopDeskByteSpan,
    cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    // SAFETY: the caller's obligations on the output buffers.
    unsafe { names(&planned_names(), out, cap, out_arena, arena_cap) }
}

/// Interns a name list into one arena and spills it — the shared body of the two doors above, so
/// that "a list of subcommand names crosses this way" is written once.
///
/// # Safety
/// The output pointers must be null, or writable for their stated capacities.
#[expect(
    unsafe_code,
    reason = "writing the answer into the caller's buffers is the other half of the boundary"
)]
unsafe fn names(
    list: &[&str],
    out: *mut SlopDeskByteSpan,
    cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    let mut pool = TextArena::default();
    let spans: Vec<SlopDeskByteSpan> = list
        .iter()
        .map(|name| span(pool.intern(name.as_bytes())))
        .collect();
    // SAFETY: the caller's obligations on the output buffers.
    unsafe { spill(&spans, &pool, out, cap, out_arena, arena_cap) }
}

/// The complete `--help` text, terminated by a trailing newline.
///
/// `program` is `argv[0]`'s last component rather than a constant, so a renamed or symlinked binary
/// describes itself by the name the user actually typed. Empty bytes fall back to `slopdesk`: a
/// usage block whose synopsis line names nothing is worse than one naming the canonical binary.
///
/// The whole block crosses — synopsis, every section, the `config` note and the global flags —
/// because the subcommand list, its availability and its help text are one table and splitting the
/// rendering would put half of that table back on the near side.
///
/// # Safety
/// `program` must be live for `program_len` bytes; `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_usage(
    program: *const c_uchar,
    program_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the program name.
    let raw = String::from_utf8_lossy(unsafe { borrow(program, program_len) }).into_owned();
    let name = if raw.is_empty() { "slopdesk" } else { raw.as_str() };
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&usage(name), out, cap) }
}

/// The config-file path: an explicit `--config-file`, else the env override, else the XDG default.
///
/// Every candidate is passed by value rather than looked up, because asking the environment is I/O
/// and the ORDER is the part that was worth porting. An empty pair means the value is absent.
///
/// # Safety
/// Every input pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_config_path(
    explicit: *const c_uchar,
    explicit_len: usize,
    from_env: *const c_uchar,
    from_env_len: usize,
    xdg: *const c_uchar,
    xdg_len: usize,
    home: *const c_uchar,
    home_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations on the five input pairs.
    let (explicit, from_env, xdg, home, fallback) = unsafe {
        (
            String::from_utf8_lossy(borrow(explicit, explicit_len)).into_owned(),
            String::from_utf8_lossy(borrow(from_env, from_env_len)).into_owned(),
            String::from_utf8_lossy(borrow(xdg, xdg_len)).into_owned(),
            String::from_utf8_lossy(borrow(home, home_len)).into_owned(),
            String::from_utf8_lossy(borrow(fallback, fallback_len)).into_owned(),
        )
    };
    let lookup = |name: &str| -> Option<String> {
        match name {
            slopdesk_cli::config::CONFIG_FILE_ENV_KEY => Some(from_env.clone()),
            "XDG_CONFIG_HOME" => Some(xdg.clone()),
            "HOME" => Some(home.clone()),
            _ => None,
        }
    };
    let answer = resolve_path(Some(explicit.as_str()), &lookup, &fallback);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&answer, out, cap) }
}

/// The XDG default config path, with no explicit override in play.
///
/// # Safety
/// Every input pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_config_default_path(
    xdg: *const c_uchar,
    xdg_len: usize,
    home: *const c_uchar,
    home_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations on the three input pairs.
    let (xdg, home, fallback) = unsafe {
        (
            String::from_utf8_lossy(borrow(xdg, xdg_len)).into_owned(),
            String::from_utf8_lossy(borrow(home, home_len)).into_owned(),
            String::from_utf8_lossy(borrow(fallback, fallback_len)).into_owned(),
        )
    };
    let lookup = |name: &str| -> Option<String> {
        match name {
            "XDG_CONFIG_HOME" => Some(xdg.clone()),
            "HOME" => Some(home.clone()),
            _ => None,
        }
    };
    let answer = default_path(&lookup, &fallback);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&answer, out, cap) }
}

/// The `keybind` value one config line declares, written into the lent buffer.
///
/// Answers 0 for every line that declares none — blank, a comment, a `[section]` header, another
/// key, or a `keybind` with nothing after the `=`. The client's loader reads its file through this,
/// and `slopdesk_cli_config_validate` reports on the SAME reading, so the validator cannot call a
/// line good that the loader will silently drop. The trim includes a carriage return, which is what
/// makes a CRLF file declare the bindings it looks like it declares.
///
/// # Safety
/// The input pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_config_keybind_value(
    line: *const c_uchar,
    line_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let raw = String::from_utf8_lossy(unsafe { borrow(line, line_len) }).into_owned();
    let Some(value) = slopdesk_cli::config::keybind_value(&raw) else {
        return 0;
    };
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(value, out, cap) }
}

/// Validates a config file against the keybind grammar, answering one record per problem. An empty
/// answer means the file is valid.
///
/// The grammar is [`slopdesk_terminal::keybind`], the same one the app parses its bindings with, so
/// the verdict tracks exactly what will be honoured. `validate` still takes it as a parameter — the
/// file's shape and the value's grammar are separate questions, and the stand-in in its own tests
/// depends on that — but the answer no longer leaves this side of the door.
///
/// # Safety
/// The input pair must be live for the call and the output pointers must be null or writable for
/// their capacities.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_config_validate(
    contents: *const c_uchar,
    contents_len: usize,
    out: *mut SlopDeskCliConfigError,
    cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskCliShape {
    // SAFETY: the caller's obligation on the contents.
    let text_in = String::from_utf8_lossy(unsafe { borrow(contents, contents_len) }).into_owned();
    let asking = |value: &str| -> bool { slopdesk_terminal::keybind::parse_line(value).is_some() };
    let problems: Vec<ValidationError> = validate(&text_in, &asking);
    let mut pool = TextArena::default();
    let records: Vec<SlopDeskCliConfigError> = problems
        .iter()
        .map(|problem| {
            SlopDeskCliConfigError {
                message: span(pool.intern(problem.message.as_bytes())),
                line: problem.line,
            }
        })
        .collect();
    // SAFETY: the caller's obligations on the output buffers.
    unsafe { spill(&records, &pool, out, cap, out_arena, arena_cap) }
}

/// Renders one list from the JSON text the control socket answered with.
///
/// # Safety
/// The input pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_table(
    kind: u32,
    rows_json: *const c_uchar,
    rows_json_len: usize,
    format: u32,
    no_headers: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the rows.
    let rows = String::from_utf8_lossy(unsafe { borrow(rows_json, rows_json_len) }).into_owned();
    let answer = table(table_of(kind), &rows, format_of(format), no_headers);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&answer, out, cap) }
}

/// Renders an aligned table from a JSON array of headers and a JSON array of row arrays.
///
/// # Safety
/// Both input pairs must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_render_table(
    headers_json: *const c_uchar,
    headers_json_len: usize,
    rows_json: *const c_uchar,
    rows_json_len: usize,
    no_headers: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations on the two inputs.
    let (headers, rows) = unsafe {
        (
            String::from_utf8_lossy(borrow(headers_json, headers_json_len)).into_owned(),
            String::from_utf8_lossy(borrow(rows_json, rows_json_len)).into_owned(),
        )
    };
    let answer = table_from_json(&headers, &rows, no_headers);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&answer, out, cap) }
}

/// Re-emits JSON text compact and key-sorted, without a trailing newline. Text that is not JSON
/// answers `[]`.
///
/// # Safety
/// The input pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_render_json(
    value_json: *const c_uchar,
    value_json_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the value.
    let raw = String::from_utf8_lossy(unsafe { borrow(value_json, value_json_len) }).into_owned();
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&render_json_text(&raw), out, cap) }
}

/// The `version` banner: the number, an optional build hash, the protocol version and the feature
/// line. An empty hash omits the parenthetical.
///
/// # Safety
/// Both input pairs must be live for the call; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cli_version_summary(
    version: *const c_uchar,
    version_len: usize,
    build_hash: *const c_uchar,
    build_hash_len: usize,
    protocol_version: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations on the two inputs.
    let (version, hash) = unsafe {
        (
            String::from_utf8_lossy(borrow(version, version_len)).into_owned(),
            String::from_utf8_lossy(borrow(build_hash, build_hash_len)).into_owned(),
        )
    };
    let answer = summary(&version, Some(hash.as_str()), protocol_version);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { text(&answer, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use std::ffi::c_uchar;

    use super::{
        SLOPDESK_CLI_INVALID_VALUE, SLOPDESK_CLI_JSON, SLOPDESK_CLI_OK, SLOPDESK_CLI_TABLE_WINDOWS,
        SLOPDESK_CLI_TEXT, SLOPDESK_SHELL_FISH, SLOPDESK_SHELL_POWERSHELL, SlopDeskCliInvocation,
        SlopDeskCliShape, planned_names, ready_names, slopdesk_cli_config_path, slopdesk_cli_parse,
        slopdesk_cli_planned_subcommands, slopdesk_cli_render_json, slopdesk_cli_shell,
        slopdesk_cli_subcommands, slopdesk_cli_table, slopdesk_cli_usage, slopdesk_cli_version_summary,
    };
    use crate::host_state::SlopDeskByteSpan;

    /// The argument list, flattened the way Swift lends it.
    fn argv(tokens: &[&str]) -> (Vec<SlopDeskByteSpan>, Vec<u8>) {
        let mut pool = Vec::new();
        let spans = tokens
            .iter()
            .map(|token| {
                let offset = pool.len();
                pool.extend_from_slice(token.as_bytes());
                SlopDeskByteSpan {
                    offset: u32::try_from(offset).unwrap_or(0),
                    length: u32::try_from(token.len()).unwrap_or(0),
                }
            })
            .collect();
        (spans, pool)
    }

    /// One parse, read back out of the buffers it named.
    fn parse(tokens: &[&str]) -> (SlopDeskCliInvocation, Vec<String>) {
        let (spans, pool) = argv(tokens);
        let mut record = SlopDeskCliInvocation::default();
        let shape = unsafe {
            slopdesk_cli_parse(
                spans.as_ptr(),
                spans.len(),
                pool.as_ptr(),
                pool.len(),
                &raw mut record,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![SlopDeskByteSpan::default(); shape.count];
        let mut arena = vec![0_u8; shape.arena_len];
        unsafe {
            slopdesk_cli_parse(
                spans.as_ptr(),
                spans.len(),
                pool.as_ptr(),
                pool.len(),
                &raw mut record,
                out.as_mut_ptr(),
                out.len(),
                arena.as_mut_ptr(),
                arena.len(),
            );
        }
        let tokens = out
            .iter()
            .map(|span| crate::arena_text(&arena, span.offset, span.length))
            .collect();
        (record, tokens)
    }

    #[test]
    fn the_flags_land_where_the_shell_typed_them() {
        let (record, tokens) = parse(&["slopdesk", "--json", "panes", "--tab", "3"]);
        assert_eq!(record.error, SLOPDESK_CLI_OK);
        assert_eq!(record.format, SLOPDESK_CLI_JSON);
        assert_eq!(
            record.rest_count, 2,
            "an unknown flag AFTER the subcommand passes through"
        );
        assert_eq!(tokens, vec!["--tab".to_owned(), "3".to_owned()]);
        assert!(!record.launch_gui);
    }

    #[test]
    fn a_bad_value_names_the_flag_and_the_value() {
        let (record, _) = parse(&["slopdesk", "--format", "yaml"]);
        assert_eq!(record.error, SLOPDESK_CLI_INVALID_VALUE);
        assert!(record.error_flag.length > 0 && record.error_value.length > 0);
    }

    #[test]
    fn the_exec_command_is_captured_whole_and_launches_the_gui() {
        let (record, tokens) = parse(&["slopdesk", "-e", "vim", "-u", "NONE"]);
        assert!(record.has_exec && record.launch_gui);
        assert_eq!(record.rest_count, 0);
        assert_eq!(
            record.exec_count, 3,
            "`-e` is terminal: leading dashes are the command's"
        );
        assert_eq!(tokens, vec!["vim".to_owned(), "-u".to_owned(), "NONE".to_owned()]);
    }

    #[test]
    fn a_shell_name_round_trips_and_an_unknown_one_does_not() {
        let mut code = 99;
        unsafe {
            assert!(slopdesk_cli_shell(b"FISH".as_ptr(), 4, &raw mut code));
            assert_eq!(code, SLOPDESK_SHELL_FISH);
            assert!(slopdesk_cli_shell(b"pwsh".as_ptr(), 4, &raw mut code));
            assert_eq!(code, SLOPDESK_SHELL_POWERSHELL, "`pwsh` aliases powershell");
            assert!(!slopdesk_cli_shell(b"tcsh".as_ptr(), 4, &raw mut code));
            assert_eq!(code, SLOPDESK_SHELL_POWERSHELL, "a refusal writes nothing");
        }
    }

    /// The shape both name-list doors wear. Named so the helper below reads as "one of the two
    /// doors" rather than as a signature.
    type NameDoor =
        unsafe extern "C" fn(*mut SlopDeskByteSpan, usize, *mut c_uchar, usize) -> SlopDeskCliShape;

    /// The names one of the two list doors answers, decoded the way Swift decodes them.
    fn crossed(door: NameDoor) -> Vec<String> {
        let shape = unsafe { door(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) };
        let mut spans = vec![SlopDeskByteSpan::default(); shape.count];
        let mut arena = vec![0_u8; shape.arena_len];
        let filled = unsafe { door(spans.as_mut_ptr(), spans.len(), arena.as_mut_ptr(), arena.len()) };
        assert_eq!(filled, shape);
        // `crate::arena_text`, not a span walk of its own: the read half of §4c had seven copies
        // once and two of them clipped differently on overflow, so even a test that only wants to
        // read its own arena asks the one reader — a test that decodes differently from the door's
        // callers is a test that can agree with nothing.
        spans
            .iter()
            .map(|span| crate::arena_text(&arena, span.offset, span.length))
            .collect()
    }

    #[test]
    fn the_subcommand_surface_crosses_whole_and_carries_only_verbs_that_run() {
        let offered = crossed(slopdesk_cli_subcommands);
        assert_eq!(offered.len(), ready_names().len());
        assert_eq!(offered.first().map(String::as_str), Some("version"));
        // The regression this door was fixed for: six planned verbs used to cross it, so every
        // shell offered a command that exits 2.
        for planned in planned_names() {
            assert!(
                !offered.iter().any(|name| name == planned),
                "{planned} is offered"
            );
        }
    }

    #[test]
    fn the_planned_surface_crosses_separately_and_shares_no_name_with_the_offered_one() {
        let planned = crossed(slopdesk_cli_planned_subcommands);
        assert_eq!(planned, planned_names());
        let offered = crossed(slopdesk_cli_subcommands);
        for name in &planned {
            assert!(!offered.contains(name), "{name} is on both lists");
        }
    }

    #[test]
    fn the_usage_text_crosses_whole_and_wears_the_program_name_it_was_given() {
        let program = b"sd";
        let needed = unsafe { slopdesk_cli_usage(program.as_ptr(), program.len(), std::ptr::null_mut(), 0) };
        assert!(needed > 0);
        let mut out = vec![0_u8; needed];
        let written =
            unsafe { slopdesk_cli_usage(program.as_ptr(), program.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(text.starts_with("usage: sd "));
        assert!(text.ends_with('\n'));
        // An empty name is a caller with no argv[0], not a caller asking for an anonymous banner.
        let fallback = unsafe { slopdesk_cli_usage(std::ptr::null(), 0, std::ptr::null_mut(), 0) };
        assert!(fallback > 0);
    }

    #[test]
    fn a_table_pads_every_column_but_the_last() {
        let rows = br#"[{"id":"w1","title":"Long title","tabCount":2,"focused":true}]"#;
        let needed = unsafe {
            slopdesk_cli_table(
                SLOPDESK_CLI_TABLE_WINDOWS,
                rows.as_ptr(),
                rows.len(),
                SLOPDESK_CLI_TEXT,
                false,
                std::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![0_u8; needed];
        unsafe {
            slopdesk_cli_table(
                SLOPDESK_CLI_TABLE_WINDOWS,
                rows.as_ptr(),
                rows.len(),
                SLOPDESK_CLI_TEXT,
                false,
                out.as_mut_ptr(),
                out.len(),
            );
        }
        let rendered = String::from_utf8_lossy(&out).into_owned();
        assert!(rendered.starts_with("ID  TITLE"), "got {rendered}");
        assert!(rendered.ends_with('*'), "the last column is unpadded: {rendered}");
    }

    #[test]
    fn json_is_re_emitted_sorted_and_nonsense_answers_empty() {
        let raw = br#"{"b":1,"a":2}"#;
        let needed = unsafe { slopdesk_cli_render_json(raw.as_ptr(), raw.len(), std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        unsafe { slopdesk_cli_render_json(raw.as_ptr(), raw.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(String::from_utf8_lossy(&out), r#"{"a":2,"b":1}"#);
        let junk = b"not json";
        let needed = unsafe { slopdesk_cli_render_json(junk.as_ptr(), junk.len(), std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        unsafe { slopdesk_cli_render_json(junk.as_ptr(), junk.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(String::from_utf8_lossy(&out), "[]");
    }

    #[test]
    fn the_config_path_prefers_the_flag_then_the_env_then_xdg() {
        let read = |explicit: &str, env: &str, xdg: &str, home: &str| -> String {
            let needed = unsafe {
                slopdesk_cli_config_path(
                    explicit.as_ptr(),
                    explicit.len(),
                    env.as_ptr(),
                    env.len(),
                    xdg.as_ptr(),
                    xdg.len(),
                    home.as_ptr(),
                    home.len(),
                    b"/var/empty".as_ptr(),
                    10,
                    std::ptr::null_mut(),
                    0,
                )
            };
            let mut out = vec![0_u8; needed];
            unsafe {
                slopdesk_cli_config_path(
                    explicit.as_ptr(),
                    explicit.len(),
                    env.as_ptr(),
                    env.len(),
                    xdg.as_ptr(),
                    xdg.len(),
                    home.as_ptr(),
                    home.len(),
                    b"/var/empty".as_ptr(),
                    10,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            String::from_utf8_lossy(&out).into_owned()
        };
        assert_eq!(read("/flag.toml", "/env.toml", "/xdg", "/home"), "/flag.toml");
        assert_eq!(read("", "/env.toml", "/xdg", "/home"), "/env.toml");
        assert_eq!(read("", "", "/xdg", "/home"), "/xdg/slopdesk/config.toml");
        assert_eq!(read("", "", "", "/home"), "/home/.config/slopdesk/config.toml");
        assert_eq!(read("", "", "", ""), "/var/empty/.config/slopdesk/config.toml");
    }

    #[test]
    fn the_banner_omits_the_parenthetical_without_a_hash() {
        let read = |hash: &str| -> String {
            let version = "9.9.9";
            let needed = unsafe {
                slopdesk_cli_version_summary(
                    version.as_ptr(),
                    version.len(),
                    hash.as_ptr(),
                    hash.len(),
                    7,
                    std::ptr::null_mut(),
                    0,
                )
            };
            let mut out = vec![0_u8; needed];
            unsafe {
                slopdesk_cli_version_summary(
                    version.as_ptr(),
                    version.len(),
                    hash.as_ptr(),
                    hash.len(),
                    7,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            String::from_utf8_lossy(&out).into_owned()
        };
        assert!(read("").starts_with("slopdesk 9.9.9\nterminal protocol v7\n"));
        assert!(read("abc1234").starts_with("slopdesk 9.9.9 (abc1234)\n"));
    }
}
