# 49 — Release pipeline (GitHub Actions → GitHub Release → Homebrew)

> **STATUS: LIVE INFRA.** Gates + env flags: [46](46-gates-env-paths.md). Signing/notarization
> background: [06 §5](06-permissions-distribution.md). Read this before cutting a release,
> rotating the Developer ID, or touching `.github/workflows/release.yml`.

## The shape

```
better-update vault (org weebuild, env production)   ← p12 + notary creds + tap token
        │  BETTER_UPDATE_ROBOT (the ONE GitHub secret)
        ▼
GitHub Actions · aislopware/slop-desk · macos-26 · arm64
   libghostty  →  cached libghostty.xcframework          (Zig 0.15.2, ~40 min cold, ~0 warm)
   package     →  scripts/build-ffi.sh                   (SlopDeskFFI.xcframework, 3 arm64 slices)
               →  scripts/package-release.sh             (build → stamp → sign → notarize)
   publish     →  GitHub Release v<version>
   tap         →  aislopware/homebrew-tap                (version + sha256 rewrite)
        ▼
brew install aislopware/tap/slopdesk           # the CLI + every sidecar daemon
brew services start slopdesk                   # superd — REQUIRED, see below
brew install --cask aislopware/tap/slopdesk    # SlopDesk.app + SlopDeskHost.app
```

`scripts/package-release.sh` is the single source of truth for *how* a release is built. CI runs
it unmodified, so a maintainer reproducing a failure locally runs the same code path.

**Two linked artifacts, both gitignored, both built by the pipeline rather than checked out.**
`libghostty.xcframework` has its own job (cached, because Zig costs ~40 minutes cold);
`SlopDeskFFI.xcframework` is a step inside `package`, because `scripts/build-ffi.sh` stamps its own
inputs and a runner is cold every time anyway. Neither is optional in the weak sense: `Package.swift`
declares a `binaryTarget` at the FFI path, so SwiftPM cannot resolve the graph without the file —
a missing step there fails the release before it compiles a line. `check-supervisor.sh` ratchets the
correspondence: every gitignored `binaryTarget` path must be produced by some step of this workflow.

## arm64 only — a constraint, not a default

Three independent reasons, any one of which is sufficient:

1. `ThirdParty/ghostty/libghostty.xcframework` is built with a `macos-arm64` slice and no other
   (`ThirdParty/ghostty/README.md`); `Apps/ClientApp-macOS/project.yml` pins `ARCHS=arm64`
   because of it. The client app cannot link on Intel.
2. Both apps deploy against macOS 26, which no Intel Mac runs.
3. The Homebrew formula and cask both declare `depends_on arch: :arm64`, so `brew` refuses the
   install rather than handing an Intel user a binary that dies at launch.

There is deliberately no x86_64 matrix leg. `package-release.sh` aborts on an x86_64 host rather
than emitting a half-broken slice.

## The vault (better-update, org `weebuild`)

better-update cannot **build** this repo — its build/submit pipeline is `ios | android`
(`apps/cli/src/lib/build-profile.ts`), so do not try `better-update build` here. It is used purely
as the end-to-end-encrypted credential vault, which is platform-agnostic.

It *can* sign and notarize macOS — `better-update macos sign|notarize` (CLI ≥ 0.73.1) does
Developer-ID signing with hardened runtime, notarizes, and staples. We still keep the identity in
`env` and drive `codesign`/`notarytool` from `package-release.sh`. **Both routes into the
credentials store were tried on 2026-08-11 and both are closed** — do not spend the afternoon
again:

| Attempt | Result |
|---|---|
| `credentials generate distribution-certificate --type developer-id` | Apple **403** — *"This operation can only be performed by the Account Holder."* The org's only ASC key (`mrke4e5m`, `39X58XWA75`) is `APP_MANAGER`. |
| `credentials upload --platform macos …` | Rejected at argument parsing — `--platform` is `<ios\|android>`, full stop. |
| `credentials upload --platform ios --type distribution-certificate` with the real Developer ID `.p12` | Upload *succeeds*, and the record is then useless: `credentials view` → *"Unsupported credential type: undefined"*, and `macos sign` still reports **no Developer ID certificate stored**. It filters on platform, not on certificate content. Deleted again. |

