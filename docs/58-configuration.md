# 58 — Configuration: one file, no settings GUI

> Read `docs/56-client-ui-split.md` for what the two clients draw. This doc is about what they do
> NOT draw any more, and where the answers come from instead.

## 0. The ruling this doc records

On 2026-08-24 the settings GUI and the first-launch flow were deleted outright — nineteen `Settings/`
views on the Mac, seventeen on the phone, six onboarding step cards, the row catalogue and taxonomy
that indexed them, the two chord recorders, and the four FFI door families underneath
(`settings_rows`, `settings_layout`, `settings_catalog`, `settings_options`). Eighty-two files.

**The ruling: every setting has one right answer, the app applies it without asking, and a file is
how you disagree.** This is Ghostty's shape and it is adopted for Ghostty's reason: a program that
opens with a wizard is a program that has not decided anything, and a window offering 110 switches
spends its screen space asking a question it should already have answered.

Three consequences, each load-bearing:

1. **No GUI.** There is no settings window, no settings sheet, no All-Settings index, and no chord
   editor. ⌘, opens `config.toml` in the reader's own editor.
2. **No onboarding.** Nothing is gated on having clicked through a flow. The things the flow used to
   OFFER are now simply done (§4).
3. **No `config set`.** The CLI reads the file and never writes it. A verb that edits a document a
   human also edits is a merge conflict with a comment-eating parser on one side.

`rust/slopdesk-invariants`' `settings-is-a-file` rule holds all of it, with a break-test per claim.

## 1. The file

| | |
| --- | --- |
| Path | `$SLOPDESK_CONFIG_FILE`, else `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `~/.config/slopdesk/config.toml` |
| Path (iOS) | the app's own Documents directory — the one place a user can put a file INTO a sandboxed app |
| Format | TOML |
| Schema | `docs/config.schema.json`, draft 2020-12, `additionalProperties: false` at every level |
| Resolver | `rust/slopdesk-settings/src/config/path.rs` |

**An empty file is a complete file, and no file at all is the supported shape.** A key is written
only to change it. That is why ⌘, on a fresh install writes a starter file that is a comment and a
`#:schema` pointer rather than a dump of the defaults: a file pre-filled with today's answers pins
them forever, so the next release improves a default and nobody who ever opened Settings gets it.

`ConfigFile.prepared()` also drops a copy of the schema NEXT to the file, so the `#:schema
./config.schema.json` line resolves with no network and no editor plugin configuration.

## 2. Where the answers come from

One Rust table: `rust/slopdesk-settings/src/config/table.rs`. Every key, its type, its domain and its
default, in one place, and it is the source of three separate things:

- **The app's reading.** `AppConfig` (Swift) is the whole configuration surface as one immutable
  value — five maps by TYPE plus the `[keybind]` and `[env]` tables — resolved in ONE crossing at
  launch and one per reload, never per draw. It holds no default of its own: a key absent from the
  maps is absent because the table declared it so, never because Swift forgot to look.
  `declaredPaths` is what tells "no such key" apart from "declared but unset".
- **The schema.** `config::schema::json_schema()` writes `docs/config.schema.json`. It is an
  ARTIFACT with a producer (`cargo run --bin write-config-schema`, i.e. `just config-schema`) and a
  staleness gate (`rust/slopdesk-settings/tests/checked_in_schema.rs`), never a document with an
  author. A stale schema is worse than none — it tells the reader a key exists that this build
  ignores, in the editor where they are most likely to believe it.
- **The diagnostics.** `slopdesk config validate` prints one line per thing wrong with the file:
  every per-ROW complaint the table can make, folded with `config::render::keybind_conflicts`,
  which is the per-PAIR one it cannot — two rows spelling ONE chord differently (`"cmd+leftarrow"`
  and `"cmd+left"`), where TOML sees two distinct keys and the last one silently wins.

`SettingsKey` (Swift) is a pure projection of `AppConfig` — 71 typed accessors over the same paths.
The `settings-is-a-file` rule's `Subset` claim checks every path it names is one the table declares:
an undeclared path answers with the accessor's fallback forever and nothing anywhere says a word.

### Sections

`agent` · `appearance` · `badges` · `controls` · `general` · `notifications` · `shell` · `terminal`
· `video` · `window`, plus two free tables:

- `[keybind]` — chord → action id, e.g. `"cmd+shift+d" = "split_down"`. Grammar and alias fold in
  `Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift`.
- `[env]` — raw `SLOPDESK_*` name → value, applied LAST and above every typed key (`docs/46`).

## 3. Reload

**There is no `config reload` verb, no file watcher, and no live-config door.** The app re-reads the
file on every ACTIVATION, which is exactly the moment a reader who just saved it in their editor
comes back to look — the one event the system already hands over for free.

`ConfigFile.reload(_:)` guards on equality first, and the guard is the feature rather than an
optimisation: `PreferencesStore` bumps the terminal-config generation unconditionally, so re-applying
an IDENTICAL reading would rebuild every live terminal's config and re-measure its grid — a visible
flash on every ⌘Tab back. `AppConfig` is `Equatable`; an unchanged file does nothing at all.

Behind the same guard, `ConfigRevision.shared.bump()` publishes the one observable edge for "the
config moved". `AppConfig.current` is a plain global behind a lock — every consumer is a synchronous
accessor on a hot path — so the EDGE is published rather than the value. A view that must re-read a
setting while it is on screen (the secure-input pair, the satellite pointer grant, the auto-hide
mode) reads `generation` alongside whatever `SettingsKey` it wants and Observation re-arms it.

