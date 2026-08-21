import CSlopDeskFFI
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
/// ## The address itself was the exception, and it had drifted twice
/// This file used to argue that the one path it does carry needs no shared implementation: a
/// rendezvous address cannot be learned from the thing it addresses, so the two ends agree by
/// construction — "a name, not a policy".
///
/// The name, yes. Which directory the name sits in is a policy, it was written out on both sides,
/// and the two were not the same policy. superd resolves `$SLOPDESK_SUPERD_SOCKET`, else
/// `$SLOPDESK_SUPERD_DIR`, else `$TMPDIR`, else `/tmp`. This file resolved the override and then
/// `NSTemporaryDirectory()`, which on Darwin does not read `$TMPDIR` at all — it answers
/// `confstr(_CS_DARWIN_USER_TEMP_DIR)` whatever the environment holds, measured. So any process
/// with a `TMPDIR` of its own had superd binding one path and hostd dialling another; and hostd had
/// never heard of `SLOPDESK_SUPERD_DIR`, so the gate script's private superd was reachable by
/// nothing. Neither showed up as an error — the daemon simply looked like it was not running. The
/// pair agreed in the one case anyone exercises because launchd sets `TMPDIR` to exactly the
/// directory that call returns, and the fixtures set the outright override.
///
/// The rule is now `slopdesk_superwire::control_socket_path`, shared with superd itself and called
/// through ``controlSocket(environment:)``. What is left here is the environment lookup, which
/// stays a parameter so the resolution is still testable with a dictionary.
public enum SupervisorPaths {
    /// Points hostd at a superd other than the login session's. The gate script uses it to run a
    /// private daemon; nothing else should.
    public static let socketEnvKey = "SLOPDESK_SUPERD_SOCKET"

    /// Points hostd at a whole private socket DIRECTORY. Same caller, one rung lower — the gate
    /// script needs two superds that cannot see each other.
    public static let directoryEnvKey = "SLOPDESK_SUPERD_DIR"

    /// superd's control socket.
    ///
    /// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes an
    /// un-suffixed name safe — and a name with no pid in it is the point (`docs/51` §1). The
    /// precedence, the emptiness filter and the last-resort directory are all the crate's; this
    /// reads the three variables and hands them over.
    ///
    /// An empty answer would mean the door refused, which it cannot — every path it can build is
    /// non-empty — so the fallback below is unreachable rather than a second opinion about where
    /// superd lives.
    public static func controlSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        let overrideBytes = Array((environment[socketEnvKey] ?? "").utf8)
        let directoryBytes = Array((environment[directoryEnvKey] ?? "").utf8)
        let tmpdirBytes = Array((environment["TMPDIR"] ?? "").utf8)
        let path = overrideBytes.withUnsafeBufferPointer { over -> String? in
            directoryBytes.withUnsafeBufferPointer { dir -> String? in
                tmpdirBytes.withUnsafeBufferPointer { temp -> String? in
                    let ask = { (out: UnsafeMutableBufferPointer<UInt8>?) -> Int in
                        slopdesk_supervisor_control_socket(
                            over.baseAddress, over.count, dir.baseAddress, dir.count,
                            temp.baseAddress, temp.count, out?.baseAddress, out?.count ?? 0,
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
        }
        return path ?? ""
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
