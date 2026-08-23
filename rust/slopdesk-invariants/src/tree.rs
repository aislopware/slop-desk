//! The repository, read once.
//!
//! Every rule in this crate asks questions of the same few thousand source files. The shell gate
//! this replaces asked them by spawning `grep`, which meant each question re-opened and re-read the
//! files it touched — 891 times over, for a tree that fits in a few tens of megabytes. Here the
//! walk happens once, the text stays resident, and a rule is a function over `&Tree`.
//!
//! ## Two views of every file, and why the second is not a convenience
//!
//! A gate that bans a call has to tell a CALL from a SENTENCE ABOUT ONE. The prose above these
//! rules names the very things they forbid — that is the point of the prose — so a rule that
//! greps raw text fires on its own explanation. [`Source::code`] is the file with its comment
//! lines removed, computed once and cached, and it is what a ban reads.
//!
//! It is line-based, not a lexer: a `//` inside a string literal keeps its line, and a block
//! comment's interior does not. Both are deliberate. The shell's stripper was `grep -vE '^
//! *(///|//|\*)'` and every rule was written against that behaviour, so matching it exactly is what
//! makes the port checkable against the original rather than merely similar.
//!
//! It is also per-LANGUAGE, and that is not a refinement of the shell — it is the shell's behaviour
//! written down. `#` opens a comment in shell and Python and opens an ATTRIBUTE in Rust, so one
//! stripper across both would eat `#[cfg(test)]` from every Rust file. Several rules stop reading a
//! Rust file AT that attribute — a test asserting an absence has to spell the banned thing — and a
//! stripper that removed the line would silently hand them the test module too.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// What opens a whole-line comment in a given file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommentStyle {
    /// Swift, Rust, C headers: `//`, `///`, `//!`, and `*` for a block comment's continuation.
    Slashes,
    /// Shell, Python, TOML: `#`.
    Hash,
    /// Markdown and JSON: nothing is a comment, so `code()` is the file.
    None,
}

impl CommentStyle {
    fn of(path: &Path) -> Self {
        match path.extension().and_then(|ext| ext.to_str()) {
            Some("swift" | "rs" | "h") => Self::Slashes,
            Some("sh" | "py" | "toml") => Self::Hash,
            _ => Self::None,
        }
    }

    fn opens(self, trimmed: &str) -> bool {
        match self {
            Self::Slashes => trimmed.starts_with("//") || trimmed.starts_with('*'),
            Self::Hash => trimmed.starts_with('#'),
            Self::None => false,
        }
    }
}

/// One file, with the two views every rule reads.
pub struct Source {
    /// The file verbatim.
    pub text: String,
    /// What a comment looks like here.
    pub style: CommentStyle,
    /// The file with whole-line comments removed. Lazily built, because most files are read only
    /// by a rule that wants the raw text.
    code: OnceLock<String>,
}

impl Source {
    const fn new(text: String, style: CommentStyle) -> Self {
        Self {
            text,
            style,
            code: OnceLock::new(),
        }
    }

    /// The file with every line whose first non-blank characters open a comment removed.
    #[must_use]
    pub fn code(&self) -> &str {
        if self.style == CommentStyle::None {
            return &self.text;
        }
        self.code.get_or_init(|| {
            let mut out = String::with_capacity(self.text.len());
            for line in self.text.lines() {
                if self.style.opens(line.trim_start()) {
                    continue;
                }
                out.push_str(line);
                out.push('\n');
            }
            out
        })
    }
}

/// The repository as a map from repo-relative path to contents.
pub struct Tree {
    root: PathBuf,
    files: BTreeMap<PathBuf, Source>,
}

/// The directories a rule may ask about, and the extensions worth holding in memory.
///
/// Deliberately NOT the whole repository: `.build`, `target`, `.git` and the rest of `ThirdParty`
/// are together larger than everything a rule reads, and walking them would trade the win this crate
/// exists for. A rule that needs a file outside these reads it with [`Tree::read`], which is the
/// escape hatch and says so at the call site.
///
/// `ThirdParty/ghostty/integration` is the ONE exception, and it is four files: the embedder Swift,
/// which is the only registrar of the terminal seam and is compiled by no `Package.swift` target.
/// The vendored `ThirdParty/ghostty` beside it stays out — the exception is the integration
/// directory, not the dependency.
const ROOTS: [&str; 8] = [
    "Sources",
    "Tests",
    "Apps",
    "rust",
    "scripts",
    "docs",
    "golden",
    "ThirdParty/ghostty/integration",
];

/// Extensions held in memory. A file outside this set is still WALKED — its path is known, so a
/// rule can assert that it exists — but its bytes are not read until asked for.
const TEXT_EXTENSIONS: [&str; 9] = ["swift", "rs", "sh", "py", "md", "h", "toml", "json", "plist"];

