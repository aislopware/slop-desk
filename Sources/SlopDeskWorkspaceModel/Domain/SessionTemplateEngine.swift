import CSlopDeskFFI
import Foundation

// MARK: - SessionTemplateEngine (the face over the crate's expand ↔ capture)

/// The expansion of a ``SessionTemplate`` into a live ``Session`` and the inverse capture, as a face over
/// `slopdesk_workspace::templates`.
///
/// Everything that DECIDED anything moved: the fresh identity on every node, the equal `.flex(1)` share
/// on every seam, the depth-first launch ORDER, the first-leaf-is-active rule, and the two repairs a
/// capture makes (a leaf whose spec the side table has lost, and a session with no active tab at all).
/// What is left here is marshalling — a layout out, a stream back, and the ``Session`` value assembled
/// from it.
///
/// It lives in this module rather than beside the store because ``SessionTemplateCrossing`` does: the
/// layout going in is the SAME stream `slopdesk_ws_template_repair` speaks, so it is encoded by the one
/// encoder that already spells that grammar rather than by a second copy of it. The `expanded` stream
/// coming back is a grammar of its own — a template has no ids, no shares and no launch order — and the
/// reader for it is below, written against the paragraph in
/// `rust/slopdesk-ffi/include/slopdesk_ffi.h` rather than against the Rust that answers it.
///
/// ## The identity pool
///
/// The crate holds no entropy on purpose, so the caller brings the ids. How many is ASKED
/// (`slopdesk_ws_template_minted_ids`) rather than counted here: a pool one short does not fail, it
/// repeats an id, and two panes born with one id surface days later as a pane that will not close.
public enum SessionTemplateEngine {
    // MARK: Expand: template → session

    /// Builds a fresh ``Session`` named `name` from `template`, plus an ORDERED list of
    /// `(PaneID, TemplatePane)` so the caller can send each pane's launch bytes once its PTY is live.
    /// The result holds the **specs == leafIDs invariant** (`specs.count == leafCount`).
    public static func makeSession(
        from template: SessionTemplate,
        name: String,
    ) -> (Session, [(PaneID, TemplatePane)]) {
        var layout = SessionTemplateCrossing.encode(template.layout)
        let pooled = layout.withUnsafeMutableBufferPointer { lent in
            slopdesk_ws_template_minted_ids(lent.baseAddress, lent.count)
        }
        var pool = (0..<pooled).map { _ in SlopDeskWsUuid(UUID()) }
        let stream = layout.withUnsafeMutableBufferPointer { lent in
            pool.withUnsafeMutableBufferPointer { ids in
                wsAnswerBytes { out, cap in
                    slopdesk_ws_template_expand(
                        lent.baseAddress, lent.count,
                        ids.baseAddress, ids.count,
                        out, cap,
                    )
                }
            }
        }

        var specs: [PaneID: PaneSpec] = [:]
        var launches: [(PaneID, TemplatePane)] = []
        var reader = ExpansionReader(stream)
        guard let root = reader.node(specs: &specs, launches: &launches), reader.isDrained else {
            // The door spells a refused layout `0`, which this side cannot produce — it encodes with
            // the same encoder the door reads. An empty launch list is what every caller already
            // guards on, so a disagreement stops the open rather than inventing a layout.
            return (Session(name: name, tabs: [], activeTabIndex: 0, specs: [:]), [])
        }
        let tab = Tab(root: root, activePane: launches.first?.0)
        return (Session(name: name, tabs: [tab], activeTabIndex: 0, specs: specs), launches)
    }

    // MARK: Capture: session → template

    /// Captures the active tab of `session` into a fresh user template named `name` with `symbol`.
    /// `cwd`/`command` are not recoverable from a running PTY, so the captured panes carry only kind +
    /// title; `isBuiltIn` is `false`.
    public static func captureTemplate(
        from session: Session,
        name: String,
        symbol: String,
    ) -> SessionTemplate {
        let tab = session.activeTab
        var captured: [UInt8] = []
        if let tab { append(tab.root, specs: session.specs, to: &captured) }
        let stream = captured.withUnsafeMutableBufferPointer { lent in
            wsAnswerBytes { out, cap in
                slopdesk_ws_template_capture(lent.baseAddress, lent.count, tab != nil, out, cap)
            }
        }
        // A `nil` here is this side disagreeing with the grammar, never the crate declining to answer:
        // the door repairs every degenerate tab it is handed. The pane it falls back to is the one the
        // crate would have answered, so a disagreement costs a layout rather than a crash.
        let layout = SessionTemplateCrossing.decodeLayout(stream)
            ?? .pane(TemplatePane(title: TreeWorkspaceDefaults.paneTitle))
        return SessionTemplate(name: name, symbol: symbol, isBuiltIn: false, layout: layout)
    }

    /// Writes one node of the `captured` stream: `0x00 has_spec [kind title]`, or
    /// `0x01 axis child_count children`.
    ///
    /// The presence byte is the point — a leaf the side table has no spec for is a different fact from
    /// one whose spec title is blank, and only the crate gets to say what the first becomes.
    private static func append(_ node: SplitNode, specs: [PaneID: PaneSpec], to out: inout [UInt8]) {
        switch node {
        case let .leaf(id):
            out.append(0)
            guard let spec = specs[id] else {
                out.append(0)
                return
            }
            out.append(1)
            out.append(WorkspacePaneKindTag.byte(for: spec.kind))
            let title = Array(spec.title.utf8)
            append(length: title.count, to: &out)
            out.append(contentsOf: title)
        case let .split(_, axis, children):
            out.append(1)
            out.append(axis == .horizontal ? 0 : 1)
            append(length: children.count, to: &out)
            for child in children { append(child.node, specs: specs, to: &out) }
        }
    }

