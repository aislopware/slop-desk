//! Reject a commit subject that is not a conventional commit.
//!
//! `better-update` gets this from commitlint (`@commitlint/config-conventional`) on lefthook's
//! `commit-msg` hook. Same job, no Node, and now no shell either: the whole rule is a grammar and
//! a handful of word tests, and this repo's hook config is `language: system` throughout on
//! purpose — nothing to provision, nothing to cache-miss.
//!
//! The convention is not decoration. `cliff.toml` reads the TYPE to decide which section of
//! `CHANGELOG.md` a commit lands in, and `git cliff --bumped-version` reads it again to turn
//! feat/fix/`!` into minor/patch/major. A subject outside the grammar is dropped from the
//! changelog silently and contributes nothing to the version — which is precisely the failure this
//! exists to make loud and early.
//!
//! Every rule here is a pure function of the message text, which is what a shell hook could not
//! be: its break-tests were prose in a comment, and these are the tests below.

/// What the hook decided about a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The subject is a plain conventional commit. The string, when present, is a NON-blocking
    /// note printed to stderr.
    Accepted(Option<String>),
    /// The subject is rejected, with the whole explanation the author should read.
    Rejected(String),
}

/// The types `cliff.toml` knows how to file.
pub const TYPES: &[&str] = &[
    "build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "revert", "style", "test",
];

/// Where GitHub ellipses a subject in the commit list, and where a changelog bullet stops being
/// scannable.
const SUBJECT_LIMIT: usize = 72;

/// The subject is the first line that is neither blank nor a comment.
///
/// Reading line 1 blindly fails on a `git commit` whose template puts a comment first.
#[must_use]
pub fn subject_of(message: &str) -> Option<&str> {
    message
        .lines()
        .find(|line| !line.trim_start().is_empty() && !line.trim_start().starts_with('#'))
}

/// git's own machinery writes these, and they are rewritten or dropped before they reach main.
///
/// Holding them to the grammar would block `--fixup`, `--squash` and conflict resolution.
fn is_gits_own(subject: &str) -> bool {
    subject.starts_with("Merge ")
        || subject.starts_with("Revert ")
        || subject.starts_with("fixup!")
        || subject.starts_with("squash!")
        || subject.starts_with("amend!")
}

/// `<type>[(scope)][!]: <text>` — the text after the colon, or `None` when the subject is not one.
///
/// Hand-parsed rather than regex-matched because each piece has its own alphabet and the failure
/// message wants to be about the grammar rather than about a pattern.
fn conventional_body(subject: &str) -> Option<&str> {
    let after_type = TYPES
        .iter()
        .find_map(|kind| subject.strip_prefix(*kind))
        .filter(|rest| rest.starts_with(['(', '!', ':']))?;

    let after_scope = match after_type.strip_prefix('(') {
        Some(scope) => {
            let (inner, rest) = scope.split_once(')')?;
            let mut characters = inner.chars();
            let first = characters.next()?;
            if !first.is_ascii_lowercase() && !first.is_ascii_digit() {
                return None;
            }
            if !characters.all(|c| {
                c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_' || c == '/' || c == '-'
            }) {
                return None;
            }
            rest
        },
        None => after_type,
    };

    let after_bang = after_scope.strip_prefix('!').unwrap_or(after_scope);
    let text = after_bang.strip_prefix(": ")?;
    if text.is_empty() { None } else { Some(text) }
}

/// A subject opening on an article, which is a sentence ABOUT the code rather than an instruction.
fn opens_on_an_article(first: &str) -> bool {
    matches!(first.to_ascii_lowercase().as_str(), "the" | "a" | "an")
}

/// Third person and past tense — the most common slip, and mechanically clear.
///
/// A gerund is checked separately below, because real imperatives end in `-ing` too.
const NOT_IMPERATIVE: &[&str] = &[
    "adds", "bumps", "changes", "drops", "fixes", "keeps", "makes", "moves", "removes", "renames", "stops",
    "updates", "uses", "added", "fixed", "changed", "removed", "updated",
];

/// Imperatives that happen to end in `-ing`, which is why the gerund rule only advises.
const IMPERATIVE_ING: &[&str] = &["bring", "ping", "string", "ring", "sing"];

