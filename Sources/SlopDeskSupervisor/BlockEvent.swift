import Foundation

/// One thing superd's command-block tap found in the chunk this event rides with.
///
/// ## Why this is a decode and not a segmenter
/// hostd used to run the OSC 133 state machine itself, over every byte of every pane, on the
/// read-loop thread, and to hold every finished command's captured output in its own address space.
/// It does neither now. superd's pump already has the bytes before anyone else sees one, so the
/// segmenting happens there, and the retained output lives there too — which is what stops the
/// Commands panel going blank across the 0.2 s of a `make host-restart`
/// (`rust/slopdesk-superd/src/blocks.rs`, `docs/51` §6.14).
///
/// ## Deliberately not `WireMessage`
/// Same boundary ``SniffedEvent`` keeps: these are what the SHELL did, and a wire message is what a
/// client is TOLD. ``progress(_:)`` in particular is a decision superd made about a slow command,
/// which hostd still has to turn into the type-32 the protocol spells — superd does not know the
/// protocol and must not learn it.
///
/// ``unknown(kind:)`` is the version-skew case, and the reason the decode below is written by hand:
/// a kind a NEWER superd knows must not take the whole batch — every exit code and command line in
/// it — down with the one member this build cannot read.
public enum BlockEvent: Sendable, Equatable {
    /// A block was created, changed, or finished. Already deduped by superd: a running command that
    /// prints steadily is reported once, not once per chunk.
    case block(BlockMetadata)
    /// A synthetic progress badge for a configured slow command should go up, or come down.
    case progress(SyntheticProgress)
    /// A kind this build has no name for. Kept rather than dropped so the batch stays countable and
    /// a skew is visible to a test, never acted on.
    case unknown(kind: String)

    /// One `{"blocks": [...]}` body, as superd packs it into a `0x05` frame.
    ///
    /// - Returns: `nil` only when the body is not the expected object at all. A member that fails to
    ///   decode becomes ``unknown(kind:)``, never a thrown batch.
    public static func decodeBatch(_ json: Data) -> [Self]? {
        try? JSONDecoder().decode(BlockBatch.self, from: json).blocks
    }
}

/// The `{"blocks": [...]}` envelope, so the array's element decode is the one below.
private struct BlockBatch: Decodable {
    var blocks: [BlockEvent]
}

extension BlockEvent: Decodable {
    private enum Tag: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let kind = try? decoder.container(keyedBy: Tag.self).decode(String.self, forKey: .kind)
        switch kind {
        case "block": self = try .block(BlockMetadata(from: decoder))
        case "progress":
            // A badge state a NEWER superd knows stays visible as a skew rather than being guessed
            // at: guessing `clear` for an unknown state would take down a spinner that should be up,
            // and guessing the other way would leave one up forever.
            let state = try? SyntheticProgressEnvelope(from: decoder).state
            self = state.map(Self.progress) ?? .unknown(kind: "progress")
        default: self = .unknown(kind: kind ?? "")
        }
    }
}

/// The `state` key alone, so an unknown value fails HERE rather than failing the batch.
private struct SyntheticProgressEnvelope: Decodable {
    var state: SyntheticProgress
}

/// What superd decided a configured slow command's badge should do.
///
/// The two states the auto-progress feature has, and no more: it never reports a percentage,
/// because it does not know one — which is precisely what an indeterminate badge is for.
public enum SyntheticProgress: String, Sendable, Equatable, Decodable {
    /// A slow command started; show an indeterminate spinner.
    case indeterminate
    /// Its block closed; take the spinner down.
    case clear
}