So the store has no macOS ingest path at 0.73.1: `generate` is the only door and Apple guards it.
Note there is nothing to *migrate* anyway — the Developer ID on App Store Connect (`YR8L23ZCAV`,
serial `3FF0DE8B…`) is byte-for-byte the identity already in `env` and in the login keychain;
`generate` would mint a *second* certificate, not move this one. Revisit only when `upload` accepts
a Developer ID, or when an Account-Holder ASC key exists and a second certificate is actually
wanted.

SlopDesk is linked as a **non-Expo** project, so `better-update init` writes the project id to a
top-level `projectId` in `eas.json` at the repo root (not `app.json` — there is no Expo config
here). That file is the only better-update footprint in the tree.

`init` also scaffolds `development` / `preview` / `production` **build** profiles into that file,
including an Android `aab` format. They were deleted deliberately: better-update never builds this
repo, and leaving them implies a native pipeline that does not exist. `eas.json` here is one key.
If you re-run `init`, trim it again.

Variables in environment `production`, all `--visibility sensitive`:

| Key | What |
|-----|------|
| `APPLE_CERTIFICATE_P12_BASE64` | The Developer ID Application identity + private key, exported as a `.p12`, base64 (single line) |
| `APPLE_CERTIFICATE_PASSWORD` | The export passphrase for that `.p12` |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID (not the account password) |
| `APPLE_TEAM_ID` | `AJ4R8GWM7A` |
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT, `Contents: read+write` on `aislopware/homebrew-tap` **only** |

The signing identity is **`Developer ID Application: WEEBUILD VIET NAM COMPANY LIMITED
(AJ4R8GWM7A)`** — the same identity that signs the idealabs desktop app
(`idealabs-tools/scripts/release-desktop.ts`). One company identity, several products; it lives in
the vault once and every pipeline pulls it.

### Exporting the p12 (interactive — a human must do this)

`security export` needs a keychain-access decision that no script can answer for you:

```bash
security export -k login.keychain-db -t identities -f pkcs12 \
  -P "$(openssl rand -base64 24)" -o ~/Desktop/developer-id.p12
```

Keep the passphrase it prints. Then, from the repo root:

```bash
better-update org switch weebuild
better-update env set APPLE_CERTIFICATE_P12_BASE64="$(base64 -i ~/Desktop/developer-id.p12)" \
  --visibility sensitive --environment production
better-update env set APPLE_CERTIFICATE_PASSWORD='<the passphrase>' \
  --visibility sensitive --environment production
rm ~/Desktop/developer-id.p12          # the vault is now the only copy outside the keychain
```

The CLI must be newer than `0.72.0` — older builds are refused by the server. CI installs
`@latest` **with `--minimum-release-age=0`**, and that flag is load-bearing: bun holds back
packages published in the last 24 h by default, so a bare `@latest` can quietly resolve to a
build the server then rejects. That hazard is why this used to be pinned to an exact version;
disabling the hold-back removes it without freezing CI on a build that ages out.

Every `credentials` and `env set` command needs the org vault **unlocked** on this device
(`better-update credentials unlock`, which prompts for the device passphrase and caches the key in
the OS keychain). A locked vault does not error — the command sits on a prompt, which in a
non-interactive context reads as a hang.

### The CI robot

CI authenticates with `BETTER_UPDATE_ROBOT`, stored as the **only** GitHub Actions secret on
`aislopware/slop-desk`. A robot needs an explicit grant on the E2E vault (`better-update
credentials access`) — being a member of the org is not enough to decrypt. Without that grant
`env pull` returns ciphertext it cannot open and the signing step fails on an empty
`APPLE_CERTIFICATE_P12_BASE64`.

## This repo is public — the masking rule

`aislopware/slop-desk` is a public repo, so every line CI prints is public forever. Two rules
hold the line, and both are load-bearing:

1. **One step touches secrets.** Pull, mask, source, import, build, sign, notarize — all inside a
   single `run:`. Nothing secret is written to `$GITHUB_ENV`, so no later step can echo it.
2. **`::add-mask::` is registered before any value can be printed.** `better-update env pull
   --stdout` emits `export KEY='value'` lines; the workflow parses and masks every value the
   moment the file lands, before sourcing it.

A value printed before its mask is registered is not retroactively hidden. If you add a variable
to the vault, it is masked automatically by that loop — but if you add a *step* that handles it,
you own the leak.

## Cutting a release

