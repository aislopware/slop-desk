//! Turning key names into the bytes to feed a PTY.
//!
//! The one send-keys primitive behind launch presets, session templates, re-running a block, a text
//! drop and the CLI verb. Literal runs become their UTF-8 bytes; a recognised `<Token>` becomes its
//! control sequence.
//!
//! ## One vocabulary, two grammars
//!
//! Two spellings reach the same table. [`encode`] scans TEXT for `<Token>` markers, which is what a
//! preset or a text drop carries; [`key_token`] answers ONE name, which is what the agent-control
//! `write` verb's comma-separated `--key C-c,Enter` list is made of. They are two ways of naming a
//! key, not two vocabularies — the Swift `write` verb used to carry its own table, and the two had
//! already drifted (its `C-?` was DEL where this one folded to `C-_`, its `C-Space` was NUL where
//! this one refused the name, and its function and page keys had no spelling here at all). The
//! union is what a `<Token>` means now, so a preset can say `<F5>` too.
//!
//! ## An unrecognised marker is literal
//!
//! `<` is ordinary text far more often than it is a token open — `a < b`, `printf "<3"`, a heredoc,
//! any shell redirect. So anything that does not parse as a known token is emitted VERBATIM,
//! including the angle bracket. A parser that swallowed or escaped it would corrupt ordinary
//! commands, which is a much worse failure than not recognising a token.
//!
//! The closing bracket is searched for within a short window, because every token name is short: a
//! lone `<` in a long line then costs a bounded scan rather than one proportional to the line.
//!
//! ## Case
//!
//! Token names are matched case-insensitively, which for a meta chord means `<M-A>` sends the same
//! bytes as `<M-a>` — the folded name is what the chord reads its character from. That is the
//! behaviour the Swift original had and the presets on disk were written against, so it is
//! preserved deliberately rather than quietly corrected.

/// The escape byte every cursor and meta sequence opens with.
const ESC: u8 = 0x1B;

/// How far past a `<` the closing `>` is looked for. The longest token name is nine characters, so
/// this leaves slack without letting an unmatched bracket scan a whole line.
const CLOSE_WINDOW: usize = 12;

/// The bytes for text with control tokens in it.
#[must_use]
pub fn encode(text: &str) -> Vec<u8> {
    let scalars: Vec<char> = text.chars().collect();
    let mut out = Vec::with_capacity(text.len());
    let mut index = 0;
    while let Some(scalar) = scalars.get(index) {
        if *scalar != '<' {
            let mut buffer = [0_u8; 4];
            out.extend_from_slice(scalar.encode_utf8(&mut buffer).as_bytes());
            index += 1;
            continue;
        }
        let name = find_close(&scalars, index + 1)
            .and_then(|close| scalars.get(index + 1..close).map(|raw| (close, raw)));
        if let Some((close, raw)) = name
            && let Some(bytes) = token(&raw.iter().collect::<String>())
        {
            out.extend_from_slice(&bytes);
            index = close + 1;
            continue;
        }
        out.push(b'<');
        index += 1;
    }
    out
}

/// The index of the next `>` within the window, or `None`.
///
/// A second `<` inside the window ends the search: the first bracket cannot have been a token open
/// if another one arrives before its close, so `a < b < c` stays literal.
fn find_close(scalars: &[char], from: usize) -> Option<usize> {
    let limit = scalars.len().min(from.saturating_add(CLOSE_WINDOW));
    let window = scalars.get(from..limit)?;
    for (offset, scalar) in window.iter().enumerate() {
        match *scalar {
            '>' => return Some(from + offset),
            '<' => return None,
            _ => {},
        }
    }
    None
}

/// The bytes for one key name, or `None` when it names no key.
///
/// The whole vocabulary, and the entry point for the comma-separated `--key` grammar. A name is
/// matched case-insensitively; a `C-`/`M-`/`A-` chord folds its character the way tmux does.
#[must_use]
pub fn key_token(raw: &str) -> Option<Vec<u8>> {
    let name = raw.to_lowercase();
    if let Some(bytes) = named(&name) {
        return Some(bytes);
    }
    let (prefix, rest) = name.split_once('-')?;
    match prefix {
        "c" => control_chord(rest),
        "m" | "a" => meta_chord(rest),
        _ => None,
    }
}

/// The bytes for a token name without its brackets, or `None` when it is not one.
fn token(raw: &str) -> Option<Vec<u8>> {
    key_token(raw)
}

/// A CSI sequence: escape, `[`, then the suffix that names the key.
fn csi(suffix: &str) -> Vec<u8> {
    let mut bytes = vec![ESC, b'['];
    bytes.extend_from_slice(suffix.as_bytes());
    bytes
}

