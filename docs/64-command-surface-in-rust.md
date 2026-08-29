# 64 — Stage H: the binding table becomes Rust

The keyboard's command surface is written twice today, in two languages, and an invariant holds the
two spellings equal. That invariant is the tell: `rust/slopdesk-invariants` does not ratchet a
contract here, it maintains a JOIN. `CLAUDE.md` names the shape directly — *one implementation, never
two languages; not a fallback, not a test fake, not a cross-language mirror fixture* — and a
`Claim::SameSet` between a Swift array literal and a Rust array literal is exactly the fixture that
rule forbids.

This stage deletes the Swift half of that pair.

## 1. What is written twice, measured

`Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` is 1135 lines, 693 of
them code, and it mentions three FFI doors. It holds:

- `WorkspaceAction` — ~80 cases, the vocabulary the UI switches over to reach a store op.
- `WorkspaceBinding` — the row struct: id, action, title, category, chord, symbol, keywords.
- `declared` — **76 rows** of hand-written data, each with a paragraph of rationale above it saying
  which chords are free and what pins the choice.
- `selectPaneRepresentative` — a 77th row, written out because it is not generated.
- `selectPaneBindings` — the nine `⌘1…⌘9` rows, a `(1...9).map`.
- `aliasChords` — three chord → action aliases with no display row.
- every derived table: `bindings`, `allBindings`, `byAction`, `chordTable`, `groupedForDisplay`.

`rust/slopdesk-workspace/src/binding_rows.rs` is 264 lines holding **the same 77 ids** and exactly one
column of the row: `platform`. Nothing else about a row crossed, so the Mac/phone split lives in Rust
and the other six columns live in Swift, over one id space.

`rust/slopdesk-invariants/src/rules/command_surface.rs` joins them:

```rust
Claim::SameSet {
    label: "binding row ids",
    swift: Extract::raw(SWIFT_BINDINGS, r#"id: "([a-z]+\.[A-Za-z0-9]+)""#),
    rust:  Extract::raw("…/binding_rows.rs", r#"row\("([a-z]+\.[A-Za-z0-9]+)""#),
}
```

Two literals, held equal by a regex over both. That is the mirror.

## 2. What crosses, and what does not

**Crosses — all of it is data.** The 77 rows entire (id, action tag, title, category, chord, symbol,
keywords, platform), the three alias chords, and `requiresActivePane`. The rationale comments cross
WITH their rows: they are ~40% of the Swift file's mass and they are the only record of why a chord
is free. A row that arrives in Rust without its paragraph has lost the thing that made it reviewable.

**Stays Swift, and is not a mirror.**

- `WorkspaceAction` — the enum the UI `switch`es over. Its cases must be a Swift type or every routing
  arm becomes a raw integer compare. It crosses as a `u16` tag with ONE typed mapping site, the
  `pane_kind.rs` precedent, and an invariant pins case-for-tag parity. This is the sanctioned
  "constant typed in both languages" that `lint-invariants` ratchets; it is not a second table.
- `selectPaneBindings` — a `(1...9).map` over a formula. There is no Rust twin to drift from, because
  a loop is not a table.
- Every derived dictionary — `byAction`, `chordTable`, `groupedForDisplay`, the override merge in
  `WorkspaceBindingOverrides`. These were never duplicated, and keeping them Swift keeps the
  per-keystroke path a hash lookup with NO door crossing on it at all. The registry asks Rust for the
  table once, at `static let` init, and never again.
- `glyph(_:)` — already a door (`slopdesk_keybind_glyph`); untouched.

## 3. The chord, crossing without a new vocabulary

A chord is a key plus four modifier bits. The key is either a printable character or one of eleven
named keys, and `KeyChord.Key.namedIndex` / `init?(namedIndex:)` already spell those eleven positions
against `slopdesk_video::key_naming`. So the chord crosses as `(named_index: i16, character: u32,
mods: u8)` with `named_index == -1` meaning "printable, read `character`" — no new key enum in Rust,
no string marshalling, and the index vocabulary stays the one already pinned.

## 4. The doors

Two records plus a text blob, in `rust/slopdesk-ffi/src/bindings.rs`. `binding_rows.rs` (both the
crate module and the FFI module) is deleted, not extended — its three doors are subsumed.