```
make release-preview     # the version and the notes the next cut would produce; writes nothing
make release             # version + CHANGELOG.md + all six version sites + commit + tag
git push origin main && git push origin vx.y.z
```

`scripts/cut-release.sh` is the whole procedure, and it exists because the manual version of it
had six steps that were each individually easy to forget. It refuses to run off `main` or on a
dirty tree, then:

1. **Decides the version** with `git cliff --bumped-version`, which reads the conventional-commit
   types since the last tag: a `feat` moves the minor, a `fix`/`perf`/`refactor` moves the patch,
   a `!` or a `BREAKING CHANGE:` trailer moves the major (below 1.0, the minor). Pass a version
   argument — `make release VERSION=0.3.0` — to override it.
2. **Renders `CHANGELOG.md`** from the same commit log (`cliff.toml`), with the pending commits
   filed under the version about to be tagged rather than left under *Unreleased*.
3. **Writes the version into all six sites** via `scripts/bump-version.sh`, which greps every one
   of them back afterwards and fails on a substitution that silently did nothing.
4. **Commits and tags** — `chore(release): vx.y.z`, the one subject `cliff.toml` skips, so the
   release commit never appears in the next release's notes.

It does **not** push. The tag push is what starts the signing pipeline, so it stays a separate
keystroke. Then run `make check` and dry-run the workflow (Actions → Release →
`workflow_dispatch`, version `x.y.z`, **dry-run checked**) if the change touched packaging;
finally verify the published artifact:

```
brew update && brew install --cask aislopware/tap/slopdesk
spctl -a -vvv -t install /Applications/SlopDesk.app     # accepted / Notarized Developer ID
```

### The six version sites — the PRODUCT's

`bump-version.sh` owns these; the table is here because the gates cannot see most of them. Every
one of them carries the same number, and it moves on every cut, because all six describe one thing:
the app the user installed. A sidecar is versioned separately — see the next section.

| File | Key | Why it is separate |
|---|---|---|
| `Sources/SlopDeskCLICore/CLIVersion.swift` | `version` | what `slopdesk version` prints |
| `Sources/SlopDeskHost/HostEnvironment.swift` | `buildVersion` | advertised to the child shell as `TERM_PROGRAM_VERSION` |
| `Apps/ClientApp-macOS/project.yml` | `MARKETING_VERSION` **and** `info.properties.CFBundleShortVersionString` | `GENERATE_INFOPLIST_FILE: NO`, so the literal in `info.properties` is what lands in Info.plist — `MARKETING_VERSION` does **not** reach it |
| `Apps/HostApp-macOS/project.yml` | same two | same reason |
| `Apps/ClientApp-macOS/Info.plist`, `Apps/HostApp-macOS/Info.plist` | `CFBundleShortVersionString` | xcodegen output that is nevertheless committed, so a clean checkout builds without running xcodegen first — which is exactly why it goes stale silently |

`package-release.sh` asks the built **CLI binary** for its version and **refuses to package** on
drift. That gate covers `CLIVersion.version` only — it never opens either Info.plist and never
reads `HostEnvironment.buildVersion`. At v0.2.1 both plists still read `0.1.0` and every local
`xcodebuild` produced an app claiming that version; releases were unaffected only because
`stamp_and_sign_app` rewrites `CFBundleShortVersionString` with PlistBuddy before signing. That
stamp is why nobody noticed for two releases, not evidence the tree was right.

`Apps/ClientApp-iOS/*.yml` carry their own `0.1.0` and are deliberately left alone: no iOS release
pipeline exists (see "Deliberately not done").

## Every sidecar carries its own version

The six sites above are one number for one product. The twelve binaries in the tarball are not one
product — each is its own process with its own lifetime, and the expensive ones outlive the release
that installed them. superd holds the master fd of every live pane (`docs/51`), so restarting it
costs the user every running agent. Under one shared number that price was paid on **every**
upgrade, because nothing could tell that superd had not changed: a one-line fix in the Android
bridge and every pane on the machine came down with it.

So each cargo tool now carries the version in its own `Cargo.toml`, and that version moves only
when the tool did.

| Piece | What it is |
|---|---|
| `scripts/shipped-tools.sh` | the tool list and the tool→crate map, SOURCED by the four scripts that need it |
| `scripts/tool-stamps.sh` | a sha256 over each tool's source closure — its crate plus every local crate it links, derived from the cargo graph |
| `scripts/tool-stamps.pin` | `<tool> <version> <stamp>` as of the last release. Written by the bumper, never by hand |
| `scripts/bump-tool-versions.sh` | stamp moved ⇒ bump; stamp same ⇒ leave it. Called by `cut-release.sh` |
| `MANIFEST.json` | in the tarball and attached to the release: one entry per binary, with its version, its stamp and its SHA |

