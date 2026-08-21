/// A fully tolerant, `Codable`, `Sendable` JSON value.
///
/// Tool inputs (the `input` of a `tool_use` block) and tool outputs are
/// schema-free — every tool defines its own shape. Rather than model each tool, we
/// keep the input as a `JSONValue` tree so a tool card can render the whole payload
/// and structured consumers (`TodoWrite`, `TaskCreate`) can reach into it by key.
///
/// Decoding never throws on shape: any valid JSON value round-trips. Unknown shapes
/// stay intact (this is the `.passthrough()` behaviour doc 16 asks for).
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            // Should be unreachable for valid JSON; stay tolerant rather than throw.
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: Convenience accessors (nil when the shape doesn't match)

    public subscript(_ key: String) -> Self? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// TRUE/FALSE for a JSON boolean; `nil` for anything else — including the string `"true"`,
    /// which a producer that stringifies its payload would send (tolerated by the callers' `??`
    /// defaults rather than guessed at here).
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [Self]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: Self]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// A human-readable flattening for UI display (text blocks joined, scalars
    /// stringified). Used to render tool input/output compactly.
    ///
    /// ## There is a second flattening, and it answers differently
    ///
    /// `rust/slopdesk-inspectord/src/json.rs`'s `display_string` renders a tool RESULT's content
    /// inside the daemon; this one renders a pending tool's INPUT inside the client. They are the
    /// same visual concept in two processes, they never see the same value, and they do not agree.
    /// That module's own note carries the table of where; the short of it is that the divergence is
    /// in this file's DECODER rather than in either flattening. ``JSONValue/init(from:)`` decodes
    /// every JSON number as a `Double`, so an integer past `2^53` is already gone by the time the
    /// `1e15` guard below reads it, and serde — which keeps the integer types apart — prints the
    /// same input exactly.
    ///
    /// The Rust answer is the better one in every divergent row, and it is not adoptable here
    /// without changing what a `JSONValue` number IS. That type is `Codable` and it is how
    /// `ToolCard.input` arrives over the inspector channel, so this is docs/55 §7 step 6's case and
    /// what is owed is a pin, not a deletion. The tests in `PendingToolSummaryTests` assert this
    /// side of the table; `json.rs`'s own tests assert the other.
    public var displayString: String {
        switch self {
        case .null: return ""
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            // Render integers without a trailing ".0".
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case let .string(value): return value
        case let .array(values): return values.map(\.displayString).joined(separator: "\n")
        case let .object(dict):
            return dict
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: "\n")
        }
    }
}
