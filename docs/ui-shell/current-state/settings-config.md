# Settings UI & Configuration System — Current State

First surveyed 2026-06-25. **Rewritten 2026-08-24, because there is no settings UI to survey.**

**The whole subject now lives in [`docs/58-configuration.md`](../../58-configuration.md).** That doc
is the reference: the file's path, the key table, the schema artifact, the reload edge, what is
enforced instead of offered, and the gates that hold each of them.

## What happened

Five waves have landed on this survey. The first four narrowed the GUI; the fifth deleted it.

1. **The feature prune, 2026-07-03.** `WorkspaceTransfer`, the workspace export/import codec,
   `Snippet` and `SnippetExpander` went (`docs/DECISIONS.md`).
2. **ONE APPEARANCE, 2026-08-08.** The theme picker, the `ThemeChoice` catalogue, `ThemeStore`, the
   dual light/dark slots and the per-theme font map were deleted, not deprecated.
3. **The Rust lift.** What Settings OFFERED — sections, option groups, scalar ladders, per-row copy,
   per-platform gates — left Swift for `rust/slopdesk-settings/`.
4. **The client-UI split, 2026-08-17** (`docs/56-client-ui-split.md`). `SlopDeskClientUI` became
   `SlopDeskMacUI` (AppKit) + `SlopDeskPhoneUI` (SwiftUI) over shared `SlopDeskClientCore`.
5. **Settings became a FILE, 2026-08-24** (`docs/58-configuration.md`). Eighty-two files deleted: the
   two settings windows, the all-settings index, both chord editors, the taxonomy, the whole
   first-launch flow, and the four FFI door families under them. Wave 3's tables went too — a row
   table exists to feed a row, and there are no rows.

## What survived, and where it is

| Still here | Where |
| --- | --- |
| The key table — every key, type, domain and default | `rust/slopdesk-settings/src/config/table.rs` |
| The resolved reading, one immutable value | `Sources/SlopDeskVideoProtocol/Settings/AppConfig.swift` |
| The typed accessors over it | `Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift` |
| The generated schema | `docs/config.schema.json` ← `make config-schema` |
| The file's path, ⌘, and the reload | `Sources/SlopDeskClientCore/App/ConfigFile.swift` |
| The observable "config moved" edge | `Sources/SlopDeskVideoProtocol/Settings/ConfigRevision.swift` |
| The `[keybind]` grammar and its conflict fold | `Sources/SlopDeskVideoProtocol/Settings/Keybind*.swift` |
| The `env → overlay → default` chain | `EnvConfig.swift` / `EnvBridge.swift` |
| `PreferencesStore` | still the live-apply owner (terminal config, keybindings, the sidecar); it no longer owns any UI |
| `Defaults` | STATE only, four keys: code-sidebar collapsed + width, opened code projects, saved window frame |

## Traps that outlived the GUI

- **`EnvConfig.overlay` is `nonisolated(unsafe)` and documented write-once-at-launch, but IS mutated
  at runtime** by `PreferencesStore.applyVideoAndAgent()`. Safe because the mutation is on
  `@MainActor` before concurrent pipeline reads; the "write-once" comment is aspirational, not
  enforced.
- **`KeybindingPreferences` has a strict schema-version gate, v3.** A blob at another version
  decode-fails to the empty default. The v2→v3 step only REMOVED fields, so a v3 blob still carrying
  `prefixKey` / `sequenceOverrides` decodes fine — those keys are simply not read.
- **`blockBookmarks` is store-only** and always was. Fire-time state, surfaced nowhere. Not a gap.
- **A path `SettingsKey` reads must be one the table DECLARES.** An undeclared path answers with the
  accessor's fallback forever and says nothing. Held by `settings-is-a-file` in
  `rust/slopdesk-invariants`, whose `Subset` claim compares the two files directly.
