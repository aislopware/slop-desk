//! Build, Developer-ID sign, notarize and package a `SlopDesk` release.
//!
//! ## Why this exists
//! `make check` proves the tree is green; nothing else in the repo turns that tree into something
//! a stranger can install. This is the ONE place that knows how to go from a clean checkout to the
//! three shippable artifacts, so CI (`.github/workflows/release.yml`) and a human cutting a release
//! by hand run identical steps.
//!
//! ## ARM64 only — a hard constraint, not a default
//! * `ThirdParty/ghostty/libghostty.xcframework` ships a `macos-arm64` slice and nothing else, and
//!   `Apps/ClientApp-macOS` pins `ARCHS=arm64` because of it. An Intel client app cannot link.
//! * The apps deploy against macOS 26, which no Intel Mac runs.
//!
//! So this REFUSES to run on an `x86_64` host rather than emitting a half-broken slice.
//!
//! ## Artifacts, into `dist/`
//! | file | what |
//! | --- | --- |
//! | `SlopDesk-<version>-arm64.dmg` | `SlopDesk.app` + `SlopDeskHost.app`, signed + stapled |
//! | `slopdesk-cli-<version>-arm64.tar.gz` | the `SwiftPM` pair plus every sidecar the host resolves at runtime, signed, carrying `MANIFEST.json` |
//! | `MANIFEST.json` | one entry per shipped binary: its OWN version, its source stamp, its SHA |
//! | `SHA256SUMS` | what the Homebrew tap's cask + formula pin |
//!
//! The `libghostty` xcframework must already exist (`ThirdParty/ghostty/build-libghostty.sh`, or
//! the cached CI artifact). Building it here would hide a 20-minute Zig build inside a packaging
//! step.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::{env, fs};

use super::stamps::{self, Pin};
use super::tools;
use crate::proc;

/// The one triple this ships.
const TRIPLE: &str = "aarch64-apple-darwin";

/// The signing identity a run falls back to when the environment names none.
const DEFAULT_IDENTITY: &str = "Developer ID Application: WEEBUILD VIET NAM COMPANY LIMITED (AJ4R8GWM7A)";

/// Everything a packaging run reads out of the environment.
///
/// CI pulls these from the vault (`docs/49-release-pipeline.md`); a local run can lean on the login
/// keychain instead.
#[derive(Debug, Clone)]
pub struct Settings {
    /// Marketing version, no leading `v`.
    pub version: String,
    /// `CFBundleVersion`.
    pub build_number: String,
    /// The `codesign` identity.
    pub identity: String,
    /// Sign and package but do not submit. For pipeline dry runs ONLY — the output will NOT pass
    /// Gatekeeper on another machine.
    pub skip_notarize: bool,
    /// `notarytool --keychain-profile` name. Takes precedence over the Apple ID triple.
    pub notary_profile: Option<String>,
    /// `notarytool` credentials when no keychain profile exists.
    pub apple: Option<(String, String, String)>,
}

impl Settings {
    /// Read the environment, or say which variable is missing.
    ///
    /// # Errors
    /// When `SLOPDESK_VERSION` is absent, or notarization is on with no credentials for it.
    pub fn from_env() -> Result<Self, String> {
        let version = env::var("SLOPDESK_VERSION")
            .map_err(|_| "SLOPDESK_VERSION is required (e.g. 0.1.0, no leading v)".to_owned())?;
        let skip_notarize = env::var("SLOPDESK_SKIP_NOTARIZE").as_deref() == Ok("1");
        let notary_profile = env::var("SLOPDESK_NOTARY_PROFILE").ok().filter(|p| !p.is_empty());
        let apple = match (
            env::var("APPLE_ID"),
            env::var("APPLE_TEAM_ID"),
            env::var("APPLE_APP_SPECIFIC_PASSWORD"),
        ) {
            (Ok(id), Ok(team), Ok(password)) => Some((id, team, password)),
            _ => None,
        };
        if !skip_notarize && notary_profile.is_none() && apple.is_none() {
            return Err("set SLOPDESK_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + \
                        APPLE_APP_SPECIFIC_PASSWORD"
                .to_owned());
        }
        Ok(Self {
            version,
            build_number: env::var("SLOPDESK_BUILD_NUMBER").unwrap_or_else(|_| "1".to_owned()),
            identity: env::var("SLOPDESK_SIGN_IDENTITY").unwrap_or_else(|_| DEFAULT_IDENTITY.to_owned()),
            skip_notarize,
            notary_profile,
            apple,
        })
    }
}

/// The directories one run works in.
struct Layout {
    root: PathBuf,
    dist: PathBuf,
    work: PathBuf,
    derived_data: PathBuf,
    stage: PathBuf,
    cli_stage: PathBuf,
    scratch: PathBuf,
}

