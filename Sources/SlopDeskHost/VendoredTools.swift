// VendoredTools — where the panel's pinned third-party programs live, and how hostd finds them.
//
// The right panel's surfaces each stand on a program this repo does not build: `code-server`
// (verb 18), `baguette serve` (verb 21), `adb` and the pushed `scrcpy-server` jar (verb 22).
// They used to be whatever Homebrew happened to have installed, which is how the code panel spent
// months on Code 1.112 without anything noticing: the formula froze there and was deprecated, and
// no file in this repo recorded which version the panel had been written against.
//
// So they are pinned in `ThirdParty/tools/tools.lock` and provisioned into
// `ThirdParty/tools/.prefix/bin` by `ThirdParty/tools/provision.sh`. This type is the read half.
//
// A face over `slopdesk-androidd`'s `toolchain`, which owns the marker, the upward walk and the two
// paths that hang off it — the same crate that owns the binary SEARCH ORDER the prefix is the
// second rung of. What stays here is the one Foundation line the walk starts from.
//
// **hostd never provisions.** Nothing here downloads, extracts or writes — it stats. A host that
// has not been provisioned reports the surface unavailable and names the script; it does not reach
// the network because someone opened a panel.
//
// **Why the running binary and not a compiled-in path.** `#filePath` bakes in the machine that
// COMPILED hostd, which is wrong the moment a build is copied. Walking up from the executable and
// looking for the lock file is honest about what is actually on this disk: it works from
// `.build/release`, from `.build/debug`, from SwiftPM's triple-nested output, and from a checkout
// that has been renamed or moved. It correctly finds NOTHING when the binary has been copied out of
// the tree — and falling through to the host's own installs is the right answer there, not
// pretending a prefix exists.
//
// Hang-safety: filesystem stats only, no processes and no sockets, so unit tests may call this —
// and do, through the injected `startingAt:`.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// The provisioned third-party prefix, resolved from the running binary's location.
enum VendoredTools {
    /// `ThirdParty/tools/.prefix/bin` for the checkout this binary was built into, or `nil` when the
    /// binary does not sit inside one. Resolved once — the answer cannot change while the process
    /// lives, and every locator consults it.
    static let binDirectory: String? = path(slopdesk_vendored_bin_dir)

    /// The committed `scrcpy-server` jar, or `nil` outside a checkout. Unlike the other three this
    /// one is IN git (716 KB, and not an executable — the device's own `app_process` runs it), so a
    /// provisioned prefix is not required for the Android panel to mirror; a checkout is.
    static let scrcpyServerJar: String? = path(slopdesk_vendored_scrcpy_server_jar)

    /// The checkout root the running binary sits inside, or `nil` outside one.
    ///
    /// `Bundle.main.executableURL` rather than `CommandLine.arguments[0]`: the latter is whatever
    /// the caller passed as argv[0], which for a `nohup`'d hostd is a relative path against a
    /// working directory nobody promised.
    static func repoRoot(
        startingAt start: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
    ) -> String? {
        path(slopdesk_vendored_repo_root, startingAt: start)
    }

    /// Runs one of the three walk doors and turns its EMPTY answer back into `nil`.
    ///
    /// Empty and absent are the same state on the far side and the same state here: both mean the
    /// binary is outside a checkout, and every locator falls through to `PATH` and the host's own
    /// installs. There is no third answer to distinguish.
    private static func path(
        _ door: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int,
        startingAt start: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
    ) -> String? {
        guard let start else { return nil }
        let bytes = Array(start.utf8)
        let answer = bytes.withUnsafeBufferPointer { input in
            ffiAnswerText { out, cap in door(input.baseAddress, input.count, out, cap) }
        }
        return answer.isEmpty ? nil : answer
    }
}
