import CSlopDeskFFI
import Foundation

// MARK: - SessionTemplateCrossing (the template layout, over the C boundary and back)

/// The one place a ``TemplateNode`` becomes bytes `rust/slopdesk-workspace` can read.
///
/// **The REPAIR here is not the shipping path; the two TABLES are.** The distinction is the whole
/// point of this file, and it took a second reading to get right.
///
/// Every other port in `docs/55` deleted its Swift original in the same change, so the door became
/// the only implementation. ``TemplateNode/repaired`` could not: ``SessionTemplate`` is `Codable`
/// and is the currency of the device-preferences file, so ``TemplateNode/init(from:)`` is how a
/// person's saved layouts actually come back, and deleting it would delete the store's ability to
/// read its own file. `docs/55` §7 step 6 names exactly that case and says what is owed instead —
/// **pin it**: same inputs to both sides, assert the same output.
/// `SessionTemplateRepairDifferentialTests` is that pin and ``repairedByTheCrate(_:)`` is what it
/// drives the far side through.
///
/// ``builtInTemplatesFromTheCrate()`` and ``builtInLaunchPresetsFromTheCrate()`` were built for that
/// same pin and then read the same way, which was the error: what `Codable` forces to stay Swift is
/// the TYPE, and a table of three shipped rows is not a type. Since 2026-08-22 they ARE
/// ``SessionTemplate/builtIns`` and ``LaunchPreset/builtIns`` — the seed a fresh device gets — and
/// the Swift literals they used to be compared against are deleted. A `nil` from either is this
/// file disagreeing with the grammar below, never the crate declining to ship a table.
///
/// So nothing here decides anything. It encodes, calls, and decodes, against the grammar written
/// down once in `rust/slopdesk-ffi/include/slopdesk_ffi.h` and once in the module that answers it —
/// and the two encoders were written against THAT PARAGRAPH rather than against each other, because
/// a codec whose only proof is its own round trip agrees with itself however both halves are wrong.
///
/// ```text
/// text     := u32 BE length, then that many UTF-8 bytes
/// opt-text := u8 present (0 or 1), then text when present
/// uuid     := 16 bytes, canonical UUID order
/// node     := 0x00 u8:kind text:title opt-text:cwd opt-text:command      -- a pane
///           | 0x01 u8:axis u32:child_count  node × child_count           -- a split, visual order
/// template := uuid:id text:name text:symbol u8:is_built_in node:layout
/// preset   := uuid:id text:name text:command opt-text:working_directory
///             u8:has_split [u8:axis text:secondary_command when has_split]
///             text:symbol u8:is_built_in
/// table    := u32 BE count, then that many records
/// ```
///
/// A stream that cannot be consumed EXACTLY reads as `nil` on both sides — never as a layout with a
/// field guessed at, because a guess would be a repair this side invented, and inventing repairs on
/// the near side is the drift the whole exercise exists to make visible.
enum SessionTemplateCrossing {
    /// A leaf node's tag.
    private static let tagPane: UInt8 = 0
    /// A partition node's tag.
    private static let tagSplit: UInt8 = 1

    // MARK: Writing

    /// One layout as the pre-order stream above.
    static func encode(_ node: TemplateNode) -> [UInt8] {
        var out: [UInt8] = []
        append(node, to: &out)
        return out
    }

    private static func append(_ node: TemplateNode, to out: inout [UInt8]) {
        switch node {
        case let .pane(pane):
            out.append(tagPane)
            out.append(WorkspacePaneKindTag.byte(for: pane.kind))
            append(text: pane.title, to: &out)
            append(optionalText: pane.cwd, to: &out)
            append(optionalText: pane.command, to: &out)
        case let .split(axis, children):
            out.append(tagSplit)
            // The axis byte is `SplitLayoutSolver`'s, spelled the same way it is there: the crate's
            // `SplitAxis::from_byte` reads any non-zero as vertical, so there is no third value for
            // this to get wrong.
            out.append(axis == .vertical ? 1 : 0)
            append(length: children.count, to: &out)
            for child in children { append(child, to: &out) }
        }
    }

