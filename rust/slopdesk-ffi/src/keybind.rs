//! The grammar for one `keybind` line of the user's config.
//!
//! A parsed binding is a fixed record plus three runs of variable-length bytes — the base key, the
//! payload (the resolved bytes of a literal action, or the id of a named one) and the argument — so
//! it crosses as a record whose runs are `(offset, length)` pairs into ONE arena the caller lends.
//! The record is asked for twice, as every arena door here is: the first call with no buffer
//! answers how much room the runs need, the second fills it. A parse that did not fit is not a
//! parse, and the record comes back invalid rather than half-written.
//!
//! The action's kind is a code rather than a tagged union, because the near side already has an
//! enum and would only unwrap one to build the other.

use core::ffi::c_uchar;

use slopdesk_terminal::keybind::{
    Action, Chord, canonical_base_key, canonical_chord, glyph_chord, parse_line,
};

use crate::{TextArena, borrow, deliver};

/// `text:<s>` — the payload run is the literal bytes.
pub const SLOPDESK_KEYBIND_TEXT: u32 = 0;
/// `csi:<p>` — the payload run is `ESC [` followed by the payload's bytes.
pub const SLOPDESK_KEYBIND_CSI: u32 = 1;
/// `esc:<p>` — the payload run is `ESC` followed by the payload's bytes.
pub const SLOPDESK_KEYBIND_ESC: u32 = 2;
/// A named registry action — the payload run is its id, and the argument run may carry an argument.
pub const SLOPDESK_KEYBIND_NAMED: u32 = 3;
/// `unbind:<chord>` — neither run carries anything; the chord is the whole content.
pub const SLOPDESK_KEYBIND_UNBIND: u32 = 4;

/// One run of bytes inside the arena.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskKeybindRun {
    /// Where the run starts in the arena.
    pub offset: u32,
    /// How many bytes it is.
    pub length: u32,
}

/// One parsed binding line.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskKeybind {
    /// The chord's base key, lowercased.
    pub key: SlopDeskKeybindRun,
    /// The action's bytes, or a named action's id. Empty for an unbind.
    pub payload: SlopDeskKeybindRun,
    /// A named action's argument, meaningful only when `has_arg`.
    pub arg: SlopDeskKeybindRun,
    /// Which action this is — one of the `SLOPDESK_KEYBIND_*` codes.
    pub kind: u32,
    /// How many bytes the three runs need in total, so the caller can size its arena.
    pub arena_len: usize,
    /// Whether a named action carried an argument. An absent argument is a FLAG, not an empty run:
    /// `goto_tab:` is refused by the grammar, so "no argument" and "an empty one" are different
    /// answers and only one of them can arise.
    pub has_arg: bool,
    /// Whether ⌘ is held.
    pub command: bool,
    /// Whether ⇧ is held.
    pub shift: bool,
    /// Whether ⌥ is held.
    pub option: bool,
    /// Whether ⌃ is held.
    pub control: bool,
    /// Whether the line parsed at all. A false here is the grammar's "drop this line".
    pub valid: bool,
}

/// Parses one binding line, writing its three runs into the lent arena.
///
/// Call once with a null arena to learn `arena_len`, then again with that much room. A record whose
/// runs did not fit comes back invalid: acting on a half-written payload would put bytes on a pane
/// that the user never wrote.
///
/// # Safety
/// The input pair must be live for the call, and `arena` must be null or writable for `arena_cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_keybind_parse_line(
    line: *const c_uchar,
    line_len: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskKeybind {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(line, line_len) }).into_owned();
    let Some(binding) = parse_line(&text) else {
        return SlopDeskKeybind::default();
    };
    let mut pool = TextArena::default();
    let mut record = SlopDeskKeybind {
        key: run(pool.intern(binding.chord.key.as_bytes())),
        kind: kind_of(&binding.action),
        command: binding.chord.command,
        shift: binding.chord.shift,
        option: binding.chord.option,
        control: binding.chord.control,
        valid: true,
        ..SlopDeskKeybind::default()
    };
    match &binding.action {
        Action::Text(bytes) | Action::Csi(bytes) | Action::Esc(bytes) => {
            record.payload = run(pool.intern(bytes));
        },
        Action::Named { id, arg } => {
            record.payload = run(pool.intern(id.as_bytes()));
            if let Some(argument) = arg {
                record.arg = run(pool.intern(argument.as_bytes()));
                record.has_arg = true;
            }
        },
        Action::Unbind => {},
    }
    record.arena_len = pool.0.len();
    if arena.is_null() || arena_cap < pool.0.len() {
        // The measuring call, or one whose arena is too small. Either way the runs were not
        // written, so the record must not claim they were — `arena_len` and `kind` still answer the
        // question the measuring call asked.
        return SlopDeskKeybind {
            valid: false,
            ..record
        };
    }
    // SAFETY: non-null and, by the caller's obligation, writable for `arena_cap` — which was just
    // checked to be at least the pool's length.
    unsafe { core::ptr::copy_nonoverlapping(pool.0.as_ptr(), arena, pool.0.len()) };
    record
}