## 4. What is enforced instead of offered

Each of these was a switch on an onboarding card. Each is now simply true.

| Was | Is |
| --- | --- |
| "Install Claude Code hooks" button | `AgentHookEnforcer.enforce()` on EVERY connection establish. Agent detection is what this app IS; a host without the hooks is a host with half the product dark. Every establish rather than once, because the host on the other end of the next connection is not necessarily the last one. |
| "Install the `slopdesk` command" switch | `CLILink` at launch, into `~/.local/bin` — a directory the user already owns. The old switch escalated to `/usr/local/bin` and raised an administrator prompt in a user's first two minutes; a password prompt is the most expensive question a program can ask, and it was being spent on a convenience. |
| "Set as default terminal" row | deleted. It changed a system-wide association from inside a wizard, which is not a default anybody asked for. |
| Theme picker | deleted 2026-08-08 by earlier ruling — the app has ONE appearance (`docs/DECISIONS.md`). |

## 5. The CLI

`slopdesk config` is READ-ONLY, by design:

| Verb | What it does |
| --- | --- |
| `config path` | print the resolved config-file path |
| `config edit` | open it in `$EDITOR` |
| `config show` | print every setting as RESOLVED — file answers and compiled defaults together |
| `config get <key>` | one resolved value |
| `config validate` | every key the file gets wrong, plus every chord written twice |
| `config schema` | print the JSON Schema |

Vocabulary: `rust/slopdesk-cli/src/vocabulary.rs`, which carries the prose for why no `config set`
row exists. `slopdesk-invariants`' `cli-config` rule holds that the CLI has ONE reader: it may not
grow its own TOML parser, its own path resolution, or its own comment handling beside
`AppConfig.load`.

## 6. Gates

| Gate | Holds |
| --- | --- |
| `just config-schema` | regenerates the artifact — the ONLY writer |
| `just settings-test` | the key table, the file resolver, the schema, and the checked-in copy |
| `settings-is-a-file` (invariants) | the GUI directories stay empty, the GUI types stay deleted, no first-launch gate returns, the schema exists, and every `SettingsKey` path is declared |
| `cli-config` (invariants) | one reader for the file |
| `checked_in_schema.rs` | the checked-in schema is byte-identical to what this build writes |

The staleness gate lives in `slopdesk-settings` rather than `slopdesk-invariants` on purpose: it is
not a pattern over the tree, it is the generator's own output compared to the artifact, and only the
crate that can RUN the generator can ask that question.

### The one duplication still standing, and the rule that ended it

**LANDED 2026-08-26** as `slopdesk-invariants`'s `choice-tokens-are-the-tables`, and it caught a live
bug on its first run. `shell.close-confirm-window`'s table row spelled its third stop `multiple-tabs`
while `CloseConfirmationPolicy` spells it `multiple_tabs` — the underscored form is the one already in
users' `UserDefaults`, which docs/56 records as deliberate for exactly two tokens. So the schema
accepted only the hyphen, and the hyphen reached an enum with no case for it and repaired to
`process`: the one stop the setting exists for was unreachable by either spelling, and nothing said
so. The table now spells it `multiple_tabs`, and `docs/config.schema.json` was regenerated.

The rule reads the table's `options:` in the three shapes it comes in — a literal array, a named
`const` in the same file, and a list built out of the crate's own `Enum::Case.token()` calls. The
third is CRATE-OWNED and is skipped by conclusion rather than by exemption: those Swift enums have no
`String` raw type at all, their `rawValue` reads the same crate table through a door, and there is no
second spelling to compare. On the Swift side it reads `enum X: String`'s cases, taking each case's
explicit `= "…"` when it has one and its name otherwise, with a keyword case's backticks stripped.
Then, per call site: every table stop must be spelled by a case (the load-bearing claim — a stop with
no case is the unreachable setting above), the path must exist in the table, and the fallback's own
token must be one of that path's stops. It also counts the pairs that reach the comparison and fails
when none do, because both halves are regex extractions over source edited daily and the failure they
share is going quiet.

The original note, kept because it is the argument the rule encodes:

---


`AppConfig.choice(_:_:)` takes a Swift enum case as a fallback, and seventeen call sites pass one.
Every single one of them is DEAD: `texts[path]` already carries the table's own default, so the
fallback fires only for a token no case spells — a hand-edited `config.toml` reaching an older
binary. `AppConfig`'s own doc says "this side holds NO default of its own", and seventeen tokens
sitting in Swift contradict it, which is the shape [`docs/55`](55-ffi-boundary.md) §8 catalogues.

Pinning each fallback TOKEN to its table default needs a three-way join — path → Swift enum →
`rawValue` → table default — and the enums mix implicit raw values (`case auto`) with explicit ones
(`case afterCurrent = "after-current"`), so the join has to model both. The cheaper equivalent, and
the one to write: pin each choice enum's CASE SET to that path's `options` in
`rust/slopdesk-settings/src/config/table.rs`. Once the sets are proved equal the fallback is
provably unreachable, and its token stops being a second default whatever it spells. The rule is
textual on both sides — `slopdesk-invariants` reads source and links no crate — so it must resolve
an `options:` that is a named `const` in the same file as well as one written as a literal array.