impl Tree {
    /// Walks the repository rooted at `root` and reads every source file under [`ROOTS`].
    ///
    /// # Errors
    /// Returns the first I/O error that stops the walk. A file that exists but cannot be read as
    /// UTF-8 is skipped rather than fatal — the tree holds a vendored fixture or two that is not
    /// text, and no rule asks about them.
    pub fn load(root: &Path) -> std::io::Result<Self> {
        let mut files = BTreeMap::new();
        for name in ROOTS {
            let dir = root.join(name);
            if dir.is_dir() {
                walk(root, &dir, &mut files)?;
            }
        }
        // The two top-level files rules ask about by name. They are outside ROOTS because they are
        // not directories, and naming them is cheaper than a whole extra walk of the repo root.
        for name in ["Makefile", "Package.swift", "CLAUDE.md", "DESIGN.md"] {
            let path = root.join(name);
            if let Ok(text) = fs::read_to_string(&path) {
                let relative = PathBuf::from(name);
                // The Makefile has no extension and `#` is its comment, so it is named rather than
                // derived — the one file in the tree whose style a suffix cannot answer.
                let style = if name == "Makefile" {
                    CommentStyle::Hash
                } else {
                    CommentStyle::of(&relative)
                };
                files.insert(relative, Source::new(text, style));
            }
        }
        Ok(Self {
            root: root.to_path_buf(),
            files,
        })
    }

    /// The repository root every path in this tree is relative to.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// One file's contents, or `None` when it is not in the tree.
    ///
    /// A rule that asserts a file EXISTS asks this and reports the `None`; a rule that reads a file
    /// it assumes exists should say what its absence means, because `None` silently satisfies a
    /// "must not contain" ban and that is the one failure this crate cannot afford.
    #[must_use]
    pub fn get(&self, path: &str) -> Option<&Source> {
        self.files.get(Path::new(path))
    }

    /// Whether a path is present in the tree.
    #[must_use]
    pub fn has(&self, path: &str) -> bool {
        self.files.contains_key(Path::new(path))
    }

    /// Every path in the tree, in sorted order — so a rule that scans is deterministic.
    pub fn paths(&self) -> impl Iterator<Item = &Path> {
        self.files.keys().map(PathBuf::as_path)
    }

    /// Every file under `prefix`, path and contents, in sorted order.
    pub fn under<'a>(&'a self, prefix: &'a str) -> impl Iterator<Item = (&'a Path, &'a Source)> {
        self.files
            .iter()
            .filter(move |(path, _)| path.starts_with(prefix))
            .map(|(path, source)| (path.as_path(), source))
    }

    /// Reads a file the walk did not hold — the escape hatch for the handful of rules that ask
    /// about something outside [`ROOTS`].
    ///
    /// # Errors
    /// Whatever [`fs::read_to_string`] returns.
    pub fn read(&self, path: &str) -> std::io::Result<String> {
        fs::read_to_string(self.root.join(path))
    }
}

fn walk(root: &Path, dir: &Path, files: &mut BTreeMap<PathBuf, Source>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // Build output and version control are the bulk of the bytes under `rust/` and none of the
        // meaning. `.build` is SwiftPM's, `target` is cargo's, and both hold copies of sources that
        // would otherwise answer a ban twice.
        if name == "target" || name == ".build" || name == ".git" || name.starts_with('.') {
            continue;
        }
        if entry.file_type()?.is_dir() {
            walk(root, &path, files)?;
            continue;
        }
        let keep = path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| TEXT_EXTENSIONS.contains(&ext));
        if !keep {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        let style = CommentStyle::of(relative);
        files.insert(relative.to_path_buf(), Source::new(text, style));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{CommentStyle, Source};

    #[test]
    fn a_comment_line_is_stripped_and_a_trailing_comment_is_not() {
        let source = Source::new(
            "// a ban's own explanation names CGWindowListCopyWindowInfo\n/// and so does its doc \
             comment\nlet x = 1 // this line is CODE, comment and all\n* a block continuation\n"
                .to_owned(),
            CommentStyle::Slashes,
        );
        assert_eq!(source.code(), "let x = 1 // this line is CODE, comment and all\n");
    }

    /// The reason the stripper is per-language. `#` opens a comment in shell and an ATTRIBUTE in
    /// Rust, and several rules stop reading a Rust file exactly AT `#[cfg(test)]` — a stripper that
    /// ate the line would hand them the test module, whose whole job is to spell what they ban.
    #[test]
    fn a_rust_attribute_survives_the_stripper_that_eats_a_shell_comment() {
        let rust = Source::new("#[cfg(test)]\nmod tests {}\n".to_owned(), CommentStyle::Slashes);
        assert!(rust.code().starts_with("#[cfg(test)]"));

        let shell = Source::new("# a comment\nls\n".to_owned(), CommentStyle::Hash);
        assert_eq!(shell.code(), "ls\n");
    }

    /// Indentation does not save a comment from the stripper, which is what makes the rules that
    /// read `code()` insensitive to how the prose above them happens to be laid out.
    #[test]
    fn an_indented_comment_is_still_a_comment() {
        let source = Source::new("    // indented\n\tlet y = 2\n".to_owned(), CommentStyle::Slashes);
        assert_eq!(source.code(), "\tlet y = 2\n");
    }

    /// The view is computed once. Rules ask for it in parallel, so the second asker must get the
    /// first one's answer rather than racing to build a second copy.
    #[test]
    fn the_code_view_is_built_once_and_reused() {
        let source = Source::new("let z = 3\n".to_owned(), CommentStyle::Slashes);
        let first: *const str = source.code();
        let second: *const str = source.code();
        assert!(std::ptr::eq(first, second));
    }
}