/// The bytes for a plain (chordless) key name, already folded to lower case.
///
/// Cursor and editing keys take their CSI ("normal cursor-key mode") forms. A full-screen app in
/// DECCKM application mode expects SS3, but every line editor and most terminal apps accept the CSI
/// form too, and nothing here keeps a terminal's mode to pick from. F1 to F4 are the exception:
/// their SS3 forms are what every terminfo entry carries, so there is no CSI spelling to prefer.
fn named(name: &str) -> Option<Vec<u8>> {
    let bytes = match name {
        "enter" | "cr" | "return" => vec![0x0D],
        "nl" | "lf" | "newline" => vec![0x0A],
        "tab" => vec![0x09],
        "esc" | "escape" => vec![ESC],
        "space" => vec![0x20],
        "bs" | "bspace" | "backspace" => vec![0x7F],
        "del" | "dc" | "delete" => csi("3~"),
        "up" => csi("A"),
        "down" => csi("B"),
        "right" => csi("C"),
        "left" => csi("D"),
        "home" => csi("H"),
        "end" => csi("F"),
        "ic" | "insert" => csi("2~"),
        "ppage" | "pgup" | "pageup" => csi("5~"),
        "npage" | "pgdn" | "pagedown" => csi("6~"),
        "f1" => vec![ESC, b'O', b'P'],
        "f2" => vec![ESC, b'O', b'Q'],
        "f3" => vec![ESC, b'O', b'R'],
        "f4" => vec![ESC, b'O', b'S'],
        "f5" => csi("15~"),
        "f6" => csi("17~"),
        "f7" => csi("18~"),
        "f8" => csi("19~"),
        "f9" => csi("20~"),
        "f10" => csi("21~"),
        "f11" => csi("23~"),
        "f12" => csi("24~"),
        _ => return None,
    };
    Some(bytes)
}

/// A control chord's byte: the ASCII control fold.
///
/// The letters fold to upper case first so `a`..`z` land on 0x01..0x1A, and the symbols `@ [ \ ] ^
/// _` already sit one row above their control byte, so the same mask carries them. Two names are
/// not that arithmetic and are spelled out: `space` is NUL, and `?` is DEL — which is what a
/// terminal means by it, where the mask would have given it C-_'s byte.
fn control_chord(rest: &str) -> Option<Vec<u8>> {
    if rest == "space" {
        return Some(vec![0x00]);
    }
    if rest == "?" {
        return Some(vec![0x7F]);
    }
    let mut characters = rest.chars();
    let (Some(last), None) = (characters.next(), characters.next()) else {
        return None;
    };
    if !last.is_ascii() {
        return None;
    }
    let byte = u8::try_from(u32::from(last)).ok()?;
    Some(vec![byte.to_ascii_uppercase() & 0x1F])
}

