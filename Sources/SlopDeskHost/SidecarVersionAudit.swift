import CSlopDeskFFI
import Foundation

// SidecarVersionAudit — is the sidecar RUNNING the sidecar that is INSTALLED?
//
// Every daemon in this repo outlives hostd. superd is a launch agent held across logins; screend is
// one too (`scripts/install-screend.sh`); dropd, inspectord and androidd are superd's children,
// which is why hostd re-learns their ports off superd's retained ring rather than by starting them.
// So `brew upgrade` replaces twelve binaries on disk and changes what is executing for none of them.
//
// That is not a bug to fix by restarting everything. Restarting superd takes every live pane with
// it, and a user who upgraded to get a fixed drop dialog did not ask to lose their sessions. The
// release ships a `MANIFEST.json` naming a version per binary and the daemons report the version
// they are RUNNING (`docs/49`), so the honest answer is per-daemon: compare, and act only where
// acting is cheap.
//
// ## The comparison and the policy are NOT here
// They are `rust/slopdesk-sidecars`, behind `slopdesk_sidecar_audit`. This file is the decode.
//
// The reason is the second caller: `slopdesk sidecars` asks the same policy table what an UPGRADE
// changed, from two `MANIFEST.json` files, and that program's core is Rust. A policy table in Swift
// for hostd and a second one in Rust for the CLI is exactly the cross-language mirror `CLAUDE.md`
// bans — and the failure it bans it for is real here: the two would answer differently about
// screend the first time somebody changed its idle-exit and updated only one of them.
//
// What stays Swift is what is Swift-shaped: spawning `--version` and reading its pipe, and the
// closures over live daemons in `SidecarVersionAuditor`.

/// What one sidecar's audit concluded.
public enum SidecarVersionVerdict: Equatable, Sendable {
    /// The process is running the version that is installed.
    case current(String)
    /// The installed binary is a different build from the process serving. Not necessarily NEWER:
    /// a downgrade reads the same, and the fix is the same restart either way.
    case stale(running: String, onDisk: String)
    /// One of the two numbers is missing. A daemon older than its version field, a binary that is
    /// gone, a `--version` that did not answer. NEVER folded into ``current`` — reporting a stale
    /// sidecar as up to date is the silent wrong answer this whole mechanism exists to remove.
    case unknown(reason: String)
}

/// What hostd is allowed to do about a ``SidecarVersionVerdict/stale(running:onDisk:)``.
///
/// The raw values are the door's, so this decodes by `init(rawValue:)` rather than by a `switch`
/// nobody would remember to extend. A policy the near side does not recognise — a case added to the
/// crate before this enum learns it — reads as ``operatorChoice`` through
/// ``SidecarVersionReport/init(tool:running:onDisk:)``, which is the same safe unknown the crate
/// itself falls back to.
public enum SidecarRestartPolicy: String, Equatable, Sendable {
    /// Restart it now. dropd, inspectord and androidd are hostd's own children.
    case automatic
    /// Report it and let it go — screend retires itself once idle.
    case selfRetiring
    /// Report it and stop — superd would take every live pane, and hostd is not killed at all.
    case operatorChoice
    /// Nothing of it is resident. The CLI, the hook, the probe and the seed fork and exit.
    case notResident
}

/// The one thing in this audit that is genuinely Swift: running a binary and reading its banner.
public enum SidecarVersionAudit {
    /// The `--version` banner of the binary at `path`, or `nil` when it is absent or would not run.
    ///
    /// The PARSE is the door's — field two of line one, the contract every shipped binary honours and
    /// `slopdesk-release package` pins against. Only the spawn is here, and it is here rather than in
    /// ``SidecarVersionReport`` so the decision stays testable without a process tree; a caller
    /// under test substitutes its own reader.
    public static func installedVersion(ofBinaryAt path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read BEFORE waiting, the same rule `CodeSeed` follows: a banner that outgrew the pipe
        // buffer would block the child's write while this side blocked on its exit.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let banner = [UInt8](data)
        let version = banner.withUnsafeBufferPointer { raw in
            sidecarDoorAnswer { out, cap in
                slopdesk_sidecar_version_banner(raw.baseAddress, raw.count, out, cap)
            }
        }
        return version.isEmpty ? nil : version
    }
}

