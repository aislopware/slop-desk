//! One pass over the outbound PTY stream, for everything the shell says out of band.
//!
//! Title, bell, command status, working directory and desktop notifications all arrive as escape
//! sequences interleaved with ordinary output, and all of them are found by the SAME state machine
//! — a strict superset of a title parser that also reports a ground-state bell. Splitting them into
//! separate passes would mean several parsers agreeing about what an OSC is, which is exactly the
//! kind of agreement that rots.
//!
//! - OSC 0 and OSC 2 — the window title. OSC 1 is icon-name only and is deliberately ignored.
//! - A ground-state `BEL` — a real bell, never a sequence terminator.
//! - OSC 133 `C` and `D[;exit]` — running and idle, with the measured duration between them.
//! - OSC 7 — the shell's working directory.
//! - OSC 9, OSC 777 and OSC 99 — desktop notifications, and the OSC 9;4 progress protocol.
//!
//! ## It only OBSERVES
//!
//! The caller forwards the original bytes untouched. State persists across chunks, so a stream
//! split anywhere — mid-ESC, mid-OSC, mid-terminator — yields the same events as the whole stream
//! at once.
//!
//! ## Bounded against a hostile stream
//!
//! Every buffer is capped and an over-cap sequence is swallowed to its terminator rather than
//! abandoned mid-sequence, so its terminator can never leak out and be read as content. A
//! DCS/SOS/PM/APC body is consumed whole and emits NOTHING: without that, any program could embed a
//! `BEL` for a phantom bell, an `ESC ] 2 ; …` to spoof someone else's title, or an `ESC ] 133 ; C`
//! to fabricate a command status.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use slopdesk_sanitize::escape::percent_decoded;

use crate::commandblocks::{duration_ms, parse_exit};

/// Cap on a buffered OSC payload. A real title is tiny; anything longer is abandoned and resynced.
const OSC_CAP: usize = 4096;

/// Tighter cap for the 133 branch: a real mark is short, so a payload of 257..4096 bytes is ignored
/// rather than parsed as a command mark.
const CMD_OSC_CAP: usize = 256;

/// Cap for the notification paths. A real notification line is short, and a multi-kilobyte one is
/// not worth raising a desktop alert for.
const NOTIFY_OSC_CAP: usize = 1024;

/// How many kitty notifications may be assembling across continuation chunks at once. A stream that
/// opens many distinct ids with `d=0` cannot grow the table past this — a brand-new id over the cap
/// is dropped rather than buffered.
const KITTY_ASSEMBLY_MAX: usize = 8;

/// Total assembled title-plus-body length for one in-flight kitty notification. Each chunk is
/// already bounded; this bounds the accumulation ACROSS chunks.
const KITTY_ASSEMBLY_CAP: usize = 4096;

const ESC: u8 = 0x1B;
const BEL: u8 = 0x07;
const RIGHT_BRACKET: u8 = b']';
const BACKSLASH: u8 = b'\\';
const SEMICOLON: u8 = b';';

/// The two event types this pass produces — `slopdesk_superwire::sniffwire`'s, re-exported.
///
/// They were declared here, with a hand-written `Serialize` beside them, and declared a second time
/// in hostd's own `SniffedEvent.swift` with a hand-written decode beside THAT.
/// Nothing compared the two and nothing could, so `state` renamed on one side left every finished
/// command reading as still running with both suites green (`docs/51` §6.13). One declaration now,
/// in the crate both ends link; this module is the byte reader again and nothing else.
pub use slopdesk_superwire::sniffwire::{CommandStatus, SniffEvent};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    /// Outside any escape sequence. A `BEL` here is a real bell.
    #[default]
    Ground,
    /// Saw `ESC`; the next byte classifies the sequence.
    Escape,
    /// Inside an OSC, buffering until `BEL` or `ST`.
    Osc,
    /// Inside an OSC after an `ESC` — waiting to see whether it is the `\` of an `ST`.
    OscEscape,
    /// An over-cap OSC being discarded. Still INSIDE the sequence, so its terminator is consumed
    /// here rather than re-parsed as ground, but nothing is buffered.
    OscDiscard,
    /// Inside a discarded OSC after an `ESC`.
    OscDiscardEscape,
    /// Inside a DCS/SOS/PM/APC string body, swallowing to the terminator and emitting nothing.
    /// UNLIKE an OSC, an embedded `ESC` that is not `\` stays part of the opaque body and starts no
    /// new sequence — which is the whole point.
    StringConsume,
    /// Inside a string body after an `ESC`.
    StringConsumeEscape,
}

/// The names this machine answers to, for [`OutputSniffer::new`].
///
/// Always `""` and `localhost`, plus the OS hostname and its leading label — `mac-studio.local`
/// also being `mac-studio`, which is what a shell's OSC 7 usually says. Asking the OS is I/O, which
/// is why the sniffer takes the answer rather than looking it up.
#[must_use]
pub fn local_hostnames() -> Vec<String> {
    /// Asked of the OS once per process. The answer cannot change under a running daemon in any way
    /// that matters here, and this is called on every spawn and every subscribe.
    static NAMES: std::sync::LazyLock<Vec<String>> = std::sync::LazyLock::new(compute_local_hostnames);
    NAMES.clone()
}

