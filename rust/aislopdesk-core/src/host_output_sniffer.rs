//! The host-side outbound-PTY output sniffer — a byte-at-a-time terminal-output state
//! machine, a port of Swift `HostOutputSniffer`
//! (Sources/AislopdeskHost/HostOutputSniffer.swift).
//!
//! It scans the OUTBOUND PTY byte stream (host → client) for the three inline host→client
//! CONTROL messages and emits them as [`crate::terminal::WireMessage`] values, in byte
//! order, without ever consuming/altering the stream (the caller forwards the original
//! bytes UNCHANGED):
//!
//! - [`WireMessage::Title`] — OSC 0 / OSC 2 (`ESC ] 0;… <term>` / `ESC ] 2;… <term>`).
//! - [`WireMessage::Bell`] — a standalone ground-state `BEL` (never an OSC/string terminator).
//! - [`WireMessage::CommandStatus`] — OSC 133 `C` (running) / `D[;exit]` (idle, with the
//!   host-measured C→D duration in milliseconds).
//! - [`WireMessage::Notification`] — OSC 9 (iTerm2/ConEmu) and OSC 777 (urxvt/ConEmu `notify`).
//!
//! ## Provenance (exact-parity port)
//! [`HostOutputSniffer::step`] is the 8-state transition table VERBATIM from the Swift
//! source (`.ground` / `.escape` / `.osc` / `.oscEscape` / `.oscDiscard` /
//! `.oscDiscardEscape` / `.stringConsume` / `.stringConsumeEscape`), including the
//! DCS/SOS/PM/APC string-swallowing anti-spoof, the cap-bounded OSC buffer, the stray-ESC
//! re-entry fix, and [`HostOutputSniffer::finish_osc`]'s Ps-prefix dispatch with the
//! EXACT-PARITY 256-byte command cap.
//!
//! ## Streaming-safe
//! A true byte-at-a-time machine: state persists across chunks, so any split (mid-ESC,
//! mid-OSC, mid-terminator) yields identical messages to the whole stream. The OSC payload
//! buffer is capped ([`HostOutputSniffer::OSC_CAP`]); over-cap / string-sequence bodies are
//! swallowed without buffering, so a hostile stream can never wedge the sniffer or make it
//! buffer unboundedly.
//!
//! ## Deviations from the Swift source (documented, output-identical)
//! - **No `NSLock`.** The Swift type is `@unchecked Sendable` and guards its mutable state
//!   with a lock so it can be captured in a `@Sendable` closure; in practice `observe` is
//!   only ever called from the single serial `PTYReadLoop` queue. This port is `&mut self`
//!   (single-owner) and drops the lock entirely.
//! - **No `memchr` fast path.** Swift skims `.ground` / `.oscDiscard` / `.stringConsume`
//!   with `memchr` to route only `ESC`/`BEL` through `step()` — a pure performance
//!   optimization that *never replaces a transition* (Swift's permanent
//!   `testChunkingInvarianceOracle` pins it to the per-byte path). This port runs the
//!   per-byte path directly: byte- and behaviour-identical, just not micro-optimized.
//! - **Clock as a parameter, not an injected closure.** Swift injects a `() -> Date` clock
//!   and measures the OSC 133 C→D duration from it. This port takes the time as
//!   `now_ms: u64` (the caller's monotonic milliseconds) on each [`HostOutputSniffer::observe`]
//!   call: it captures the start ms when the `C` marker is processed and computes
//!   `duration = now_ms - start` (saturating) at `D`, clamped to `u32` exactly like Swift's
//!   `durationMS`. See the crate's golden-vector dumper notes for the scripted-clock mapping
//!   that makes the two agree.

use crate::terminal::{CommandStatus, WireMessage};

