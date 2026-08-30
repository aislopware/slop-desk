#if os(macOS)
import CSlopDeskFFI
import Foundation

// The `slopdesk` command, linked without asking — as the Swift face of `slopdesk-clilink`, reached
// through `rust/slopdesk-ffi`'s `cli_link` door.
//
// ## What is not here any more
//
// The link itself, and every question around it: where it goes, whether one is already there, whose
// file it is, and the four verdicts that come out. All Rust's — it is an EFFECT on the filesystem,
// and every effect on the system is Rust's (`docs/67`). What stays is the ONE thing no crate can
// derive: where this bundle's own executable lives, which is `Bundle.main` and nothing else.
//
// ## Compiled-only
// `#if os(macOS)`: iOS has no `PATH` and no place to put a command, so the door is inside the
// header's `MACOS-ONLY` region and this file is gated to match.

/// Links the bundled `slopdesk` executable into the user's own bin directory.
@preconcurrency
@MainActor
public enum CLILink {
    /// Makes the link if it is missing or points somewhere else, and answers whether the command is
    /// reachable afterwards.
    ///
    /// Idempotent and silent. Every failure mode — no bundled binary, an unwritable home, a real
    /// file already sitting at the path — answers `false` and changes nothing: the app works without
    /// the command, and a launch that threw over a symlink would be trading the product for a
    /// convenience. Which of those it was is the door's four-verdict answer; nothing here reads more
    /// than "is it there", so nothing here spells the other three out again.
    @discardableResult
    public static func ensureLinked() -> Bool {
        guard let source = bundledCLIPath() else { return false }
        let home = NSHomeDirectory()
        let verdict = Array(home.utf8).withUnsafeBufferPointer { homeBytes in
            Array(source.utf8).withUnsafeBufferPointer { sourceBytes in
                slopdesk_cli_link(
                    homeBytes.baseAddress, homeBytes.count,
                    sourceBytes.baseAddress, sourceBytes.count,
                )
            }
        }
        return UInt32(verdict) == SLOPDESK_CLI_LINK_ALREADY || UInt32(verdict) == SLOPDESK_CLI_LINK_MADE
    }

    /// The `slopdesk` executable shipped inside this bundle, or `nil` in a build that has none —
    /// which a `swift build` binary run straight out of `.build` is.
    ///
    /// The near side of the seam, and the whole of it: `Bundle.main` is the only thing on either
    /// side that knows where this app put itself.
    private static func bundledCLIPath() -> String? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        return directory.appendingPathComponent("slopdesk", isDirectory: false).path
    }
}
#endif