/// One line of the report hostd logs, and the client shows.
public struct SidecarVersionReport: Equatable, Sendable {
    /// The tool's `MANIFEST.json` name, e.g. `slopdesk-superd`.
    public let tool: String
    public let verdict: SidecarVersionVerdict
    public let policy: SidecarRestartPolicy
    /// True when the daemon is running code the install has replaced AND hostd may fix it itself.
    public let restartable: Bool
    /// One sentence for the log. Says which way round the two numbers are, because "stale" alone
    /// leaves the reader unable to tell an upgrade from a downgrade. Worded by the crate, so the
    /// log line and `slopdesk sidecars` say the same thing about the same daemon.
    public let summary: String

    /// Audits one sidecar from the two numbers its caller gathered.
    ///
    /// A door that does not answer — an empty `tool`, a build whose artifact predates it — lands in
    /// ``SidecarVersionVerdict/unknown(reason:)`` under ``SidecarRestartPolicy/operatorChoice``.
    /// That is the same shape as a daemon that stayed silent, and it is deliberate: the failure
    /// modes this type must never have are "reported as current" and "restarted on a guess".
    public init(tool: String, running: String?, onDisk: String?) {
        let decoded = Self.ask(tool: tool, running: running, onDisk: onDisk)
        self.tool = tool
        verdict = decoded?.verdict ?? .unknown(reason: "the version audit did not answer")
        policy = decoded?.policy ?? .operatorChoice
        restartable = decoded?.restartable ?? false
        summary = decoded?.summary ?? "\(tool) version is unknown: the version audit did not answer"
    }

    /// The door's answer, decoded. `nil` when it did not answer or answered something this build
    /// cannot read.
    private static func ask(
        tool: String, running: String?, onDisk: String?,
    ) -> (verdict: SidecarVersionVerdict, policy: SidecarRestartPolicy, restartable: Bool, summary: String)? {
        let toolBytes = [UInt8](tool.utf8)
        let runningBytes = [UInt8]((running ?? "").utf8)
        let onDiskBytes = [UInt8]((onDisk ?? "").utf8)
        let text = toolBytes.withUnsafeBufferPointer { name in
            runningBytes.withUnsafeBufferPointer { live in
                onDiskBytes.withUnsafeBufferPointer { disk in
                    sidecarDoorAnswer { out, cap in
                        slopdesk_sidecar_audit(
                            name.baseAddress, name.count,
                            live.baseAddress, live.count,
                            disk.baseAddress, disk.count,
                            out, cap,
                        )
                    }
                }
            }
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              let summary = object["summary"] as? String
        else { return nil }

        let verdict: SidecarVersionVerdict
        switch state {
        case "current":
            guard let version = object["running"] as? String else { return nil }
            verdict = .current(version)
        case "stale":
            guard let live = object["running"] as? String, let disk = object["onDisk"] as? String
            else { return nil }
            verdict = .stale(running: live, onDisk: disk)
        default:
            verdict = .unknown(reason: object["reason"] as? String ?? state)
        }
        let policy = (object["policy"] as? String).flatMap(SidecarRestartPolicy.init(rawValue:))
            ?? .operatorChoice
        return (verdict, policy, object["restartable"] as? Bool ?? false, summary)
    }
}

/// Calls a `(out, cap) -> needed` door under the pure convention, growing the buffer once.
///
/// The empty string is the door's `0`, which every caller here reads as "no answer" — there is no
/// question in this file whose real answer is an empty version.
func sidecarDoorAnswer(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
    let needed = call(nil, 0)
    guard needed > 0 else { return "" }
    var bytes = [UInt8](repeating: 0, count: needed)
    let written = bytes.withUnsafeMutableBufferPointer { out in call(out.baseAddress, out.count) }
    guard written == needed else { return "" }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}