    private static func append(text: String, to out: inout [UInt8]) {
        let bytes = Array(text.utf8)
        append(length: bytes.count, to: &out)
        out.append(contentsOf: bytes)
    }

    /// A presence byte, and the string behind it when there is one.
    ///
    /// An absent value and an empty one are DIFFERENT answers here. Both reach
    /// ``LaunchPresetEngine/keystrokes(command:cwd:)`` as "no directory", so nothing downstream can
    /// tell them apart — but the repair copies the value through untouched, and an encoding that
    /// flattened the two would leave this suite unable to see the day one side started rewriting
    /// one into the other.
    private static func append(optionalText: String?, to out: inout [UInt8]) {
        guard let optionalText else {
            out.append(0)
            return
        }
        out.append(1)
        append(text: optionalText, to: &out)
    }

    private static func append(length: Int, to out: inout [UInt8]) {
        let word = UInt32(clamping: length)
        out.append(UInt8(truncatingIfNeeded: word >> 24))
        out.append(UInt8(truncatingIfNeeded: word >> 16))
        out.append(UInt8(truncatingIfNeeded: word >> 8))
        out.append(UInt8(truncatingIfNeeded: word))
    }

    // MARK: Reading

    /// A field that was there, or was declared absent — the inner half of the presence byte, kept as
    /// a type rather than as a `String??` so the two questions stay legible at the call site.
    private enum Field {
        case absent
        case present(String)

        var value: String? {
            switch self {
            case .absent: nil
            case let .present(text): text
            }
        }
    }

    /// A forward-only cursor. Nothing is seekable and nothing is indexable — the walk IS the
    /// contract, so every read that would leave the buffer answers `nil` and the whole decode fails.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var remaining: Int { bytes.count - offset }
        var isAtEnd: Bool { offset == bytes.count }

        mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func length() -> Int? {
            guard remaining >= 4 else { return nil }
            var word: UInt32 = 0
            for index in offset..<(offset + 4) { word = (word << 8) | UInt32(bytes[index]) }
            offset += 4
            return Int(word)
        }