/// The wire-relevant facts about one command block.
///
/// A value type with no behaviour on purpose: every judgement about it — whether it is worth an
/// emit, when its output ages out — was made by superd's tap before this crossed the socket.
///
/// `exitCode` and `durationMS` are optional in the same sense superd writes them: always PRESENT,
/// carrying `null` when there is no value, so a missing key and an absent one are never told apart
/// by which build wrote the frame.
public struct BlockMetadata: Sendable, Equatable, Decodable {
    /// The block's index in emission order over the pane's life.
    public var index: UInt32
    /// The command's `$?`, or `nil` when the shell reported none.
    public var exitCode: Int32?
    /// The measured `C`→`D` milliseconds, `nil` while the command is still running.
    public var durationMS: UInt32?
    /// Whether the matching `D` mark has arrived.
    public var complete: Bool
    /// How many output bytes superd holds for this block.
    public var outputLen: UInt32
    /// The typed command line.
    public var commandText: String
    /// The block's prompt-row ordinal, `0` when unknown.
    public var promptOrdinal: UInt32

    public init(
        index: UInt32,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
        complete: Bool = false,
        outputLen: UInt32 = 0,
        commandText: String = "",
        promptOrdinal: UInt32 = 0,
    ) {
        self.index = index
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.complete = complete
        self.outputLen = outputLen
        self.commandText = commandText
        self.promptOrdinal = promptOrdinal
    }
}

/// One finished block joined with its retained output — what the agent-control verbs read.
public struct BlockRecord: Sendable, Equatable, Decodable {
    /// The block's index.
    public var index: UInt32
    /// The typed command line.
    public var commandText: String
    /// The command's `$?`, when the shell reported one.
    public var exitCode: Int32?
    /// The measured `C`→`D` milliseconds.
    public var durationMS: UInt32?
    /// Whether the block closed on its own `D` rather than on a fresh prompt.
    public var complete: Bool
    /// The retained output bytes.
    ///
    /// Base64 on the wire, because this is a fetch a person asked for — a click on a block, or a ctl
    /// `last-output` — rather than a stream. superd caps one block at 256 KiB, so the encoded worst
    /// case sits an order of magnitude under the frame ceiling.
    public var output: [UInt8]

    private enum Key: String, CodingKey {
        case index
        case commandText
        case exitCode
        case durationMS
        case complete
        case output
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        index = try values.decodeIfPresent(UInt32.self, forKey: .index) ?? 0
        commandText = try values.decodeIfPresent(String.self, forKey: .commandText) ?? ""
        exitCode = try values.decodeIfPresent(Int32.self, forKey: .exitCode)
        durationMS = try values.decodeIfPresent(UInt32.self, forKey: .durationMS)
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        let encoded = try values.decodeIfPresent(String.self, forKey: .output) ?? ""
        // Validate-then-drop: bytes that will not decode would be a transcript that silently lies,
        // so an unusable body becomes an empty one rather than a guess at what was meant.
        output = [UInt8](Data(base64Encoded: encoded) ?? Data())
    }
}

/// The running command, as much of it as any caller has ever wanted.
///
/// Its command line and how much it has printed, never its bytes: a `last-output` call while
/// `tail -f` is running would otherwise ship a quarter of a megabyte to answer a question about the
/// commands BEFORE it.
public struct OpenBlock: Sendable, Equatable, Decodable {
    /// The typed command line.
    public var commandText: String
    /// How many output bytes it has produced so far.
    public var outputLen: UInt32
}

/// What a block-reading verb answers with.
///
/// Every field is optional because the three verbs fill different ones. The whole object being
/// absent is itself an answer, and a distinct one: it means the pane has no tap — blocks are off —
/// which a caller reports differently from "this pane has run nothing yet".
public struct BlocksReply: Sendable, Equatable, Decodable {
    /// `blockOutput`: the retained bytes, base64. Absent for an evicted or unknown index.
    public var output: String?
    /// `blockSnapshot`: every block still known, ascending.
    public var snapshot: [BlockMetadata]?
    /// `blockControl`: the last N finished blocks, oldest first, with their bytes.
    public var recent: [BlockRecord]?
    /// `blockControl`: the block still running, if one is.
    public var open: OpenBlock?
    /// `blockControl`: the index the next command typed at this prompt will close under.
    public var nextIndex: UInt32?

    /// The retained bytes of a `blockOutput` reply, decoded. Empty for an evicted index.
    public var outputBytes: [UInt8] {
        [UInt8](output.flatMap { Data(base64Encoded: $0) } ?? Data())
    }
}
