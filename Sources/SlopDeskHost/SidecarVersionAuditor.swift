import Foundation
import SlopDeskScreen
import SlopDeskSupervisor

// SidecarVersionAuditor — the six audits, run together, once.
//
// `rust/slopdesk-sidecars` decides about ONE sidecar from two strings, through the door
// `SidecarVersionReport` calls. This assembles the strings for all of them and carries out the one
// action a stale verdict permits. The split is the same one `SupervisedServiceLifecycle` makes:
// the comparison is pure and tested without a process tree, and everything that touches a live
// daemon lives behind a closure the tests replace.
//
// Where each RUNNING version comes from is not a detail — it is the whole design (`docs/49`):
//
//   superd      `hello`'s `buildVersion`, minor 8. It has a real handshake, so it uses it.
//   screend     the third field of the `hello` reply, after the pinned protocol banner.
//   dropd       ┐ the announce line's `(v…`, because these three outlive hostd and hostd already
//   inspectord  │ re-learns them by replaying superd's ring — the line is the only channel that
//   androidd    ┘ describes a child this hostd did not start.
//
// Every ON-DISK version is `<binary> --version`, field two of line one. One contract, every shipped binary.

/// Runs the per-sidecar version audit and applies the one remedy a stale verdict allows.
public struct SidecarVersionAuditor: Sendable {
    /// One sidecar's two readers and its remedy.
    public struct Subject: Sendable {
        /// The name it ships under in `MANIFEST.json`, which is also the policy table's key.
        public let tool: String
        /// The version of the process that is serving, or `nil` when it is not up or does not say.
        public let running: @Sendable () -> String?
        /// The version of the binary that would be started now, or `nil` when there is none.
        public let installed: @Sendable () -> String?
        /// Restarts it. Only ever called for a ``SidecarRestartPolicy/automatic`` subject, and only
        /// on a stale verdict. `nil` for the ones hostd does not own.
        public let restart: (@Sendable () async -> Void)?

        @preconcurrency
        public init(
            tool: String,
            running: @escaping @Sendable () -> String?,
            installed: @escaping @Sendable () -> String?,
            restart: (@Sendable () async -> Void)? = nil,
        ) {
            self.tool = tool
            self.running = running
            self.installed = installed
            self.restart = restart
        }
    }

    private let subjects: [Subject]

    public init(subjects: [Subject]) {
        self.subjects = subjects
    }

    /// Audits every subject, logs one line each, and restarts the stale ones it is allowed to.
    ///
    /// Returns the reports so a caller can answer a client with them. Order follows `subjects`, so
    /// the log reads the same every run — a report whose order shifts is a report nobody diffs.
    ///
    /// A subject whose restart closure is `nil` is reported and left alone even when the policy is
    /// ``SidecarRestartPolicy/automatic``: the policy says what MAY be done, the closure says what
    /// this caller CAN do, and a manager that never came up has nothing to restart.
    @discardableResult
    public func run(log: (String) -> Void) async -> [SidecarVersionReport] {
        var reports: [SidecarVersionReport] = []
        for subject in subjects {
            let report = SidecarVersionReport(
                tool: subject.tool,
                running: subject.running(),
                onDisk: subject.installed(),
            )
            reports.append(report)
            log("version-audit: \(report.summary)")
            if report.restartable, let restart = subject.restart {
                await restart()
            }
        }
        return reports
    }
}

