import Darwin
import Foundation

/// The one thing hostd has to know about superd before it can ask superd anything: the address.
///
/// ## Only the address, deliberately
/// superd owns every other path — the hook socket, the agent-control socket, the lock file, and
/// the directory they all sit in. hostd learns the two it cares about from the `hello` reply
/// (``HelloReply/hookSocketPath``), which is the whole reason that reply carries them. There is no
/// Swift copy of that resolution: it lives in `rust/slopdesk-superd/src/paths.rs`, and a second
/// implementation would be a second answer to "where is the hook socket" — the exact drift that
/// pid-keyed paths already caused once (`docs/51` §1, `DECISIONS.md` 2026-08-11).
///
/// A rendezvous address cannot be learned from the thing it addresses, so this constant is shared
/// by construction. It is a name, not a policy.
public enum SupervisorPaths {
    /// Points hostd at a superd other than the login session's. The gate script uses it to run a
    /// private daemon; nothing else should.
    public static let socketEnvKey = "SLOPDESK_SUPERD_SOCKET"

    /// superd's control socket.
    ///
    /// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes an
    /// un-suffixed name safe — and a name with no pid in it is the point (`docs/51` §1).
    public static func controlSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment[socketEnvKey], !override.isEmpty { return override }
        let directory = NSTemporaryDirectory()
        let separator = directory.hasSuffix("/") ? "" : "/"
        return directory + separator + "slopdesk-superd.sock"
    }
}

/// `sockaddr_un.sun_path` is a fixed 104-byte array on Darwin. `connect` validates against it
/// rather than letting `strncpy` silently truncate into a path that connects to the WRONG name.
public enum UnixSocketPath {
    public static var maximumLength: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    }

    public enum PathError: Error, Sendable {
        case tooLong(path: String, limit: Int)
    }

    public static func validate(_ path: String) throws {
        guard path.utf8.count <= maximumLength else {
            throw PathError.tooLong(path: path, limit: maximumLength)
        }
    }

    /// Fills a `sockaddr_un` for `path`. Throws rather than truncating.
    public static func address(for path: String) throws -> sockaddr_un {
        try validate(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let limit = maximumLength
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            path.withCString { cString in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    cString,
                    limit,
                )
            }
        }
        return addr
    }
}
