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
   package     →  scripts/package-release.sh             (build → stamp → sign → notarize)
   publish     →  GitHub Release v<version>
   tap         →  aislopware/homebrew-tap                (version + sha256 rewrite)
        ▼
brew install aislopware/tap/slopdesk           # slopdesk, slopdesk-hostd, slopdesk-ctl
brew install --cask aislopware/tap/slopdesk    # SlopDesk.app + SlopDeskHost.app
```

`scripts/package-release.sh` is the single source of truth for *how* a release is built. CI runs
it unmodified, so a maintainer reproducing a failure locally runs the same code path.

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

It *can* sign and notarize macOS, though — `better-update macos sign|notarize` (CLI ≥ 0.73.1)
does Developer-ID signing with hardened runtime, notarizes, and staples. We do **not** use it, for
one concrete reason: it reads the certificate from the *credentials* store, and the only way to
get a Developer ID in there is `credentials generate distribution-certificate --type developer-id`,
which **issues a new certificate** — `credentials upload` is still `--platform=<ios|android>` with
no developer-id type, so the existing `.p12` cannot be imported. Our identity lives in `env` and
`package-release.sh` drives `codesign`/`notarytool` directly, which is proven and costs no second
certificate. Revisit only if `upload` learns to take a Developer ID.

(A related correction: the *credentials* store is not iOS/Android-only, as an earlier version of
this doc implied. `generate` reaches macOS; `upload` and `configure` do not.)

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

The CLI must be newer than `0.72.0` — older builds are refused by the server. **Pin the version
explicitly** (`bun add -g @better-update/cli@0.73.1`): bun's `minimumReleaseAge` holds back
packages published in the last 24 h, so `@latest` can quietly resolve to a build the server then
rejects.

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

1. Bump the version in **five** places — `grep -rn '<old version>' Sources Apps` before you tag:

   | File | Key | Why it is separate |
   |---|---|---|
   | `Sources/SlopDeskCLICore/CLIVersion.swift` | `version` | what `slopdesk version` prints |
   | `Apps/ClientApp-macOS/project.yml` | `MARKETING_VERSION` **and** `info.properties.CFBundleShortVersionString` | `GENERATE_INFOPLIST_FILE: NO`, so the literal in `info.properties` is what lands in Info.plist — `MARKETING_VERSION` does **not** reach it |
   | `Apps/HostApp-macOS/project.yml` | same two | same reason |
   | `Sources/SlopDeskHost/HostEnvironment.swift` | `buildVersion` | advertised to the child shell as `TERM_PROGRAM_VERSION` |

   Then run `xcodegen generate` for both specs and **commit the regenerated
   `Apps/*/Info.plist`**. Those two files are build output that is nevertheless committed, so they
   go stale silently: at v0.2.1 both still read `0.1.0`, and every local `xcodebuild` produced an
   app claiming that version. Releases were unaffected only because `stamp_and_sign_app` rewrites
   `CFBundleShortVersionString` with PlistBuddy before signing — that stamp is the reason nobody
   noticed for two releases, not evidence the tree is right.

   `package-release.sh` asks the built **CLI binary** for its version and **refuses to package** on
   drift. That gate covers `CLIVersion.version` only — it never opens either Info.plist and never
   reads `HostEnvironment.buildVersion`, so those two can ship stale with a fully green pipeline.
   `Apps/ClientApp-iOS/*.yml` carry their own `0.1.0` and are deliberately left alone: no iOS
   release pipeline exists (see "Deliberately not done").
2. `make check` (lint + build + test + golden).
3. Dry run: Actions → Release → `workflow_dispatch`, version `x.y.z`, **dry-run checked**. Builds
   and signs, skips notarization, the Release and the tap bump. Artifacts land on the run.
4. `git tag vx.y.z && git push origin vx.y.z` — the tag push runs the real thing.
5. Verify: `brew update && brew install --cask aislopware/tap/slopdesk`, then
   `spctl -a -vvv -t install /Applications/SlopDesk.app` should say *accepted / Notarized
   Developer ID*.

## `--product`, never `--target`

Under the Swift 6.3 build backend `swift build --target slopdesk` compiles the module, prints
*Build of target: 'slopdesk' complete!* and **never links a binary** — a green build with nothing
to ship. Only `--product` links (*Linking slopdesk*), and `--product` needs a declared product, so
`Package.swift` exposes the three shipped executables as `.executable` products. The other
`executableTarget`s are dev/bench tools and stay product-less on purpose.

`package-release.sh` also pins `--scratch-path .build-release` rather than discovering the output
directory, and still *searches* it for the binary instead of assuming a layout: the path differs by
build backend (`<triple>/release` vs `Products/Release`), and a packaging script that cannot find
its own output fails three minutes into CI instead of at the flag.

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