Two questions, two sources, and they are not interchangeable. **Did this tool change** is the
*stamp*, never the commit log — a commit that touches only prose or a fixture inside a crate
directory changes no binary, and a commit to `rust/slopdesk-sanitize` changes screend and superd
while naming neither. **By how much** is the commit log, scoped to the same closure and read with
the same conventional-commit grammar the product bump uses.

When they disagree the stamp wins in both directions: a changed stamp with no bump-worthy commit
takes a patch (something really is different, and shipping it under the old version would make the
install side skip a restart it needed); an unchanged stamp with commits present takes nothing (they
reached a README, and a version that moved would restart a daemon to install the identical binary).

### The version is the identity, not the SHA

`package-release.sh` signs every binary with `--timestamp`, so an unchanged tool rebuilt and
re-signed has **different bytes every time**. Comparing shipped SHAs across two releases would
report every tool as changed, forever — the exact behaviour this exists to end. `MANIFEST.json`
carries a `sha256` per tool for integrity of *that* file *now*, and the `stamp` beside it is what
decided the version was allowed to move; the comparison an upgrade makes is on `version`.

Two gates keep the number honest, and they are deliberately in different places:

* `check-invariants.py` — every shipped cargo tool has a pin entry, and every pin entry names a
  shipped tool. Runs in `make check`.
* `package-release.sh` — asks every **built** binary `--version` and refuses to package on a
  disagreement with the pin. The same question the CLI gate has always asked, now asked of all twelve,
  and asked of the binary rather than the source, so a stale artifact staged by `locate_tool` is
  caught here instead of on a user's machine.

There is deliberately **no** gate that fails when a sidecar's sources have changed since the last
release: that is the ordinary state of `main`, so it would be red almost always and mean nothing
when it was. `make tool-versions` prints the same information as a report.

Every cargo tool answers `--version` with the version in the **second whitespace-separated field of
the first line** — the shape `slopdesk version` has always had and `package-release.sh` has always
parsed. The parenthetical after it, where there is one, is a *protocol* number and a different
thing entirely: superd's `1.8`, dropd's `1`, screend's banner digit. A reader who conflates the two
concludes a patch release requires a client update.

## The running daemon, and the one on disk

An upgrade does not reach a running daemon. superd and screend are LaunchAgents held across logins;
dropd, inspectord and androidd are superd's children that a restarted hostd **adopts** rather than
starts. `brew upgrade` therefore writes twelve new binaries and changes what is executing for none of
them — a host silently running last week's code behind this week's version number.

The fix is not "restart everything", which is the price the shared version number already charged.
It is: ask each daemon what it is **running**, compare that with what is **installed**, and act only
where acting is cheap. Each daemon reports on the channel it already has:

| Daemon | Channel | Shape |
|---|---|---|
| superd | `hello` reply, protocol minor **8** | `buildVersion` — a field, because superd has a real handshake and rule 4 of `docs/51` §3 says a verb would be the expensive answer |
| screend | `hello` reply payload | `slopdesk-screend 1 <build>` — the pinned `HELLO_BANNER` is the *protocol* identity and stays byte-identical; the build version is a third field appended after it |
| dropd, inspectord, androidd | the **announce line** | `(v<build>, …` — first in the parenthetical, `v`-prefixed |

The announce line is the right place for the last three precisely because they outlive hostd: hostd
re-learns a survivor's port by replaying superd's ring from offset 0, so that line is already the
only channel describing a child this hostd did not start. Putting the version anywhere else would
leave it missing on exactly the path that needs it. `AnnouncedPort.directlyAfter` was already
documented to take the digits as a run, so appending words after the port was compatible by
construction; `AnnouncedVersion.directlyAfter` beside it reads the new field, searching from the end
of the port marker so a `(v` in a path cannot win.

Every **installed** version is `<binary> --version`, field two of line one — one contract, every
shipped binary — resolved through the same `RustServicePaths.locate` the spawn uses, so the audit can
never compare against a binary that is not the one that would run.

### What hostd does about a mismatch