fn compute_local_hostnames() -> Vec<String> {
    let mut names = vec![String::new(), "localhost".to_owned()];
    if let Ok(hostname) = nix::unistd::gethostname()
        && let Some(hostname) = hostname.to_str()
    {
        let hostname = hostname.to_lowercase();
        if let Some(label) = hostname.split('.').next()
            && label != hostname
        {
            names.push(label.to_owned());
        }
        names.push(hostname);
    }
    names
}

/// The fused output sniffer.
#[derive(Debug, Clone, Default)]
pub struct OutputSniffer {
    local_hostnames: Vec<String>,
    state: State,
    osc_buffer: Vec<u8>,
    last_title: Option<String>,
    /// When the foreground command started, `None` at a prompt.
    running_since_ms: Option<i64>,
    /// Whether an idle signal has already gone out for this prompt cycle.
    ///
    /// Stops a `133;B` from emitting a second idle after a `133;D` already carried the exit code,
    /// while still surfacing `B` at first launch — where no command has run, so no `D` ever fired.
    idle_sent_since_last_c: bool,
    /// Kitty notifications assembling across continuation chunks, keyed by their `i=` group.
    kitty_assembly: Vec<(String, String, String)>,
}

impl OutputSniffer {
    /// A sniffer that treats `local_hostnames` as naming this machine.
    ///
    /// The empty authority and `localhost` are always local whatever this says. Any OTHER authority
    /// on an OSC 7 must be in this list or its path is DROPPED — a shell that has `ssh`'d to
    /// another box must not poison cwd inheritance, or the next split would `chdir` somewhere
    /// that does not exist here. The list is injected because asking the OS its hostname is
    /// I/O.
    #[must_use]
    pub fn new(local_hostnames: Vec<String>) -> Self {
        Self {
            local_hostnames: local_hostnames
                .into_iter()
                .map(|name| name.to_lowercase())
                .collect(),
            ..Self::default()
        }
    }

    /// Forgets the title deduplication anchor, so the next OSC 0/2 is emitted even if it repeats.
    ///
    /// The host pushes an explicit title retirement when a detected agent exits. Without this the
    /// anchor would still hold that agent's last title and silently swallow an identical one from
    /// the next run in the same pane — the common case, since a fresh session opens on a static
    /// banner.
    pub fn forget_title_coalescing(&mut self) {
        self.last_title = None;
    }

    /// Whether a command is running right now.
    ///
    /// The reattach path re-asserts only the RUNNING case: idle is already the client's reconnect
    /// reset state, and a synthetic idle would fabricate a completion edge — and a `lastCommand`
    /// with no exit code and no duration — for a command that never finished.
    #[must_use]
    pub const fn is_command_running(&self) -> bool {
        self.running_since_ms.is_some()
    }

    /// When the current command opened, on the caller's own clock scale, or `None` at a prompt.
    ///
    /// The same latch [`is_command_running`](Self::is_command_running) reads, as a TIME rather than
    /// a verdict: the workspace document compares it against the title's stamp to decide whether a
    /// title is fresh, and a status carries no timestamp to compare.
    #[must_use]
    pub const fn command_running_since_ms(&self) -> Option<i64> {
        self.running_since_ms
    }

    /// Observes a chunk and answers the events found in it, in byte order.
    ///
    /// `now_ms` is the caller's clock reading for this chunk. The bytes are not modified or
    /// consumed; the caller forwards the original chunk.
    pub fn observe(&mut self, bytes: &[u8], now_ms: i64) -> Vec<SniffEvent> {
        let mut events = Vec::new();
        let mut cursor = 0;
        while let Some(rest) = bytes.get(cursor..).filter(|rest| !rest.is_empty()) {
            match self.state {
                State::Ground => cursor += self.skim_ground(rest, now_ms, &mut events),
                State::OscDiscard | State::StringConsume => {
                    cursor += self.skim_swallowing(rest, now_ms, &mut events);
                },
                // Buffering and classifying states: every byte matters.
                _ => {
                    if let Some(&byte) = rest.first() {
                        self.step(byte, now_ms, &mut events);
                    }
                    cursor += 1;
                },
            }
        }
        events
    }

    /// The ground fast path: only `ESC` and `BEL` matter, so find them rather than walking.
    ///
    /// The `BEL` scan is bounded to the prefix BEFORE the next `ESC`, and that bound is the whole
    /// point. An unbounded scan over the rest of the chunk, re-run on every return to ground,
    /// degrades to quadratic on escape-dense output — measurably SLOWER than a plain per-byte loop.
    /// Bounded this way, each byte is examined by at most one `ESC` scan and one `BEL` scan.
    fn skim_ground(&mut self, rest: &[u8], now_ms: i64, events: &mut Vec<SniffEvent>) -> usize {
        let esc_at = rest.iter().position(|&byte| byte == ESC).unwrap_or(rest.len());
        let mut scanned = 0;
        while let Some(prefix) = rest.get(scanned..esc_at) {
            let Some(bel_at) = prefix.iter().position(|&byte| byte == BEL) else {
                break;
            };
            self.step(BEL, now_ms, events);
            scanned += bel_at + 1;
        }
        if esc_at < rest.len() {
            self.step(ESC, now_ms, events);
            return esc_at + 1;
        }
        rest.len()
    }

