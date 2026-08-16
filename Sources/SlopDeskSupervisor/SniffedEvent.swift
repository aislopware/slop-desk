import Foundation

/// Something a pane's shell said OUT OF BAND, found by superd's sniffer in the chunk it rides with.
///
/// ## Why this is a decode and not a parser
/// hostd used to run the OSC state machine itself, over every byte of every pane, on the read-loop
/// thread. It does not any more: superd's pump already holds every byte before anyone else sees one,
/// so the scan happens there, costs no extra copy and no round trip, and hostd receives the ANSWER
/// (`rust/slopdesk-superd/src/sniffer.rs`). What is left here is a decode of a small JSON array that
/// arrives only when a chunk actually contained something.
///
/// ## Deliberately not `WireMessage`
/// The events are what the shell SAID; a wire message is what a client is TOLD. Those are the same
/// thing today for a title and are not for a cwd (host-gated, resolved into a project key) or a
/// notification (dropped while an agent's hook already banners the edge). Keeping the two vocabularies
/// apart is what lets `MuxChannelSession` keep making those decisions in one place.
///
/// ``unknown`` is the version-skew case and the reason this decodes by hand: a newer superd may send
/// a kind this build has no name for, and a throw would take the WHOLE batch — every title and exit
/// code in it — down with the one member it could not read.
public enum SniffedEvent: Sendable, Equatable {
    /// A new window title, already deduplicated against the last one superd emitted for this pane.
    case title(String)
    /// A real terminal bell.
    case bell
    /// A command began executing.
    case commandRunning
    /// The shell returned to a prompt. `exitCode` is `nil` for the code-less `D` mark, which carries
    /// no new truth and must not overwrite a latched one; `durationMS` is superd-measured C→D wall
    /// clock and arrives on every `D`.
    case commandIdle(exitCode: Int32?, durationMS: UInt32)
    /// The shell's working directory, already verified local and percent-decoded.
    case cwd(String)
    /// A desktop notification. `title` is empty when the source gave only a body.
    case notification(title: String, body: String)
    /// The BODY of an OSC 9;4 progress sequence, verbatim after the `9;`.
    ///
    /// Unparsed on purpose, at both ends: the progress vocabulary belongs to `ProgressOSCParser`,
    /// which already owns it, and a second copy of that grammar inside the byte reader is exactly
    /// the drift this port exists to remove. A body that does not parse is dropped here — it was
    /// progress either way, never a notification.
    case progress(String)
    /// A kind this build has no name for. Kept rather than dropped so the batch stays countable and
    /// a skew is visible to a test, never acted on.
    case unknown(kind: String)

    /// One `{"events": [...]}` body, as superd packs it into a `0x04` frame.
    ///
    /// - Returns: `nil` only when the body is not the expected object at all. A member that fails to
    ///   decode becomes ``unknown``, never a thrown batch.
    public static func decodeBatch(_ json: Data) -> [Self]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let members = root["events"] as? [[String: Any]]
        else { return nil }
        return members.map(decodeOne)
    }

    private static func decodeOne(_ member: [String: Any]) -> Self {
        let kind = member["kind"] as? String ?? ""
        switch kind {
        case "title": return .title(member["value"] as? String ?? "")
        case "cwd": return .cwd(member["value"] as? String ?? "")
        case "progress": return .progress(member["value"] as? String ?? "")
        case "bell": return .bell
        case "notification":
            return .notification(
                title: member["title"] as? String ?? "",
                body: member["body"] as? String ?? "",
            )
        case "status":
            guard member["state"] as? String == "idle" else { return .commandRunning }
            // `exitCode` is always present and carries `null` for the code-less `D` — so a missing
            // key and an absent code are the same thing here, which is what `as?` already gives.
            let exitCode = (member["exitCode"] as? Int).flatMap { Int32(exactly: $0) }
            let durationMS = (member["durationMS"] as? Int).flatMap { UInt32(exactly: $0) } ?? 0
            return .commandIdle(exitCode: exitCode, durationMS: durationMS)
        default: return .unknown(kind: kind)
        }
    }
}