/// Whether a config value is a binding this grammar honours — the question the CLI's file validator
/// asks of every line it reads.
///
/// # Safety
/// The input pair must be live for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_keybind_is_valid(line: *const c_uchar, line_len: usize) -> bool {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(line, line_len) }).into_owned();
    parse_line(&text).is_some()
}

/// The ONE spelling a base key is stored under — the fold that decides which chord a keystroke
/// finds.
///
/// It is the same table that decides which spellings this grammar ACCEPTS, and that is why it
/// crosses: an alias the parser takes but the near side does not fold binds under a key no
/// keystroke produces, so the binding is accepted, persisted, and never fires.
///
/// # Safety
/// The input pair must be live for the call, and `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_keybind_canonical_key(
    key: *const c_uchar,
    key_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(key, key_len) }).into_owned();
    let folded = canonical_base_key(&text);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(folded.as_bytes(), out, cap) }
}

/// The chord written back out in the one order two equal chords share — the identity a conflict is
/// detected by, and the text a config file would spell the same chord with.
///
/// # Safety
/// The input pair must be live for the call, and `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_keybind_canonical_chord(
    key: *const c_uchar,
    key_len: usize,
    command: bool,
    shift: bool,
    option: bool,
    control: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(key, key_len) }).into_owned();
    let written = canonical_chord(&Chord {
        key: text,
        command,
        shift,
        option,
        control,
    });
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(written.as_bytes(), out, cap) }
}

/// The chord as a human reads it — the modifier glyphs in the platform's order, then the key.
///
/// The same key text [`slopdesk_keybind_canonical_chord`] takes, because it is the same chord
/// written for a different reader: one goes in a config file, this one in a menu row.
///
/// # Safety
/// The input pair must be live for the call, and `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_keybind_glyph(
    key: *const c_uchar,
    key_len: usize,
    command: bool,
    shift: bool,
    option: bool,
    control: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(key, key_len) }).into_owned();
    let written = glyph_chord(&Chord {
        key: text,
        command,
        shift,
        option,
        control,
    });
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(written.as_bytes(), out, cap) }
}

/// The crossing form of an interned run.
const fn run(interned: (u32, u32)) -> SlopDeskKeybindRun {
    SlopDeskKeybindRun {
        offset: interned.0,
        length: interned.1,
    }
}

