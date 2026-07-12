#if os(macOS)
import AppKit
import Foundation
import SlopDeskProtocol

/// The THIN macOS shim that actuates the TWO side-effecting metadata verbs (``MetadataVerb/openPath``
/// = 9 / ``MetadataVerb/revealPath`` = 10) on the HOST's own Finder / Launch Services. It is the
/// open/reveal twin of the read-only ``HostMetadataProbe``: ``MuxChannelSession/serveMetadata`` routes a
/// `metadataRequest` whose verb is 9/10 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs
/// NO side effects and never sees these verbs in production), and forwards every OTHER verb to the
/// builder. Like ``HostMetadataProbe`` it is **compiled + code-reviewed ONLY** — never instantiated in a
/// unit test (`NSWorkspace` needs a window-server + Launch Services session; the hang-safety rule). The
/// CLIENT routing (verb 9/10 encode + ok/notFound/error decode) is the unit-tested half (`MetadataClient`
/// + `PathActionRoutingTests`).
///
/// **No exfiltration → no cwd confinement.** Unlike the read verbs (`gitDiff`/`listDirectory`/
/// `readAgentSession`), which are confined to the pane cwd subtree because they stream host file CONTENTS
/// back over the wire, open/reveal return ONLY a status byte + empty payload — no host bytes ever cross
/// the wire. So they accept any ABSOLUTE host path (⌘click ANY detected path, not
/// just one under the cwd). The security boundary is the trusted WireGuard mesh (no app-layer crypto);
/// the path is still validated defensively (see below).
///
/// **Validate-then-drop everywhere.** An invalid-UTF-8 / empty / relative argument → ``MetadataStatus/error``;
/// a well-formed absolute path that does not exist → ``MetadataStatus/notFound``; an `NSWorkspace.open`
/// that returns `false` → ``MetadataStatus/error``; otherwise ``MetadataStatus/ok``. NEVER force-unwraps,
/// NEVER traps on a hostile argument. The host ALWAYS replies for 9/10 so the client's pending-request
/// registry never hangs.
///
/// `#if os(macOS)` — `AppKit`/`NSWorkspace` is unavailable on iOS; it is NEVER compiled into the iOS slice
/// (the iOS client routes open/reveal TO the host over this same wire, it never performs them locally).
enum HostPathActionPerformer {
    /// Routes one `metadataRequest`. If `verb` is a side-effecting path verb (9/10), actuates it on the
    /// host and returns the `metadataResponse` (empty payload + status). Returns `nil` for EVERY other
    /// verb (incl. an unknown future byte) so the caller falls through to the read-only
    /// ``MetadataResponseBuilder`` unchanged — keeping this shim's responsibility to ONLY the two
    /// side-effecting verbs.
    static func response(requestID: UInt32, verb: UInt8, payload: Data) -> WireMessage? {
        let action: (String) -> MetadataStatus
        switch MetadataVerb(rawValue: verb) {
        case .openPath: action = openInDefaultApp(path:)
        case .revealPath: action = revealInFinder(path:)
        default: return nil // not a side-effecting path verb → caller uses the read-only builder
        }
        // A non-UTF-8 argument is a malformed request → .error (validate-then-drop, never a trap).
        let status = String(data: payload, encoding: .utf8).map(action) ?? .error
        return .metadataResponse(requestID: requestID, status: status.rawValue, payload: Data())
    }

    /// Opens `path` in its default app / Finder (`NSWorkspace.open`). `.error` for an empty/relative
    /// argument, `.notFound` for a missing absolute path, `.error` if the open returns `false`, else `.ok`.
    /// (Named `openInDefaultApp`, NOT `open`: a fn literally named `open` trips a SwiftFormat bug that
    /// deletes statements — repo strict-tooling trap.)
    static func openInDefaultApp(path: String) -> MetadataStatus {
        switch resolveExisting(path) {
        case let .failure(status): status
        case let .success(url): NSWorkspace.shared.open(url) ? .ok : .error
        }
    }

    /// Reveals `path` in the host's Finder (`NSWorkspace.activateFileViewerSelecting`). `.error` for an
    /// empty/relative argument, `.notFound` for a missing absolute path, else `.ok` (the call is void —
    /// success is the existence check passing + the reveal being issued).
    static func revealInFinder(path: String) -> MetadataStatus {
        switch resolveExisting(path) {
        case let .failure(status): return status
        case let .success(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .ok
        }
    }

    /// The outcome of resolving a request path: the existing file-URL, or the ``MetadataStatus`` to reply.
    /// A bespoke result enum (NOT `Result<URL, MetadataStatus>`) because `MetadataStatus` is a wire status
    /// byte, not an `Error` — `Result`'s `Failure` must conform to `Error`, which this deliberately is not.
    private enum ResolvedPath {
        case success(URL)
        case failure(MetadataStatus)
    }

    /// Validates a request path argument into an existing file-URL, or the status to reply on failure.
    /// Expands a leading `~` against the HOST's home (the correct home for a host-side open), then
    /// requires an ABSOLUTE path (empty/relative → `.error`) and confirms it exists (`.notFound` if not).
    private static func resolveExisting(_ path: String) -> ResolvedPath {
        // swiftlint:disable:next legacy_objc_type
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(.error) } // empty or relative → malformed
        // swiftlint:disable:next legacy_objc_type
        let standardized = (expanded as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardized) else { return .failure(.notFound) }
        return .success(URL(fileURLWithPath: standardized))
    }
}
#endif