`rust/slopdesk-sidecars` is the pure comparison and the policy table, reached through
`slopdesk_sidecar_audit`; `SidecarVersionAuditor` assembles the numbers and carries out the one
permitted action. The policy is Rust rather than Swift because it has a **second caller** in the
other half of this mechanism — `slopdesk sidecars`, below — and a table in each language is the
cross-language mirror `CLAUDE.md` bans. `slopdesk-hostd` runs it once at startup, after the sidecars
are up, and logs one line each.

| Policy | Daemons | Why |
|---|---|---|
| `automatic` | dropd, inspectord, androidd | hostd's own children. It ends the stale one and re-opens on the **same** port and drop directory, so a client that reconnects finds it unmoved. androidd is only ended — its port is the OS's, and the next `ensure` round boots the installed binary |
| `selfRetiring` | screend | it exits after `SLOPDESK_SCREEND_IDLE_EXIT` (2 minutes) of quiet and `ScreenClient` starts the installed one on the next verb. The window closes with nobody acting, and hostd holds no handle to a LaunchAgent anyway |
| `operatorChoice` | superd, hostd, and anything this table has not been taught about | ending superd ends every live pane; hostd is the process `CLAUDE.md` forbids killing, and its relaunch is a user quitting an app they may be working in. Information, never an action — and an unknown restart cost is an unknown, so the safe default is "ask" |
| `notResident` | slopdesk, slopdesk-ctl, slopdesk-probe, slopdesk-hook, slopdesk-agenthooks, slopdesk-codeseed | forked per event and gone: `slopdesk` once per invocation, the hook twice per tool call. Replacing the file **is** the upgrade, completed. Kept apart from `automatic` because "restarted" and "was never running" read identically in a log line and mean opposite things the day one of them stops being true |

A missing number on either side is `unknown`, never `current`. Reporting a stale sidecar as up to
date is the silent wrong answer the whole mechanism exists to remove, and the two `nil`s are kept
distinct because they call for opposite fixes: a daemon that reports no version predates the field
and a restart resolves it; an install that reports no version is broken and a restart makes it
worse.

`scripts/check-supervisor.sh` ratchets all of it — the `buildVersion` field on both sides of
superd's hello, `hello_payload` and its Swift parse for screend, and the four spellings of the
announce version marker against the three managers that read it. A skew in any of them is the
quietest failure in this tree: the parser finds no marker, reports `unknown`, and the host goes on
running the old daemon with green tests and a working panel.

### The other half: what the INSTALL knows

The audit above asks live daemons. That is the right question at hostd's start and the wrong one at
install time, and the reason is timing: `brew upgrade` runs while every daemon is still serving the
**old** binaries, so a live audit at that moment reports all twelve as stale whether one tool
changed or twelve. It cannot tell an upgrade apart from a reinstall.

What an install *can* answer is about files: the `MANIFEST.json` that just landed, against the one
recorded after the previous install. Their difference is exactly the set this upgrade touched, and
it is known before anything is dialled, spawned or ended. That is `slopdesk sidecars`:

```
$ slopdesk sidecars
TOOL              WAS    NOW    CHANGE     NEXT
slopdesk          0.4.0  0.5.0  changed    nothing of it is resident; the next invocation is the new one
slopdesk-hostd    0.4.0  0.5.0  changed    quit and relaunch SlopDeskHost.app when convenient; its own audit then restarts the sidecars it owns
slopdesk-superd   0.1.0  0.1.0  unchanged  unchanged; nothing to do
slopdesk-screend  0.1.0  0.2.0  changed    it retires itself once idle, and the next verb starts the new one
slopdesk-dropd    0.1.0  0.2.0  changed    hostd restarts it the next time it starts
```

The diff, the wording of every `NEXT` and the policy behind it are `rust/slopdesk-sidecars` —
the same table hostd's audit reads, which is the whole reason it is in Rust. `--json` emits the
record form; `--manifest` / `--previous` point at either file explicitly.

**The previous manifest has to be recorded, not found.** Homebrew replaces the Cellar directory
wholesale, so the old release's `MANIFEST.json` is gone by the time anything could compare against
it. `slopdesk sidecars --record` copies the current one into the Application Support container,
where it survives the thing it describes, and the formula's `post_install` is what runs it. An
install that never recorded reads as a first install: every tool `added`, nothing claimed.