// Internal, not public: `AndroidServiceManager` is, and the seam hostd's `main.swift` uses is
// ``HostServer/auditSidecarVersions(drops:inspector:inspectorPort:inspectorTranscriptPath:dropPort:dropDirectory:log:)``,
// which is the only caller that has every piece in hand.
extension SidecarVersionAuditor {
    /// The audit hostd runs against its own live sidecars.
    ///
    /// Every reader is best-effort by construction — a daemon that is down reads `nil` and lands in
    /// ``SidecarVersionVerdict/unknown(reason:)``, which is a log line and nothing else. The audit
    /// must never be the thing that takes a host down.
    ///
    /// - Parameters:
    ///   - supervisor: the live superd link; its `hello` already carried the version.
    ///   - screen: the screend client, dialled once for a `hello`.
    ///   - drops/inspector/android: the managers, or `nil` when that path is disabled or failed to
    ///     start — a `nil` manager is simply not audited, because there is nothing running to
    ///     compare against.
    static func forHost(
        supervisor: SupervisorClient,
        screen: ScreenClient = .shared,
        drops: FileDropServiceManager?,
        inspector: InspectorServiceManager?,
        android: AndroidServiceManager?,
        inspectorPort: UInt16?,
        inspectorTranscriptPath: String?,
        dropPort: UInt16?,
        dropDirectory: URL?,
    ) -> SidecarVersionAuditor {
        var subjects: [Subject] = [
            Subject(
                tool: "slopdesk-superd",
                running: { supervisor.superdBuildVersion },
                installed: { installedVersion(of: "slopdesk-superd") },
            ),
            Subject(
                tool: "slopdesk-screend",
                running: { try? screen.buildVersion() },
                installed: { installedVersion(of: "slopdesk-screend") },
            ),
        ]
        if let drops, let dropPort, let dropDirectory {
            subjects.append(Subject(
                tool: "slopdesk-dropd",
                running: { drops.runningVersion },
                installed: { installedVersion(of: "slopdesk-dropd") },
                restart: {
                    // Ends the old one and starts the installed one on the SAME port: the port is
                    // hostd's to choose here, and a client that reconnects must find it unmoved.
                    drops.shutdown()
                    await drops.start(port: dropPort, dropDirectory: dropDirectory)
                },
            ))
        }
        if let inspector, let inspectorPort {
            subjects.append(Subject(
                tool: "slopdesk-inspectord",
                running: { inspector.runningVersion },
                installed: { installedVersion(of: "slopdesk-inspectord") },
                restart: {
                    inspector.shutdown()
                    await inspector.start(port: inspectorPort, transcriptPath: inspectorTranscriptPath)
                },
            ))
        }
        if let android {
            subjects.append(Subject(
                tool: "slopdesk-androidd",
                running: { android.runningVersion },
                installed: { installedVersion(of: "slopdesk-androidd") },
                // No respawn here: androidd's port is the OS's, so ending it is the whole remedy —
                // the next `ensure` round finds it gone and boots the installed binary. Starting a
                // second one here would race that round for the panel's endpoint.
                restart: { android.shutdown() },
            ))
        }
        return SidecarVersionAuditor(subjects: subjects)
    }

    /// The `--version` of the daemon binary this host would start, by the crate's own name.
    ///
    /// Each name carries the override variable its own manager uses, spelled out rather than
    /// derived: `SLOPDESK_<X>_BIN` happens to be the pattern today, and a derivation would go on
    /// quietly resolving to a variable nobody set the day one of them is named differently. Every
    /// path then goes through ``RustServicePaths/locate(_:crate:overrideVariable:environment:fileManager:executable:)``,
    /// the same resolution the spawn uses — the audit must never compare against a binary that is
    /// not the one that would run.
    private static func installedVersion(of name: String) -> String? {
        let overrideVariable: String? =
            switch name {
            case "slopdesk-superd": "SLOPDESK_SUPERD_BIN"
            case "slopdesk-screend": ScreenPaths.binaryEnvKey
            case "slopdesk-dropd": FileDropServiceManager.binaryEnvKey
            case "slopdesk-inspectord": InspectorServiceManager.binaryEnvKey
            case "slopdesk-androidd": AndroidServiceManager.binaryEnvKey
            default: nil
            }
        guard let overrideVariable else { return nil }
        guard let path = RustServicePaths.locate(
            name, crate: name, overrideVariable: overrideVariable,
        ) else { return nil }
        return SidecarVersionAudit.installedVersion(ofBinaryAt: path)
    }
}