/// The code one action carries.
const fn kind_of(action: &Action) -> u32 {
    match action {
        Action::Text(_) => SLOPDESK_KEYBIND_TEXT,
        Action::Csi(_) => SLOPDESK_KEYBIND_CSI,
        Action::Esc(_) => SLOPDESK_KEYBIND_ESC,
        Action::Named { .. } => SLOPDESK_KEYBIND_NAMED,
        Action::Unbind => SLOPDESK_KEYBIND_UNBIND,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        clippy::indexing_slicing,
        clippy::expect_used,
        reason = "the tests call the C entry points, a run the door just interned is inside the arena it \
                  just sized, and a panic in a test is the failure report"
    )]

    use super::{
        SLOPDESK_KEYBIND_NAMED, SLOPDESK_KEYBIND_TEXT, SLOPDESK_KEYBIND_UNBIND, SlopDeskKeybind,
        slopdesk_keybind_is_valid, slopdesk_keybind_parse_line,
    };

    /// Parses through the door the way the near side does: measure, then fill.
    fn parsed(line: &str) -> Option<(SlopDeskKeybind, Vec<u8>)> {
        let bytes = line.as_bytes();
        // SAFETY: the slice is live for both calls and the arena is this function's own.
        let measured =
            unsafe { slopdesk_keybind_parse_line(bytes.as_ptr(), bytes.len(), core::ptr::null_mut(), 0) };
        let mut arena = vec![0u8; measured.arena_len];
        let record = unsafe {
            slopdesk_keybind_parse_line(bytes.as_ptr(), bytes.len(), arena.as_mut_ptr(), arena.len())
        };
        record.valid.then_some((record, arena))
    }

    fn text_of(arena: &[u8], run: super::SlopDeskKeybindRun) -> Vec<u8> {
        let start = run.offset as usize;
        arena[start..start + run.length as usize].to_vec()
    }

    #[test]
    fn a_literal_action_crosses_with_its_bytes_already_resolved() {
        let (record, arena) = parsed("cmd+shift+h:csi:17~").expect("a binding");
        assert_eq!(text_of(&arena, record.key), b"h");
        assert!(record.command && record.shift && !record.option && !record.control);
        assert_eq!(text_of(&arena, record.payload), b"\x1b[17~");
    }

    #[test]
    fn a_named_action_carries_its_argument_behind_a_flag() {
        let (record, arena) = parsed("cmd+1:goto_tab:1").expect("a binding");
        assert_eq!(record.kind, SLOPDESK_KEYBIND_NAMED);
        assert_eq!(text_of(&arena, record.payload), b"goto_tab");
        assert!(record.has_arg);
        assert_eq!(text_of(&arena, record.arg), b"1");
        let (bare, bare_arena) = parsed("cmd+t:new_tab").expect("a binding");
        assert!(!bare.has_arg);
        assert_eq!(text_of(&bare_arena, bare.payload), b"new_tab");
    }

    #[test]
    fn an_unbind_carries_nothing_but_its_chord() {
        let (record, arena) = parsed("unbind:cmd+q").expect("a binding");
        assert_eq!(record.kind, SLOPDESK_KEYBIND_UNBIND);
        assert_eq!(text_of(&arena, record.key), b"q");
        assert_eq!(record.payload.length, 0);
    }

    #[test]
    fn a_line_that_did_not_fit_is_not_a_parse() {
        let line = b"cmd+h:text:hello";
        // SAFETY: the slice is live and the arena is deliberately one byte short of the runs.
        let measured =
            unsafe { slopdesk_keybind_parse_line(line.as_ptr(), line.len(), core::ptr::null_mut(), 0) };
        assert!(measured.arena_len > 1, "the runs need room");
        assert!(!measured.valid, "the measuring call wrote nothing");
        let mut cramped = vec![0u8; measured.arena_len - 1];
        let record = unsafe {
            slopdesk_keybind_parse_line(line.as_ptr(), line.len(), cramped.as_mut_ptr(), cramped.len())
        };
        assert!(!record.valid, "a half-written payload is not a binding");
        assert_eq!(
            record.kind, SLOPDESK_KEYBIND_TEXT,
            "but it still says what it would be"
        );
    }

    #[test]
    fn a_malformed_line_is_dropped_at_the_door() {
        assert!(parsed("badmod+h:text:hi").is_none());
        assert!(parsed("").is_none());
        // SAFETY: both slices are live for their calls.
        unsafe {
            assert!(slopdesk_keybind_is_valid(
                c"cmd+t:new_tab".to_bytes().as_ptr(),
                13
            ));
            assert!(!slopdesk_keybind_is_valid(
                c"font-size = 14".to_bytes().as_ptr(),
                14
            ));
            assert!(!slopdesk_keybind_is_valid(core::ptr::null(), 0));
        }
    }
}
