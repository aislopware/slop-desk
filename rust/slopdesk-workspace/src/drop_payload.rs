//! WHICH of a drag's items is the drop — a pasteboard reduced to one [`Dropped`].
//!
//! [`drop_action`](crate::drop_action) is the other half and it was here first: it answers what a
//! `(zone, content)` pair DOES. This answers where that `content` came from, and until `docs/67` it
//! was the one step of that walk still decided in Swift — `classify → resolve → actuate`, with the
//! middle in Rust and the ends in the shells. Two languages deciding consecutive steps of one walk
//! is the one-implementation rule broken at a join, so the join moved rather than the rule.
//!
//! ## What crosses, and what does not
//!
//! Not the pasteboard. `AppKit` asks an `NSPasteboard` for its types and `UIKit` asks an
//! `NSItemProvider` to load them, and the two disagree about everything up to the value: a file URL
//! with an `isDirectory` resource value, a web URL, a plain string. Reading them is a framework
//! errand and stays where the framework is. What arrives here is that errand's RESULT — the
//! supported slice, already extracted — and an unsupported type is simply absent from it.
//!
//! This layer never touches the disk. `is_directory` is resolved on the platform side, because the
//! only honest reading of a dropped path is the one the drag itself carried: by the time a
//! classifier could `stat` it, the file may be gone.
//!
//! ## Precedence, and why it is not a preference
//!
//! **file → url → text.** A Finder file drag also publishes a text representation of its own path,
//! so a classifier that read text first would turn every file drop into a paste. The order is what
//! makes "you dropped a file" and "you dropped the words of a path" different answers, which is the
//! whole difference between opening something and typing its name.
//!
//! An empty or all-whitespace value is dropped on the way past rather than classified — a hostile
//! or empty drag is the normal case, not a fault (validate-then-drop), and it answers [`None`] the
//! same way an unsupported type does.

use crate::drop_action::{Dropped, DroppedKind};

/// One file-URL entry the platform layer surfaced: the POSIX path, and whether it names a
/// directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileEntry<'a> {
    /// The path, as the drag carried it.
    pub path: &'a str,
    /// Resolved on the platform side from the URL's resource values — never by stat-ing here.
    pub is_directory: bool,
}

/// The supported slice of a drag pasteboard, already extracted by the platform layer.
///
/// Three groups rather than one heterogeneous list, because precedence is BETWEEN the groups and
/// the platform layer already had them apart: a drag publishes its file URLs, its web URLs and its
/// text as separate representations of itself.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Payload<'a> {
    /// Every file URL the drag carried, in the order the pasteboard listed them.
    pub files: &'a [FileEntry<'a>],
    /// Every non-file URL it carried.
    pub urls: &'a [&'a str],
    /// Its plain-text representation, when it published one.
    pub text: Option<&'a str>,
}

/// Reduces a `payload` to the one thing that was dropped, or [`None`] when nothing supported and
/// non-blank is in it.
///
/// The FIRST non-blank entry in precedence order wins. A group whose entries are all blank falls
/// through to the next one rather than answering nothing, so a drag that published an empty file
/// list beside real text still pastes.
#[must_use]
pub fn classify<'a>(payload: &Payload<'a>) -> Option<Dropped<'a>> {
    if let Some(entry) = payload.files.iter().find(|entry| !is_blank(entry.path)) {
        return Some(Dropped {
            kind: if entry.is_directory {
                DroppedKind::Folder
            } else {
                DroppedKind::File
            },
            value: entry.path,
        });
    }
    if let Some(url) = payload.urls.iter().find(|url| !is_blank(url)) {
        return Some(Dropped {
            kind: DroppedKind::Url,
            value: url,
        });
    }
    match payload.text {
        Some(text) if !is_blank(text) => {
            Some(Dropped {
                kind: DroppedKind::Text,
                value: text,
            })
        },
        _ => None,
    }
}

/// Whether `value` is empty or nothing but whitespace — the validate-then-drop gate.
fn is_blank(value: &str) -> bool {
    value.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::{FileEntry, Payload, classify};
    use crate::drop_action::{Dropped, DroppedKind};

    const fn file(path: &str) -> FileEntry<'_> {
        FileEntry {
            path,
            is_directory: false,
        }
    }

    const fn folder(path: &str) -> FileEntry<'_> {
        FileEntry {
            path,
            is_directory: true,
        }
    }

    #[test]
    fn a_directory_and_a_regular_file_are_different_answers() {
        assert_eq!(
            classify(&Payload {
                files: &[folder("/repo")],
                ..Payload::default()
            }),
            Some(Dropped {
                kind: DroppedKind::Folder,
                value: "/repo"
            })
        );
        assert_eq!(
            classify(&Payload {
                files: &[file("/repo/a.txt")],
                ..Payload::default()
            }),
            Some(Dropped {
                kind: DroppedKind::File,
                value: "/repo/a.txt"
            })
        );
    }

    #[test]
    fn a_file_drag_that_also_publishes_its_path_as_text_is_still_a_file() {
        // The precedence that earns its keep: Finder publishes both, and reading the text first
        // would turn every file drop into a paste of its own name.
        let payload = Payload {
            files: &[file("/repo/a.txt")],
            urls: &["https://x.dev"],
            text: Some("/repo/a.txt"),
        };
        assert_eq!(
            classify(&payload),
            Some(Dropped {
                kind: DroppedKind::File,
                value: "/repo/a.txt"
            })
        );
    }

    #[test]
    fn a_url_wins_over_text_and_loses_to_a_file() {
        assert_eq!(
            classify(&Payload {
                urls: &["https://x.dev"],
                text: Some("x"),
                ..Payload::default()
            }),
            Some(Dropped {
                kind: DroppedKind::Url,
                value: "https://x.dev"
            })
        );
    }

    #[test]
    fn text_answers_when_it_is_the_only_thing_there() {
        assert_eq!(
            classify(&Payload {
                text: Some("hello"),
                ..Payload::default()
            }),
            Some(Dropped {
                kind: DroppedKind::Text,
                value: "hello"
            })
        );
    }

    #[test]
    fn a_blank_group_falls_through_rather_than_answering_nothing() {
        let payload = Payload {
            files: &[file("   ")],
            urls: &[""],
            text: Some("hello"),
        };
        assert_eq!(
            classify(&payload),
            Some(Dropped {
                kind: DroppedKind::Text,
                value: "hello"
            }),
            "a group whose entries are all blank is skipped, not fatal"
        );
    }

    #[test]
    fn the_first_non_blank_entry_in_a_group_wins() {
        let payload = Payload {
            files: &[file(" "), folder("/repo"), file("/other")],
            ..Payload::default()
        };
        assert_eq!(
            classify(&payload),
            Some(Dropped {
                kind: DroppedKind::Folder,
                value: "/repo"
            })
        );
    }

    #[test]
    fn an_empty_or_all_blank_drag_classifies_to_nothing() {
        assert_eq!(classify(&Payload::default()), None);
        assert_eq!(
            classify(&Payload {
                files: &[file("")],
                urls: &["\n"],
                text: Some("  \t ")
            }),
            None,
            "validate-then-drop: a hostile or empty drag is the normal case"
        );
    }
}
