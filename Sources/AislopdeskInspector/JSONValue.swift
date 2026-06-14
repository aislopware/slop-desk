import Foundation

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
