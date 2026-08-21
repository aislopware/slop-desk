import CSlopDeskFFI
import Foundation
import SlopDeskSupervisor

/// Where `slopdesk-screend` listens, and where its binary is.
///
/// ## The name is shared by construction; the DIRECTORY was not
/// This file used to argue that a rendezvous address needs no shared implementation: a client has
/// to find the socket before it can say `hello`, so the address cannot be learned from the thing it
/// addresses, so the two ends agree by construction — "a name, not a policy".
///
/// The name, yes. Which directory the name sits in is a policy, it was written out on both sides,
/// and the two were not the same policy. screend resolves `$SLOPDESK_SCREEND_SOCKET`, else
/// `$TMPDIR`, else `/tmp`; this file resolved the override and then `NSTemporaryDirectory()`, which
/// on Darwin does not read `$TMPDIR` at all — it answers `confstr(_CS_DARWIN_USER_TEMP_DIR)`
/// whatever the environment holds, measured. So any process whose `TMPDIR` pointed elsewhere had a
/// daemon binding one path and this client dialling another, and the only symptom was screend
/// appearing not to be running. The pair agreed in practice for one accidental reason: launchd sets
/// `TMPDIR` to exactly the directory that call returns, and the test fixture sets the override — so
/// the two paths anyone exercised were the two where the disagreement cancels.
///
/// The rule is now `slopdesk_screenwire::socket_path`, called through `slopdesk_screen_socket_path`.
/// What is left here is the environment lookup, which stays a parameter so the resolution is still
/// testable with a dictionary. Everything else about screend — its registry, its eviction, its
/// frame limits — already existed once, in Rust.
public enum ScreenPaths {
    /// Points this process at a screend other than the login session's. The test fixture uses it to
    /// run a private daemon; nothing else should.
    public static let socketEnvKey = "SLOPDESK_SCREEND_SOCKET"

    /// Overrides which `slopdesk-screend` binary gets started when none is listening.
    public static let binaryEnvKey = "SLOPDESK_SCREEND_BIN"

    /// screend's request socket — `slopdesk-screend.sock`, under whichever directory the rule picks.
    ///
    /// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes an
    /// un-suffixed name safe — and a name with no pid in it is the point: a restarted screend must
    /// answer at the address its clients already hold. The precedence, the emptiness filter and the
    /// last-resort directory are all the crate's; this reads the two variables and hands them over.
    ///
    /// An empty answer would mean the door refused, which it cannot — every path it can build is
    /// non-empty — so the fallback below is unreachable rather than a second opinion about where
    /// screend lives.
    public static func requestSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        let overrideBytes = Array((environment[socketEnvKey] ?? "").utf8)
        let tmpdirBytes = Array((environment["TMPDIR"] ?? "").utf8)
        let path = overrideBytes.withUnsafeBufferPointer { over -> String? in
            tmpdirBytes.withUnsafeBufferPointer { temp -> String? in
                let ask = { (out: UnsafeMutableBufferPointer<UInt8>?) -> Int in
                    slopdesk_screen_socket_path(
                        over.baseAddress, over.count, temp.baseAddress, temp.count,
                        out?.baseAddress, out?.count ?? 0,
                    )
                }
                let needed = ask(nil)
                guard needed > 0 else { return nil }
                var room = [UInt8](repeating: 0, count: needed)
                let written = room.withUnsafeMutableBufferPointer { ask($0) }
                guard written == needed else { return nil }
                return String(bytes: room, encoding: .utf8)
            }
        }
        return path ?? ""
    }

    /// The `slopdesk-screend` executable, or `nil` when this machine has none.
    ///
    /// In order: the override, the installed copy, then the crate's cargo target directories — the
    /// shared rule for this tree's own Rust services, which lives once in ``RustServicePaths``.
    /// There is deliberately no `PATH` search: screend is not a user-facing command and a stray
    /// same-named binary on someone's `PATH` should not become the screen engine.
    public static func binary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        executable: URL? = Bundle.main.executableURL,
    ) -> String? {
        RustServicePaths.locate(
            "slopdesk-screend",
            crate: "slopdesk-screend",
            overrideVariable: binaryEnvKey,
            environment: environment,
            fileManager: fileManager,
            executable: executable,
        )
    }
}