/// The whole hook, as one function of the message file's contents.
#[must_use]
pub fn check(message: &str) -> Verdict {
    let Some(subject) = subject_of(message) else {
        return Verdict::Rejected("check-commit-msg: empty commit message".to_owned());
    };
    if is_gits_own(subject) {
        return Verdict::Accepted(None);
    }

    let Some(text) = conventional_body(subject) else {
        let types = TYPES.join(", ");
        return Verdict::Rejected(format!(
            "check-commit-msg: the subject is not a conventional commit.

  got:  {subject}

  want: <type>[(scope)][!]: <subject>
  type: {types}
        `!` or a \"BREAKING CHANGE:\" trailer marks a breaking change.

  e.g.  fix(release): staple the ticket to each .app before it enters the image
        feat(rail)!: key the pane id on a UUID instead of an index

Why: cliff.toml reads the type to place this commit in CHANGELOG.md, and
`git cliff --bumped-version` reads it to compute the next version. A subject
outside the grammar is silently absent from both."
        ));
    };

    // Everything below governs the TEXT after the colon. It is enforced because that text is
    // published: [`super::changelog`] slices these subjects out of `CHANGELOG.md` and the GitHub
    // Release body is one bullet per subject, verbatim. A subject written to be read inside the
    // repo becomes a release note read by someone who has never seen the repo.
    //
    // The rule is: say what the change DOES, in the imperative, to a reader who was not here.
    let first = text.split(' ').next().unwrap_or(text);
    let lowered = first.to_ascii_lowercase();

    if opens_on_an_article(first) {
        return Verdict::Rejected(style_error(
            subject,
            &format!("opens with the article \"{first}\" — that is a description, not a change"),
            "start with a verb: what does this commit DO? (\"stop the plate sliding between projects\")",
        ));
    }
    if NOT_IMPERATIVE.contains(&lowered.as_str()) {
        return Verdict::Rejected(style_error(
            subject,
            &format!("\"{first}\" is not the imperative"),
            "write it as an instruction: \"add\", \"fix\", \"drop\", \"rename\"",
        ));
    }
    if text.ends_with('.') {
        return Verdict::Rejected(style_error(
            subject,
            "ends in a full stop",
            "drop the trailing period",
        ));
    }
    // Hard, not a warning: the fix is always available — move the detail into the body, which is
    // where the argument for a change belongs anyway.
    let length = subject.chars().count();
    if length > SUBJECT_LIMIT {
        return Verdict::Rejected(style_error(
            subject,
            &format!("the subject is {length} chars; GitHub ellipses past {SUBJECT_LIMIT}"),
            "cut it to 72 and move the rest into the commit body",
        ));
    }

    // Gerunds are usually a slipped mood ("Adding X" for "Add X"), but "bring"/"ping"/"string"
    // are imperatives that end the same way — so this one advises rather than blocks.
    if lowered.ends_with("ing") && !IMPERATIVE_ING.contains(&lowered.as_str()) {
        return Verdict::Accepted(Some(format!(
            "check-commit-msg: \"{first}\" reads as a gerund; the imperative is usually shorter and clearer."
        )));
    }
    Verdict::Accepted(None)
}

/// The shape every style rejection prints, so the author reads the same three lines each time.
fn style_error(subject: &str, issue: &str, want: &str) -> String {
    format!(
        "check-commit-msg: the subject is a conventional commit, but not a plain one.

  got:   {subject}
  issue: {issue}
  want:  {want}

The release body is one bullet per subject, verbatim (slopdesk-release changelog section).
Detail that does not fit belongs in the commit BODY, which the changelog never reads."
    )
}

#[cfg(test)]
mod tests {
    use super::{Verdict, check, subject_of};

    fn accepted(message: &str) -> bool {
        matches!(check(message), Verdict::Accepted(_))
    }

    fn rejection(message: &str) -> String {
        match check(message) {
            Verdict::Rejected(why) => why,
            Verdict::Accepted(_) => panic!("accepted: {message:?}"),
        }
    }

    #[test]
    fn the_subject_skips_the_template_comments_git_writes() {
        let message = "# Please enter the commit message\n\n\nfix(wire): drop the stale frame\n";
        assert_eq!(subject_of(message), Some("fix(wire): drop the stale frame"));
    }

    #[test]
    fn an_all_comment_message_is_empty() {
        assert!(rejection("# nothing\n#   \n").contains("empty commit message"));
    }

    #[test]
    fn the_grammar_takes_a_scope_and_a_breaking_marker() {
        assert!(accepted("feat: add a pane\n"));
        assert!(accepted("feat(rail): add a pane\n"));
        assert!(accepted("feat(rail)!: add a pane\n"));
        assert!(accepted("feat!: add a pane\n"));
        assert!(accepted("refactor(a.b/c-d_e): move it\n"));
    }

    #[test]
    fn a_subject_outside_the_grammar_is_rejected() {
        for bad in [
            "add a pane\n",
            "feature: add a pane\n",
            "feat add a pane\n",
            "feat:add a pane\n",
            "feat(): add a pane\n",
            "feat(Rail): add a pane\n",
            "feat: \n",
        ] {
            assert!(
                rejection(bad).contains("not a conventional commit"),
                "accepted {bad:?}"
            );
        }
    }

    /// git writes these itself; holding them to the grammar would block a conflict resolution.
    #[test]
    fn gits_own_subjects_pass_untouched() {
        for own in [
            "Merge branch 'main' into topic\n",
            "Revert \"feat: add a pane\"\n",
            "fixup! feat: add a pane\n",
            "squash! feat: add a pane\n",
            "amend! feat: add a pane\n",
        ] {
            assert!(accepted(own), "rejected {own:?}");
        }
    }

    #[test]
    fn an_article_reads_as_a_description() {
        assert!(rejection("fix(rail): the plate stops sliding\n").contains("the article \"the\""));
        assert!(rejection("fix(rail): An extra pane appears\n").contains("the article \"An\""));
    }

    #[test]
    fn the_third_person_is_not_the_imperative() {
        assert!(rejection("fix(rail): adds a pane\n").contains("is not the imperative"));
        assert!(rejection("fix(rail): Updated the pin\n").contains("is not the imperative"));
        assert!(accepted("fix(rail): add a pane\n"));
    }

    #[test]
    fn a_title_carries_no_full_stop() {
        assert!(rejection("fix(rail): add a pane.\n").contains("ends in a full stop"));
    }

    #[test]
    fn seventy_two_is_the_ceiling_and_not_a_warning() {
        let at_limit = format!("fix(rail): {}", "x".repeat(72 - "fix(rail): ".len()));
        assert_eq!(at_limit.chars().count(), 72);
        assert!(accepted(&at_limit));
        assert!(rejection(&format!("{at_limit}y")).contains("GitHub ellipses past 72"));
    }

    #[test]
    fn a_gerund_advises_and_an_imperative_ending_in_ing_does_not() {
        assert!(matches!(
            check("fix(rail): adding a pane\n"),
            Verdict::Accepted(Some(_))
        ));
        assert_eq!(
            check("fix(rail): bring the pane forward\n"),
            Verdict::Accepted(None)
        );
        assert_eq!(check("fix(net): ping the host once\n"), Verdict::Accepted(None));
    }
}