**It restarts nothing, deliberately.** hostd owns the lifetime of the three daemons it spawned and
restarts the stale ones at its next start; screend retires itself; superd is the user's call because
ending it ends every live pane. A CLI that killed dropd here would leave file-drop dead until the
next hostd start, because `FileDropServiceManager.start` is called once at startup and not on
demand. So the install side reports and records, and the runtime side acts — which is why the
`slopdesk-hostd` line above says to relaunch the app: that relaunch **is** the restart mechanism.

### The formula lives here now

`packaging/homebrew/Formula/slopdesk.rb` and `packaging/homebrew/Casks/slopdesk.rb` are the source
of truth; the `tap` job **copies** them into `aislopware/homebrew-tap` and rewrites two lines each,
`version` and `sha256`, verifying afterwards that both rewrites landed.

They moved because the tap was edited in place and nothing could check it. For four releases its
`bin.install` named three of the twelve binaries — `slopdesk`, `slopdesk-hostd`, `slopdesk-ctl` —
so a `brew install` produced a host with no superd and therefore no pane, which is the exact bug
`the_release_ships_every_sidecar_the_host_needs` was written to end, surviving one step further
down the pipeline in a file that gate could not see. `check-invariants.py` now derives the
formula's install list from `scripts/shipped-tools.sh` as well, and checks that `MANIFEST.json` is
installed alongside it.

The same edit made two things this document already claimed actually true: the formula's `service`
block, and the cask's `depends_on formula: "slopdesk"`.

## Commit subjects are release input

The commit TYPE is read twice by the release: once to decide the version, once to decide which
section of `CHANGELOG.md` the change lands in. A subject outside the conventional-commit grammar
contributes to neither — silently. So it is gated at commit time by
`scripts/check-commit-msg.sh`, wired as a `commit-msg` hook in `.pre-commit-config.yaml`:

```
<type>[(scope)][!]: <subject>
type: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test
```

This is the same bargain `better-update` strikes with commitlint on lefthook, minus the Node
dependency — the rule is a regex, and every hook in this repo is `language: system` so there is no
environment to provision.

### The subject is published text

The grammar is only half of it. `changelog-section.sh` slices these subjects out of `CHANGELOG.md`
and the GitHub Release body is **one bullet per subject, verbatim** — so a subject written to be
read inside the repo becomes a release note read by someone who has never seen it. The rule is:
**say what the change does, in the imperative, to a reader who was not here.**

The hook enforces what a regex honestly can:

| Rejected | Because | Instead |
|---|---|---|
| opens with `the` / `a` / `an` | a sentence *about* the code, not a change to it — the reader has to reverse-engineer what moved and whether it affects them | open with a verb |
| `adds`, `fixes`, `stopped`, `updated`, … | third person or past tense | the imperative `git revert` and `git merge` already write for you |
| a trailing full stop | a subject is a title | drop it |
| longer than 72 chars | GitHub ellipses it, and the rendered bullet stops being scannable | move the detail to the **body**, which the changelog never reads |

A gerund opening (`Adding …`) warns rather than blocks: `bring`, `ping` and `string` are
imperatives that end the same way.

```
✗ fix(rail): the plate stops sliding between projects — it ignites in the one it lands in
✓ fix(rail): stop the selection plate sliding between projects

✗ fix(ui): a border that matches its own fill stops passing for a border
✓ fix(ui): give the chip rim a colour distinct from its fill
```

**Not retroactive, and the change of habit is large**: measured against the 162 non-merge commits
before the rule landed, 149 of them (91%) would be rejected — 117 for the opening article, 31 for
length. History keeps its style; `cliff.toml` renders it as-is. Only new commits are held here.

`cliff.toml` skips almost nothing, which is deliberate: git-cliff drops a release whose commits
all got skipped, **header and all**. v0.2.1 carried one `ci` commit and one `chore(release)`
commit, and hiding both would have deleted the release from the file entirely — then
`changelog-section.sh 0.2.1` fails on a version that genuinely shipped. Emphasis comes from
ordering instead: features and fixes on top, tooling underneath.

### Where the release notes come from

`scripts/changelog-section.sh <version>` slices one release out of `CHANGELOG.md`. The publish job
posts that slice, and **fails when the section is missing** rather than falling back to prose. A
second copy of the same check runs in the `package` job right after the version resolves, so a tag
with no notes fails in seconds instead of after a ~20-minute signed, notarized build.

