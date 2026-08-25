import Foundation
import SlopDeskProtocol

/// The shim that actuates ``MetadataVerb/ensureSimulatorServer`` (= 21) against the process-wide
/// ``SimulatorServerManager``. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest`
/// whose verb is 21 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side
/// effects and never sees this verb in production), and forwards every OTHER verb onward.
///
/// **Host-global, not pane-scoped.** One host has one set of simulated devices; the manager is a
/// process-wide singleton like ``HostCodeServerPerformer/sharedManager``.
///
/// **The request payload is EMPTY and that is enforced.** There is nothing to scope, so a payload
/// carrying bytes is a client this host does not understand — answer `.error` rather than ignore
/// it, so a future field cannot be silently dropped by an old host that would then look like it
/// honoured a request it never read.
enum HostSimulatorPerformer {
    /// The production manager singleton (one host → one shared instance).
    static let sharedManager = SimulatorServerManager()

    /// Serves verb 21 — ensure the host's simulator server — and answers its endpoint.
    ///
    /// Nothing to scope, so a payload carrying bytes is a client this host does not understand:
    /// answering `.error` keeps a future field from being silently dropped by an old host that
    /// would then look like it honoured a request it never read. A verb OTHER than 21 is
    /// unreachable — which verbs reach here is ``MetadataAdmission/performer(for:)``'s answer —
    /// and takes the same exit rather than a second opinion about who owns a verb.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: SimulatorServerManager = sharedManager,
    ) -> WireMessage {
        guard MetadataVerb(rawValue: verb) == .ensureSimulatorServer, payload.isEmpty else {
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