impl Layout {
    fn new(root: &Path, version: &str) -> Self {
        let work = root.join(".work/package-release");
        let stage = root.join(".work/package-release/stage");
        Self {
            root: root.to_path_buf(),
            dist: root.join("dist"),
            derived_data: work.join("DerivedData"),
            cli_stage: stage.join(format!("slopdesk-cli-{version}-arm64")),
            stage,
            work,
            // `--scratch-path` DICTATES where SwiftPM builds instead of leaving it to the
            // toolchain. On the CI toolchain the default scratch dir was not `.build` at all: all
            // three targets built, `.build` held only checkouts, and nothing named `slopdesk`
            // existed anywhere under it. A packaging step that cannot find its own output is the
            // one failure worth spending a flag on. `.build-release` is covered by .gitignore's
            // `.build-*/` and survives between local runs.
            scratch: root.join(".build-release"),
        }
    }

    /// Search roots for a `SwiftPM` product, widest last.
    ///
    /// Even inside a pinned scratch dir the layout differs by build backend (`<triple>/release` for
    /// llbuild, `Products/Release` for Swift Build), so the path is found, never assumed.
    fn search_roots(&self) -> Vec<PathBuf> {
        let mut roots = vec![self.scratch.clone(), self.root.join(".build")];
        if let Some(home) = env::var_os("HOME") {
            roots.push(PathBuf::from(home).join("Library/Developer/Xcode/DerivedData"));
        }
        roots
    }
}

/// The cargo directory a tool's binary lands in, or `None` if it is not a cargo tool.
///
/// The two answers are the two workspaces: a root member writes to the shared `rust/target/`, an
/// excluded daemon to its own `rust/<crate>/target/`. The hook installer is the one name that is
/// not its own crate — it rides the relay's package into the shared directory.
fn cargo_bin_dir(root: &Path, tool: &str) -> Option<PathBuf> {
    if tools::is_root_tool(tool) {
        return Some(root.join("rust/target").join(TRIPLE).join("release"));
    }
    if tools::is_crate_tool(tool) {
        return Some(
            root.join("rust")
                .join(tool)
                .join("target")
                .join(TRIPLE)
                .join("release"),
        );
    }
    None
}

/// True when `path` is a Mach-O executable — thin arm64 or a fat container.
///
/// The shell asked `file -b`; reading the magic is the same question with no process and no locale.
fn is_macho_executable(path: &Path) -> bool {
    let Ok(header) = fs::read(path) else { return false };
    let Some(magic) = header.get(..4) else {
        return false;
    };
    // A fat container's members are executables or the linker would not have produced it.
    if magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA] {
        return true;
    }
    // 64-bit Mach-O, little-endian — the only thin shape this tree builds.
    if magic != [0xCF, 0xFA, 0xED, 0xFE] {
        return false;
    }
    // `filetype` at offset 12; `MH_EXECUTE` is 2. A `.dylib` or a `.o` of the same name is not the
    // product, and `file` could not tell them apart without being asked twice.
    header
        .get(12..16)
        .is_some_and(|filetype| filetype == [2, 0, 0, 0])
}

/// Every file named `wanted` under `dir`, depth-first.
fn find_named(dir: &Path, wanted: &str, into: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            find_named(&path, wanted, into);
        } else if entry.file_name() == wanted {
            into.push(path);
        }
    }
}

