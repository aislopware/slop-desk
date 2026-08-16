import Foundation
import SlopDeskSupervisor

/// Where `slopdesk-screend` listens, and where its binary is.
///
/// ## Only the address, deliberately — the same rule as ``SupervisorPaths``
/// screend resolves this path itself, in `rust/slopdesk-screend/src/server.rs`. A rendezvous
/// address cannot be learned from the thing it addresses, so the two ends necessarily agree on it
/// by construction; everything else about screend (its registry, its eviction, its frame limits)
/// exists once, in Rust. This is a name, not a policy.
public enum ScreenPaths {
    /// Points this process at a screend other than the login session's. The test fixture uses it to
    /// run a private daemon; nothing else should.
    public static let socketEnvKey = "SLOPDESK_SCREEND_SOCKET"

    /// Overrides which `slopdesk-screend` binary gets started when none is listening.
    public static let binaryEnvKey = "SLOPDESK_SCREEND_BIN"

    /// screend's request socket.
    ///
    /// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes an
    /// un-suffixed name safe — and a name with no pid in it is the point: a restarted screend must
    /// answer at the address its clients already hold.
    public static func requestSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment[socketEnvKey], !override.isEmpty { return override }
        let directory = NSTemporaryDirectory()
        let separator = directory.hasSuffix("/") ? "" : "/"
        return directory + separator + "slopdesk-screend.sock"
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
