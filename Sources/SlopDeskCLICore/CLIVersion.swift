import Foundation
import SlopDeskProtocol

// `slopdesk version` — prints the marketing version, an optional build hash, and a brief
// protocol/feature summary. PURE: ``versionSummary(environment:)`` takes its environment as a
// parameter (defaulting to the process environment) so the build-hash branch is unit-testable
// without mutating real env. No socket — `version` is a local op.

public enum CLIVersion {
    /// The marketing version string. Kept in step with the app target's `MARKETING_VERSION`
    /// (`Apps/ClientApp-macOS/project.yml`).
    public static let version = "0.1.0"

    /// Env var carrying an optional short build/commit hash, injected by the release pipeline.
    /// Absent in a plain `swift build`, so the summary simply omits the build parenthetical.
    public static let buildHashEnvKey = "SLOPDESK_BUILD_HASH"

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
        var head = "slopdesk \(version)"
        if let hash = environment[buildHashEnvKey], !hash.isEmpty {
            head += " (\(hash))"
        }
        let proto = "terminal protocol v\(SlopDesk.protocolVersion)"
        let features = "remote-terminal · gui-video · read-only-inspector"
        return """
        \(head)
        \(proto)
        \(features)
        """
    }
}
