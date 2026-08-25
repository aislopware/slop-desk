import Foundation
import SlopDeskProtocol

/// The shim that actuates ``MetadataVerb/ensureAndroidBridge`` (= 22) against the process-wide
/// ``AndroidServiceManager``. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest` whose
/// verb is 22 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side effects and
/// never sees this verb in production), and forwards every OTHER verb onward.
///
/// Deliberately the same shape as ``HostSimulatorPerformer``: host-global manager singleton, empty
/// request payload enforced rather than ignored, ``MetadataCodec/ServiceEndpoint`` back.
enum HostAndroidPerformer {
    /// The production manager singleton (one host → one `adb` server → one bridge daemon).
    static let sharedManager = AndroidServiceManager()

    /// Serves verb 22 — ensure the host's Android bridge — and answers its endpoint.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: AndroidServiceManager = sharedManager,
    ) -> WireMessage {
        // Nothing to scope, so a payload carrying bytes is a client this host does not understand.
        // Answering `.error` keeps a future field from being silently dropped by an old host that
        // would then look like it honoured a request it never read. A verb OTHER than 22 is
        // unreachable — which verbs reach here is ``MetadataAdmission/performer(for:)``'s answer —
        // and takes the same exit rather than a second opinion about who owns a verb.
        guard MetadataVerb(rawValue: verb) == .ensureAndroidBridge, payload.isEmpty else {
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