```c
typedef struct {
    uint16_t action;           // the WorkspaceAction tag — its case POSITION
    int16_t  chord_named;      // the named-key index, or -1 for a printable key
    int32_t  arg;              // the action's payload, or 0; only selectPane uses it
    uint32_t chord_char;       // the printable key's scalar; meaningless unless chord_named is -1
    uint8_t  category;         // 0 panes · 1 tabs · 2 focus · 3 view
    uint8_t  chord_modifiers;  // shift 1 · control 2 · option 4 · command 8
    uint8_t  kind;             // 0 a declared row · 1 the collapsed ⌘1…⌘9 representative
    bool     has_chord;
    bool     shown;            // does the half that ASKED list this row
} SlopDeskWsBindingRow;

typedef struct {
    uint16_t action;
    int16_t  chord_named;
    uint32_t chord_char;
    uint8_t  chord_modifiers;
} SlopDeskWsBindingAlias;

size_t slopdesk_ws_binding_count(void);
size_t slopdesk_ws_binding_rows(bool mac, SlopDeskWsBindingRow *out, size_t cap);
size_t slopdesk_ws_binding_text(uint8_t *out, size_t cap);
size_t slopdesk_ws_binding_aliases(SlopDeskWsBindingAlias *out, size_t cap);
bool   slopdesk_ws_action_requires_active_pane(uint16_t action);
```

The WHOLE table per crossing, not a row per crossing, because the registry walks it ONCE building a
`static let` and never again — three calls at process start rather than 240. The four strings per row
(id, title, symbol, keywords) cross as ONE length-prefixed blob in row order, cut by `wsRuns`; four
runs are always pushed, empty for a row with no keywords, so the cursor advances by a constant and a
missing field cannot slide every later field onto its neighbour.

Copy-out rather than lent static pointers because the walk happens once. The cost is 77 rows × 4
strings at process start; the saving is a header with no lifetimes in it.

`slopdesk_ws_binding_rows` takes `mac` rather than answering for the running half, because
`BindingRowPlatformTests` asks the phone's table from a Mac. A door that could only answer "this
slice" would delete that test.

`kind` is on the record rather than implied by position because the collapsed `pane.selectN`
representative is a row the cheat sheet appends and the palette catalog and the menu omit. It is a
FILTER the near side applies, not an index it counts to.

## 5. The invariants, re-aimed rather than exempted

- `a_keybinding_names_its_platform_once`'s `SameSet` goes red the moment the Swift literals vanish. It
  becomes a BAN on the DATA, not on the constructor: no `id: "<noun>.<verb>"` literal in
  `WorkspaceBindingRegistry.swift`, plus two `Matches` pinning that the face's `bindings` comes from
  `WorkspaceBindingTable.current.listed` and that the table is assembled from
  `slopdesk_ws_binding_rows`. A join becomes a floor — the same strengthening `one-coremedia-builder`
  made. Banning `WorkspaceBinding(` outright would ban the assembly constructor the crossing needs,
  which is the opposite of the rule's subject: a row built FROM door output is the one implementation,
  a row TYPED beside a Rust one is the two.
- `the_chord_table_is_held_not_rebuilt` pins four exact Swift spellings. The `let`-not-`var` pin and the
  `liveChordTable` memo pin both survive and still matter (the 210µs measurement is unchanged); their
  patterns re-aim at whatever the face spells.
- `every_keybinding_is_reachable_from_the_palette` survives unchanged — the face still exposes
  `bindings`.
- A new rule pins `WorkspaceAction` case-for-tag parity in both directions.

## 6. The finish line, stated so it can be checked

- `rust/slopdesk-workspace/src/binding_rows.rs` does not exist.
- `rust/slopdesk-ffi/src/binding_rows.rs` does not exist.
- `WorkspaceBindingRegistry.swift` declares no row: no `id: "<noun>.<verb>"` literal appears in it.
  The nine-row `(1...9).map` survives because its id is INTERPOLATED, which is the same thing said
  about it here — a loop over a formula has no twin to drift from. This is what the invariant
  enforces, and it is deliberately narrower than "no `WorkspaceBinding(` anywhere":
  `WorkspaceBindingTable.swift` constructs rows too, but only ever FROM crossed data (plus one
  unreachable fallback for a build whose header does not match its library), and a constructor over
  door output is the opposite of a second table.
- `WorkspaceBindingRegistry`'s public surface is byte-identical: `bindings`, `allBindings`,
  `selectPaneBindings`, `selectPaneRepresentative`, `aliasChords`, `chordTable`, `binding(for:)`,
  `glyph(_:)`, `glyph(for:)`, `groupedForDisplay`. Sixty files read it; none of them changes.
- **Zero test-expectation changes** in `E1KeymapParityTests`, `TreeCommandRoutingTests`,
  `WorkspaceBindingRoutingTests`, `BindingRowPlatformTests`. Those suites pin chords, uniqueness and
  chord-less rows against the face; any diff in them is a transcription error in the Rust table, not a
  test to update. They ARE the differential suite this port is verified by.
