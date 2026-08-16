//! One shell word from any text.
//!
//! Every place that types a path into a live `/bin/sh` needs this: a `cd` a jump emits, a
//! template's opening line, the editor shim's argument, a paste the terminal has to keep as one
//! word, the CLI installer's escalated copy. A path with a space in it becomes several arguments
//! without it, and one with a quote in it becomes a syntax error or worse.
//!
//! ## Why it is here rather than at each caller
//!
//! It was written EIGHT times — seven in Swift and once, privately, in this crate's own template
//! emitter. One of the seven carried a doc comment calling itself the single source of truth while
//! four of the others sat beside it, and another justified its copy by not wanting to widen a
//! daemon's dependency graph for four lines. Both readings were right about the cost and wrong
//! about the alternative: the door is already linked everywhere, so a face costs nothing and the
//! rule is spelled once.

/// `value` as one shell word: wrapped in single quotes, with each embedded quote written as the
/// POSIX `'\''` idiom — close the quote, emit an escaped one, reopen.
///
/// Single quotes rather than double because inside them NOTHING is special: no `$`, no backtick, no
/// backslash. The escape idiom is the price of that, and it is the same one `zoxide` uses for its
/// own `cd` target. The empty string becomes `''`, which is a real empty argument rather than no
/// argument at all.
#[must_use]
pub fn single_quoted(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for character in value.chars() {
        if character == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(character);
        }
    }
    out.push('\'');
    out
}

/// The set `shlex.quote` calls safe: a word made only of these needs no quoting at all, because a
/// shell reads it as itself. Deliberately narrow — `~` and `{` are absent because a shell EXPANDS
/// them, and this rule exists to stop expansion.
const fn is_bare_safe(character: char) -> bool {
    matches!(character,
        'a'..='z' | 'A'..='Z' | '0'..='9' | '@' | '%' | '+' | '=' | ':' | ',' | '.' | '/' | '-' | '_')
}

/// `value` as one shell word, left BARE when it needs no quotes — Python's `shlex.quote`.
///
/// The same answer as [`single_quoted`] for anything a shell would treat specially; the difference
/// is only that `file.txt` stays `file.txt` rather than becoming `'file.txt'`. That matters where a
/// human reads the line back: a pasted path lands in the prompt looking like the path. The empty
/// string is NOT safe — it must be quoted to remain an argument.
#[must_use]
pub fn shlex_quoted(value: &str) -> String {
    if !value.is_empty() && value.chars().all(is_bare_safe) {
        return value.to_owned();
    }
    single_quoted(value)
}

#[cfg(test)]
mod tests {
    use super::{shlex_quoted, single_quoted};

    #[test]
    fn a_path_a_shell_would_split_stays_one_word() {
        assert_eq!(single_quoted("/Users/x/My Project"), "'/Users/x/My Project'");
        assert_eq!(single_quoted("plain"), "'plain'");
        assert_eq!(single_quoted(""), "''", "an empty value is still an argument");
    }

    #[test]
    fn nothing_inside_the_quotes_is_special_except_the_quote_itself() {
        assert_eq!(single_quoted("$HOME `id` ;rm"), "'$HOME `id` ;rm'");
        assert_eq!(single_quoted("back\\slash"), "'back\\slash'");
        assert_eq!(single_quoted("a'b"), "'a'\\''b'");
        assert_eq!(
            single_quoted("'"),
            "''\\'''",
            "a lone quote closes, escapes and reopens"
        );
        assert_eq!(single_quoted("a'b'c"), "'a'\\''b'\\''c'");
    }

    #[test]
    fn the_answer_survives_a_round_trip_through_a_shell_reading_of_it() {
        // What a shell does with `'…'`: drop the outer quotes, and read `'\''` as one quote.
        for original in ["plain", "/a b/c", "a'b", "'", "", "$x`y`\\z", "…nghiêng…"] {
            let quoted = single_quoted(original);
            let inner = quoted
                .strip_prefix('\'')
                .and_then(|rest| rest.strip_suffix('\''))
                .unwrap_or_default();
            assert_eq!(inner.replace("'\\''", "'"), original, "shell reading of {quoted}");
        }
    }

    #[test]
    fn the_bare_reading_quotes_exactly_what_a_shell_would_act_on() {
        assert_eq!(shlex_quoted("file.txt"), "file.txt");
        assert_eq!(shlex_quoted("a/b-c_d.e"), "a/b-c_d.e");
        assert_eq!(shlex_quoted(""), "''", "the empty word still needs to BE a word");
        assert_eq!(shlex_quoted("/My Documents/a.txt"), "'/My Documents/a.txt'");
        assert_eq!(shlex_quoted("it's"), "'it'\\''s'");
        assert_eq!(shlex_quoted("~/x"), "'~/x'", "a shell would expand a bare tilde");
        for expanding in ["$(whoami)", "a;b&c|d", "rm -rf *", "`id`", "a{b,c}", "x\ny"] {
            assert_eq!(shlex_quoted(expanding), single_quoted(expanding));
        }
    }
}
