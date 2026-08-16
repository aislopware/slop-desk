import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

// `slopdesk version` — the Swift face of `rust/slopdesk-cli`'s `version`. The banner's SHAPE and
// the build-hash branch are the crate's; the version NUMBER stays here on purpose. `docs/49` names
// six version sites and `bump-version.sh` owns all six because no gate can see most of them — a
// seventh, in Rust, would be one the bump script does not know about and `package-release.sh`
// would not catch, because that gate asks the built CLI binary. So the number is passed in.

public enum CLIVersion {
    /// The marketing version string. Kept in step with the app target's `MARKETING_VERSION`
    /// (`Apps/ClientApp-macOS/project.yml`).
    public static let version = "0.4.0"

    /// Env var carrying an optional short build/commit hash, injected by the release pipeline.
    /// Absent in a plain `swift build`, so the summary simply omits the build parenthetical.
    public static let buildHashEnvKey = CLICompletions
        .answer { out, cap in slopdesk_cli_build_hash_env_key(out, cap) }

    /// Builds the multi-line `version` output:
    /// ```
    /// slopdesk <version>[ (<hash>)]
    /// terminal protocol v<N>
    /// <feature summary>
    /// ```
    /// - Parameter environment: the env to read the build hash from (defaults to the process env).
    public static func versionSummary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        let number = Array(version.utf8)
        let hash = Array((environment[buildHashEnvKey] ?? "").utf8)
        return number.withUnsafeBufferPointer { version in
            hash.withUnsafeBufferPointer { build in
                CLICompletions.answer { out, cap in
                    slopdesk_cli_version_summary(
                        version.baseAddress, version.count, build.baseAddress, build.count,
                        UInt16(clamping: SlopDesk.protocolVersion), out, cap,
                    )
                }
            }
        }
    }
}
