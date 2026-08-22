// CustomLinkSchemes — the ONE reading of the Controls → Link Schemes free-text field.
//
// `SettingsKey.customLinkSchemes` stores a `[String]`; the editor is a single text field, so something
// has to say where one scheme ends and the next begins. That rule was written twice — the Mac's
// binding split on `,` alone, the phone's on `,`, space, newline and tab — and the two disagreed in a
// way a user could type by accident: `ssh vscode` stored ONE scheme on the Mac (`"ssh vscode"`, which
// matches no URL at all) and TWO on the phone.
//
// The PERMISSIVE reading is the correct one, and not because it is newer. A scheme cannot contain a
// space — RFC 3986 spells it `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` — so whitespace inside the
// field is never part of a value and can only ever be a separator or padding. A parser that treats it
// as neither is one that silently stores a token that can never match, with no error to say so.
//
// ``SettingsIndexPresentation/isReadOnly(_:)`` already records why this key has exactly one editor:
// "a second editor here would be a second way to write a list whose separator rules live at the first
// one." There were two first ones. This is where they live now.

import Foundation

/// Reading and writing the custom link-scheme list as ONE text field's worth of text.
///
/// Not a view: a `String -> [String]` and its inverse. Both shells' settings bindings call it, and
/// the All-Settings index prints ``field(_:)`` for its read-only summary.
package enum CustomLinkSchemes {
    /// The characters that end a scheme in the editor: the comma the field is written back with, plus
    /// every whitespace a keyboard can put between two words.
    private static let separators: Set<Character> = [",", " ", "\n", "\t"]

    /// The stored list a field's raw text means: each token trimmed, empties dropped, order kept.
    ///
    /// Order is the user's — this is a list they typed, not a set — and duplicates are left alone for
    /// the same reason a text field does not reorder what is in it while it is being edited.
    package static func parse(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The field's text for a stored list — comma-and-space, which is what ``parse(_:)`` reads back
    /// unchanged, so a round trip through the editor is the identity.
    package static func field(_ schemes: [String]) -> String {
        schemes.joined(separator: ", ")
    }
}