    /// The two swallowing states, where only a terminator matters. `BEL` ends both in this grammar.
    fn skim_swallowing(&mut self, rest: &[u8], now_ms: i64, events: &mut Vec<SniffEvent>) -> usize {
        let esc_at = rest.iter().position(|&byte| byte == ESC).unwrap_or(rest.len());
        if let Some(bel_at) = rest
            .get(..esc_at)
            .and_then(|prefix| prefix.iter().position(|&byte| byte == BEL))
        {
            self.step(BEL, now_ms, events);
            return bel_at + 1;
        }
        if esc_at < rest.len() {
            self.step(ESC, now_ms, events);
            return esc_at + 1;
        }
        rest.len()
    }

    fn step(&mut self, byte: u8, now_ms: i64, events: &mut Vec<SniffEvent>) {
        match self.state {
            State::Ground => {
                match byte {
                    ESC => self.state = State::Escape,
                    BEL => events.push(SniffEvent::Bell),
                    _ => {},
                }
            },
            State::Escape => {
                match byte {
                    RIGHT_BRACKET => {
                        self.state = State::Osc;
                        self.osc_buffer.clear();
                    },
                    // DCS, SOS, PM, APC — swallow the body, emitting nothing. See the module note.
                    b'P' | b'X' | b'^' | b'_' => self.state = State::StringConsume,
                    // `ESC ESC` — stay here and classify the second one.
                    ESC => self.state = State::Escape,
                    // Any other escape: a CSI, a two-byte or nF form. Not an OSC, so untracked. A `BEL`
                    // here is neither a sequence we want nor a standalone bell, and treating it as
                    // ground content is right.
                    _ => self.state = State::Ground,
                }
            },
            State::Osc => {
                match byte {
                    BEL => {
                        // This BEL is a TERMINATOR — emit whatever the sequence was, and crucially
                        // not a bell.
                        self.finish_osc(now_ms, events);
                        self.state = State::Ground;
                    },
                    ESC => self.state = State::OscEscape,
                    _ => {
                        self.osc_buffer.push(byte);
                        if self.osc_buffer.len() > OSC_CAP {
                            // Overlong — abandon without emitting, but do NOT drop to ground: we
                            // are still inside the OSC and its
                            // terminator has not arrived, so ground would
                            // re-read that terminating BEL as a spurious bell and misread what
                            // follows.
                            self.osc_buffer.clear();
                            self.state = State::OscDiscard;
                        }
                    },
                }
            },
            State::OscEscape => {
                self.finish_osc(now_ms, events);
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    // The `ESC` was not an `ST`, so the OSC ends here — but that consumed `ESC` may
                    // itself introduce a NEW sequence. Re-enter escape and reclassify. Dropping to
                    // ground would orphan it and let the next sequence's `]` read as plain content,
                    // losing the whole thing.
                    self.state = State::Escape;
                    self.step(byte, now_ms, events);
                }
            },
            State::OscDiscard => {
                match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::OscDiscardEscape,
                    _ => {},
                }
            },
            State::OscDiscardEscape => {
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    // Same reclassification as `OscEscape`, with no payload to finish.
                    self.state = State::Escape;
                    self.step(byte, now_ms, events);
                }
            },
            State::StringConsume => {
                match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::StringConsumeEscape,
                    _ => {},
                }
            },
            State::StringConsumeEscape => {
                match byte {
                    BACKSLASH => self.state = State::Ground,
                    // Another `ESC` could still begin an `ST` — keep waiting.
                    ESC => self.state = State::StringConsumeEscape,
                    // A lone `ESC` inside the body: swallow it and keep consuming. This is what stops an
                    // embedded `ESC ] 2 ; …` from spoofing a title.
                    _ => self.state = State::StringConsume,
                }
            },
        }
    }

    fn finish_osc(&mut self, now_ms: i64, events: &mut Vec<SniffEvent>) {
        let buffer = core::mem::take(&mut self.osc_buffer);
        // Split the Ps at the FIRST `;` — a title's payload may itself contain more.
        let Some(separator) = buffer.iter().position(|&byte| byte == SEMICOLON) else {
            return;
        };
        let Some(ps) = buffer
            .get(..separator)
            .and_then(|raw| core::str::from_utf8(raw).ok())
        else {
            return;
        };
        let after_ps = buffer
            .get(separator + 1..)
            .and_then(|raw| core::str::from_utf8(raw).ok());
        match ps {
            // OSC 0 sets icon name and window title, OSC 2 the window title.
            "0" | "2" => self.on_title(after_ps, events),
            "133" => self.on_command_mark(&buffer, now_ms, events),
            "7" => {
                if let Some(cwd) = after_ps.and_then(|body| osc7_path(body, &self.local_hostnames)) {
                    events.push(SniffEvent::Cwd(cwd));
                }
            },
            "9" => Self::on_osc9(&buffer, after_ps, events),
            "777" => Self::on_osc777(&buffer, events),
            "99" => self.on_kitty(&buffer, after_ps, events),
            // OSC 1 icon name, OSC 4 palette, OSC 8 hyperlink, OSC 52 clipboard and the rest: none
            // of them is a title, a mark or a notification.
            _ => {},
        }
    }

    /// OSC 0 and OSC 2.
    ///
    /// An EMPTY body is dropped silently: prompt frameworks emit one during a redraw, before
    /// setting the real title, and wiring it through clears the client's shown title across
    /// every command boundary. The client keeps the last real title until a non-empty one
    /// arrives.
    fn on_title(&mut self, body: Option<&str>, events: &mut Vec<SniffEvent>) {
        let Some(title) = body.filter(|title| !title.is_empty()) else {
            return;
        };
        if self.last_title.as_deref() == Some(title) {
            return;
        }
        self.last_title = Some(title.to_owned());
        events.push(SniffEvent::Title(title.to_owned()));
    }

    /// OSC 133 `B`, `C` and `D`.
    fn on_command_mark(&mut self, buffer: &[u8], now_ms: i64, events: &mut Vec<SniffEvent>) {
        // Re-impose the tighter cap: a 257..4096-byte payload stays ignored rather than being read
        // as a command mark.
        if buffer.len() > CMD_OSC_CAP {
            return;
        }
        let Ok(payload) = core::str::from_utf8(buffer) else {
            return;
        };
        let fields: Vec<&str> = payload.split(';').collect();
        match fields.get(1) {
            Some(&"C") => {
                self.idle_sent_since_last_c = false;
                self.running_since_ms = Some(now_ms);
                events.push(SniffEvent::Status(CommandStatus::Running));
            },
            Some(&"D") => {
                // A `D` with no matching `C` is the first-prompt phantom `D;0`. Emitting a
                // zero-duration idle for it would report a completion for a command that never ran.
                let Some(started) = self.running_since_ms.take() else {
                    return;
                };
                self.idle_sent_since_last_c = true;
                events.push(SniffEvent::Status(CommandStatus::Idle {
                    exit_code: parse_exit(&fields),
                    duration_ms: duration_ms(started, now_ms),
                }));
            },
            // Prompt-ready. Emit idle only when nothing else has this cycle — first launch, before
            // any command ran. After a `D` the client already knows, and repeating it would discard
            // that `D`'s exit code and duration.
            Some(&"B") if self.running_since_ms.is_none() && !self.idle_sent_since_last_c => {
                self.idle_sent_since_last_c = true;
                events.push(SniffEvent::Status(CommandStatus::Idle {
                    exit_code: None,
                    duration_ms: 0,
                }));
            },
            // `A`, `E`, or something from a newer shim: not a status change.
            _ => {},
        }
    }

    /// OSC 9 — a notification, or the progress protocol wearing the same number.
    ///
    /// The two are told apart by SHAPE, not by parsing: `9;4` and `9;4;…` are progress and are
    /// handed up as a body, everything else is a free-text notification. Without that split, a
    /// build tool emitting progress continuously would raise a desktop alert reading `4;1;50`
    /// every few hundred milliseconds.
    fn on_osc9(buffer: &[u8], body: Option<&str>, events: &mut Vec<SniffEvent>) {
        if buffer.len() > NOTIFY_OSC_CAP {
            return;
        }
        let Some(body) = body.filter(|body| !body.is_empty()) else {
            return;
        };
        if body == "4" || body.starts_with("4;") {
            events.push(SniffEvent::ProgressBody(body.to_owned()));
            return;
        }
        events.push(SniffEvent::Notification {
            title: String::new(),
            body: body.to_owned(),
        });
    }

    /// OSC 777 — `777;notify;<title>;<body>`. Only the `notify` subcommand is a notification.
    fn on_osc777(buffer: &[u8], events: &mut Vec<SniffEvent>) {
        if buffer.len() > NOTIFY_OSC_CAP {
            return;
        }
        let Ok(payload) = core::str::from_utf8(buffer) else {
            return;
        };
        let fields: Vec<&str> = payload.splitn(4, ';').collect();
        if fields.get(1) != Some(&"notify") {
            return;
        }
        let title = (*fields.get(2).unwrap_or(&"")).to_owned();
        let body = (*fields.get(3).unwrap_or(&"")).to_owned();
        if title.is_empty() && body.is_empty() {
            return;
        }
        events.push(SniffEvent::Notification { title, body });
    }

    /// OSC 99 — the kitty notification protocol, in the subset that maps onto a plain notification.
    ///
    /// Title, body, base64 payloads and chunked continuation are handled; urgency, buttons, icons,
    /// the capability query and multi-datagram reassembly are a documented ceiling and their chunks
    /// are DROPPED rather than half-answered, so there is no dead query path to maintain.
    fn on_kitty(&mut self, buffer: &[u8], remainder: Option<&str>, events: &mut Vec<SniffEvent>) {
        if buffer.len() > NOTIFY_OSC_CAP {
            return;
        }
        let Some(chunk) = remainder.and_then(parse_kitty_chunk) else {
            return;
        };
        let existing = self.kitty_assembly.iter().position(|(id, ..)| *id == chunk.id);
        // Bound the in-flight count BEFORE opening a slot, so a brand-new id over the cap is
        // dropped rather than buffered.
        if existing.is_none() && self.kitty_assembly.len() >= KITTY_ASSEMBLY_MAX {
            return;
        }
        let slot = if let Some(at) = existing {
            at
        } else {
            self.kitty_assembly
                .push((chunk.id.clone(), String::new(), String::new()));
            self.kitty_assembly.len() - 1
        };
        let Some((_, title, body)) = self.kitty_assembly.get_mut(slot) else {
            return;
        };
        if chunk.is_body {
            body.push_str(&chunk.text);
        } else {
            title.push_str(&chunk.text);
        }
        // Bound the accumulation across chunks: a stream that keeps appending is abandoned.
        if title.chars().count() + body.chars().count() > KITTY_ASSEMBLY_CAP || chunk.done {
            let over_cap = title.chars().count() + body.chars().count() > KITTY_ASSEMBLY_CAP;
            let (title, body) = (core::mem::take(title), core::mem::take(body));
            self.kitty_assembly.remove(slot);
            if over_cap {
                return;
            }
            // A title-only notification folds into the BODY, so the banner shows it as primary text
            // — matching the OSC 9 empty-title form and the client's pane-title fallback. Both
            // fields survive when a `p=body` chunk supplied a distinct body.
            let (title, body) = if body.is_empty() {
                (String::new(), title)
            } else {
                (title, body)
            };
            if !title.is_empty() || !body.is_empty() {
                events.push(SniffEvent::Notification { title, body });
            }
        }
    }
}

