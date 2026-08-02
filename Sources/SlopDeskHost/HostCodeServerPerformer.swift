import Foundation
import SlopDeskProtocol

/// The shim that actuates ``MetadataVerb/ensureCodeServer`` (= 18) against the process-wide
/// ``CodeServerManager``. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest` whose verb
/// is 18 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side effects and never
/// sees this verb in production), and forwards every OTHER verb onward.
///
/// **Host-global, not pane-scoped.** One code-server per project serves every pane and every client
/// of that project — the manager is a process-wide singleton, keyed by project root, exactly like
/// ``HostClipboardPerformer``'s pasteboard state.
///
/// **Validate-then-drop.** A non-UTF-8 / empty / relative payload maps to ``MetadataStatus/error``;
/// a root that is not an existing host directory maps to ``MetadataStatus/notFound``; a valid root
/// ALWAYS answers `.ok` with a ``MetadataCodec/CodeServerEndpoint`` (whose state may be
/// `unavailable` — "no binary" is an answer, not a failure). Never a trap; the host always replies.
enum HostCodeServerPerformer {
    /// The production manager singleton (one host → one instance table).
    static let sharedManager = CodeServerManager()

    /// Routes one `metadataRequest`. Returns the `metadataResponse` when `verb` is
    /// ``MetadataVerb/ensureCodeServer``; `nil` for EVERY other verb (incl. an unknown future byte)
    /// so the caller falls through to the read-only ``MetadataResponseBuilder`` unchanged.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: CodeServerManager = sharedManager,
    ) -> WireMessage? {
        guard MetadataVerb(rawValue: verb) == .ensureCodeServer else { return nil }
        guard let root = String(data: payload, encoding: .utf8), root.hasPrefix("/") else {
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )
        }
        guard let endpoint = manager.ensure(projectRoot: root) else {
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.notFound.rawValue, payload: Data(),
            )
        }
        return .metadataResponse(
            requestID: requestID, status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeCodeServerEndpoint(endpoint),
        )
    }
}
