# Install, build, run

Overview and architecture: [`README.md`](README.md). Repo rules and invariants:
[`CLAUDE.md`](CLAUDE.md).

## Install

Apple silicon, macOS 26 or newer. Signed and notarized, two packages installed independently:

```sh
brew install --cask aislopware/tap/slopdesk  # SlopDesk.app, the client viewer
brew services start slopdesk                 # slopdesk-superd, required, see below
```

The cask depends on the formula, so that first command also installs the CLI (`slopdesk`,
`slopdesk-hostd`, `slopdesk-ctl`) and the sidecar daemons. `brew install aislopware/tap/slopdesk`
alone gets you those without the apps.

`brew services start slopdesk` is not optional. `slopdesk-superd` holds every pane's PTY master,
which is what lets you restart the host without killing the agents under it, and neither the host
app nor `slopdesk-hostd` forks a shell itself. Without the service running there are no panes.

The app bundles carry no copy of the CLI. Signed artifacts also live on the
[releases page](https://github.com/aislopware/slop-desk/releases); how they are built and signed is
[`docs/49-release-pipeline.md`](docs/49-release-pipeline.md).

## Toolchain

Every gate, build and test in this repo is a `just` recipe. `just --list` names all of them, and
`just help` groups them. Install `just` first, then let it bring the rest, including the pinned
copy of itself:

```sh
brew install just
just install-tools
```

## Build and test

The headless core needs no GUI, no Metal and no signing:

```sh
swift build
swift test
just check-ios   # iOS slice (#if os(iOS)), needs Xcode
```

Gates: `just quick` after every edit, `just check` once before pushing. The gate matrix and the
`SLOPDESK_*` environment flags are [`docs/46-gates-env-paths.md`](docs/46-gates-env-paths.md).

## Run the host

Terminal path:

```sh
swift build -c release
.build/release/slopdesk-hostd --port 7420
.build/release/slopdesk-hostd --port 7420 --inspector   # inspector on port+1
```

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port (default `7420`, `0` = OS-chosen) |
| `--shell`, `-s` | Login shell (default: the user's) |
| `--inspector` | Read-only inspector on `port + 1` |
| `--transcript PATH` | Claude Code JSONL path (implies `--inspector`) |

Sessions survive a disconnect, and clients resume from the replay buffer. Claude is a normal shell
running `claude`, detected automatically.

Restart the host with `just host-restart`, which replays hostd's recorded launch. Never `pkill` it.
The restart is the config reload; there is no live one.

GUI-window path. Needs Screen Recording and Accessibility permission, and a real GUI session.
`slopdesk-videohostd` ships in the formula and is a LaunchAgent of its own in a checkout
(`just videohostd-install`), because TCC grants go to the responsible process: a daemon started
from a Terminal is granted AS that Terminal, and a launchd job is granted as itself. The client's
remote-window pane dials it on UDP 9000/9001 and reports "no video host answered" after ten
seconds if nothing is listening. By hand, from a desktop Terminal:

```sh
rust/slopdesk-videohostd/target/release/slopdesk-videohostd --list
rust/slopdesk-videohostd/target/release/slopdesk-videohostd            # serves every window the client picks
rust/slopdesk-videohostd/target/release/slopdesk-videohostd --window-id <N>
```

Window panes default to 30 fps, desktop panes to 60. `--fps N` overrides.

## Run a client

CLI client:

```sh
.build/release/slopdesk-client --host <host> --port 7420
# local escape: Ctrl-]   scripting: --no-raw
```

GUI apps. The terminal engine's sources are pinned in `ThirdParty/tools/tools.lock`, so provision
once:

```sh
just provision

xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj \
  -scheme ClientApp-macOS -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodegen generate --spec Apps/ClientApp-iOS/project.yml
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj \
  -scheme ClientApp-iOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Conventions

`CLAUDE.md` is the short version and the one to read: Rust is the default language, one
implementation per feature, `unsafe` is admitted in five crates, the wire is golden-pinned, and
commit subjects are release input, so never hand-edit `CHANGELOG.md` or bump a version by hand.

`just lint-invariants` enforces the cross-language contracts and each failure names its doc
section. `just lint-reach` covers what reading cannot decide: what a recipe would actually run, and
whether a linked artifact is older than its sources.

More detail: [`docs/68-terminal-surface-in-rust.md`](docs/68-terminal-surface-in-rust.md),
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).
