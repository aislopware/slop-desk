import Foundation
import SlopDeskProtocol

/// The shim that actuates ``MetadataVerb/ensureWebBrowser`` (= 23) against the process-wide
/// ``WebBrowserManager``. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest` whose verb
/// is 23 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side effects and
/// never sees this verb in production), and forwards every OTHER verb onward.
///
/// **Host-global, not pane-scoped**, for verb 21's reason: one host, one browser, one shared set of
/// tabs — so ``WebBrowserManager`` is a process-wide singleton like
/// ``HostSimulatorPerformer/sharedManager``.
///
/// **The request payload is EMPTY and that is enforced**, again for verb 21's reason: there is
/// nothing to scope, so bytes mean a client this host does not understand, and answering `.error`
/// beats silently dropping a field the client believes was honoured.
enum HostWebPerformer {
    /// The production manager singleton (one host → one browser).
    static let sharedManager = WebBrowserManager()

    /// Routes one `metadataRequest`. Returns the `metadataResponse` when `verb` is 23; `nil` for
    /// EVERY other verb (incl. an unknown future byte) so the caller falls through unchanged.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: WebBrowserManager = sharedManager,
    ) -> WireMessage? {
        guard MetadataVerb(rawValue: verb) == .ensureWebBrowser else { return nil }
        guard payload.isEmpty else {
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )
        }
        return .metadataResponse(
            requestID: requestID, status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeServiceEndpoint(manager.ensure()),
        )
    }
}