**The slice is the whole body.** Install, Requirements, Signing and a Checksums block used to sit
underneath it — four sections byte-identical in every release, so repetition from the second one
onward, and each already has a home that stays current on its own:

| Was in the body | Lives in |
|---|---|
| Install, Requirements | `README.md` |
| Signing | this document |
| Checksums | the `SHA256SUMS` asset attached to the release |

A release note answers one question — what changed — and a section that does not answer it pushes
the part that does off the first screen. Before any of this, the body was **only** those fixed
lines: `v0.2.1` and `v0.2.2` taught a reader exactly the same nothing.

The assembly writes to `$RUNNER_TEMP`, not the checkout. A scratch `changelog.md` beside the repo's
`CHANGELOG.md` is one case-insensitive filesystem away from the redirect truncating the file the job
exists to read; it does precisely that on macOS, and `runs-on` is one line of config.

## `--product`, never `--target`

Under the Swift 6.3 build backend `swift build --target slopdesk` compiles the module, prints
*Build of target: 'slopdesk' complete!* and **never links a binary** — a green build with nothing
to ship. Only `--product` links (*Linking slopdesk*), and `--product` needs a declared product, so
`Package.swift` exposes the two shipped SwiftPM executables — `slopdesk`, `slopdesk-hostd` — as
`.executable` products. The other `executableTarget`s are dev/bench tools and stay product-less on
purpose.

Everything else in the tarball is Rust, and `package-release.sh` builds it with
`cargo build --release --target aarch64-apple-darwin`. That target triple is explicit for the same
reason `--arch arm64` is on the Swift half. `locate_tool` resolves a cargo binary to its cargo path
or to *nothing* — deliberately never falling through to the SwiftPM search, because a stale
`.build*/release/slopdesk-ctl` left by the deleted Swift target would otherwise ship silently under
the right name, and that is the one substitution the `slopdesk version` check cannot catch.

## What the tarball ships, and why the list is not shorter

Ten binaries, not three. The three it used to be — `slopdesk`, `slopdesk-hostd`, `slopdesk-ctl` —
produced a host that could not open a pane, because `slopdesk-superd` forks and owns every PTY
master and hostd has no fallback path (`docs/51`; `HostServiceSupervisor.connected()` says it in
one line). The other five daemons each cost a feature outright: no screen engine, no file drop, no
inspector, no Android panel, no profile seed.

The cargo half splits along the **workspace** boundary, and so does the build:

| Group | Binaries | Built from | Lands in |
| --- | --- | --- | --- |
| root workspace members | `slopdesk-ctl`, `slopdesk-probe`, `slopdesk-hook`, `slopdesk-agenthooks` | `rust/`, with `-p` | `rust/target/…` |
| own-workspace daemons | `slopdesk-superd`, `-screend`, `-dropd`, `-inspectord`, `-androidd`, `-codeseed` | the crate's own directory | that crate's own `target/` |

`rust/Cargo.toml` `exclude`s every daemon, so `cargo build -p slopdesk-superd` from `rust/` fails —
cargo cannot see a package it excluded. That same seam is the one `RustServicePaths` walks, which is
why one function walks for a per-crate `target/` and the other only looks beside the executable.

`slopdesk-hook` is not optional trim: `slopdesk-agenthooks` installs the relay from
`executable.parent()/slopdesk-hook`, so the two must land in the same directory. That is also why
the formula puts everything in one flat `bin` rather than tucking the daemons into `libexec`.

`check-invariants.py` derives the required set from the `RustServicePaths.locate`/`locateBeside`
call sites and compares it with the tool arrays in `package-release.sh`, so a seventh daemon cannot
be forgotten the way six were. It reads the ARRAYS, not the file: a first draft grepped the script
whole and the comment naming every daemon satisfied it on its own.

## superd is a service, not a caveat

`packaging/homebrew/Formula/slopdesk.rb` carries a `service` block, so `brew services start slopdesk` runs superd as a LaunchAgent
under `homebrew.mxcl.slopdesk`. It is `keep_alive successful_exit: false`, never a bare `true`, and
that detail is load-bearing: superd exits **0 on purpose** when another instance already holds its
lock file, rather than stealing a live socket and stranding the panes behind it. A bare `KeepAlive`
restarts on any exit, so the loser respawned every ten seconds forever. A machine with both agents —
this one and a checkout's `com.slopdesk.superd` from `scripts/install-superd.sh` — now settles, with
whichever booted first keeping the panes. `install-superd.sh` was fixed to the same form.

