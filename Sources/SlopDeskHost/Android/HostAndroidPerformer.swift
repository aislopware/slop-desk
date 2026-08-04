import Foundation
import SlopDeskProtocol

/// The shim that actuates ``MetadataVerb/ensureAndroidBridge`` (= 22) against the process-wide
/// ``AndroidBridgeManager``. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest` whose
/// verb is 22 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side effects and
/// never sees this verb in production), and forwards every OTHER verb onward.
///
/// Deliberately the same shape as ``HostSimulatorPerformer``: host-global manager singleton, empty
/// request payload enforced rather than ignored, ``MetadataCodec/ServiceEndpoint`` back.
enum HostAndroidPerformer {
    /// The production manager singleton (one host → one `adb` server → one bridge).
    static let sharedManager = AndroidBridgeManager()

    /// Routes one `metadataRequest`. Returns the `metadataResponse` when `verb` is 22; `nil` for
    /// EVERY other verb (incl. an unknown future byte) so the caller falls through unchanged.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: AndroidBridgeManager = sharedManager,
    ) -> WireMessage? {
        guard MetadataVerb(rawValue: verb) == .ensureAndroidBridge else { return nil }
        // Nothing to scope, so a payload carrying bytes is a client this host does not understand.
        // Answering `.error` keeps a future field from being silently dropped by an old host that
        // would then look like it honoured a request it never read.
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