/// Parser state for the byte-at-a-time machine — a verbatim port of the Swift `State` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Outside any escape sequence (opaque content). A `BEL` here is a real terminal bell.
    Ground,
    /// Saw `ESC` (`0x1B`); waiting for the next byte to classify (`]` → OSC, etc.).
    Escape,
    /// Inside an OSC sequence (`ESC ]`). Collecting payload until `BEL` or `ST`.
    Osc,
    /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the `\` that
    /// completes an `ST` terminator (`ESC \`), or a new sequence start.
    OscEscape,
    /// An over-cap OSC is being DISCARDED: still INSIDE the OSC (so its terminator must be
    /// consumed here, not re-parsed as ground), but no longer buffering. Bounded O(n).
    OscDiscard,
    /// Inside a discarded OSC and the previous byte was `ESC` (possible `ST`).
    OscDiscardEscape,
    /// Inside a DCS/SOS/PM/APC string sequence: swallow the body to its ST/BEL terminator,
    /// emitting NOTHING. UNLIKE an OSC, an embedded ESC that is NOT `\` is part of the opaque
    /// string (it does NOT start a new sequence), so this never re-classifies.
    StringConsume,
    /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC \`).
    StringConsumeEscape,
}

/// The FUSED host-side outbound-PTY output sniffer. See the module docs for the full
/// grammar; a port of Swift `HostOutputSniffer`.
///
/// Drive it by feeding chunks of the outbound byte stream to [`observe`](Self::observe);
/// state persists across calls so chunk boundaries are irrelevant to the emitted messages.
#[derive(Debug, Clone)]
pub struct HostOutputSniffer {
    state: State,
    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator), e.g.
    /// `0;my title` or `133;D;0`. Bounded by [`Self::OSC_CAP`].
    osc_buffer: Vec<u8>,
    /// The last title emitted, for trivial coalescing (don't spam identical titles).
    last_title: Option<String>,
    /// The `now_ms` captured when the foreground command started (set on `133;C`, cleared
    /// on `133;D`); `None` when idle. Mirrors Swift's `runningSince: Date?`.
    start_ms: Option<u64>,
}

impl Default for HostOutputSniffer {
    /// A fresh sniffer in the ground state, no command running, no last title. Equivalent to
    /// [`HostOutputSniffer::new`].
    fn default() -> Self {
        Self::new()
    }
}

impl HostOutputSniffer {
    /// Hard cap on the buffered OSC payload (the title sniffer's cap). A real title is tiny;
    /// anything longer is abandoned and the parser resyncs. Mirrors Swift `oscCap`.
    const OSC_CAP: usize = 4096;

    /// EXACT-PARITY guard for the 133 path: the old command sniffer capped ITS buffer at
    /// 256, so a `133;…` payload of 257..=4096 bytes never reached its `finishOSC`. The fused
    /// machine buffers up to 4096, so [`finish_osc`](Self::finish_osc) re-imposes 256 on the
    /// 133 branch. Mirrors Swift `cmdOscCap`.
    const CMD_OSC_CAP: usize = 256;

    /// Payload cap for the OSC 9 / OSC 777 notification path: a real notification line is
    /// short; a multi-kilobyte one is not worth surfacing (and bounds a hostile stream).
    /// Mirrors Swift `notifyOscCap`.
    const NOTIFY_OSC_CAP: usize = 1024;

    const ESC: u8 = 0x1B;
    const BEL: u8 = 0x07;
    const RIGHT_BRACKET: u8 = 0x5D; // ']'
    const BACKSLASH: u8 = 0x5C; // '\'
    const SEMICOLON: u8 = 0x3B; // ';'
                                // String-sequence introducers: DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`.
    const DCS: u8 = 0x50; // 'P'
    const SOS: u8 = 0x58; // 'X'
    const PM: u8 = 0x5E; // '^'
    const APC: u8 = 0x5F; // '_'

    /// Builds a fresh sniffer in the ground state. Equivalent to Swift `HostOutputSniffer()`.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: State::Ground,
            osc_buffer: Vec::new(),
            last_title: None,
            start_ms: None,
        }
    }

    /// Observes a chunk of the OUTBOUND byte stream and returns the CONTROL messages
    /// (`Title` / `Bell` / `CommandStatus` / `Notification`) detected in it, **in byte
    /// order**. Does NOT modify or consume the bytes — the caller forwards the original chunk
    /// unchanged.
    ///
    /// `now_ms` is the caller's monotonic clock in milliseconds, used to stamp the OSC 133
    /// C→D duration: the value seen when a `C` marker completes is the start, and the value
    /// seen when the matching `D` completes yields `duration = now_ms - start` (saturating,
    /// clamped to `u32`). It is otherwise ignored. Mirrors Swift's `@discardableResult
    /// observe(_:)` (the result may be ignored).
    pub fn observe(&mut self, bytes: &[u8], now_ms: u64) -> Vec<WireMessage> {
        let mut messages = Vec::new();
        for &byte in bytes {
            self.step(byte, now_ms, &mut messages);
        }
        messages
    }

    /// One byte through the state machine — the Swift `step(_:into:)` transition table
    /// verbatim. `now_ms` is threaded through only so [`finish_osc`](Self::finish_osc) can
    /// stamp a C/D duration.
    fn step(&mut self, byte: u8, now_ms: u64, messages: &mut Vec<WireMessage>) {
        match self.state {
            State::Ground => match byte {
                Self::ESC => self.state = State::Escape,
                // A BEL in ground state is a real terminal bell (NOT an OSC terminator).
                Self::BEL => messages.push(WireMessage::Bell),
                _ => {} // opaque content byte — ignore.
            },

            State::Escape => match byte {
                Self::RIGHT_BRACKET => {
                    self.state = State::Osc;
                    self.osc_buffer.clear();
                }
                // DCS/SOS/PM/APC introduce a STRING sequence whose body a conformant terminal
                // swallows to its ST/BEL terminator WITHOUT ringing a bell or changing the
                // title — anti-spoof of an embedded BEL / `ESC]2;…` / `ESC]133;…`.
                Self::DCS | Self::SOS | Self::PM | Self::APC => self.state = State::StringConsume,
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                Self::ESC => self.state = State::Escape,
                // Some other escape (CSI `ESC[`, a 2-byte / nF escape). Not an OSC; back to
                // ground.
                _ => self.state = State::Ground,
            },

            State::Osc => match byte {
                // BEL terminates the OSC string — emit a title / status / notification if it
                // is one, and CRUCIALLY do NOT emit a Bell (this BEL is a terminator).
                Self::BEL => {
                    self.finish_osc(now_ms, messages);
                    self.state = State::Ground;
                }
                // Possible start of an `ST` terminator (`ESC \`).
                Self::ESC => self.state = State::OscEscape,
                _ => {
                    self.osc_buffer.push(byte);
                    if self.osc_buffer.len() > Self::OSC_CAP {
                        // Overlong — abandon WITHOUT emitting. Do NOT drop to ground (we are
                        // still INSIDE the OSC; its real terminator has not arrived). Switch
                        // to OscDiscard to swallow the rest, terminator included.
                        self.osc_buffer.clear();
                        self.state = State::OscDiscard;
                    }
                }
            },

            State::OscDiscard => match byte {
                Self::BEL => self.state = State::Ground,
                Self::ESC => self.state = State::OscDiscardEscape,
                _ => {} // discarded payload byte
            },

            State::OscDiscardEscape => {
                if byte == Self::BACKSLASH {
                    self.state = State::Ground; // `ESC \` = ST terminator of the discarded OSC.
                } else {
                    // The `ESC` was not an ST terminator — it may introduce a NEW sequence.
                    // Re-enter escape and re-classify this byte (no payload to finish — the
                    // OSC was discarded).
                    self.state = State::Escape;
                    self.step(byte, now_ms, messages);
                }
            }

            State::StringConsume => match byte {
                Self::BEL => self.state = State::Ground,
                Self::ESC => self.state = State::StringConsumeEscape,
                _ => {} // opaque string-body byte — swallow.
            },

            State::StringConsumeEscape => match byte {
                Self::BACKSLASH => self.state = State::Ground, // `ESC \` = ST terminator.
                Self::ESC => self.state = State::StringConsumeEscape, // another ESC — keep waiting.
                _ => self.state = State::StringConsume, // a lone ESC inside the body — swallow + continue.
            },

            State::OscEscape => {
                // Either way the OSC ends here (`ESC \` = ST, or a stray ESC terminates it).
                self.finish_osc(now_ms, messages);
                if byte == Self::BACKSLASH {
                    self.state = State::Ground; // clean ST terminator.
                } else {
                    // The `ESC` was not an ST terminator — it may itself introduce a NEW
                    // sequence, so re-enter escape (NOT ground) and re-classify this byte as
                    // that sequence's introducer.
                    self.state = State::Escape;
                    self.step(byte, now_ms, messages);
                }
            }
        }
    }

    /// Fused OSC dispatch on the Ps prefix: OSC 0/2 (title), OSC 133 C/D (command status),
    /// OSC 9 / OSC 777 (notification). Consumes the buffered payload (always cleared on exit,
    /// mirroring Swift's `defer { oscBuffer.removeAll() }`). A port of Swift `finishOSC(into:)`.
    fn finish_osc(&mut self, now_ms: u64, messages: &mut Vec<WireMessage>) {
        // Take the buffer out — leaves `self.osc_buffer` empty (the Swift `defer`-clear) and
        // frees `self` for the `last_title` / `start_ms` mutations below.
        let buffer = std::mem::take(&mut self.osc_buffer);

        // Split the Ps prefix at the FIRST ';' — the payload after it may itself contain ';'.
        let Some(sep) = buffer.iter().position(|&b| b == Self::SEMICOLON) else {
            return;
        };
        let ps = Self::utf8_or_empty(&buffer[..sep]);

        match ps.as_str() {
            // Title path — OSC 0 (icon name + window title) and OSC 2 (window title only).
            // OSC 1 is icon-name-ONLY and deliberately ignored.
            "0" | "2" => {
                let title = Self::utf8_or_empty(&buffer[sep + 1..]);
                // Trivial dedup: don't spam an identical title back-to-back.
                if self.last_title.as_deref() == Some(title.as_str()) {
                    return;
                }
                self.last_title = Some(title.clone());
                messages.push(WireMessage::Title(title));
            }

            "133" => {
                // EXACT-PARITY guard: a `133;…` payload of 257..=4096 bytes reaches here in
                // the fused machine (title cap) but was discarded by the old command sniffer's
                // 256-byte cap — reproduce that so those payloads stay ignored.
                if buffer.len() > Self::CMD_OSC_CAP {
                    return;
                }
                let payload = Self::utf8_or_empty(&buffer);
                // Full split on ';' with EMPTY fields KEPT (Swift omittingEmptySubsequences:
                // false). Expected: "133;A" | "133;B" | "133;C" | "133;D" | "133;D;<exit>"
                // (+ extra ;k=v).
                let fields: Vec<&str> = payload.split(';').collect();
                if fields.len() < 2 || fields[0] != "133" {
                    return;
                }
                match fields[1] {
                    // A command began executing — mark RUNNING and start the duration clock.
                    "C" => {
                        self.start_ms = Some(now_ms);
                        messages.push(WireMessage::CommandStatus(CommandStatus::Running));
                    }
                    // A command finished. Ignore a `D` with no matching `C` (the first-prompt
                    // phantom `D;0`) — never emit a 0-duration idle for a command that never ran.
                    "D" => {
                        let Some(started) = self.start_ms else {
                            return;
                        };
                        self.start_ms = None;
                        let exit_code = Self::parse_exit(&fields);
                        let duration_ms = Self::duration_ms(started, now_ms);
                        messages.push(WireMessage::CommandStatus(CommandStatus::Idle {
                            exit_code,
                            duration_ms,
                        }));
                    }
                    _ => {} // A / B / unknown 133 subcommand — not surfaced.
                }
            }

            // OSC 9 — iTerm2/ConEmu "post a notification" (`ESC ] 9 ; <body> ST`). The whole
            // remainder after `9;` is the body; no explicit title.
            "9" => {
                if buffer.len() > Self::NOTIFY_OSC_CAP {
                    return;
                }
                let body = Self::utf8_or_empty(&buffer[sep + 1..]);
                if body.is_empty() {
                    return;
                }
                // OSC 9 is overloaded: `ESC]9;4;<state>;<pct>` is the taskbar PROGRESS-BAR
                // protocol (winget, long builds), NOT a desktop notification — skip the `9;4`
                // progress subtype so it doesn't flood the user with alerts like "4;1;50".
                if body == "4" || body.starts_with("4;") {
                    return;
                }
                messages.push(WireMessage::Notification {
                    title: String::new(),
                    body,
                });
            }

            // OSC 777 — urxvt/ConEmu `ESC ] 777 ; notify ; <title> ; <body> ST`. Only the
            // `notify` subcommand is a desktop notification.
            "777" => {
                if buffer.len() > Self::NOTIFY_OSC_CAP {
                    return;
                }
                let payload = Self::utf8_or_empty(&buffer);
                // maxSplits: 3 → at most 4 fields; the body (field 3) keeps embedded ';'.
                let fields: Vec<&str> = payload.splitn(4, ';').collect();
                if fields.len() < 3 || fields[1] != "notify" {
                    return;
                }
                let title = fields[2].to_owned();
                let body = if fields.len() >= 4 {
                    fields[3].to_owned()
                } else {
                    String::new()
                };
                if title.is_empty() && body.is_empty() {
                    return;
                }
                messages.push(WireMessage::Notification { title, body });
            }

            // Any other Ps (OSC 1 icon, OSC 8 hyperlink, OSC 52 clipboard, OSC 4 palette …)
            // is neither a title, a command mark, nor a notification — skip.
            _ => {}
        }
    }

    /// Decodes bytes as strict UTF-8, falling back to the empty string on invalid UTF-8 —
    /// the Rust analogue of Swift's `String(bytes:encoding:.utf8) ?? ""`.
    #[must_use]
    fn utf8_or_empty(bytes: &[u8]) -> String {
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .unwrap_or_default()
    }

    /// Parses the optional exit code from a `133;D[;<exit>[;k=v…]]` field list (field[2],
    /// tolerating a trailing `=value`), truncated to `i32`. Returns `None` when
    /// absent/unparsable. A port of Swift `parseExit`.
    #[must_use]
    fn parse_exit(fields: &[&str]) -> Option<i32> {
        if fields.len() < 3 {
            return None;
        }
        let field = fields[2];
        // Swift: `fields[2].split(separator: "=").first` (empty subsequences omitted) → the
        // FIRST non-empty `=`-segment; `?? String(fields[2])` keeps the whole field when none.
        let raw = field.split('=').find(|s| !s.is_empty()).unwrap_or(field);
        // Swift `Int(raw)` is 64-bit; `Int32(truncatingIfNeeded:)` wraps to 32 bits (`as i32`).
        raw.parse::<i64>().ok().map(|value| value as i32)
    }

    /// The non-negative C→D duration in milliseconds, saturating at 0 (a non-monotonic clock
    /// or same-instant C/D can never produce a negative) and clamped to [`u32::MAX`]. The
    /// integer-ms analogue of Swift `durationMS(from:to:)` — the dumper scripts the Swift
    /// clock so `(end - start) * 1000` rounded equals `now_ms - start_ms`.
    #[must_use]
    const fn duration_ms(start_ms: u64, now_ms: u64) -> u32 {
        let dur = now_ms.saturating_sub(start_ms);
        if dur >= u32::MAX as u64 {
            u32::MAX
        } else {
            dur as u32
        }
    }
}