/// The filesystem path of an OSC 7 `file://<authority>/<path>`, or `None` when it is not one, or is
/// not local.
///
/// The authority is honoured rather than skipped past. A shell that has `ssh`'d elsewhere reports
/// that box's paths, and treating them as local would make the next split `chdir` into a path that
/// does not exist here — the same check iTerm2, Terminal.app and ghostty all perform. The empty
/// authority and `localhost` are machine-independent and always local; anything else must be in
/// `local_hostnames`.
#[must_use]
pub fn osc7_path(body: &str, local_hostnames: &[String]) -> Option<String> {
    let after_scheme = body.strip_prefix("file://")?;
    let slash = after_scheme.find('/')?;
    let authority = after_scheme.get(..slash)?;
    let host = percent_decoded(authority)
        .unwrap_or_else(|| authority.to_owned())
        .to_lowercase();
    if !(host.is_empty() || host == "localhost" || local_hostnames.contains(&host)) {
        return None;
    }
    let encoded = after_scheme.get(slash..).filter(|path| path.starts_with('/'))?;
    percent_decoded(encoded).filter(|decoded| decoded.starts_with('/'))
}

/// One parsed kitty chunk, after the `99;` was stripped.
#[derive(Debug, Clone)]
struct KittyChunk {
    id: String,
    done: bool,
    is_body: bool,
    text: String,
}