The **cask depends on the formula** (`packaging/homebrew/Casks/slopdesk.rb`). `SlopDeskHost.app` does not shell out to `slopdesk-hostd`; it
runs the same `HostServer` in-process, so it needs superd exactly as much as the CLI does, and a
cask-only install was the same broken host wearing a menu-bar icon. The CLI tools coming along is a
side effect of declaring the real dependency.

`package-release.sh` also pins `--scratch-path .build-release` rather than discovering the output
directory, and still *searches* it for the SwiftPM binaries instead of assuming a layout: the path
differs by build backend (`<triple>/release` vs `Products/Release`), and a packaging script that
cannot find its own output fails three minutes into CI instead of at the flag.

`scripts/package-release.sh` names `SlopDesk.app` without ever launching it, which is the first
counterexample to `GuiGateLaunchContractTests`'s "names it ⇒ launches it" net. It is declared in
that file's `nonLaunchingScripts`, and a companion test re-derives the claim — add an `open` there
and the suite fails with the verb named.

## What v0.1.0 (the first real cut) established

- **Notarization works end to end.** Both bundles report `accepted / source=Notarized Developer
  ID` and the DMG carries a stapled ticket.
- **The `tap` job has never run successfully.** On v0.1.0 it died on `Project not linked` (exit 4)
  because it had no `actions/checkout` — the vault client resolves the project from `eas.json` in
  the working directory. Fixed in the workflow (checkout first, ahead of `download-artifact`, so
  nothing wipes `dist/`), but the v0.1.0 tap commit was made **by hand** from the published
  `SHA256SUMS`. The next release is the first real exercise of that job.
- **Only the DMG was stapled, not the apps inside it.** A cask copies `SlopDesk.app` out of the
  image, so the installed app had no ticket of its own and Gatekeeper resolved it online — fine on
  a networked machine, a failed first launch offline. Verified on the shipped v0.2.1 DMG:
  `stapler validate SlopDesk.app` → *does not have a ticket stapled to it*.

  **Fixed in §3b of `package-release.sh`** (from v0.2.2): both bundles are zipped and notarized in
  one submission, each is stapled, and only then is the image built from the stapled originals.
  Ordering is the whole trick — the bundle inside the DMG is a *copy*, so a staple after
  `hdiutil create` reaches nothing. Moving that block below the image step leaves the pipeline
  green and silently ships unticketed apps again, so §3b validates each staple and `die`s on a
  miss rather than trusting the exit code. Cost: one extra notarization round per release.

## Known-fragile: the libghostty job

This is the part most likely to break, and it breaks in CI in ways it does not break locally.
`build-libghostty.sh` is documented at length in its own header; the three that bite in CI:

- **It needs a macOS SDK ≤ 15.x** for its `xcrun` shim, because Zig 0.15.2 cannot link the macOS
  26 SDK. The workflow *searches* for one across the runner's Xcode bundles instead of trusting
  the script's default CLT path, and fails with an explicit message if the image ships none. If
  that happens the fix is to pin an older Xcode (`maxim-lobanov/setup-xcode`), not to bump Zig —
  ghostty does not compile under 0.16 (README, "Why Zig stays 0.15.2").
- **It needs the Metal toolchain** (`xcodebuild -downloadComponent MetalToolchain`), without which
  the libtool step never runs and the harvest silently finds nothing.
- **`zig build` is EXPECTED to exit non-zero.** The script harvests the intermediate libtool
  archives itself and re-archives them (caveat #3). A future "fix" that makes the job fail on that
  exit code will break the build for the wrong reason.

Because it is slow and fragile, it is a separate job keyed on `hashFiles` of the recipe, the
consolidated fork delta and the README pins. It reruns only when one of those changes.

## Deliberately not done

- **No Sparkle / in-app updater.** `brew upgrade` is the update channel. Doc 06 §5 lists Sparkle
  as an option; the tap is the one that shipped.
- **No Mac App Store.** The host cannot be sandboxed (doc 06 §4) — MAS is closed to it by
  construction.
- **No iOS client release.** `Apps/ClientApp-iOS` builds, but TestFlight/App Store distribution is
  a separate pipeline and better-update *does* cover that path natively when it is wanted.
- **No x86_64.** See above.