/// Where the built `tool` is, or `None` with the layout dumped for the reader.
///
/// A cargo tool resolves to its cargo path or to NOTHING. Falling through to the `SwiftPM` search
/// would let a stale `.build*/release/slopdesk-ctl` — the Swift binary that one replaced — ship
/// silently under the right name, which is the one failure the version check cannot catch.
fn locate_tool(layout: &Layout, tool: &str, swift_bin: Option<&Path>) -> Option<PathBuf> {
    if let Some(dir) = cargo_bin_dir(&layout.root, tool) {
        let built = dir.join(tool);
        return built.is_file().then_some(built);
    }
    if let Some(bin) = swift_bin {
        let built = bin.join(tool);
        if built.is_file() {
            return Some(built);
        }
    }
    for root in layout.search_roots() {
        if !root.is_dir() {
            continue;
        }
        let mut candidates = Vec::new();
        find_named(&root, tool, &mut candidates);
        candidates.sort();
        for candidate in candidates {
            // Release paths only. A stale debug build of the same name must never reach the
            // tarball. No permission filter: a product directory created 0700 is still the product.
            let text = candidate.to_string_lossy();
            if !text.contains("/release/") && !text.contains("/Release/") {
                continue;
            }
            if is_macho_executable(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

/// One failure in the search costs a five-minute rebuild to diagnose, so spend the listing up front
/// rather than learning the layout one CI round-trip at a time.
fn dump_build_layout(layout: &Layout) {
    eprintln!("--- where did the products go? ---");
    for root in layout.search_roots() {
        eprintln!("[{}]", root.display());
        if !root.is_dir() {
            eprintln!("  (does not exist)");
            continue;
        }
        let mut hits = Vec::new();
        find_named(&root, "slopdesk", &mut hits);
        for path in hits.iter().take(40) {
            eprintln!("{}", path.display());
        }
    }
}

/// The first line's second field — the shape every tool in this tree answers.
fn reported_version(binary: &Path, flag: &str) -> Option<String> {
    let text = proc::ask(&binary.to_string_lossy(), &[flag], Path::new("/"))?;
    text.lines().next()?.split_whitespace().nth(1).map(str::to_owned)
}

/// Hex `SHA-256` of a file, in `shasum -a 256`'s own output shape.
fn sha256_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let bytes = fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut hex = String::with_capacity(64);
    for byte in Sha256::digest(&bytes) {
        let _ = write!(hex, "{byte:02x}");
    }
    Ok(hex)
}

/// Run the whole pipeline.
///
/// # Errors
/// At the first step that cannot be completed, with the reason a reader can act on.
pub fn run(root: &Path, settings: &Settings) -> Result<(), String> {
    let layout = Layout::new(root, &settings.version);
    preflight(&layout, settings)?;

    let swift_bin = build_cli(&layout)?;
    stage_cli(&layout, swift_bin.as_deref())?;
    check_versions(&layout, settings)?;
    sign_cli(&layout, settings)?;

    build_and_sign_apps(&layout, settings)?;
    notarize_apps(&layout, settings)?;

    let dmg = build_dmg(&layout, settings)?;
    write_manifest(&layout, settings)?;
    let tarball = build_tarball(&layout, settings)?;

    notarize_containers(&layout, settings, &dmg)?;
    checksums(&layout, &[&dmg, &tarball])?;

    println!("OK: {}", layout.dist.display());
    Ok(())
}

fn preflight(layout: &Layout, settings: &Settings) -> Result<(), String> {
    proc::step("Preflight");
    let machine = proc::capture("/usr/bin/uname", &["-m"], &layout.root)?;
    if machine != "arm64" {
        return Err(format!(
            "arm64-only release: this host is {machine}. libghostty ships no x86_64 slice."
        ));
    }
    // `cargo` is here for the same reason as the rest: the sidecars are Rust, and a missing
    // toolchain should fail in the preflight rather than after the ten-minute app builds.
    for tool in ["xcodegen", "xcodebuild", "codesign", "hdiutil", "cargo", "swift"] {
        if !proc::on_path(tool) {
            return Err(format!("missing required tool: {tool}"));
        }
    }
    let xcframework = layout.root.join("ThirdParty/ghostty/libghostty.xcframework");
    if !xcframework.join("macos-arm64").is_dir() {
        return Err(format!(
            "{} is missing its macos-arm64 slice. Build it first:\n  ThirdParty/ghostty/build-libghostty.sh",
            xcframework.display()
        ));
    }
    let identities = proc::capture(
        "security",
        &["find-identity", "-v", "-p", "codesigning"],
        &layout.root,
    )?;
    if !identities.contains(&settings.identity) {
        return Err(format!(
            "signing identity not in any unlocked keychain: {}",
            settings.identity
        ));
    }

    if layout.work.exists() {
        fs::remove_dir_all(&layout.work).map_err(|error| format!("clearing .work: {error}"))?;
    }
    for directory in [&layout.dist, &layout.derived_data, &layout.stage] {
        fs::create_dir_all(directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    }
    println!("version={} build={}", settings.version, settings.build_number);
    println!("identity={}", settings.identity);
    Ok(())
}

/// Build both halves of the CLI, and report where `SwiftPM` says its products landed.
fn build_cli(layout: &Layout) -> Result<Option<PathBuf>, String> {
    proc::step("Building CLI (swift build -c release)");
    let scratch = layout.scratch.to_string_lossy().into_owned();
    // `--arch arm64` keeps this honest even under Rosetta or a future universal-capable toolchain:
    // the tarball claims arm64 and must contain only arm64.
    //
    // `--product`, NOT `--target`. Under the Swift 6.3 build backend `--target slopdesk-hostd`
    // compiles the module, reports "Build of target: … complete!", and never links a binary — a
    // green build that produces nothing to ship. `--product` links, which is why Package.swift
    // declares the shipped executable as a product.
    for tool in tools::SPM_TOOLS {
        proc::run(
            "swift",
            &[
                "build",
                "-c",
                "release",
                "--arch",
                "arm64",
                "--scratch-path",
                &scratch,
                "--product",
                tool,
            ],
            &layout.root,
        )?;
    }

    // The cargo half. `--target` is explicit for the same reason `--arch` is above. Naming the
    // target also fixes the output directory, so the search below is never reached for these.
    proc::step("Building CLI (cargo build --release)");
    for package in tools::RUST_ROOT_PACKAGES {
        proc::run(
            "cargo",
            &["build", "--release", "--target", TRIPLE, "-p", package],
            &layout.root.join("rust"),
        )?;
    }
    for daemon in tools::RUST_CRATE_TOOLS {
        proc::run(
            "cargo",
            &["build", "--release", "--target", TRIPLE],
            &layout.root.join("rust").join(daemon),
        )?;
    }

    // Where the Swift binaries land is NOT a constant: `--show-bin-path` does not report the newer
    // backend's `Products/Release`. So it is a HINT, and the search is the answer.
    Ok(proc::ask(
        "swift",
        &[
            "build",
            "-c",
            "release",
            "--arch",
            "arm64",
            "--scratch-path",
            &scratch,
            "--show-bin-path",
        ],
        &layout.root,
    )
    .filter(|path| !path.is_empty())
    .map(PathBuf::from))
}

fn stage_cli(layout: &Layout, swift_bin: Option<&Path>) -> Result<(), String> {
    fs::create_dir_all(&layout.cli_stage)
        .map_err(|error| format!("{}: {error}", layout.cli_stage.display()))?;
    for tool in tools::cli_tools() {
        let Some(built) = locate_tool(layout, tool, swift_bin) else {
            dump_build_layout(layout);
            return Err(format!(
                "the build reported success but no release {tool} executable exists\n  (--show-bin-path \
                 said: {}; cargo dir: {})",
                swift_bin.map_or_else(|| "<nothing>".to_owned(), |path| path.display().to_string()),
                cargo_bin_dir(&layout.root, tool).map_or_else(
                    || "<not a cargo tool>".to_owned(),
                    |dir| dir.display().to_string()
                )
            ));
        };
        println!("  {tool} <- {}", built.display());
        fs::copy(&built, layout.cli_stage.join(tool)).map_err(|error| format!("staging {tool}: {error}"))?;
    }
    Ok(())
}

/// The product's version, then every sidecar's own — both asked of the BUILT binary.
///
/// `slopdesk version` reads its own `CARGO_PKG_VERSION`, not the tag, so a release cut without
/// bumping `rust/slopdesk-cli/Cargo.toml` ships a binary that lies about its own version. Asking
/// the binary rather than grepping the source is the point: this is the string users will actually
/// see, and it is baked in at COMPILE time — a bumped manifest with no rebuild fails here too.
///
/// The sidecar half is the same question of every cargo tool, and it matters more. A `Cargo.toml`
/// bumped without a rebuild, a stale binary picked up by the search, a crate that failed to
/// recompile — all three produce a manifest that lies, and all three are caught here rather than on
/// a user's machine. A number that is wrong there means a superd that DID change is reported
/// unchanged, the restart is skipped, and the user keeps running code this release does not
/// contain — silently, because everything still works.
fn check_versions(layout: &Layout, settings: &Settings) -> Result<(), String> {
    let declared = reported_version(&layout.cli_stage.join("slopdesk"), "version")
        .ok_or_else(|| "the staged `slopdesk` did not answer `version`".to_owned())?;
    if declared != settings.version {
        return Err(format!(
            "version drift: `slopdesk version` says {declared}, this release is {}.\n  Bump \
             rust/slopdesk-cli/Cargo.toml (and the MARKETING_VERSION in both\n  Apps/*/project.yml) to {} \
             before tagging.",
            settings.version, settings.version
        ));
    }

    proc::step(&format!("Checking sidecar versions against {}", stamps::PIN));
    let pin = Pin::read(&layout.root)?;
    let mut drifted = false;
    for tool in tools::pinned_tools() {
        let Some(pinned) = pin.entry(tool) else {
            eprintln!("  MISSING  {tool} has no entry in {}", stamps::PIN);
            drifted = true;
            continue;
        };
        // Same parse as the product gate: field 2 of line 1. Every tool in the tree answers it.
        let reported = reported_version(&layout.cli_stage.join(tool), "--version");
        match reported {
            Some(reported) if reported == pinned.version => {
                println!("  ok       {tool:<22} {}", pinned.version);
            },
            Some(reported) => {
                eprintln!(
                    "  DRIFT    {tool}: the binary says {reported}, the pin says {}",
                    pinned.version
                );
                drifted = true;
            },
            None => {
                eprintln!("  DRIFT    {tool}: the staged binary answered no --version");
                drifted = true;
            },
        }
    }
    if drifted {
        return Err(format!(
            "a sidecar's binary disagrees with {}.\n  Run `slopdesk-release bump-tools` and rebuild, or \
             find out why a stale binary was staged.",
            stamps::PIN
        ));
    }
    Ok(())
}

fn sign_cli(layout: &Layout, settings: &Settings) -> Result<(), String> {
    proc::step("Signing CLI binaries");
    for tool in tools::cli_tools() {
        let binary = layout.cli_stage.join(tool).to_string_lossy().into_owned();
        // Hardened runtime + a secure timestamp are both notarization prerequisites. The CLI needs
        // no entitlements: hostd forks a PTY, which requires none when unsandboxed.
        proc::run(
            "codesign",
            &[
                "--force",
                "--sign",
                settings.identity.as_str(),
                "--options",
                "runtime",
                "--timestamp",
                binary.as_str(),
            ],
            &layout.root,
        )?;
        proc::run(
            "codesign",
            &["--verify", "--strict", "--verbose=1", binary.as_str()],
            &layout.root,
        )?;
    }
    Ok(())
}

/// Build both bundles UNSIGNED, stamp the plists, then sign — in that order and no other.
///
/// The version has to be stamped into `Info.plist` AFTER the build (the committed plists carry a
/// literal `CFBundleShortVersionString` that `MARKETING_VERSION` does not override), and editing a
/// plist inside a signed bundle invalidates the signature.
fn build_and_sign_apps(layout: &Layout, settings: &Settings) -> Result<(), String> {
    // The client is the ONLY target that links libghostty. The renderer wiring injects the
    // xcframework + CGhostty module map into the (deliberately placeholder) committed spec and
    // regenerates the project; it is idempotent, and the spec is checked back out afterwards.
    proc::step("Wiring the libghostty renderer into ClientApp-macOS");
    // An in-process call, not a spawn: the injector is [`crate::ops::renderer`] in this same
    // binary, and shelling out to a copy of itself would only add a way for the two to disagree.
    crate::ops::renderer::enable(&layout.root, &crate::ops::renderer::MACOS)?;

    for (spec, project, scheme, product, entitlements) in [
        (
            "Apps/ClientApp-macOS/project.yml",
            "Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj",
            "ClientApp-macOS",
            "SlopDesk.app",
            "Apps/ClientApp-macOS/ClientApp-macOS.entitlements",
        ),
        (
            "Apps/HostApp-macOS/project.yml",
            "Apps/HostApp-macOS/HostApp-macOS.xcodeproj",
            "HostApp-macOS",
            "SlopDeskHost.app",
            "Apps/HostApp-macOS/HostApp-macOS.entitlements",
        ),
    ] {
        build_one_app(layout, spec, project, scheme, product)?;
        stamp_and_sign_app(layout, settings, product, entitlements)?;
    }

    // Restore the committed placeholder spec so a CI checkout (and a developer's tree) stays clean.
    proc::run(
        "git",
        &["checkout", "--", "Apps/ClientApp-macOS/project.yml"],
        &layout.root,
    )
}

/// Regenerate one project, build it unsigned, and copy the bundle into the stage.
fn build_one_app(
    layout: &Layout,
    spec: &str,
    project: &str,
    scheme: &str,
    product: &str,
) -> Result<(), String> {
    proc::step(&format!("Building {scheme} (unsigned)"));
    proc::run("xcodegen", &["generate", "--spec", spec, "--quiet"], &layout.root)?;
    let derived = layout.derived_data.to_string_lossy().into_owned();
    proc::run(
        "xcodebuild",
        &[
            "-project",
            project,
            "-scheme",
            scheme,
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=macOS",
            "-derivedDataPath",
            &derived,
            "ARCHS=arm64",
            "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        &layout.root,
    )?;
    let built = layout.derived_data.join("Build/Products/Release").join(product);
    if !built.is_dir() {
        return Err(format!("xcodebuild did not produce {}", built.display()));
    }
    let staged = layout.stage.join(product);
    if staged.exists() {
        fs::remove_dir_all(&staged).map_err(|error| format!("{}: {error}", staged.display()))?;
    }
    proc::run(
        "cp",
        &["-R".as_ref(), built.as_os_str(), layout.stage.as_os_str()],
        &layout.root,
    )
}

/// Write the two version keys into the STAGED bundle's plist, then sign it and verify the seal.
///
/// The order is the whole point: a plist edited inside a signed bundle invalidates the signature,
/// so the stamp lands first and `codesign --verify --deep` proves the seal covers what shipped.
fn stamp_and_sign_app(
    layout: &Layout,
    settings: &Settings,
    product: &str,
    entitlements: &str,
) -> Result<(), String> {
    proc::step(&format!("Stamping + signing {product}"));
    let staged = layout.stage.join(product);
    let plist = staged.join("Contents/Info.plist").to_string_lossy().into_owned();
    proc::run(
        "/usr/libexec/PlistBuddy",
        &[
            "-c",
            &format!("Set :CFBundleShortVersionString {}", settings.version),
            &plist,
        ],
        &layout.root,
    )?;
    proc::run(
        "/usr/libexec/PlistBuddy",
        &[
            "-c",
            &format!("Set :CFBundleVersion {}", settings.build_number),
            &plist,
        ],
        &layout.root,
    )?;
    let bundle = staged.to_string_lossy().into_owned();
    proc::run(
        "codesign",
        &[
            "--force",
            "--sign",
            settings.identity.as_str(),
            "--options",
            "runtime",
            "--timestamp",
            "--entitlements",
            entitlements,
            bundle.as_str(),
        ],
        &layout.root,
    )?;
    proc::run(
        "codesign",
        &["--verify", "--strict", "--deep", "--verbose=1", bundle.as_str()],
        &layout.root,
    )
}

/// Submit one artifact and wait.
fn notarize(layout: &Layout, settings: &Settings, artifact: &Path) -> Result<(), String> {
    let path = artifact.to_string_lossy().into_owned();
    if let Some(profile) = &settings.notary_profile {
        return proc::run(
            "xcrun",
            &[
                "notarytool",
                "submit",
                &path,
                "--keychain-profile",
                profile,
                "--wait",
            ],
            &layout.root,
        );
    }
    let (id, team, password) = settings
        .apple
        .as_ref()
        .ok_or_else(|| "no notarization credentials, and notarization is on".to_owned())?;
    proc::run(
        "xcrun",
        &[
            "notarytool",
            "submit",
            &path,
            "--apple-id",
            id,
            "--team-id",
            team,
            "--password",
            password,
            "--wait",
        ],
        &layout.root,
    )
}

/// Notarize + staple the app bundles BEFORE they enter the image.
///
/// The cask copies `SlopDesk.app` OUT of the DMG, so a ticket stapled only to the image never
/// reaches the app the user actually launches, and Gatekeeper has to resolve it online — which
/// fails on a first launch with no network. A ticket can only be stapled to a bundle, and the
/// bundle inside the image is a COPY, so the staple has to land before the image is built. Moving
/// this after the DMG step silently restores the old behaviour: the run stays green and the shipped
/// app carries no ticket.
///
/// Notarization is per-artifact, not per-file, so both bundles ride in ONE zip and one submission;
/// the DMG still needs its own round afterwards (Apple has no way to derive an image's ticket from
/// its contents). That is the "one extra submission per release" this buys.
fn notarize_apps(layout: &Layout, settings: &Settings) -> Result<(), String> {
    if settings.skip_notarize {
        println!("SLOPDESK_SKIP_NOTARIZE=1 — app bundles are signed but NOT notarized or stapled.");
        return Ok(());
    }
    proc::step("Notarizing the app bundles");
    let apps_dir = layout.work.join("apps");
    if apps_dir.exists() {
        fs::remove_dir_all(&apps_dir).map_err(|error| format!("{}: {error}", apps_dir.display()))?;
    }
    fs::create_dir_all(&apps_dir).map_err(|error| format!("{}: {error}", apps_dir.display()))?;
    for app in ["SlopDesk.app", "SlopDeskHost.app"] {
        proc::run(
            "cp",
            &[
                "-R".as_ref(),
                layout.stage.join(app).as_os_str(),
                apps_dir.as_os_str(),
            ],
            &layout.root,
        )?;
    }
    // `--keepParent` takes ONE source, so a directory holding both bundles is archived by its
    // CONTENTS: the zip then has both `.app` bundles at its root, and notarytool walks the archive
    // for bundles. `--sequesterRsrc` is Apple's documented flag for notarization zips — it keeps
    // resource forks from corrupting the upload.
    let zip = layout
        .work
        .join(format!("slopdesk-apps-{}-arm64.zip", settings.version));
    let _ = fs::remove_file(&zip);
    proc::run(
        "ditto",
        &[
            "-c".as_ref(),
            "-k".as_ref(),
            "--sequesterRsrc".as_ref(),
            apps_dir.as_os_str(),
            zip.as_os_str(),
        ],
        &layout.root,
    )?;
    notarize(layout, settings, &zip)?;

    // Staple the ORIGINALS in the stage — those are what the DMG is built from. Validating here
    // rather than trusting the staple's exit code: a ticket that did not attach must fail the
    // release, not ship an app that looks fine until someone launches it offline.
    proc::step("Stapling the app bundles");
    for app in ["SlopDesk.app", "SlopDeskHost.app"] {
        let bundle = layout.stage.join(app).to_string_lossy().into_owned();
        proc::run("xcrun", &["stapler", "staple", &bundle], &layout.root)?;
        proc::run("xcrun", &["stapler", "validate", &bundle], &layout.root).map_err(|_| {
            format!(
                "no ticket stapled to {app} — the image would ship an app that fails first launch offline"
            )
        })?;
    }
    Ok(())
}

fn build_dmg(layout: &Layout, settings: &Settings) -> Result<PathBuf, String> {
    proc::step("Building the DMG");
    let dmg_root = layout.work.join("dmg");
    fs::create_dir_all(&dmg_root).map_err(|error| format!("{}: {error}", dmg_root.display()))?;
    for app in ["SlopDesk.app", "SlopDeskHost.app"] {
        proc::run(
            "cp",
            &[
                "-R".as_ref(),
                layout.stage.join(app).as_os_str(),
                dmg_root.as_os_str(),
            ],
            &layout.root,
        )?;
    }
    let link = dmg_root.join("Applications");
    if !link.exists() {
        std::os::unix::fs::symlink("/Applications", &link)
            .map_err(|error| format!("the /Applications symlink: {error}"))?;
    }

    let dmg = layout
        .dist
        .join(format!("SlopDesk-{}-arm64.dmg", settings.version));
    let _ = fs::remove_file(&dmg);
    proc::run(
        "hdiutil",
        &[
            "create".as_ref(),
            "-srcfolder".as_ref(),
            dmg_root.as_os_str(),
            "-volname".as_ref(),
            format!("SlopDesk {}", settings.version).as_ref(),
            "-fs".as_ref(),
            "HFS+".as_ref(),
            "-format".as_ref(),
            "UDZO".as_ref(),
            "-quiet".as_ref(),
            dmg.as_os_str(),
        ],
        &layout.root,
    )?;
    proc::run(
        "codesign",
        &[
            "--force".as_ref(),
            "--sign".as_ref(),
            settings.identity.as_ref(),
            "--timestamp".as_ref(),
            dmg.as_os_str(),
        ],
        &layout.root,
    )?;
    Ok(dmg)
}

/// `MANIFEST.json` — what this release actually contains, tool by tool.
///
/// The upgrade side reads this. Under one product version there was no way to say "the Android
/// bridge changed and superd did not", so `brew upgrade` restarted everything — and restarting
/// superd costs the user every live pane, because it holds the master fd of each one (`docs/51`).
/// With a per-tool version here, an install can replace what moved and leave the rest alone.
///
/// THE VERSION IS THE IDENTITY, NOT THE SHA. Every binary is signed with `--timestamp`, so an
/// unchanged tool rebuilt and re-signed has different bytes every single time. Comparing shipped
/// SHAs across two releases would report every tool as changed, forever, which is the behaviour
/// this whole mechanism exists to end. The `sha256` field is therefore INTEGRITY ONLY — what this
/// file should hash to right now — and the `stamp` beside it is the source digest that decided
/// whether `version` was allowed to move.
///
/// Written AFTER signing so the SHA is of the file that actually ships, and INSIDE the staged
/// directory so it travels in the tarball rather than beside it.
fn write_manifest(layout: &Layout, settings: &Settings) -> Result<(), String> {
    proc::step("Writing MANIFEST.json");
    let pin = Pin::read(&layout.root)?;
    let mut json = String::new();
    let _ = writeln!(json, "{{");
    let _ = writeln!(json, "  \"product\": \"{}\",", settings.version);
    let _ = writeln!(json, "  \"arch\": \"arm64\",");
    let _ = writeln!(json, "  \"tools\": [");
    let all = tools::cli_tools();
    for (index, tool) in all.iter().enumerate() {
        // The PRODUCT pair carry no version of their own — `docs/49` §"The six version sites" is
        // where their number lives, and duplicating it per-tool here would invent a seventh site.
        // They appear with the product version and an empty stamp, because a manifest that lists
        // ten of the twelve binaries in the tarball is one a reader cannot trust. Which of the two
        // is built by cargo and which by `SwiftPM` does not enter into it.
        let (version, stamp) = if tools::is_product(tool) {
            (settings.version.clone(), String::new())
        } else {
            let entry = pin
                .entry(tool)
                .ok_or_else(|| format!("{tool} has no entry in {}", stamps::PIN))?;
            (entry.version.clone(), entry.stamp.clone())
        };
        let sha = sha256_file(&layout.cli_stage.join(tool))?;
        let comma = if index + 1 == all.len() { "" } else { "," };
        let _ = writeln!(
            json,
            "    {{\"name\": \"{tool}\", \"version\": \"{version}\", \"sha256\": \"{sha}\", \"stamp\": \
             \"{stamp}\"}}{comma}"
        );
    }
    let _ = writeln!(json, "  ]");
    let _ = writeln!(json, "}}");

    // The shell shelled out to python3 for this. A parse in-process is the same assertion with one
    // fewer runtime: a tool name or version carrying a quote would produce a document the install
    // side cannot read.
    serde_json::from_str::<serde_json::Value>(&json)
        .map_err(|error| format!("the manifest just written is not valid JSON: {error}"))?;

    fs::write(layout.cli_stage.join("MANIFEST.json"), &json)
        .map_err(|error| format!("MANIFEST.json: {error}"))?;
    fs::write(layout.dist.join("MANIFEST.json"), &json)
        .map_err(|error| format!("dist/MANIFEST.json: {error}"))
}

fn build_tarball(layout: &Layout, settings: &Settings) -> Result<PathBuf, String> {
    proc::step("Building the CLI tarball");
    let name = format!("slopdesk-cli-{}-arm64", settings.version);
    let tarball = layout.dist.join(format!("{name}.tar.gz"));
    let _ = fs::remove_file(&tarball);
    proc::run(
        "tar",
        &[
            "-czf".as_ref(),
            tarball.as_os_str(),
            "-C".as_ref(),
            layout.stage.as_os_str(),
            name.as_ref(),
        ],
        &layout.root,
    )?;
    Ok(tarball)
}

/// The two containers, which carry no ticket of their own yet.
fn notarize_containers(layout: &Layout, settings: &Settings, dmg: &Path) -> Result<(), String> {
    if settings.skip_notarize {
        println!("SLOPDESK_SKIP_NOTARIZE=1 — artifacts are signed but NOT notarized (dry run only).");
        return Ok(());
    }
    proc::step("Notarizing the DMG");
    notarize(layout, settings, dmg)?;
    let path = dmg.to_string_lossy().into_owned();
    proc::run("xcrun", &["stapler", "staple", &path], &layout.root)?;
    proc::run("xcrun", &["stapler", "validate", &path], &layout.root)?;

    // A bare Mach-O cannot carry a stapled ticket, so the CLI is notarized inside a zip and
    // Gatekeeper resolves the ticket online. The shipped container stays the tarball — Homebrew
    // formulas read that, and brew does not quarantine formula downloads.
    proc::step("Notarizing the CLI binaries");
    let name = format!("slopdesk-cli-{}-arm64", settings.version);
    let zip = layout.work.join(format!("{name}.zip"));
    proc::run(
        "ditto",
        &[
            "-c".as_ref(),
            "-k".as_ref(),
            "--keepParent".as_ref(),
            name.as_ref(),
            zip.as_os_str(),
        ],
        &layout.stage,
    )?;
    notarize(layout, settings, &zip)
}

/// What the Homebrew tap's cask + formula pin, in `shasum -a 256`'s own two-space shape.
fn checksums(layout: &Layout, artifacts: &[&Path]) -> Result<(), String> {
    proc::step("Checksums");
    let mut sums = String::new();
    for artifact in artifacts {
        let name = artifact
            .file_name()
            .ok_or_else(|| format!("{} has no file name", artifact.display()))?
            .to_string_lossy();
        let _ = writeln!(sums, "{}  {name}", sha256_file(artifact)?);
    }
    print!("{sums}");
    fs::write(layout.dist.join("SHA256SUMS"), &sums).map_err(|error| format!("SHA256SUMS: {error}"))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{cargo_bin_dir, is_macho_executable};

    #[test]
    fn a_root_member_and_a_daemon_build_into_different_targets() {
        let root = Path::new("/tree");
        assert_eq!(
            cargo_bin_dir(root, "slopdesk-ctl").unwrap(),
            Path::new("/tree/rust/target/aarch64-apple-darwin/release")
        );
        assert_eq!(
            cargo_bin_dir(root, "slopdesk-superd").unwrap(),
            Path::new("/tree/rust/slopdesk-superd/target/aarch64-apple-darwin/release")
        );
    }

    /// The hook installer rides the relay's package into the SHARED directory, which is what makes
    /// `executable.parent()/slopdesk-hook` resolve after an install.
    #[test]
    fn the_hook_installer_lands_beside_the_relay() {
        let root = Path::new("/tree");
        assert_eq!(
            cargo_bin_dir(root, "slopdesk-agenthooks"),
            cargo_bin_dir(root, "slopdesk-hook")
        );
    }

    /// hostd is the last `SwiftPM` binary; the product CLI beside it is cargo's and resolves to the
    /// shared directory, which is what keeps a stale Swift `slopdesk` in `.build` from staging.
    #[test]
    fn the_swift_half_has_no_cargo_directory_and_the_cli_does() {
        let root = Path::new("/tree");
        assert_eq!(cargo_bin_dir(root, "slopdesk-hostd"), None);
        assert_eq!(
            cargo_bin_dir(root, "slopdesk"),
            cargo_bin_dir(root, "slopdesk-ctl")
        );
    }

    #[test]
    fn a_missing_file_is_not_an_executable() {
        assert!(!is_macho_executable(Path::new("/nonexistent/slopdesk")));
    }
}