/// Parses `<metadata>;<payload>`, or `None` for anything malformed or outside the supported subset.
///
/// Dropped rather than guessed at: a missing metadata separator, an encoding other than `0` or `1`,
/// a payload type other than `title` or `body` — which is where the capability query `p=?`, buttons
/// and icons all land — bad base64, or bytes that are not UTF-8 once decoded.
fn parse_kitty_chunk(remainder: &str) -> Option<KittyChunk> {
    // The protocol requires `99;<metadata>;<payload>`, so after stripping `99;` a separator must
    // still be there. A single-`;` form is malformed.
    let meta_end = remainder.find(';')?;
    let metadata = remainder.get(..meta_end)?;
    let payload = remainder.get(meta_end + 1..)?;

    let mut id = String::new();
    // The defaults: this is the final chunk, plain UTF-8, and an unmarked payload is the title.
    let mut done = true;
    let mut encoding = "";
    let mut payload_type = "title";
    for token in metadata.split(':').filter(|token| !token.is_empty()) {
        // Lenient about a keyless token; strict about the values of the keys we act on.
        let Some(equals) = token.find('=') else {
            continue;
        };
        let (key, value) = (token.get(..equals)?, token.get(equals + 1..)?);
        match key {
            "i" => value.clone_into(&mut id),
            "d" => done = value != "0",
            "e" => encoding = value,
            "p" => payload_type = value,
            // Urgency, actions, when, close: the documented ceiling.
            _ => {},
        }
    }
    if !matches!(encoding, "" | "0" | "1") || !matches!(payload_type, "title" | "body") {
        return None;
    }
    let text = if encoding == "1" {
        String::from_utf8(decode_base64(payload)?).ok()?
    } else {
        payload.to_owned()
    };
    Some(KittyChunk {
        id,
        done,
        is_body: payload_type == "body",
        text,
    })
}

/// Standard base64 with required padding, or `None`.
///
/// Strict on purpose, matching the Foundation decoder this replaces: a payload that is not
/// well-formed base64 is a payload not to be trusted, and half-decoding it would put arbitrary
/// bytes into a desktop alert. `STANDARD` is that strictness by construction — canonical padding
/// required, no trailing bits allowed — and it is the same engine [`crate::blocks`] encodes with.
fn decode_base64(text: &str) -> Option<Vec<u8>> {
    STANDARD.decode(text).ok()
}

#[cfg(test)]
mod tests {
    use super::{CommandStatus, OutputSniffer, SniffEvent, decode_base64, local_hostnames, osc7_path};

