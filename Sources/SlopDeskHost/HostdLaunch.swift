import CSlopDeskFFI
import Foundation

/// How `slopdesk-hostd` was started — the argv it accepts, and the record it publishes about the
/// argv it was actually given. Two faces over `slopdesk-hostlaunch`, one file because they are one
/// domain: `--port 0` is accepted by the first and only answerable by the second.
///
/// ## What is left here
/// Nothing that decides anything. The grammar, the usage text, the default port, the record's eight
/// fields, the atomic write and the container path are all Rust's. This is the marshalling and the
/// two Foundation types the callers want back.
///
/// The record's Swift half used to be a `Codable` struct, and `slopdesk-devtools` carried a
/// hand-written reader for the same eight fields — one document spelled twice, in two languages,
/// where a rename on either side compiles, passes every test and silently breaks the restart.
/// `CLAUDE.md`'s "one implementation, never two languages" is exactly that case, so both readers are
/// `slopdesk_hostlaunch::record` now.

/// Parsed command-line configuration for the `slopdesk-hostd` daemon.
///
/// A value, not a parser: ``parse(_:)`` hands the whole argv to a door and decodes the answer. The
/// grammar — which flags exist, which take values, which are refused — is
/// `slopdesk_hostlaunch::args`, and so is the usage text, so a flag cannot be documented that the
/// parser does not accept.
public struct HostdArguments: Sendable, Equatable {
    public let port: UInt16
    public let shell: String?
    /// Whether to start the inspector server on `port + 1`. Explicit under `--inspector`, and
    /// implied by `--transcript`, which supplies something for it to tail.
    public let inspectorEnabled: Bool
    /// The transcript path the inspector tails, if one was supplied.
    public let transcriptPath: String?

    public init(
        port: UInt16,
        shell: String?,
        inspectorEnabled: Bool = false,
        transcriptPath: String? = nil,
    ) {
        self.port = port
        self.shell = shell
        self.inspectorEnabled = inspectorEnabled
        self.transcriptPath = transcriptPath
    }

    /// The port hostd binds when nobody says otherwise — ASKED, never spelled.
    ///
    /// The client's connect gate and the menu-bar app want the same number, and the three of them
    /// disagreed once: the menu-bar app stored `7779` while the client dialled `7420`, so starting a
    /// host from the menu bar and pressing Connect dialled a port nothing was listening on. All
    /// three now read `slopdesk_hostd_default_port`, which is `docs/55` §8's answer for a constant
    /// that crosses in-process.
    public static var defaultPort: UInt16 { slopdesk_hostd_default_port() }

    /// The usage string printed on `--help` or a parse error.
    public static func usage(programName: String) -> String {
        let name = Array(programName.utf8)
        return hostAnswerText(capacity: 256) { out, cap in
            name.withUnsafeBufferPointer { bytes in
                slopdesk_hostd_args_usage(bytes.baseAddress, bytes.count, out, cap)
            }
        }
    }

    /// Parses a full argv, `argv[0]` included and dropped. `nil` is the door's refusal — `--help`,
    /// a flag with no value, a `--port` that is not a port, or a flag this daemon does not have —
    /// and the caller then prints ``usage(programName:)`` and exits non-zero.
    ///
    /// The arguments cross NUL-joined, which is lossless because an `execve` argument cannot contain
    /// a NUL, and which is what carries a `--shell /opt/My Shells/zsh` intact.
    public static func parse(_ args: [String]) -> Self? {
        let joined = Array(args.joined(separator: "\0").utf8)
        let blob = hostAnswerBytes(capacity: 512) { out, cap in
            joined.withUnsafeBufferPointer { bytes in
                slopdesk_hostd_args_parse(bytes.baseAddress, bytes.count, out, cap)
            }
        }
        // Byte 0 is the STATUS — see the door, which documents why a refusal is not `needed == 0`.
        // A short blob is the two sides disagreeing about the layout, which reads as a refusal
        // rather than as a daemon started on whatever the bytes happened to say.
        guard blob.count > 4, blob[0] == 1 else { return nil }
        let texts = hostRuns(Array(blob[4...]), count: 2)
        guard texts.count == 2 else { return nil }
        return Self(
            port: UInt16(blob[1]) << 8 | UInt16(blob[2]),
            shell: texts[0].isEmpty ? nil : texts[0],
            inspectorEnabled: blob[3] != 0,
            transcriptPath: texts[1].isEmpty ? nil : texts[1],
        )
    }
}

/// What a running hostd publishes about how it was started, so it can be restarted **identically**
/// without anyone having to remember.
///
/// ## Why this exists
/// `docs/51` made a hostd restart cheap: superd holds the panes, the child-facing sockets and the
/// panel backends, so stopping hostd costs a reconnect rather than the afternoon's work. What was
/// left was the ritual — find the process, hope `pkill` matched the right thing, wait long enough,
/// retype the flags. A restart that is *technically* free but *manually* fiddly still gets
/// postponed, which is the behaviour the whole subsystem set out to change. So hostd states its own
/// launch and `slopdesk-ops restart-hostd` reads it.
///
/// ## Why ``publish(boundPort:version:)`` takes two arguments and not eight
/// The pid, the argv, the cwd, the environment and the executable are the PROCESS's answers, and
/// the process is the same one on both sides of this boundary — so Rust asks it directly rather
/// than having six values marshalled across. What is passed is the two facts the daemon alone
/// knows: the port its listener actually BOUND (`--port 0` mints one that differs from the request)
/// and its build version.
public enum HostLaunchRecord {
    /// State this daemon's launch, now that the bound port is known. Returns the file's path when
    /// it landed, and `nil` otherwise.
    ///
    /// Best-effort by design: a host that cannot write this file is a host that still serves every
    /// client, and the only thing lost is that the restart path falls back to asking.
    @discardableResult
    public static func publish(
        boundPort: UInt16,
        version: String = HostEnvironment.buildVersion,
    ) -> String? {
        let stamp = Array(version.utf8)
        let wrote = stamp.withUnsafeBufferPointer { bytes in
            slopdesk_hostd_launch_record_write(boundPort, bytes.baseAddress, bytes.count)
        }
        guard wrote else { return nil }
        let path = hostAnswerText(capacity: 512) { out, cap in
            slopdesk_hostd_launch_record_path(out, cap)
        }
        return path.isEmpty ? nil : path
    }

    /// Delete the record, on the orderly shutdown.
    ///
    /// Called BEFORE the drain, not after: from that point this daemon will not serve, and a record
    /// naming a dying pid is worse than none. Its absence is meaningful — a record whose pid is gone
    /// means hostd died badly, which is worth telling apart from a clean stop.
    public static func remove() {
        slopdesk_hostd_launch_record_remove()
    }
}