        mutating func text() -> String? {
            guard let count = length(), count <= remaining,
                  let text = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8)
            else { return nil }
            offset += count
            return text
        }

        mutating func field() -> Field? {
            // A presence byte that is neither of its two values is a shape disagreement, not an
            // absent field: guessing would let a corrupt stream read as a valid layout.
            switch byte() {
            case .some(0):
                return .absent
            case .some(1):
                guard let text = text() else { return nil }
                return .present(text)
            default:
                return nil
            }
        }

        mutating func flag() -> Bool? {
            switch byte() {
            case .some(0): false
            case .some(1): true
            default: nil
            }
        }

        mutating func uuid() -> UUID? {
            guard remaining >= 16 else { return nil }
            let source = bytes, start = offset
            var raw = UUID().uuid
            withUnsafeMutableBytes(of: &raw) { slot in
                for index in 0..<16 { slot[index] = source[start + index] }
            }
            offset += 16
            return UUID(uuid: raw)
        }
    }

    /// One layout out of the stream, or `nil` for bytes this reader could not consume exactly.
    static func decodeLayout(_ bytes: [UInt8]) -> TemplateNode? {
        var reader = Reader(bytes: bytes)
        // A trailing byte is refused rather than ignored: two encoders that disagreed about a
        // field's width would otherwise still agree on every shallow input, which is the exact
        // shape of the drift this crossing exists to expose.
        guard let node = node(&reader), reader.isAtEnd else { return nil }
        return node
    }

    /// Recursive where the crate's reader is iterative, and the asymmetry is the input's: everything
    /// decoded here is an ANSWER — a repaired layout, bounded by ``SplitNode/maxDepth``, or a shipped
    /// table three levels deep — while the crate is handed whatever the far side of a C pointer holds.
    private static func node(_ reader: inout Reader) -> TemplateNode? {
        guard let tag = reader.byte() else { return nil }
        switch tag {
        case tagPane:
            // The kind byte is total on the way in for the reason ``WorkspacePaneKindTag`` is: a
            // kind this build does not know is a degraded pane, never a lost layout.
            guard let kindByte = reader.byte(), let title = reader.text(),
                  let cwd = reader.field(), let command = reader.field()
            else { return nil }
            return .pane(TemplatePane(
                kind: WorkspacePaneKindTag.kind(for: kindByte),
                title: title,
                cwd: cwd.value,
                command: command.value,
            ))
        case tagSplit:
            // Every child costs at least its own tag byte, so a count larger than what is left is a
            // truncated stream rather than a big tree — refused before it is an allocation.
            guard let axisByte = reader.byte(), let count = reader.length(), count <= reader.remaining
            else { return nil }
            var children: [TemplateNode] = []
            for _ in 0..<count {
                guard let child = node(&reader) else { return nil }
                children.append(child)
            }
            return .split(axis: axisByte == 1 ? .vertical : .horizontal, children: children)
        default:
            return nil
        }
    }

    // MARK: The doors

    /// `layout` with every invariant re-established, **by the crate** — the far half of the pair
    /// ``TemplateNode/init(from:)`` is the near half of.
    ///
    /// `nil` only when the crossing itself went wrong. Every layout the crate can read has a repair,
    /// so a `nil` here is this file disagreeing with the header's grammar and never a template the
    /// far side declined to fix.
    static func repairedByTheCrate(_ layout: TemplateNode) -> TemplateNode? {
        let stream = encode(layout)
        let answer = stream.withUnsafeBufferPointer { input in
            wsBytes { out, cap in
                slopdesk_ws_template_repair(input.baseAddress, input.count, out, cap)
            }
        }
        return answer.isEmpty ? nil : decodeLayout([UInt8](answer))
    }

    /// The session templates the crate ships, as it spells them.
    static func builtInTemplatesFromTheCrate() -> [SessionTemplate]? {
        var reader = Reader(bytes: [UInt8](wsBytes { out, cap in slopdesk_ws_built_in_templates(out, cap) }))
        guard let count = reader.length() else { return nil }
        var rows: [SessionTemplate] = []
        for _ in 0..<count {
            guard let id = reader.uuid(), let name = reader.text(), let symbol = reader.text(),
                  let isBuiltIn = reader.flag(), let layout = node(&reader)
            else { return nil }
            rows.append(SessionTemplate(id: id, name: name, symbol: symbol, isBuiltIn: isBuiltIn, layout: layout))
        }
        return reader.isAtEnd ? rows : nil
    }

    /// The launch presets the crate ships, as it spells them.
    static func builtInLaunchPresetsFromTheCrate() -> [LaunchPreset]? {
        var reader = Reader(bytes: [UInt8](wsBytes { out, cap in slopdesk_ws_built_in_launch_presets(out, cap) }))
        guard let count = reader.length() else { return nil }
        var rows: [LaunchPreset] = []
        for _ in 0..<count {
            guard let id = reader.uuid(), let name = reader.text(), let command = reader.text(),
                  let cwd = reader.field(), let hasSplit = reader.flag()
            else { return nil }
            var split: LaunchPreset.SplitConfig?
            if hasSplit {
                guard let axisByte = reader.byte(), let secondary = reader.text() else { return nil }
                split = LaunchPreset.SplitConfig(
                    axis: axisByte == 1 ? .vertical : .horizontal,
                    secondaryCommand: secondary,
                )
            }
            guard let symbol = reader.text(), let isBuiltIn = reader.flag() else { return nil }
            rows.append(LaunchPreset(
                id: id, name: name, command: command, workingDirectory: cwd.value,
                split: split, symbol: symbol, isBuiltIn: isBuiltIn,
            ))
        }
        return reader.isAtEnd ? rows : nil
    }
}
