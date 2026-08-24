#if os(macOS)
import Foundation

// The `slopdesk` command, linked without asking.
//
// It used to be a first-launch card with a switch on it, and the switch escalated: `/usr/local/bin`
// is root-owned, so turning it on raised an administrator prompt on a user's first two minutes with
// the app. Two things were wrong with that. A password prompt is the most expensive question a
// program can ask, and it was being spent on a convenience; and a card that can be dismissed is a
// card most people dismiss, which left `slopdesk edit` — the command every doc example opens with —
// not existing on most installs.
//
// So the link is made at launch, into a directory the user already owns. No prompt, no switch,
// nothing to opt into. `~/.local/bin` is the XDG user-binary location and is already on `PATH` in
// most shell setups; where it is not, the file is still there to point at, which is strictly more
// than the dismissed card left behind.
//
// ## Compiled-only
// Touches the filesystem. `#if os(macOS)`: iOS has no `PATH` and no place to put a command.

/// Links the bundled `slopdesk` executable into the user's own bin directory.
@preconcurrency
@MainActor
public enum CLILink {
    /// Where the link lands: `~/.local/bin/slopdesk`.
    ///
    /// Deliberately NOT `/usr/local/bin`, which needs a privilege the app should never ask for, and
    /// not `/opt/homebrew/bin`, which belongs to a package manager that did not install this.
    public static var linkPath: String {
        NSHomeDirectory() + "/.local/bin/slopdesk"
    }

    /// Makes the link if it is missing or points somewhere else, and answers whether the command is
    /// now reachable at ``linkPath``.
    ///
    /// Idempotent and silent. Every failure mode — no bundled binary, an unwritable home, a real
    /// file already sitting at the path — answers `false` and changes nothing: the app works without
    /// the command, and a launch that threw over a symlink would be trading the product for a
    /// convenience.
    ///
    /// A path that already holds a REGULAR file is left alone. That is somebody else's `slopdesk`,
    /// or an earlier copy the user placed by hand, and replacing it silently is the one outcome
    /// worse than not linking at all.
    @discardableResult
    public static func ensureLinked() -> Bool {
        guard let source = bundledCLIPath() else { return false }
        let manager = FileManager.default
        let link = linkPath
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link) {
            if existing == source { return true }
            try? manager.removeItem(atPath: link)
        } else if manager.fileExists(atPath: link) {
            return false // a real file somebody else owns
        }
        try? manager.createDirectory(
            atPath: URL(fileURLWithPath: link).deletingLastPathComponent().path,
            withIntermediateDirectories: true,
        )
        try? manager.createSymbolicLink(atPath: link, withDestinationPath: source)
        return (try? manager.destinationOfSymbolicLink(atPath: link)) == source
    }

    /// The `slopdesk` executable shipped inside this bundle, or `nil` in a build that has none —
    /// which a `swift build` binary run straight out of `.build` is.
    private static func bundledCLIPath() -> String? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        let candidate = directory.appendingPathComponent("slopdesk", isDirectory: false).path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
#endif