    /// The JSON shape the Swift decoder reads, pinned here because nothing else can see both ends.
    ///
    /// A rename on either side is a silent break: hostd would decode an event with a missing field
    /// and drop it, and a pane would simply stop reporting its titles with nothing logged.
    #[test]
    fn every_event_serialises_to_the_shape_the_client_decodes() {
        let json = |event: &SniffEvent| serde_json::to_string(event).unwrap_or_default();
        assert_eq!(
            json(&SniffEvent::Title("x".to_owned())),
            r#"{"kind":"title","value":"x"}"#
        );
        assert_eq!(
            json(&SniffEvent::Cwd("/x".to_owned())),
            r#"{"kind":"cwd","value":"/x"}"#
        );
        assert_eq!(
            json(&SniffEvent::ProgressBody("4;1;50".to_owned())),
            r#"{"kind":"progress","value":"4;1;50"}"#
        );
        assert_eq!(json(&SniffEvent::Bell), r#"{"kind":"bell"}"#);
        assert_eq!(
            json(&SniffEvent::Status(CommandStatus::Running)),
            r#"{"kind":"status","state":"running"}"#
        );
        assert_eq!(
            json(&SniffEvent::Status(CommandStatus::Idle {
                exit_code: Some(-1),
                duration_ms: 7,
            })),
            r#"{"kind":"status","state":"idle","exitCode":-1,"durationMS":7}"#
        );
        // The code-less `D`: the key stays, carrying null, so the receiver never has to tell a
        // missing field from an absent exit code.
        assert_eq!(
            json(&SniffEvent::Status(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            })),
            r#"{"kind":"status","state":"idle","exitCode":null,"durationMS":0}"#
        );
        assert_eq!(
            json(&SniffEvent::Notification {
                title: "t".to_owned(),
                body: "b".to_owned(),
            }),
            r#"{"kind":"notification","title":"t","body":"b"}"#
        );
    }

    /// The two names that are not the machine's, and must be there whatever the machine is called.
    #[test]
    fn the_local_names_always_include_the_empty_authority_and_localhost() {
        let names = local_hostnames();
        assert!(names.contains(&String::new()));
        assert!(names.contains(&"localhost".to_owned()));
        // Everything is lowercased, because `osc7_path` compares against a lowercased authority.
        assert!(names.iter().all(|name| name == &name.to_lowercase()));
    }

    fn sniffer() -> OutputSniffer {
        OutputSniffer::new(vec!["mac-studio".to_owned(), "mac-studio.local".to_owned()])
    }

    fn observe(stream: &str) -> Vec<SniffEvent> {
        sniffer().observe(stream.as_bytes(), 0)
    }

    fn title(text: &str) -> SniffEvent {
        SniffEvent::Title(text.to_owned())
    }

    #[test]
    fn a_title_is_surfaced_for_osc_0_and_2_but_never_for_osc_1() {
        assert_eq!(observe("\u{1B}]0;zero\u{7}"), vec![title("zero")]);
        assert_eq!(observe("\u{1B}]2;two\u{7}"), vec![title("two")]);
        assert!(observe("\u{1B}]1;icon\u{7}").is_empty());
    }

    #[test]
    fn an_empty_title_from_a_prompt_redraw_never_clears_the_shown_one() {
        assert_eq!(observe("\u{1B}]2;real\u{7}\u{1B}]2;\u{7}"), vec![title("real")]);
    }

    #[test]
    fn an_identical_title_is_coalesced_until_the_anchor_is_forgotten() {
        let mut sniffer = sniffer();
        assert_eq!(sniffer.observe(b"\x1B]2;same\x07", 0), vec![title("same")]);
        assert!(sniffer.observe(b"\x1B]2;same\x07", 0).is_empty());
        sniffer.forget_title_coalescing();
        assert_eq!(sniffer.observe(b"\x1B]2;same\x07", 0), vec![title("same")]);
    }

    #[test]
    fn a_ground_bell_rings_but_an_osc_terminator_does_not() {
        assert_eq!(observe("ding\u{7}"), vec![SniffEvent::Bell]);
        // The BEL closing the title is a terminator, so exactly one event comes out.
        assert_eq!(observe("\u{1B}]2;t\u{7}"), vec![title("t")]);
    }

    #[test]
    fn a_string_sequence_body_can_spoof_neither_a_bell_nor_a_title_nor_a_status() {
        let hostile = "\u{1B}_\u{1B}]2;stolen\u{1B}\\";
        assert!(observe(hostile).is_empty());
        // And every string introducer behaves the same way.
        for introducer in ['P', 'X', '^', '_'] {
            let stream = format!("\u{1B}{introducer}\u{1B}]133;C\u{1B}\\");
            assert!(observe(&stream).is_empty(), "{introducer}");
        }
    }

    #[test]
    fn a_command_runs_then_finishes_with_its_code_and_measured_duration() {
        let mut sniffer = sniffer();
        assert_eq!(sniffer.observe(b"\x1B]133;C\x07", 1_000), vec![
            SniffEvent::Status(CommandStatus::Running)
        ]);
        assert!(sniffer.is_command_running());
        assert_eq!(sniffer.command_running_since_ms(), Some(1_000));
        assert_eq!(sniffer.observe(b"\x1B]133;D;137;k=v\x07", 1_450), vec![
            SniffEvent::Status(CommandStatus::Idle {
                exit_code: Some(137),
                duration_ms: 450,
            })
        ]);
        assert!(!sniffer.is_command_running());
        assert_eq!(sniffer.command_running_since_ms(), None);
    }