#[cfg(test)]
#[allow(clippy::too_many_lines)]
mod tests {
    use super::*;

    // Control bytes, mirroring the Swift test constants.
    const ESC: u8 = 0x1B;
    const BEL: u8 = 0x07;

    /// Concatenates byte fragments into one stream (Swift tests build streams with `+`).
    fn cat(parts: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for p in parts {
            out.extend_from_slice(p);
        }
        out
    }

    /// `ESC ] 133 ; <mark> BEL` — mirrors the Swift `osc133(_:)` helper.
    fn osc133(mark: &str) -> Vec<u8> {
        cat(&[b"\x1b]133;", mark.as_bytes(), &[BEL]])
    }

    /// Feeds `bytes` to a fresh sniffer in one shot at `now_ms = 0`.
    fn observe_whole(bytes: &[u8]) -> Vec<WireMessage> {
        HostOutputSniffer::new().observe(bytes, 0)
    }

    /// Feeds `bytes` to a fresh sniffer split into chunks of `size`, at `now_ms = 0`.
    fn observe_chunked(bytes: &[u8], size: usize) -> Vec<WireMessage> {
        let mut s = HostOutputSniffer::new();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            let end = (i + size).min(bytes.len());
            out.extend(s.observe(&bytes[i..end], 0));
            i = end;
        }
        out
    }

    fn title(s: &str) -> WireMessage {
        WireMessage::Title(s.to_owned())
    }

    fn idle(exit_code: Option<i32>, duration_ms: u32) -> WireMessage {
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code,
            duration_ms,
        })
    }

    fn running() -> WireMessage {
        WireMessage::CommandStatus(CommandStatus::Running)
    }

    fn notif(t: &str, b: &str) -> WireMessage {
        WireMessage::Notification {
            title: t.to_owned(),
            body: b.to_owned(),
        }
    }

    fn command_only(messages: &[WireMessage]) -> Vec<WireMessage> {
        messages
            .iter()
            .filter(|m| matches!(m, WireMessage::CommandStatus(_)))
            .cloned()
            .collect()
    }

    fn notifications_only(messages: &[WireMessage]) -> Vec<WireMessage> {
        messages
            .iter()
            .filter(|m| matches!(m, WireMessage::Notification { .. }))
            .cloned()
            .collect()
    }

    // =====================================================================================
    // Ported from HostOutputSnifferTests — title / bell
    // =====================================================================================

    #[test]
    fn osc0_with_bel_terminator_emits_title() {
        assert_eq!(observe_whole(b"\x1b]0;hello\x07"), vec![title("hello")]);
    }

    #[test]
    fn osc2_with_st_terminator_emits_title() {
        assert_eq!(
            observe_whole(b"\x1b]2;my window\x1b\\"),
            vec![title("my window")]
        );
    }

    #[test]
    fn osc0_with_st_terminator_emits_title() {
        assert_eq!(observe_whole(b"\x1b]0;both\x1b\\"), vec![title("both")]);
    }

    #[test]
    fn osc2_with_bel_terminator_emits_title() {
        assert_eq!(observe_whole(b"\x1b]2;winbel\x07"), vec![title("winbel")]);
    }

    #[test]
    fn osc_split_across_two_chunks() {
        let bytes = b"\x1b]0;split title\x07";
        for cut in 1..bytes.len() {
            let mut s = HostOutputSniffer::new();
            let mut out = s.observe(&bytes[..cut], 0);
            out.extend(s.observe(&bytes[cut..], 0));
            assert_eq!(out, vec![title("split title")], "split at {cut} diverged");
        }
    }

    #[test]
    fn osc_split_every_chunk_size_equivalence() {
        let bytes = "\u{1b}]2;Claude Code — repo\u{07}".as_bytes();
        let expected = vec![title("Claude Code — repo")];
        for size in 1..=bytes.len() {
            assert_eq!(observe_chunked(bytes, size), expected, "chunk size {size}");
        }
    }

    #[test]
    fn standalone_bel_emits_bell() {
        assert_eq!(observe_whole(&[BEL]), vec![WireMessage::Bell]);
    }

    #[test]
    fn bel_amid_content_emits_bell() {
        assert_eq!(observe_whole(b"abc\x07def"), vec![WireMessage::Bell]);
    }

    #[test]
    fn multiple_standalone_bels_emit_multiple_bells() {
        assert_eq!(
            observe_whole(&[BEL, BEL, BEL]),
            vec![WireMessage::Bell, WireMessage::Bell, WireMessage::Bell]
        );
    }

    #[test]
    fn bel_terminating_osc_is_not_a_bell() {
        let msgs = observe_whole(b"\x1b]0;title via bel\x07");
        assert_eq!(msgs, vec![title("title via bel")]);
        assert!(!msgs.contains(&WireMessage::Bell));
    }

    #[test]
    fn title_then_real_bell_are_distinguished() {
        assert_eq!(
            observe_whole(b"\x1b]0;t\x07\x07"),
            vec![title("t"), WireMessage::Bell]
        );
    }

    #[test]
    fn unterminated_osc_then_valid_title_not_lost() {
        let bytes = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
        let msgs = observe_whole(&bytes);
        assert_eq!(msgs, vec![title("abc"), title("real")]);
        assert!(msgs.contains(&title("real")));
    }

    #[test]
    fn unterminated_osc_then_valid_title_split_consistent() {
        let bytes = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
        let expected = vec![title("abc"), title("real")];
        for size in 1..=bytes.len() {
            assert_eq!(observe_chunked(&bytes, size), expected, "chunk size {size}");
        }
    }

    #[test]
    fn stray_esc_in_osc_then_bel_is_not_a_bell() {
        // `ESC]0;abc` then `ESC X` (SOS introducer) then BEL (= the SOS terminator).
        let bytes = cat(&[b"\x1b]0;abc", b"\x1bX", &[BEL]]);
        assert_eq!(observe_whole(&bytes), vec![title("abc")]);
    }

    #[test]
    fn string_sequences_swallow_embedded_bell_and_title() {
        // DCS with an embedded BEL → swallowed (no phantom bell).
        assert_eq!(observe_whole(b"\x1bPq\x07"), vec![]);
        // APC with an embedded OSC-2 title → swallowed (no title spoof).
        let apc_spoof = cat(&[b"\x1b_\x1b]2;pwned\x07", b"\x1b\\"]);
        assert_eq!(observe_whole(&apc_spoof), vec![]);
        // A REAL OSC 2 after a swallowed PM string still fires.
        let pm_then_real = cat(&[b"\x1b^junk\x07", b"\x1b]2;real\x07"]);
        assert_eq!(observe_whole(&pm_then_real), vec![title("real")]);
    }

    #[test]
    fn double_esc_then_backslash_terminates_st() {
        let bytes = cat(&[b"\x1b]2;x", b"\x1b\x1b\\"]);
        assert_eq!(observe_whole(&bytes), vec![title("x")]);
    }

    #[test]
    fn overlong_unterminated_osc_bounded_then_resync() {
        let junk = vec![b'x'; 10000];
        let bytes = cat(&[b"\x1b]2;", &junk, b"\x1b]0;after\x07"]);
        assert_eq!(observe_whole(&bytes), vec![title("after")]);
    }

    #[test]
    fn overlong_osc_bounded_split_consistent() {
        let junk = vec![b'y'; 9000];
        let bytes = cat(&[b"\x1b]0;", &junk, b"\x1b]2;done\x07"]);
        let expected = vec![title("done")];
        for size in [1usize, 2, 7, 64, 128, 4096, bytes.len()] {
            assert_eq!(observe_chunked(&bytes, size), expected, "chunk size {size}");
        }
    }

    #[test]
    fn overlong_osc_terminator_bel_is_not_a_phantom_bell() {
        let junk = vec![b'x'; 5000]; // > 4096 cap
        let bytes = cat(&[b"\x1b]2;", &junk, &[BEL], b"\x1b]0;real\x07"]);
        let msgs = observe_whole(&bytes);
        assert!(!msgs.contains(&WireMessage::Bell));
        assert_eq!(msgs, vec![title("real")]);
        for size in [1usize, 3, 64, 4096, bytes.len()] {
            assert_eq!(
                observe_chunked(&bytes, size),
                vec![title("real")],
                "chunk size {size}"
            );
        }
    }

    #[test]
    fn overlong_osc_terminated_by_st_resyncs() {
        let junk = vec![b'x'; 5000];
        let bytes = cat(&[b"\x1b]2;", &junk, b"\x1b\\", b"\x1b]0;real\x07"]);
        let msgs = observe_whole(&bytes);
        assert!(!msgs.contains(&WireMessage::Bell));
        assert_eq!(msgs, vec![title("real")]);
    }

    #[test]
    fn osc1_icon_name_ignored() {
        assert_eq!(observe_whole(b"\x1b]1;iconname\x07"), vec![]);
    }

    #[test]
    fn unrelated_osc_ignored() {
        let bytes = cat(&[
            b"\x1b]8;;https://example.com\x07",
            b"\x1b]52;c;BASE64==\x07",
            b"\x1b]133;A\x07",
            b"\x1b]4;1;rgb:00/00/00\x07",
        ]);
        assert_eq!(observe_whole(&bytes), vec![]);
    }

    #[test]
    fn osc_without_semicolon_ignored() {
        assert_eq!(observe_whole(b"\x1b]0\x07"), vec![]);
    }

    #[test]
    fn empty_title_is_emitted_once() {
        assert_eq!(observe_whole(b"\x1b]2;\x07"), vec![title("")]);
    }

    #[test]
    fn title_with_semicolons_in_text() {
        assert_eq!(observe_whole(b"\x1b]0;a;b;c\x07"), vec![title("a;b;c")]);
    }

    #[test]
    fn identical_consecutive_titles_deduped() {
        let bytes = cat(&[b"\x1b]0;same\x07", b"\x1b]2;same\x07", b"\x1b]0;same\x07"]);
        assert_eq!(observe_whole(&bytes), vec![title("same")]);
    }

    #[test]
    fn different_titles_not_deduped() {
        let bytes = cat(&[b"\x1b]0;one\x07", b"\x1b]2;two\x07", b"\x1b]0;one\x07"]);
        assert_eq!(
            observe_whole(&bytes),
            vec![title("one"), title("two"), title("one")]
        );
    }

    #[test]
    fn interleaved_real_world_stream() {
        let stream = "welcome\n".to_owned()
            + "\u{1b}]0;Claude Code\u{07}"
            + "$ ls\n"
            + "\u{1b}[?1049h"
            + "drawing\u{1b}[2J"
            + "\u{1b}]2;vim — file.txt\u{1b}\\"
            + "\u{07}"
            + "\u{1b}[?1049l"
            + "\u{1b}]2;vim — file.txt\u{1b}\\"
            + "bye\n";
        let bytes = stream.as_bytes();
        let expected = vec![
            title("Claude Code"),
            title("vim — file.txt"),
            WireMessage::Bell,
        ];
        assert_eq!(observe_whole(bytes), expected);
        for size in 1..=bytes.len() {
            assert_eq!(observe_chunked(bytes, size), expected, "chunk size {size}");
        }
    }

    #[test]
    fn utf8_title_and_content_pass_through() {
        let mut bytes = "café 🚀\n".as_bytes().to_vec();
        bytes.extend_from_slice(&[0xFF, 0x80, 0xC0]); // raw high-bit content
        bytes.extend_from_slice("\u{1b}]0;日本語\u{07}".as_bytes());
        assert_eq!(observe_whole(&bytes), vec![title("日本語")]);
    }

    #[test]
    fn partial_sequence_at_end_never_misfires() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(b"\x1b]0;par", 0), vec![]);
        assert_eq!(s.observe(b"tial\x07", 0), vec![title("partial")]);
    }

    // =====================================================================================
    // Ported from HostOutputSnifferTests — command status (with the now_ms clock parameter)
    // =====================================================================================

    #[test]
    fn c_started_then_d_finished_with_exit_and_duration() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
        // 12 seconds elapse → now_ms advances by 12_000.
        assert_eq!(
            s.observe(&osc133("D;0"), 12_000),
            vec![idle(Some(0), 12_000)]
        );
    }

    #[test]
    fn quick_command_sub_second_duration() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
        assert_eq!(s.observe(&osc133("D;0"), 300), vec![idle(Some(0), 300)]);
    }

    #[test]
    fn non_zero_exit_code_parsed() {
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(
            s.observe(&osc133("D;130"), 1000),
            vec![idle(Some(130), 1000)]
        );
    }

    #[test]
    fn d_without_exit_code_yields_nil_exit() {
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(s.observe(&osc133("D"), 2000), vec![idle(None, 2000)]);
    }

    #[test]
    fn d_extra_key_value_fields_tolerated() {
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(
            s.observe(&osc133("D;0;aid=123"), 1000),
            vec![idle(Some(0), 1000)]
        );
    }

    #[test]
    fn d_without_preceding_c_is_ignored() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(&osc133("D;0"), 0), vec![]);
    }

    #[test]
    fn a_and_b_marks_are_not_surfaced() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(&osc133("A"), 0), vec![]);
        assert_eq!(s.observe(&osc133("B"), 0), vec![]);
    }

    #[test]
    fn full_prompt_cycle_yields_running_then_idle() {
        let mut s = HostOutputSniffer::new();
        let mut out = Vec::new();
        out.extend(s.observe(&osc133("D;0"), 0)); // phantom precmd D (ignored)
        out.extend(s.observe(&osc133("A"), 0)); // prompt A (ignored)
        out.extend(s.observe(&osc133("C"), 0)); // preexec C
        out.extend(s.observe(&osc133("D;0"), 11_000)); // precmd D (11s later)
        out.extend(s.observe(&osc133("A"), 11_000)); // prompt A (ignored)
        assert_eq!(out, vec![running(), idle(Some(0), 11_000)]);
    }

    #[test]
    fn split_at_every_byte_boundary_produces_identical_events() {
        let c_bytes = osc133("C");
        let d_bytes = osc133("D;7");

        // Whole-chunk reference: C at now_ms=0, advance 5s, D at now_ms=5000.
        let mut reference = HostOutputSniffer::new();
        let mut want = reference.observe(&c_bytes, 0);
        want.extend(reference.observe(&d_bytes, 5000));

        // One byte at a time, with the SAME single advance between the two marks.
        let mut split = HostOutputSniffer::new();
        let mut got = Vec::new();
        for &b in &c_bytes {
            got.extend(split.observe(&[b], 0));
        }
        for &b in &d_bytes {
            got.extend(split.observe(&[b], 5000));
        }

        assert_eq!(got, want);
        assert_eq!(got, vec![running(), idle(Some(7), 5000)]);
    }

    #[test]
    fn st_terminator_recognized() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(b"\x1b]133;C\x1b\\", 0), vec![running()]);
        assert_eq!(
            s.observe(b"\x1b]133;D;0\x1b\\", 1000),
            vec![idle(Some(0), 1000)]
        );
    }

    #[test]
    fn ignores_non_133_osc_and_plain_content() {
        let mut s = HostOutputSniffer::new();
        let on_preamble = s.observe(b"\x1b]0;my title\x07user@host % ", 0);
        assert_eq!(command_only(&on_preamble), vec![]);
        assert_eq!(on_preamble, vec![title("my title")]);
        assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
    }

    #[test]
    fn two_sequential_commands_each_measured_independently() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
        assert_eq!(s.observe(&osc133("D;0"), 3000), vec![idle(Some(0), 3000)]);
        // Second command: now_ms restarts from the D at 3000 → C at 3000, D at 10000 → 7000ms.
        assert_eq!(s.observe(&osc133("C"), 3000), vec![running()]);
        assert_eq!(s.observe(&osc133("D;1"), 10_000), vec![idle(Some(1), 7000)]);
    }

    // =====================================================================================
    // Ported from HostOutputSnifferTests — OSC 9 / OSC 777 notifications
    // =====================================================================================

    #[test]
    fn osc9_emits_notification_with_empty_title() {
        assert_eq!(
            observe_whole(b"\x1b]9;build done\x07"),
            vec![notif("", "build done")]
        );
    }

    #[test]
    fn osc9_with_st_terminator() {
        assert_eq!(
            observe_whole(b"\x1b]9;tests passed\x1b\\"),
            vec![notif("", "tests passed")]
        );
    }

    #[test]
    fn osc777_notify_subcommand_emits_title_and_body() {
        assert_eq!(
            observe_whole(b"\x1b]777;notify;CI;all green\x07"),
            vec![notif("CI", "all green")]
        );
    }

    #[test]
    fn osc777_body_may_contain_semicolons() {
        assert_eq!(
            observe_whole(b"\x1b]777;notify;Deploy;step 1;step 2 done\x07"),
            vec![notif("Deploy", "step 1;step 2 done")]
        );
    }

    #[test]
    fn osc777_non_notify_subcommand_ignored() {
        assert_eq!(
            notifications_only(&observe_whole(b"\x1b]777;precmd;something\x07")),
            vec![]
        );
    }

    #[test]
    fn osc9_empty_body_ignored() {
        assert_eq!(notifications_only(&observe_whole(b"\x1b]9;\x07")), vec![]);
    }

    #[test]
    fn osc9_progress_bar_subtype_is_not_a_notification() {
        assert_eq!(
            notifications_only(&observe_whole(b"\x1b]9;4;1;50\x07")),
            vec![]
        );
        assert_eq!(notifications_only(&observe_whole(b"\x1b]9;4\x07")), vec![]);
        // A free-text body that only STARTS with '4' (not the `4;` subtype) still fires.
        assert_eq!(
            observe_whole(b"\x1b]9;42 tests passed\x07"),
            vec![notif("", "42 tests passed")]
        );
    }

    #[test]
    fn notification_split_across_chunks_equivalence() {
        let raw = "\u{1b}]777;notify;Title;Body text 🚀\u{07}".as_bytes();
        let whole = observe_whole(raw);
        for size in 1..=raw.len() {
            assert_eq!(
                observe_chunked(raw, size),
                whole,
                "diverged at chunk size {size}"
            );
        }
    }

    #[test]
    fn string_sequence_swallows_embedded_notification() {
        let dcs_spoof = b"\x1bP\x1b]9;spoofed\x07\x1b\\";
        assert_eq!(notifications_only(&observe_whole(dcs_spoof)), vec![]);
        assert_eq!(observe_whole(b"\x1b]9;real\x07"), vec![notif("", "real")]);
    }

    #[test]
    fn string_sequences_swallow_embedded_command_status() {
        let mut s = HostOutputSniffer::new();
        let dcs_spoof = b"\x1bP\x1b]133;C\x07\x1b\\";
        assert_eq!(s.observe(dcs_spoof, 0), vec![]);
        assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
    }

    // =====================================================================================
    // Ported from HostOutputSnifferCharacterizationTests — expected-value asserts
    // =====================================================================================

    #[test]
    fn malformed_ps_payloads() {
        assert_eq!(observe_whole(b"\x1b]133\x07"), vec![]); // bare 133, no ';'
        assert_eq!(observe_whole(b"\x1b];x\x07"), vec![]); // leading-empty Ps
        assert_eq!(observe_whole(b"\x1b]1330;C\x07"), vec![]); // Ps is "1330", not "133"
    }

    #[test]
    fn first_prompt_phantom_d_is_ignored() {
        assert_eq!(observe_whole(b"\x1b]133;D;0\x07"), vec![]);
        // A D after the phantom + a real C measures from the REAL C (same call → 0ms).
        let cycle = b"\x1b]133;D;0\x07\x1b]133;C\x07\x1b]133;D;7\x07";
        assert_eq!(observe_whole(cycle), vec![running(), idle(Some(7), 0)]);
    }

    #[test]
    fn stray_esc_ends_osc_then_next_osc_parses() {
        // Title flavor.
        let titles = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
        assert_eq!(observe_whole(&titles), vec![title("abc"), title("real")]);

        // Cmd flavor: stray ESC fires C, the following D emits idle (same call → 0ms).
        let marks = cat(&[b"\x1b]133;C", b"\x1b]133;D;0\x07"]);
        assert_eq!(observe_whole(&marks), vec![running(), idle(Some(0), 0)]);

        // Cross flavor: a title OSC ended by the stray ESC of a 133 mark.
        let cross = cat(&[b"\x1b]2;t", b"\x1b]133;C\x07"]);
        assert_eq!(observe_whole(&cross), vec![title("t"), running()]);
    }

    #[test]
    fn interleaved_cross_type_stream() {
        let stream = "welcome\n".to_owned()
            + "\u{1b}]0;Claude Code\u{07}"
            + "\u{1b}]133;A\u{07}"
            + "$ make\n"
            + "\u{1b}]133;C\u{07}"
            + "\u{07}building\u{1b}[2J"
            + "\u{1b}]2;make — repo\u{1b}\\"
            + "\u{1b}]133;D;2\u{07}"
            + "\u{07}";
        let bytes = stream.as_bytes();
        let expected = vec![
            title("Claude Code"),
            running(),
            WireMessage::Bell,
            title("make — repo"),
            idle(Some(2), 0),
            WireMessage::Bell,
        ];
        assert_eq!(observe_whole(bytes), expected);
    }

    #[test]
    fn title_dedup_across_an_interleaved_mark() {
        let bytes = cat(&[
            b"\x1b]0;same\x07",
            b"\x1b]2;same\x07", // deduped
            b"\x1b]133;C\x07",  // a mark between the dupes must not break dedup
            b"\x1b]0;same\x07", // still deduped
            b"\x1b]0;other\x07",
        ]);
        assert_eq!(
            observe_whole(&bytes),
            vec![title("same"), running(), title("other")]
        );
    }

    #[test]
    fn double_esc_sequences() {
        // ESC ESC ]2;x BEL — the second ESC re-classifies; the OSC still parses.
        assert_eq!(observe_whole(b"\x1b\x1b]2;x\x07"), vec![title("x")]);
        // ESC ]2;x ESC ESC \ — oscEscape sees a second ESC: OSC ends, `\` is a lone final.
        assert_eq!(observe_whole(b"\x1b]2;x\x1b\x1b\\"), vec![title("x")]);
        // Same shape through the 133 path.
        assert_eq!(observe_whole(b"\x1b]133;C\x1b\x1b\\"), vec![running()]);
    }

    // =====================================================================================
    // Cap-boundary characterization (OSC_CAP 4096 / CMD_OSC_CAP 256)
    // =====================================================================================

    #[test]
    fn title_payload_length_boundaries() {
        for length in [255usize, 256, 257, 4095, 4096, 4097] {
            let pad = vec![b'x'; length - 2]; // "0;" + pad == `length` bytes
            for term in [vec![BEL], cat(&[&[ESC], b"\\"])] {
                let bytes = cat(&[b"\x1b]0;", &pad, &term]);
                let expected = if length <= 4096 {
                    vec![title(std::str::from_utf8(&pad).unwrap())]
                } else {
                    vec![]
                };
                assert_eq!(observe_whole(&bytes), expected, "title L={length}");
            }
        }
    }

    #[test]
    fn command_payload_length_boundaries() {
        let c_prefix = b"\x1b]133;C\x07"; // → running
        for length in [255usize, 256, 257, 4095, 4096, 4097] {
            let pad = vec![b'x'; length - 8]; // "133;D;0;" + pad == `length`
            for term in [vec![BEL], cat(&[&[ESC], b"\\"])] {
                let bytes = cat(&[c_prefix, b"\x1b]133;D;0;", &pad, &term]);
                let mut expected = vec![running()];
                if length <= 256 {
                    expected.push(idle(Some(0), 0));
                }
                assert_eq!(observe_whole(&bytes), expected, "cmd L={length}");
            }
        }
    }

    // =====================================================================================
    // Permanent chunking-invariance oracle (whole == byte-at-a-time == every chunk size)
    // =====================================================================================

    #[test]
    fn chunking_invariance_oracle() {
        let esc = "\u{1b}";
        let bel = "\u{07}";
        let st = "\u{1b}\\";
        let streams: Vec<String> = vec![
            "plain text, no sequences at all".to_owned(),
            format!("{bel}a{bel}{bel}b"),
            format!("{esc}]0;one{bel}{esc}]2;one{bel}{esc}]0;two{st}{esc}]2;{bel}{esc}]0;a;b;c{bel}"),
            format!("{esc}]133;D;0{bel}{esc}]133;A{bel}{esc}]133;C{bel}out{esc}]133;D;1{st}"),
            format!("{esc}P{esc}]2;spoof{bel}{esc}X9{bel}{esc}_{esc}]133;C{bel}{esc}]2;real{bel}{esc}]133;C{bel}"),
            format!("{esc}]0;abc{esc}]2;next{bel}{esc}{esc}]0;dbl{bel}"),
            format!("{esc}]2;{}{bel}{bel}{esc}]0;after{bel}", "x".repeat(5000)),
            format!("{esc}]133;{}{st}{esc}]133;C{bel}", "y".repeat(700)),
            format!("tail{esc}]0;par"),
        ];
        for stream in &streams {
            let raw = stream.as_bytes();
            let whole = observe_whole(raw);
            // Byte-at-a-time on a single machine, fixed clock (no advance → 0ms durations).
            let mut per_byte = HostOutputSniffer::new();
            let mut concatenated = Vec::new();
            for &b in raw {
                concatenated.extend(per_byte.observe(&[b], 0));
            }
            assert_eq!(whole, concatenated, "byte-at-a-time diverged on {stream:?}");
            for size in [2usize, 3, 7, 64] {
                assert_eq!(
                    observe_chunked(raw, size),
                    whole,
                    "chunk size {size} on {stream:?}"
                );
            }
        }
    }

    // =====================================================================================
    // Added edge cases (beyond the Swift suite)
    // =====================================================================================

    #[test]
    fn duration_saturates_on_non_monotonic_clock() {
        // D's now_ms is BEFORE C's → saturating_sub yields 0 (Swift's `guard ms > 0`).
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 1000);
        assert_eq!(s.observe(&osc133("D;0"), 500), vec![idle(Some(0), 0)]);
    }

    #[test]
    fn duration_clamps_to_u32_max() {
        // A huge gap clamps to u32::MAX, exactly like Swift's `ms >= UInt32.max` branch.
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(
            s.observe(&osc133("D;0"), u64::MAX),
            vec![idle(Some(0), u32::MAX)]
        );
    }

    #[test]
    fn duration_just_below_and_at_u32_max_boundary() {
        // Exactly u32::MAX ms → clamped to u32::MAX (Swift's `>=`).
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(
            s.observe(&osc133("D;0"), u64::from(u32::MAX)),
            vec![idle(Some(0), u32::MAX)]
        );
        // One below → passes through unclamped.
        let mut s2 = HostOutputSniffer::new();
        let _ = s2.observe(&osc133("C"), 0);
        assert_eq!(
            s2.observe(&osc133("D;0"), u64::from(u32::MAX) - 1),
            vec![idle(Some(0), u32::MAX - 1)]
        );
    }

    #[test]
    fn negative_exit_code_parsed() {
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(s.observe(&osc133("D;-1"), 0), vec![idle(Some(-1), 0)]);
    }

    #[test]
    fn exit_code_truncated_to_i32() {
        // 2^32 truncates to 0 (Swift Int32(truncatingIfNeeded: 4294967296) == 0).
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(
            s.observe(&osc133("D;4294967296"), 0),
            vec![idle(Some(0), 0)]
        );
    }

    #[test]
    fn exit_code_unparsable_yields_none() {
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(s.observe(&osc133("D;abc"), 0), vec![idle(None, 0)]);
    }

    #[test]
    fn exit_code_equals_prefix_tolerated() {
        // `=5` → first non-empty `=`-segment is "5".
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(s.observe(&osc133("D;=5"), 0), vec![idle(Some(5), 0)]);
    }

    #[test]
    fn exit_code_lone_equals_yields_none() {
        // `=` → no non-empty segment, falls back to "=", which is not an Int → None.
        let mut s = HostOutputSniffer::new();
        let _ = s.observe(&osc133("C"), 0);
        assert_eq!(s.observe(&osc133("D;="), 0), vec![idle(None, 0)]);
    }

    #[test]
    fn invalid_utf8_title_decodes_to_empty_string() {
        // Valid Ps "0", invalid title bytes → String(bytes:encoding:.utf8) ?? "" → "".
        let bytes = cat(&[b"\x1b]0;", &[0xFF, 0xFE], &[BEL]]);
        assert_eq!(observe_whole(&bytes), vec![title("")]);
    }

    #[test]
    fn invalid_utf8_ps_is_ignored() {
        // Invalid Ps bytes → ps decodes to "" → default branch → nothing.
        let bytes = cat(&[b"\x1b]", &[0xFF], b";x", &[BEL]]);
        assert_eq!(observe_whole(&bytes), vec![]);
    }

    #[test]
    fn osc777_notify_title_only_no_body() {
        assert_eq!(
            observe_whole(b"\x1b]777;notify;OnlyTitle\x07"),
            vec![notif("OnlyTitle", "")]
        );
    }

    #[test]
    fn osc777_notify_empty_title_and_body_ignored() {
        assert_eq!(
            notifications_only(&observe_whole(b"\x1b]777;notify;\x07")),
            vec![]
        );
    }

    #[test]
    fn osc777_notify_empty_title_with_body_emits() {
        assert_eq!(
            observe_whole(b"\x1b]777;notify;;body\x07"),
            vec![notif("", "body")]
        );
    }

    #[test]
    fn determinism_two_instances_same_output() {
        let stream = b"\x1b]0;t\x07\x07\x1b]133;C\x07\x1b]9;done\x07";
        assert_eq!(observe_whole(stream), observe_whole(stream));
    }

    #[test]
    fn default_equals_new() {
        let stream = b"\x1b]0;x\x07";
        assert_eq!(
            HostOutputSniffer::default().observe(stream, 0),
            HostOutputSniffer::new().observe(stream, 0)
        );
    }

    #[test]
    fn empty_chunk_emits_nothing_and_preserves_state() {
        let mut s = HostOutputSniffer::new();
        assert_eq!(s.observe(b"\x1b]0;par", 0), vec![]);
        assert_eq!(s.observe(&[], 0), vec![]); // empty chunk is a no-op
        assert_eq!(s.observe(b"t\x07", 0), vec![title("part")]);
    }
}
