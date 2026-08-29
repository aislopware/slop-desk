import CSlopDeskFFI
import SlopDeskWorkspaceModel

// WorkspaceBindingTable — the near side of `slopdesk_workspace::bindings`.
//
// One read of the whole table per half, memoized. This used to be a Swift array literal of 77 rows
// beside a Rust array literal of the same 77 ids, held equal by a `SameSet` claim over a regex on
// each side — a join maintained by hand across a language boundary. docs/64 is why that ended.
//
// Read ONCE, at `static let` init, and never again. Nothing on the per-keystroke path comes through
// here: `WorkspaceBindingRegistry.chordTable` is a Swift dictionary built from what this returns,
// and resolving a chord is a hash lookup with no door on it.
//
// TWO halves are readable, not one. A process is one slice, so the compiled slice IS the answer for
// everything the app does — but the interesting question ("what does the OTHER half bind?") can only
// be asked from a Mac, which is where the tests run, so the door takes `mac` as an argument.

/// The whole binding table, as one half sees it.
struct WorkspaceBindingTable: Sendable {
    /// The rows this half lists, in display order — the shipped table.
    let listed: [WorkspaceBinding]
    /// The collapsed ⌘1…⌘9 stand-in, lifted out because the cheat sheet appends it and the palette
    /// catalog and the menu omit it.
    let representative: WorkspaceBinding
    /// Every declared id, in table order, whether or not this half lists it — the parity pin's half.
    let declaredIDs: [String]
    /// The ids this half does NOT list, so `BindingRowPlatform` can answer for a single row without
    /// walking the table again.
    let withheldIDs: Set<String>
    /// Second chords that fire an existing action without minting a display row.
    let aliases: [KeyChord: WorkspaceAction]

    /// The table as the Mac sees it.
    static let mac = read(mac: true)
    /// The table as the phone sees it.
    static let phone = read(mac: false)

    /// The table as THIS binary's half sees it.
    static var current: Self {
        #if os(macOS)
        mac
        #else
        phone
        #endif
    }

    /// The table a named half sees.
    static func of(mac wantsMac: Bool) -> Self {
        wantsMac ? mac : phone
    }

    /// Reads every door once and assembles the rows.
    ///
    /// A row whose action tag this build does not know is DROPPED rather than guessed at, and a
    /// short text delivery pads with empties rather than sliding every field onto its neighbour —
    /// both are `wsRuns`' own discipline, restated here because the failure is silent otherwise.
    private static func read(mac: Bool) -> Self {
        let count = slopdesk_ws_binding_count()
        var records = [SlopDeskWsBindingRow](
            repeating: SlopDeskWsBindingRow(), count: count,
        )
        let written = records.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_binding_rows(mac, buffer.baseAddress, buffer.count)
        }
        let rows = written == count ? records : []
        let words = wsRuns(
            wsAnswerBytes { out, cap in slopdesk_ws_binding_text(out, cap) },
            count: rows.count * fieldsPerRow,
        )

        var listed: [WorkspaceBinding] = []
        var representative: WorkspaceBinding?
        var declaredIDs: [String] = []
        var withheldIDs: Set<String> = []
        listed.reserveCapacity(rows.count)
        declaredIDs.reserveCapacity(rows.count)

        for (index, record) in rows.enumerated() {
            let id = words[index * fieldsPerRow]
            let keywords = words[index * fieldsPerRow + 3]
            guard let action = WorkspaceAction(tag: record.action, arg: record.arg),
                  let category = WorkspaceAction.Category(code: record.category)
            else { continue }
            let binding = WorkspaceBinding(
                id: id,
                action: action,
                title: words[index * fieldsPerRow + 1],
                category: category,
                chord: record.chord,
                symbol: words[index * fieldsPerRow + 2],
                keywords: keywords.isEmpty ? nil : keywords,
            )
            declaredIDs.append(id)
            if !record.shown { withheldIDs.insert(id) }
            if record.kind == representativeKind {
                representative = binding
            } else if record.shown {
                listed.append(binding)
            }
        }

        return Self(
            listed: listed,
            representative: representative ?? fallbackRepresentative,
            declaredIDs: declaredIDs,
            withheldIDs: withheldIDs,
            aliases: readAliases(),
        )
    }

    /// The three alias chords, read as records.
    private static func readAliases() -> [KeyChord: WorkspaceAction] {
        var records = [SlopDeskWsBindingAlias](
            repeating: SlopDeskWsBindingAlias(), count: aliasCapacity,
        )
        let written = records.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_binding_aliases(buffer.baseAddress, buffer.count)
        }
        guard written > 0, written <= records.count else { return [:] }
        var table: [KeyChord: WorkspaceAction] = [:]
        for record in records.prefix(written) {
            guard let chord = record.chord,
                  let action = WorkspaceAction(tag: record.action, arg: 0)
            else { continue }
            table[chord] = action
        }
        return table
    }

    /// id, title, symbol, keywords — four runs per row, ALWAYS, so a row with no keywords is an
    /// empty run rather than a missing one.
    private static let fieldsPerRow = 4

    /// `Kind::Representative`.
    private static let representativeKind: UInt8 = 1

    /// Past the three aliases the table declares; a fourth would need this raised, and the crate's
    /// own test is what says how many there are.
    private static let aliasCapacity = 8

    /// What the representative would be if the table crossed without one — unreachable in a build
    /// whose header matches its library, and a blank cheat-sheet row rather than a crash if it is not.
    private static let fallbackRepresentative = WorkspaceBinding(
        id: "pane.selectN", action: .selectPane(1), title: "", category: .panes,
        chord: nil, symbol: "number.square",
    )
}

private extension WorkspaceAction.Category {
    /// The category `code` names, or `nil` for a code this build does not know.
    init?(code: UInt8) {
        switch code {
        case 0: self = .panes
        case 1: self = .tabs
        case 2: self = .focus
        case 3: self = .view
        default: return nil
        }
    }
}

private extension SlopDeskWsBindingRow {
    /// The row's default chord, or `nil` when it has none.
    var chord: KeyChord? {
        has_chord ? KeyChord(named: chord_named, character: chord_char, modifiers: chord_modifiers) : nil
    }
}

private extension SlopDeskWsBindingAlias {
    /// The alias chord, or `nil` when the key crossed as one this build cannot spell.
    var chord: KeyChord? {
        KeyChord(named: chord_named, character: chord_char, modifiers: chord_modifiers)
    }
}

private extension KeyChord {
    /// Rebuilds a chord from the three scalars it crosses as.
    ///
    /// `named` is `-1` for a printable key — the sentinel spelling of `KeyChord.Key.namedIndex`'s
    /// `nil`, because a chord has exactly one key and the discriminator IS which kind it is. A named
    /// index this build does not know answers `nil` rather than falling back to a character, since
    /// the character field carries nothing meaningful for a named key.
    init?(named: Int16, character: UInt32, modifiers: UInt8) {
        let key: Key
        if named < 0 {
            guard let scalar = Unicode.Scalar(character) else { return nil }
            key = .character(Character(scalar))
        } else {
            guard let index = UInt8(exactly: named), let known = Key(namedIndex: index) else { return nil }
            key = known
        }
        self.init(key, Modifiers(rawValue: Int(modifiers)))
    }
}
