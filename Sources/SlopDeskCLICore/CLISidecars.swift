import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// `slopdesk sidecars` — what an upgrade changed, tool by tool.
//
// The other half of the mechanism `SidecarVersionAudit` is (`docs/49`). That one asks LIVE daemons
// what they are running, at hostd's start. This one asks two FILES, right after an install, and the
// difference is not a preference: `brew upgrade` runs while every daemon is still serving the old
// binaries, so a live audit at that moment reports every one of them as stale whether one changed or twelve.
//
// The manifest that just landed, against the one recorded after the previous install, is exactly
// the set this upgrade touched — and it is knowable before anything is dialled, spawned or ended.
//
// The DIFF is `rust/slopdesk-sidecars`, behind `slopdesk_sidecar_upgrade_plan`, and so is the
// policy that decides what each change means. This file is the two paths and the file I/O.

/// The install-side reader: where the manifests are, and what changed between them.
public enum CLISidecars {
    /// Points at the `MANIFEST.json` this install shipped. Set it and neither guess below is made.
    public static let manifestEnvKey = "SLOPDESK_MANIFEST"

    /// The name the recorded copy is kept under, inside the Application Support container.
    ///
    /// Recorded rather than derived: Homebrew replaces the Cellar directory wholesale, so the
    /// previous release's `MANIFEST.json` is GONE by the time anything could read it. A copy in the
    /// user's container is the only place the previous answer can survive the thing it describes.
    public static let recordName = "sidecars-manifest.json"

    /// The manifest belonging to the binaries this process was launched from.
    ///
    /// Three places, in order, and every one of them is a layout that actually ships:
    /// 1. `SLOPDESK_MANIFEST`, for a test and for an install that puts it somewhere else entirely;
    /// 2. beside the binary — the release TARBALL's layout, where `MANIFEST.json` travels inside
    ///    `slopdesk-cli-<version>-arm64/` next to the twelve tools;
    /// 3. one directory up — Homebrew's, where the tools are in `#{prefix}/bin` and the manifest is
    ///    the formula's `prefix.install`.
    ///
    /// `argv0` is resolved through its symlinks first, because Homebrew's `bin` is a farm of links
    /// into the Cellar and the unresolved path's parent has no manifest under it.
    public static func installedManifestURL(
        argv0: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        if let override = environment[manifestEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard !argv0.isEmpty else { return nil }
        let binary = URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
        let directory = binary.deletingLastPathComponent()
        for candidate in [
            directory.appendingPathComponent("MANIFEST.json"),
            directory.deletingLastPathComponent().appendingPathComponent("MANIFEST.json"),
        ] where fileManager.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// The copy recorded by the last run of `slopdesk sidecars --record`.
    ///
    /// `nil` only when Application Support cannot be resolved, which does not happen on macOS. It
    /// honours `SLOPDESK_APP_SUPPORT_DIR` like everything else in the container, so a test never
    /// writes over the developer's real record.
    public static func recordedManifestURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        SlopDeskAppSupport.directory(environment: environment, fileManager: fileManager)?
            .appendingPathComponent(recordName, isDirectory: false)
    }

    /// The plan, as the door's JSON text. Empty when `current` is not a readable manifest.
    ///
    /// A `previous` of `nil` is a first install: every tool reads `added`, which is right rather
    /// than a special case, because nothing was running for the upgrade to have replaced.
    public static func plan(previous: String?, current: String) -> String {
        let previousBytes = [UInt8]((previous ?? "").utf8)
        let currentBytes = [UInt8](current.utf8)
        return previousBytes.withUnsafeBufferPointer { before in
            currentBytes.withUnsafeBufferPointer { now in
                CLICompletions.answer { out, cap in
                    slopdesk_sidecar_upgrade_plan(
                        before.baseAddress, before.count, now.baseAddress, now.count, out, cap,
                    )
                }
            }
        }
    }

    /// Records `text` as the baseline the NEXT upgrade is diffed against.
    ///
    /// Written whole rather than appended, and the container is created if it is not there — this
    /// runs from a formula's `post_install`, which is the one moment the container may not exist
    /// yet on a first install.
    ///
    /// - Throws: whatever `FileManager`/`Data` throws; the caller reports it rather than trapping,
    ///   because a record that could not be written costs one upgrade's worth of detail and nothing
    ///   else — the plan is still correct, it just reads as a first install next time.
    public static func record(
        _ text: String,
        to url: URL,
        fileManager: FileManager = .default,
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
