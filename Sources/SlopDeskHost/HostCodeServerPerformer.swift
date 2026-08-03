import Foundation
import SlopDeskProtocol

/// The shim that actuates the two embedded-VS Code verbs against the process-wide
/// ``CodeServerManager``: ``MetadataVerb/ensureCodeServer`` (= 18) and
/// ``MetadataVerb/openInCodeServer`` (= 19). ``MuxChannelSession/serveMetadata`` routes a
/// `metadataRequest` whose verb is 18/19 HERE (BEFORE the pure ``MetadataResponseBuilder``, which
/// performs NO side effects and never sees these verbs in production), and forwards every OTHER
/// verb onward.
///
/// **Host-global, not pane-scoped.** The ONE shared code-server serves every project, pane and
/// client — the manager is a process-wide singleton, exactly like ``HostClipboardPerformer``'s
/// pasteboard state.
///
/// **Validate-then-drop.** A non-UTF-8 / empty / relative payload maps to ``MetadataStatus/error``;
/// a path that does not exist on the host maps to ``MetadataStatus/notFound``; a valid ensure
/// ALWAYS answers `.ok` with a ``MetadataCodec/CodeServerEndpoint`` (whose state may be
/// `unavailable` — "no binary" is an answer, not a failure). Never a trap; the host always replies.
enum HostCodeServerPerformer {
    /// The production manager singleton (one host → one shared instance).
    static let sharedManager = CodeServerManager()

    /// Opens a path host-side in its default app — the verb-19 FALLBACK for a directory / a host
    /// without code-server. A seam (defaulting to the verb-9 actuator) so unit tests never touch
    /// `NSWorkspace` (hang-safety: it needs a window server + Launch Services session).
    typealias FallbackOpener = @Sendable (String) -> MetadataStatus

    #if os(macOS)
    static let defaultFallbackOpener: FallbackOpener = HostPathActionPerformer.openInDefaultApp(path:)
    #else
    static let defaultFallbackOpener: FallbackOpener = { _ in .error }
    #endif

    /// Routes one `metadataRequest`. Returns the `metadataResponse` when `verb` is 18 or 19; `nil`
    /// for EVERY other verb (incl. an unknown future byte) so the caller falls through to the
    /// read-only ``MetadataResponseBuilder`` unchanged.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        manager: CodeServerManager = sharedManager,
        fallbackOpen: FallbackOpener = defaultFallbackOpener,
    ) -> WireMessage? {
        switch MetadataVerb(rawValue: verb) {
        case .ensureCodeServer:
            ensureResponse(requestID: requestID, payload: payload, manager: manager)
        case .openInCodeServer:
            openResponse(
                requestID: requestID, payload: payload, manager: manager, fallbackOpen: fallbackOpen,
            )
        case .syncCodeFont:
            syncFontResponse(requestID: requestID, payload: payload, manager: manager)
        default:
            nil // not an embedded-editor verb → caller uses the read-only builder
        }
    }

    /// Verb 20: fold the client's terminal-font spec into the shared workbench settings. The
    /// decoder is the validator (range-checked, validate-then-drop — these values land in a file
    /// the workbench trusts); a spec that decodes always answers `.ok`, whether or not the file
    /// needed a write (already-in-sync is success, not failure).
    private static func syncFontResponse(
        requestID: UInt32, payload: Data, manager: CodeServerManager,
    ) -> WireMessage {
        guard let spec = try? MetadataCodec.decodeCodeFontSpec(payload) else {
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )
        }
        manager.syncEditorFont(spec)
        return .metadataResponse(
            requestID: requestID, status: MetadataStatus.ok.rawValue, payload: Data(),
        )
    }

    private static func ensureResponse(
        requestID: UInt32, payload: Data, manager: CodeServerManager,
    ) -> WireMessage {
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

    /// Verb 19: validate the target, then route — a FILE with code-server present goes to the
    /// workbench (`code-server -r`, retried async; the reply is ACCEPTED, not completed — the
    /// metadata queue must never sit out a workbench boot); a directory, or a binary-less host,
    /// falls back to the default-app open. The 1-byte reply payload tells the client which.
    private static func openResponse(
        requestID: UInt32, payload: Data, manager: CodeServerManager, fallbackOpen: FallbackOpener,
    ) -> WireMessage {
        func reply(_ status: MetadataStatus, _ payload: Data = Data()) -> WireMessage {
            .metadataResponse(requestID: requestID, status: status.rawValue, payload: payload)
        }
        guard let raw = String(data: payload, encoding: .utf8), !raw.isEmpty else {
            return reply(.error)
        }
        let (pathPart, suffix) = splitLineColSuffix(raw)
        // swiftlint:disable:next legacy_objc_type
        let expanded = ((pathPart as NSString).expandingTildeInPath as NSString).standardizingPath
        guard expanded.hasPrefix("/") else { return reply(.error) } // relative → malformed
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return reply(.notFound)
        }
        let workbenchDisposition = MetadataCodec.encodeCodeOpenDisposition(.workbench)
        let hostDisposition = MetadataCodec.encodeCodeOpenDisposition(.hostDefault)
        if isDirectory.boolValue {
            return reply(fallbackOpen(expanded), hostDisposition)
        }
        let projectRoot = (expanded as NSString).deletingLastPathComponent // swiftlint:disable:this legacy_objc_type
        guard manager.openInWorkbench(target: expanded + suffix, projectRoot: projectRoot) != nil else {
            // No code-server on the host — the file still opens, just in the host's default app.
            return reply(fallbackOpen(expanded), hostDisposition)
        }
        return reply(.ok, workbenchDisposition)
    }

    /// Splits a trailing `:line[:col]` numeric suffix off `target` (at most two colon-number runs,
    /// leading colon kept in the suffix) — the existence check needs the bare path while the
    /// workbench CLI wants the full `path:line:col`. Mirrors the client detector's splitter.
    static func splitLineColSuffix(_ target: String) -> (path: String, suffix: String) {
        let chars = Array(target)
        func runStart(endingAt end: Int) -> Int? {
            var index = end
            var sawDigit = false
            while index > 0, chars[index - 1].isASCII, chars[index - 1].isNumber {
                index -= 1
                sawDigit = true
            }
            if sawDigit, index > 0, chars[index - 1] == ":" { return index - 1 }
            return nil
        }
        guard let colStart = runStart(endingAt: chars.count) else { return (target, "") }
        if let lineStart = runStart(endingAt: colStart) {
            return (String(chars[0..<lineStart]), String(chars[lineStart...]))
        }
        return (String(chars[0..<colStart]), String(chars[colStart...]))
    }
}