/// A meta chord: escape, then whatever the rest of the name resolves to.
///
/// The remainder is itself a key name, so `M-Enter` is escape then carriage return, not a refusal;
/// anything that is not a name falls back to its single literal character.
fn meta_chord(rest: &str) -> Option<Vec<u8>> {
    let mut bytes = vec![ESC];
    if let Some(named) = key_token(rest) {
        bytes.extend_from_slice(&named);
        return Some(bytes);
    }
    let mut characters = rest.chars();
    let (Some(last), None) = (characters.next(), characters.next()) else {
        return None;
    };
    let mut buffer = [0_u8; 4];
    bytes.extend_from_slice(last.encode_utf8(&mut buffer).as_bytes());
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::{ESC, encode, key_token};

    #[test]
    fn plain_text_passes_through_as_its_own_bytes() {
        assert_eq!(encode("ls -la"), b"ls -la".to_vec());
    }

    #[test]
    fn a_command_and_its_newline_is_the_common_case() {
        assert_eq!(encode("make test<Enter>"), b"make test\r".to_vec());
    }

    #[test]
    fn token_names_are_case_insensitive() {
        assert_eq!(encode("<enter>"), encode("<ENTER>"));
        assert_eq!(encode("<Esc>"), vec![ESC]);
    }

    #[test]
    fn every_alias_of_a_token_agrees() {
        assert_eq!(encode("<cr>"), encode("<return>"));
        assert_eq!(encode("<nl>"), encode("<lf>"));
        assert_eq!(encode("<bs>"), encode("<backspace>"));
    }

    #[test]
    fn a_control_chord_masks_to_its_control_byte() {
        assert_eq!(encode("<C-c>"), vec![0x03]);
        assert_eq!(encode("<C-C>"), vec![0x03], "the fold makes the case irrelevant");
        assert_eq!(encode("<C-a>"), vec![0x01]);
        assert_eq!(
            encode("<C-[>"),
            vec![ESC],
            "the symbols carry through the same mask"
        );
    }

    #[test]
    fn a_meta_chord_is_escape_then_the_character() {
        assert_eq!(encode("<M-b>"), vec![ESC, b'b']);
    }

    #[test]
    fn the_cursor_keys_are_their_escape_sequences() {
        assert_eq!(encode("<Up>"), vec![ESC, b'[', b'A']);
        assert_eq!(encode("<Delete>"), vec![ESC, b'[', b'3', b'~']);
    }

    #[test]
    fn an_unrecognised_token_is_emitted_literally() {
        assert_eq!(
            encode("<Nope>"),
            b"<Nope>".to_vec(),
            "swallowing it would silently drop text the person typed",
        );
    }

    #[test]
    fn ordinary_text_containing_an_angle_bracket_is_never_mangled() {
        assert_eq!(encode("if a < b"), b"if a < b".to_vec());
        assert_eq!(encode("printf \"<3\""), b"printf \"<3\"".to_vec());
        assert_eq!(encode("cat < in > out"), b"cat < in > out".to_vec());
    }

    #[test]
    fn a_bracket_with_no_close_in_the_window_stays_literal() {
        let long = "<this-name-is-far-too-long-to-be-a-token>";
        assert_eq!(encode(long), long.as_bytes().to_vec());
    }

    #[test]
    fn a_second_bracket_ends_the_search_for_a_close() {
        assert_eq!(encode("<a<Enter>"), b"<a\r".to_vec());
    }

    #[test]
    fn a_token_in_the_middle_splits_the_literal_runs_around_it() {
        assert_eq!(encode("git<Space>status<Enter>"), b"git status\r".to_vec());
    }

    #[test]
    fn a_non_ascii_chord_character_is_not_a_token() {
        assert_eq!(encode("<C-é>"), "<C-é>".as_bytes().to_vec());
    }

    #[test]
    fn non_ascii_text_keeps_its_utf8() {
        assert_eq!(encode("echo é<Enter>"), "echo é\r".as_bytes().to_vec());
    }

    #[test]
    fn an_empty_marker_is_literal() {
        assert_eq!(encode("<>"), b"<>".to_vec());
    }

    #[test]
    fn the_two_grammars_read_one_table() {
        assert_eq!(key_token("Enter"), Some(vec![0x0D]));
        assert_eq!(key_token("enter"), Some(vec![0x0D]), "a name folds its case");
        assert_eq!(
            key_token("C-C"),
            Some(vec![0x03]),
            "and so does a chord, the way tmux does"
        );
        assert_eq!(
            encode("<F5>"),
            key_token("F5").unwrap_or_default(),
            "a marker and a bare name answer the same bytes"
        );
        assert_eq!(key_token("Frobnicate"), None);
        assert_eq!(key_token("C-"), None);
        assert_eq!(key_token(""), None);
    }

    #[test]
    fn the_two_names_the_control_fold_gets_wrong_are_spelled_out() {
        assert_eq!(
            key_token("C-Space"),
            Some(vec![0x00]),
            "the fold would have refused the name"
        );
        assert_eq!(
            key_token("C-?"),
            Some(vec![0x7F]),
            "and would have given it C-_'s byte rather than DEL"
        );
        assert_eq!(
            key_token("C-_"),
            Some(vec![0x1F]),
            "which is still what C-_ means"
        );
    }

    #[test]
    fn a_meta_chord_resolves_a_name_before_it_falls_back_to_a_character() {
        assert_eq!(key_token("M-x"), Some(vec![ESC, b'x']));
        assert_eq!(key_token("A-x"), Some(vec![ESC, b'x']), "alt is the same chord");
        assert_eq!(key_token("M-Enter"), Some(vec![ESC, 0x0D]));
        assert_eq!(key_token("M-xy"), None, "and two characters name nothing");
    }

    #[test]
    fn the_function_and_paging_keys_have_the_forms_terminfo_carries() {
        assert_eq!(key_token("F1"), Some(vec![ESC, b'O', b'P']), "F1 to F4 are SS3");
        assert_eq!(key_token("F4"), Some(vec![ESC, b'O', b'S']));
        assert_eq!(
            key_token("F5"),
            Some(vec![ESC, b'[', b'1', b'5', b'~']),
            "and the rest are CSI"
        );
        assert_eq!(key_token("F12"), Some(vec![ESC, b'[', b'2', b'4', b'~']));
        assert_eq!(
            key_token("PageUp"),
            key_token("ppage"),
            "tmux's spelling is the same key"
        );
        assert_eq!(key_token("PgDn"), Some(vec![ESC, b'[', b'6', b'~']));
        assert_eq!(key_token("Insert"), key_token("ic"));
    }
}