    #[test]
    fn the_first_prompts_phantom_finish_reports_nothing() {
        assert!(observe("\u{1B}]133;D;0\u{7}").is_empty());
    }

    #[test]
    fn the_prompt_mark_reports_idle_at_first_launch_and_stays_quiet_after_a_finish() {
        // Before any command has run, `B` is the only signal the shell is ready.
        assert_eq!(observe("\u{1B}]133;B\u{7}"), vec![SniffEvent::Status(
            CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }
        )]);
        // After a `D`, a following `B` must not discard that `D`'s exit code with a bare idle.
        let mut sniffer = sniffer();
        sniffer.observe(b"\x1B]133;C\x07", 0);
        sniffer.observe(b"\x1B]133;D;3\x07", 5);
        assert!(sniffer.observe(b"\x1B]133;B\x07", 6).is_empty());
        // A new command re-arms it.
        sniffer.observe(b"\x1B]133;C\x07", 7);
        sniffer.observe(b"\x1B]133;D;0\x07", 8);
        assert!(sniffer.observe(b"\x1B]133;B\x07", 9).is_empty());
    }

    #[test]
    fn an_oversized_command_mark_is_ignored_rather_than_parsed() {
        let padding = "x".repeat(300);
        assert!(observe(&format!("\u{1B}]133;C;{padding}\u{7}")).is_empty());
    }

    #[test]
    fn a_local_working_directory_is_surfaced_and_percent_decoded() {
        assert_eq!(observe("\u{1B}]7;file:///Users/me/My%20Code\u{7}"), vec![
            SniffEvent::Cwd("/Users/me/My Code".to_owned())
        ]);
        assert_eq!(observe("\u{1B}]7;file://localhost/tmp\u{7}"), vec![
            SniffEvent::Cwd("/tmp".to_owned())
        ]);
        assert_eq!(observe("\u{1B}]7;file://mac-studio.local/work\u{7}"), vec![
            SniffEvent::Cwd("/work".to_owned())
        ]);
    }

    #[test]
    fn a_foreign_authority_is_dropped_so_an_ssh_cannot_poison_cwd_inheritance() {
        assert!(observe("\u{1B}]7;file://build-box/home/me\u{7}").is_empty());
        let names = vec!["mac-studio".to_owned()];
        assert_eq!(osc7_path("file://build-box/x", &names), None);
        // The case of the authority does not matter.
        assert_eq!(osc7_path("file://MAC-STUDIO/x", &names).as_deref(), Some("/x"));
    }

    #[test]
    fn a_malformed_or_relative_working_directory_is_dropped() {
        for body in [
            "not-a-url",
            "http://host/path",
            "file://host-only",
            "file:///%ZZ",
            "file://",
        ] {
            assert_eq!(osc7_path(body, &[]), None, "{body}");
        }
    }

    #[test]
    fn osc_9_is_a_notification_unless_it_is_the_progress_protocol() {
        assert_eq!(observe("\u{1B}]9;build finished\u{7}"), vec![
            SniffEvent::Notification {
                title: String::new(),
                body: "build finished".to_owned(),
            }
        ]);
        // The shape test, not a parse — a bare `4` and a `4;…` are both progress.
        assert_eq!(observe("\u{1B}]9;4;1;50\u{7}"), vec![SniffEvent::ProgressBody(
            "4;1;50".to_owned()
        )]);
        assert_eq!(observe("\u{1B}]9;4\u{7}"), vec![SniffEvent::ProgressBody(
            "4".to_owned()
        )]);
        // And a body that merely STARTS with a 4 is still a notification.
        assert_eq!(observe("\u{1B}]9;42 tests passed\u{7}"), vec![
            SniffEvent::Notification {
                title: String::new(),
                body: "42 tests passed".to_owned(),
            }
        ]);
        assert!(observe("\u{1B}]9;\u{7}").is_empty());
    }

    #[test]
    fn osc_777_surfaces_only_its_notify_subcommand() {
        assert_eq!(observe("\u{1B}]777;notify;Build;done in 4s\u{7}"), vec![
            SniffEvent::Notification {
                title: "Build".to_owned(),
                body: "done in 4s".to_owned(),
            }
        ]);
        // A body containing its own semicolons survives, because the split stops at four fields.
        assert_eq!(observe("\u{1B}]777;notify;T;a;b;c\u{7}"), vec![
            SniffEvent::Notification {
                title: "T".to_owned(),
                body: "a;b;c".to_owned(),
            }
        ]);
        assert!(observe("\u{1B}]777;precmd;x\u{7}").is_empty());
        assert!(observe("\u{1B}]777;notify;;\u{7}").is_empty());
    }

    #[test]
    fn a_kitty_notification_folds_a_title_only_form_into_the_body() {
        assert_eq!(observe("\u{1B}]99;;hello\u{7}"), vec![SniffEvent::Notification {
            title: String::new(),
            body: "hello".to_owned(),
        }]);
        // With a distinct body, both fields survive.
        assert_eq!(
            observe("\u{1B}]99;i=1:d=0;Title\u{7}\u{1B}]99;i=1:p=body;Body\u{7}"),
            vec![SniffEvent::Notification {
                title: "Title".to_owned(),
                body: "Body".to_owned(),
            }]
        );
    }

    #[test]
    fn a_kitty_payload_may_be_base64_and_a_bad_one_is_dropped() {
        assert_eq!(observe("\u{1B}]99;e=1;aGVsbG8=\u{7}"), vec![
            SniffEvent::Notification {
                title: String::new(),
                body: "hello".to_owned(),
            }
        ]);
        assert!(observe("\u{1B}]99;e=1;not!base64\u{7}").is_empty());
        assert!(observe("\u{1B}]99;e=2;x\u{7}").is_empty(), "an unknown encoding");
        assert!(observe("\u{1B}]99;p=?;x\u{7}").is_empty(), "the capability query");
        assert!(observe("\u{1B}]99;single-semicolon\u{7}").is_empty());
    }

    #[test]
    fn kitty_assembly_is_bounded_in_both_count_and_length() {
        let mut crowded = sniffer();
        // Nine distinct ids opened with d=0; the ninth is dropped rather than buffered.
        for id in 0..9 {
            crowded.observe(format!("\u{1B}]99;i={id}:d=0;x\u{7}").as_bytes(), 0);
        }
        assert!(
            crowded.observe(b"\x1B]99;i=8:d=1;done\x07", 0).is_empty(),
            "the ninth id never got a slot"
        );
        // A stream that keeps appending is abandoned rather than accumulating: none of the five
        // chunks emits, and the flood never reaches a banner.
        let mut long = sniffer();
        let chunk = "z".repeat(1000);
        for _ in 0..5 {
            assert!(
                long.observe(format!("\u{1B}]99;i=a:d=0;{chunk}\u{7}").as_bytes(), 0)
                    .is_empty()
            );
        }
        // The abandoned id is not poisoned — a later chunk simply starts a fresh, empty assembly.
        assert_eq!(long.observe(b"\x1B]99;i=a:d=1;end\x07", 0), vec![
            SniffEvent::Notification {
                title: String::new(),
                body: "end".to_owned(),
            }
        ]);
    }

    #[test]
    fn base64_is_strict_about_padding_and_alphabet() {
        assert_eq!(decode_base64(""), Some(Vec::new()));
        assert_eq!(decode_base64("aGk="), Some(b"hi".to_vec()));
        assert_eq!(decode_base64("aGVsbG8h"), Some(b"hello!".to_vec()));
        assert_eq!(decode_base64("aGk"), None, "unpadded");
        assert_eq!(decode_base64("a=Gk"), None, "padding in the middle");
        assert_eq!(decode_base64("a G="), None, "not in the alphabet");
    }

    #[test]
    fn an_over_cap_osc_is_swallowed_to_its_terminator_and_never_leaks_a_bell() {
        let flood = "t".repeat(5000);
        let events = observe(&format!("\u{1B}]2;{flood}\u{7}\u{1B}]2;after\u{7}"));
        assert_eq!(
            events,
            vec![title("after")],
            "the discarded terminator rang nothing"
        );
    }

    #[test]
    fn a_stray_escape_ends_an_osc_without_orphaning_the_next_sequence() {
        // The `ESC` is not an `ST`, so the title ends there — and the `]` that follows must still
        // be read as an introducer rather than as content.
        assert_eq!(observe("\u{1B}]2;first\u{1B}\u{1B}]2;second\u{7}"), vec![
            title("first"),
            title("second")
        ]);
    }

    #[test]
    fn an_st_terminator_reads_the_same_as_a_bel_one() {
        assert_eq!(observe("\u{1B}]2;t\u{1B}\\"), vec![title("t")]);
    }

    #[test]
    fn splitting_the_stream_at_every_byte_yields_identical_events() {
        let stream = "out\u{7}\u{1B}]2;title\u{7}\u{1B}]7;file:///tmp\u{7}\u{1B}]133;C\u{7}\
             work\u{1B}]133;D;0\u{7}\u{1B}]9;note\u{7}";
        let whole = observe(stream);
        let mut sniffer = sniffer();
        let mut piecewise = Vec::new();
        for byte in stream.as_bytes() {
            piecewise.extend(sniffer.observe(&[*byte], 0));
        }
        assert_eq!(whole, piecewise);
        assert_eq!(whole.len(), 6, "bell, title, cwd, running, idle, notification");
    }

    #[test]
    fn events_come_out_in_byte_order_across_kinds() {
        let events = observe("\u{7}\u{1B}]2;t\u{7}\u{1B}]133;C\u{7}\u{7}");
        assert_eq!(events, vec![
            SniffEvent::Bell,
            title("t"),
            SniffEvent::Status(CommandStatus::Running),
            SniffEvent::Bell,
        ]);
    }

    #[test]
    fn ordinary_output_and_unhandled_sequences_produce_nothing() {
        assert!(observe("plain text with no escapes").is_empty());
        assert!(observe("\u{1B}[1;32mcolour\u{1B}[0m").is_empty());
        assert!(observe("\u{1B}]8;;https://x.com\u{7}link\u{1B}]8;;\u{7}").is_empty());
        assert!(observe("\u{1B}]52;c;Zm9v\u{7}").is_empty());
        assert!(observe("\u{1B}]2\u{7}").is_empty(), "no separator at all");
    }
}