    /// A `u32` length, big-endian.
    private static func append(length: Int, to out: inout [UInt8]) {
        let value = UInt32(truncatingIfNeeded: length)
        out.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    // MARK: Launch bytes

    /// The bytes to type into a freshly-spawned template pane once its PTY is live: a `cd <cwd>\n` (only
    /// for a non-empty cwd) followed by `<command>\n` (only for a non-empty command), or `nil` when BOTH
    /// are empty/nil (a true no-op — never a bare newline). REUSES ``LaunchPresetEngine/keystrokes(command:cwd:)``
    /// verbatim, so a template pane behaves IDENTICALLY to a launch preset: the cwd is emitted as a SAFE
    /// literal `cd` (never through `SendKeysParser`, so a `<Enter>`/quote in a path can't inject a command
    /// — see the engine's SECURITY note), while the command resolves `SendKeysParser` tokens.
    /// The emptiness rule is the crate's alone. It used to be written here too — a trim on the cwd and a
    /// trim on the command, ahead of a call to the rule that decides the same thing — and the two did not
    /// agree: `templates::keystrokes` gated the directory UNTRIMMED, so a whitespace-only cwd was "no
    /// directory" here and `cd '  '` there. Both production callers pass `cwd: nil`, which is precisely why
    /// a pair like this can sit disagreeing for as long as anyone leaves it. The crate's gate is symmetric
    /// now and this reads its answer: an empty answer is the no-op, and nothing else decides it.
    public static func launchBytes(cwd: String?, command: String?) -> [UInt8]? {
        let bytes = LaunchPresetEngine.keystrokes(command: command ?? "", cwd: cwd)
        return bytes.isEmpty ? nil : bytes
    }
}

// MARK: - The `expanded` stream

/// The reader for the one grammar only this door speaks, written against the header paragraph.
///
/// ```text
/// node := 0x00 uuid:pane u8:kind text:title opt-text:cwd opt-text:command
///       | 0x01 uuid:split u8:axis u32:child_count (weight node) × child_count
/// ```
///
/// Every field that cannot be read exactly answers `nil`, which the caller reports as an empty
/// expansion — never as a tree with a field guessed at, because a guess here would be a repair this
/// side invented at the one place the caller cannot tell the difference.
private struct ExpansionReader {
    private let bytes: [UInt8]
    private var cursor: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        cursor = bytes.startIndex
    }

    /// Whether the stream was consumed EXACTLY. A trailing byte means the two encoders disagree about
    /// a field's width, which they would still do on every shallow input if this were ignored.
    var isDrained: Bool { cursor == bytes.endIndex }

    private mutating func byte() -> UInt8? {
        guard cursor < bytes.endIndex else { return nil }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private mutating func length() -> Int? {
        guard cursor + 4 <= bytes.endIndex else { return nil }
        let value = UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
            | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
        cursor += 4
        return Int(value)
    }

    private mutating func text() -> String? {
        guard let count = length(), cursor + count <= bytes.endIndex else { return nil }
        defer { cursor += count }
        // The repairing initialiser, matching `ArenaText`: these bytes came back from a Rust
        // `String`, so a failable init has no reachable arm and answering `""` would lose the whole
        // field rather than one character of it.
        return String(decoding: bytes[cursor..<cursor + count], as: UTF8.self)
    }

    private mutating func optionalText() -> String?? {
        switch byte() {
        case 0: .some(nil)
        case 1: text().map { .some($0) }
        default: nil
        }
    }

    private mutating func uuid() -> UUID? {
        guard cursor + 16 <= bytes.endIndex else { return nil }
        defer { cursor += 16 }
        let raw = Array(bytes[cursor..<cursor + 16])
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        ))
    }

    /// One share: a kind byte, then the raw bits of its magnitude — never a re-parsed decimal.
    private mutating func weight() -> SplitWeight? {
        guard let kind = byte(), cursor + 8 <= bytes.endIndex else { return nil }
        var pattern: UInt64 = 0
        for offset in 0..<8 { pattern = pattern << 8 | UInt64(bytes[cursor + offset]) }
        cursor += 8
        let value = Double(bitPattern: pattern)
        return kind == 0 ? .flex(value) : .fixed(value)
    }

    /// One node and everything under it, seeding `specs` and appending each leaf to `launches` in the
    /// pre-order the door wrote them in — which IS the launch order.
    mutating func node(
        specs: inout [PaneID: PaneSpec],
        launches: inout [(PaneID, TemplatePane)],
    ) -> SplitNode? {
        switch byte() {
        case 0:
            guard let id = uuid().map(PaneID.init(raw:)),
                  let kind = byte().map(WorkspacePaneKindTag.kind(for:)),
                  let title = text(),
                  let cwd = optionalText(),
                  let command = optionalText()
            else { return nil }
            specs[id] = PaneSpec(kind: kind, title: title)
            launches.append((id, TemplatePane(kind: kind, title: title, cwd: cwd, command: command)))
            return .leaf(id)
        case 1:
            guard let id = uuid().map(SplitNodeID.init(raw:)),
                  let axisByte = byte(),
                  let count = length()
            else { return nil }
            var children: [WeightedChild] = []
            children.reserveCapacity(count)
            for _ in 0..<count {
                guard let share = weight(),
                      let child = node(specs: &specs, launches: &launches)
                else { return nil }
                children.append(WeightedChild(weight: share, node: child))
            }
            return .split(id: id, axis: axisByte == 0 ? .horizontal : .vertical, children: children)
        default:
            return nil
        }
    }
}
