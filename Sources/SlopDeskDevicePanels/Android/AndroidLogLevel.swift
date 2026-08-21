import CSlopDeskFFI
import SlopDeskWorkspaceModel

// AndroidLogLine — gone; what is left is the FILTER MENU.
//
// The grammar it was named for is `slopdesk_devicelog::logcat` and the row it produced is
// ``DeviceLogLine``, which is now the one console row both device panels use. It was never a
// different type from the simulator's — the same four fields, the same "keep an unrecognised line
// verbatim" rule, and one field NAME apart (`tag` against `process`) for the same slot.
//
// The parse moved for the reason `docs/55` gives: it ran over text a program on the far side of a
// device wrote, thousands of lines a minute, on the socket read path, asking `Character.isNumber`
// per grapheme cluster and building four `String`s a row.

/// The priorities `logcat`'s own filter spec accepts, in ascending severity.
///
/// ## The SET is not here, and that is the fix
///
/// This used to be a five-case Swift enum, on the argument that a menu is not a grammar. The
/// argument was right about the labels and wrong about the letters. The letter is interpolated into
/// `*:<level>`, reaches an argument vector, and is validated by androidd against
/// `slopdesk_androidd::protocol::LOGCAT_LEVELS` before it spawns `logcat` — so the offer and the
/// guarantee are the same table, and this side was holding a stale copy of it. It listed
/// `V D I W E` where the alphabet is `V D I W E F`, which is not a crash and never showed up as
/// one: it is a FATAL filter the user simply could not ask for, on the one severity a console gets
/// opened to find.
///
/// So the set crosses now — ``allCases`` is whatever androidd will accept, in androidd's order —
/// and this type is the token plus its name. That makes it a `struct` rather than an `enum`: a case
/// list cannot be built from a table at run time, and an enum whose cases are written out again
/// here would be the same two copies under a different keyword. Nothing switches over these, so
/// nothing is lost — the two consoles iterate them and compare them, which a `Hashable`
/// `RawRepresentable` does exactly as well.
package struct AndroidLogLevel: RawRepresentable, Hashable, Sendable, Identifiable, CaseIterable {
    /// The `logcat` priority letter, which is the value that reaches the argument vector.
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var id: String { rawValue }

    /// The named levels, for the call sites that mean one in particular rather than a menu row.
    ///
    /// These are constants, not a second declaration of the set: each is a letter the alphabet
    /// either contains — in which case it is the same value ``allCases`` carries — or does not, in
    /// which case ``AndroidLogLevelTests`` fails rather than a menu quietly gaining a row androidd
    /// would refuse.
    package static let verbose = Self(rawValue: "V")
    package static let debug = Self(rawValue: "D")
    package static let info = Self(rawValue: "I")
    package static let warning = Self(rawValue: "W")
    package static let error = Self(rawValue: "E")
    package static let fatal = Self(rawValue: "F")

    /// Every level the menu offers, least severe first — androidd's own array, read once.
    ///
    /// Read once because it cannot change while the process runs: it is a `const` compiled into the
    /// linked archive, so re-crossing per menu build would buy nothing but calls.
    package static let allCases: [Self] = (0..<slopdesk_android_log_level_count()).compactMap { index in
        let letter = wsDelivered(capacity: 8) { out, cap in
            slopdesk_android_log_level_letter(index, out, cap)
        }
        return letter.map { Self(rawValue: $0) }
    }

    /// What the level is CALLED — the one part of this that is still Swift.
    ///
    /// A label is a vocabulary in the `docs/55` §6 sense: it is read by a menu and by nothing else,
    /// it decides nothing, and marshalling six words across C would buy no guarantee. The `default`
    /// arm is deliberately the bare letter rather than a placeholder: if the alphabet ever gains a
    /// priority, the menu shows the honest thing it knows — `"F"` — instead of hiding the row, and
    /// ``AndroidLogLevelTests`` fails until someone names it.
    package var title: String {
        switch rawValue {
        case Self.verbose.rawValue: "Verbose"
        case Self.debug.rawValue: "Debug"
        case Self.info.rawValue: "Info"
        case Self.warning.rawValue: "Warning"
        case Self.error.rawValue: "Error"
        case Self.fatal.rawValue: "Fatal"
        default: rawValue
        }
    }
}
