//! Wire the libghostty renderer into a client app's generated `project.yml`.
//!
//! ## Why this is a script at all
//! `libghostty.xcframework` is 64 MB and gitignored, and xcodegen resolves a framework path at
//! GENERATE time — so a committed renderer-enabled spec would fail on every checkout that has not
//! built the artifact. The macOS spec is therefore kept in its PLACEHOLDER state and this puts the
//! wiring back on demand. (The iOS spec ships ENABLED, and this re-asserts it — same three inserts,
//! same idempotence, which is how the wiring was authored and how it is restored after a revert.)
//!
//! ## Why a text insert and not a YAML round-trip
//! A round-trip reorders keys and strips comments, and this file is more comment than key: every
//! insert below carries the paragraph that says why the setting is there. A structural insert keyed
//! on an anchor is precise, idempotent and leaves the rest of the document byte-identical — which
//! also means `git diff` after a run shows the wiring and nothing else.
//!
//! ## The two specs, which differ in four things
//! `embed` (macOS `false` — the xcframework wraps a STATIC archive, so its symbols are already in
//! the executable after the link and a copy in `Contents/Frameworks` is dead weight AND unsignable;
//! iOS `true`), the required slices, `Carbon` in `OTHER_LDFLAGS` (macOS-only), and the prose. That
//! is a table, not a second script — which is what the two 170-line shell files were.
//!
//! Restore either afterwards with `git checkout -- <spec>` and a regenerate.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::say;
use crate::proc;

/// One app's renderer wiring: where the spec is, which slices it needs, and the three inserts.
#[derive(Debug)]
pub struct Target {
    /// `macos` or `ios`, as the CLI spells it.
    pub name: &'static str,
    /// The spec, relative to the repo root.
    pub spec: &'static str,
    /// Every xcframework sub-directory that must exist, as ALTERNATIVES within a group.
    ///
    /// A group is satisfied by any one of its members: the macOS app accepts the native
    /// `macos-arm64` slice OR the universal build's `macos-arm64_x86_64`, since it pins
    /// `ARCHS=arm64` and both carry an arm64 slice. iOS needs BOTH of its two, so it lists two
    /// groups of one.
    pub slices: &'static [&'static [&'static str]],
    /// What to tell the developer to run when a slice is missing.
    pub build_hint: &'static str,
    /// The `embed:` value for the framework dependency.
    pub embed: bool,
    /// The system frameworks `OTHER_LDFLAGS` must link, in order.
    pub frameworks: &'static [&'static str],
    /// The prose above the sources insert.
    pub sources_note: &'static str,
    /// The prose above the dependency insert.
    pub dependency_note: &'static str,
    /// The prose above the `ARCHS` pin.
    pub archs_note: &'static str,
    /// The prose above `OTHER_LDFLAGS`.
    pub ldflags_note: &'static str,
}

/// The macOS client app, whose committed spec is the PLACEHOLDER.
pub const MACOS: Target = Target {
    name: "macos",
    spec: "Apps/ClientApp-macOS/project.yml",
    slices: &[&["macos-arm64", "macos-arm64_x86_64"]],
    build_hint:
        "bash ThirdParty/ghostty/build-libghostty.sh                 # native (macOS only)\n         \
         XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh  # + iOS",
    embed: false,
    frameworks: &["Carbon", "CoreText", "CoreGraphics", "QuartzCore", "Metal"],
    sources_note: "\
      # PATH 1 (libghostty renderer): the gated renderer host + binding. This directory
      # carries BOTH GhosttySurface.swift (the @MainActor TerminalSurface binding over the
      # CGhostty C ABI) and GhosttyTerminalView.swift (the TerminalSurfaceHosting conformer —
      # the file name is history, `GhosttyLayerBackedView` is what it holds).
      # They are NOT members of any Package.swift target — they join THIS app target so
      # `import CGhostty` resolves and `#if canImport(CGhostty)` flips true.",
    dependency_note: "\
      # PATH 1 (libghostty renderer): the libghostty static binary (the link-time
      # `ghostty` C-ABI symbols) packaged as an xcframework, built ON this macOS host by
      # ThirdParty/ghostty/build-libghostty.sh. The universal build also ships iOS slices
      # (`slopdesk-ops enable-renderer ios`); this macOS target links the macOS slice.
      # embed: false — the xcframework wraps a STATIC archive (macos-arm64.a). Its symbols
      # are already in the executable after the link; embedding additionally COPIES the .a
      # into Contents/Frameworks, where it is dead weight and, worse, unsignable: codesign
      # walks the bundle and fails the whole app with `code object is not signed at all`
      # on that member. A dylib would need embed: true; a .a must not have it.",
    archs_note: "\
        # libghostty.xcframework currently ships ONLY a macos-arm64 slice (built on this
        # arm64 host; the x86_64/universal slice needs a separate build). Pin the macOS app
        # to arm64 so the link resolves against that slice. (Apple-silicon is the target;
        # Intel macOS is EOL for this project.)",
    ldflags_note: "\
        # libghostty vendors C/C++ dependencies (Dear ImGui, spirv-cross, glslang,
        # FreeType, sentry, oniguruma, …). The static lib references the C++ runtime and
        # a handful of system frameworks (Carbon for TIS keyboard-layout APIs, CoreText/
        # CoreGraphics for font rendering). Link them so the libghostty symbols resolve.",
};

/// The iOS client app, whose committed spec ships ENABLED.
pub const IOS: Target = Target {
    name: "ios",
    spec: "Apps/ClientApp-iOS/project.yml",
    slices: &[&["ios-arm64"], &["ios-arm64-simulator"]],
    build_hint: "XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh",
    embed: true,
    frameworks: &["CoreText", "CoreGraphics", "QuartzCore", "Metal"],
    sources_note: "\
      # PATH 1 (libghostty renderer): the gated renderer host + binding (GhosttySurface.swift
      # + GhosttyTerminalView.swift). NOT members of any Package.swift target — they join THIS
      # app target so `import CGhostty` resolves and `#if canImport(CGhostty)` flips true.",
    dependency_note: "\
      # PATH 1 (libghostty renderer): the libghostty static binary (link-time `ghostty`
      # C-ABI symbols) as an xcframework. The UNIVERSAL build ships ios-arm64 (device) +
      # ios-arm64-simulator slices, both built on this host against the iOS SDK; the
      # xcframework auto-selects the right slice per destination.",
    archs_note: "\
        # The xcframework ships ios-arm64 (device) + ios-arm64-simulator — both arm64
        # only (Apple-silicon target). Pin ARCHS=arm64 so a generic 'iOS Simulator'
        # destination does NOT also demand an x86_64 slice (which would fail to link).",
    ldflags_note: "\
        # libghostty vendors C/C++ deps (Dear ImGui, spirv-cross, glslang, FreeType,
        # sentry, oniguruma, …) referencing the C++ runtime + a few iOS system frameworks
        # (CoreText/CoreGraphics for fonts, QuartzCore/Metal for the layer). NO Carbon —
        # it is macOS-only; the iOS slice does not reference it.",
};

/// The target a verb names.
///
/// # Errors
/// When the name is neither of the two.
pub fn by_name(name: &str) -> Result<&'static Target, String> {
    match name {
        "macos" => Ok(&MACOS),
        "ios" => Ok(&IOS),
        other => Err(format!("unknown renderer target: {other} (macos | ios)")),
    }
}

/// Where the sources insert goes.
const SOURCES_ANCHOR: &str = "    sources:\n      - path: ../Shared\n";
/// Where the dependency insert goes.
const DEPENDENCY_ANCHOR: &str = "      - package: SlopDesk\n        product: SlopDeskVideoClient\n";
/// Where the settings insert goes.
const SETTINGS_ANCHOR: &str = "        CODE_SIGN_STYLE: Automatic\n";

/// The marker that says an insert has already happened, per insert.
const SOURCES_MARK: &str = "integration/GhosttySurface";
/// Ditto, for the framework dependency.
const DEPENDENCY_MARK: &str = "libghostty.xcframework";
/// Ditto, for the build settings.
const SETTINGS_MARK: &str = "SWIFT_INCLUDE_PATHS";

/// Inject the three blocks into a spec's text, or leave it exactly as it was.
///
/// Idempotent per insert, not per file: a spec that already has the sources entry and not the
/// settings block gets only the settings block, which is what a half-reverted tree looks like.
///
/// # Errors
/// When an anchor an insert needs is not in the document — a spec that has been restructured, and
/// a case that must fail loudly rather than write the block somewhere wrong.
pub fn inject(target: &Target, text: &str) -> Result<String, String> {
    let mut out = text.to_owned();

    if !out.contains(SOURCES_MARK) {
        let block = format!(
            "{SOURCES_ANCHOR}{note}\n      - path: ../../ThirdParty/ghostty/integration/GhosttySurface\n",
            note = target.sources_note
        );
        out = replace_once(&out, SOURCES_ANCHOR, &block, "the `- path: ../Shared` sources")?;
    }

    if !out.contains(DEPENDENCY_MARK) {
        let block = format!(
            "{DEPENDENCY_ANCHOR}{note}\n      - framework: \
             ../../ThirdParty/ghostty/libghostty.xcframework\n        embed: {embed}\n",
            note = target.dependency_note,
            embed = target.embed
        );
        out = replace_once(
            &out,
            DEPENDENCY_ANCHOR,
            &block,
            "the SlopDeskVideoClient dependency",
        )?;
    }

    if !out.contains(SETTINGS_MARK) {
        let mut ldflags = String::from("        OTHER_LDFLAGS:\n          - -lc++\n");
        for framework in target.frameworks {
            ldflags.push_str("          - -framework\n");
            ldflags.push_str("          - ");
            ldflags.push_str(framework);
            ldflags.push('\n');
        }
        let block = format!(
            "{SETTINGS_ANCHOR}# PATH 1 (libghostty renderer): point the Swift importer at the CGhostty clang
        # module map (module.modulemap + vendored ghostty.h) so `import CGhostty` resolves
        # and `#if canImport(CGhostty)` flips true → GhosttyTerminalView/GhosttySurface
        # compile into this target and link against libghostty.xcframework.
        SWIFT_INCLUDE_PATHS: $(SRCROOT)/../../ThirdParty/ghostty/integration/CGhostty
{archs}
        ARCHS: arm64
        ONLY_ACTIVE_ARCH: \"NO\"
{ldflags_note}
{ldflags}",
            archs = target.archs_note,
            ldflags_note = target.ldflags_note,
            ldflags = ldflags
        );
        out = replace_once(&out, SETTINGS_ANCHOR, &block, "the CODE_SIGN_STYLE settings")?;
    }

    Ok(out)
}

/// Replace the FIRST occurrence of an anchor, or say which anchor is gone.
fn replace_once(text: &str, anchor: &str, block: &str, what: &str) -> Result<String, String> {
    let at = text
        .find(anchor)
        .ok_or_else(|| format!("could not find {what} anchor in the spec — it has been restructured"))?;
    let mut out = String::with_capacity(text.len() + block.len());
    out.push_str(&text[..at]);
    out.push_str(block);
    out.push_str(&text[at + anchor.len()..]);
    Ok(out)
}

/// The xcframework, and the check that it carries the slices this target links.
fn preflight(root: &Path, target: &Target) -> Result<(), String> {
    let xcframework = root.join("ThirdParty/ghostty/libghostty.xcframework");
    if !xcframework.is_dir() {
        return Err(format!(
            "{} is missing.\n       Build it first, then re-run:\n         {}",
            xcframework.display(),
            target.build_hint
        ));
    }
    for group in target.slices {
        if !group.iter().any(|slice| xcframework.join(slice).is_dir()) {
            return Err(format!(
                "{} has no '{}' slice.\n       Rebuild the xcframework:\n         {}",
                xcframework.display(),
                group.join("' or '"),
                target.build_hint
            ));
        }
    }
    if !proc::on_path("xcodegen") {
        return Err("xcodegen not found on PATH (install: brew install xcodegen)".to_owned());
    }
    Ok(())
}

/// Inject the wiring and regenerate the `.xcodeproj`.
///
/// # Errors
/// When the xcframework or a slice is missing, an anchor is gone, or `xcodegen` fails.
pub fn enable(root: &Path, target: &Target) -> Result<(), String> {
    preflight(root, target)?;
    let spec: PathBuf = root.join(target.spec);
    let before = fs::read_to_string(&spec).map_err(|error| format!("{}: {error}", spec.display()))?;
    let after = inject(target, &before)?;
    if after == before {
        say(
            "enable-renderer",
            "project.yml: renderer wiring already present (idempotent no-op)",
        );
    } else {
        fs::write(&spec, &after).map_err(|error| format!("{}: {error}", spec.display()))?;
        say("enable-renderer", "project.yml: renderer wiring injected");
    }
    generate(root, &spec)?;
    println!("==> {} renderer ENABLED.", target.name);
    println!(
        "    Restore: git checkout -- {} && slopdesk-ops regenerate {}",
        target.spec, target.name
    );
    Ok(())
}

/// Regenerate a spec's `.xcodeproj`, with `xcodegen`'s own chatter swallowed.
///
/// The other half of the restore pair, and the reason it is a verb rather than a line in the
/// closing message: `git checkout -- <spec>` puts the placeholder back and leaves a generated
/// project that still names the framework, which fails to build with no hint at the cause.
///
/// # Errors
/// When `xcodegen` is missing or fails.
pub fn generate(root: &Path, spec: &Path) -> Result<(), String> {
    if !proc::on_path("xcodegen") {
        return Err("xcodegen not found on PATH (install: brew install xcodegen)".to_owned());
    }
    say(
        "enable-renderer",
        &format!("xcodegen generate --spec {}", spec.display()),
    );
    let status = Command::new("xcodegen")
        .args(["generate", "--spec", &spec.to_string_lossy()])
        .current_dir(root)
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|error| format!("xcodegen: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("xcodegen exited {}", status.code().unwrap_or(-1)))
    }
}

#[cfg(test)]
mod tests {
    /// A spec with all three anchors and none of the wiring.
    fn placeholder() -> String {
        String::from(
            "targets:\n  ClientApp:\n    sources:\n      - path: ../Shared\n    dependencies:\n      - \
             package: SlopDesk\n        product: SlopDeskVideoClient\n    settings:\n      base:\n        \
             CODE_SIGN_STYLE: Automatic\n        PRODUCT_NAME: SlopDesk\n",
        )
    }

    /// The three inserts land, and the document that follows each anchor survives.
    #[test]
    fn injecting_adds_all_three_blocks_and_keeps_the_rest() {
        let out = super::inject(&super::MACOS, &placeholder()).expect("the anchors are all there");
        assert!(out.contains("- path: ../../ThirdParty/ghostty/integration/GhosttySurface"));
        assert!(out.contains("- framework: ../../ThirdParty/ghostty/libghostty.xcframework"));
        assert!(
            out.contains("SWIFT_INCLUDE_PATHS: $(SRCROOT)/../../ThirdParty/ghostty/integration/CGhostty")
        );
        assert!(
            out.contains("PRODUCT_NAME: SlopDesk"),
            "the text after the last anchor is kept"
        );
        assert!(out.contains("- path: ../Shared"), "and the anchor itself");
    }

    /// Running it twice is running it once.
    #[test]
    fn injecting_twice_changes_nothing_the_second_time() {
        let once = super::inject(&super::MACOS, &placeholder()).expect("first");
        let twice = super::inject(&super::MACOS, &once).expect("second");
        assert_eq!(once, twice);
    }

    /// A half-reverted spec gets only the part it is missing.
    #[test]
    fn a_partially_wired_spec_gets_only_what_it_lacks() {
        let full = super::inject(&super::MACOS, &placeholder()).expect("full");
        // Take the settings block back out, the way a hand-edit would.
        let reverted = full
            .lines()
            .filter(|line| !line.contains("SWIFT_INCLUDE_PATHS"))
            .collect::<Vec<_>>()
            .join("\n");
        let repaired = super::inject(&super::MACOS, &reverted).expect("repairable");
        assert!(repaired.contains("SWIFT_INCLUDE_PATHS"));
        assert_eq!(
            repaired
                .matches("- framework: ../../ThirdParty/ghostty/libghostty.xcframework")
                .count(),
            1,
            "the dependency it already had is not added a second time"
        );
    }

    /// The two targets differ in exactly the ways the table says.
    #[test]
    fn the_two_targets_differ_in_embed_and_in_carbon() {
        let mac = super::inject(&super::MACOS, &placeholder()).expect("macos");
        let ios = super::inject(&super::IOS, &placeholder()).expect("ios");
        assert!(
            mac.contains("embed: false"),
            "a static archive must not be embedded"
        );
        assert!(ios.contains("embed: true"));
        assert!(
            mac.contains("- Carbon"),
            "TIS keyboard-layout APIs are macOS-only"
        );
        assert!(
            !ios.contains("- Carbon"),
            "and the iOS slice does not reference them"
        );
        for framework in ["CoreText", "CoreGraphics", "QuartzCore", "Metal"] {
            assert!(mac.contains(&format!("- {framework}")), "macOS links {framework}");
            assert!(ios.contains(&format!("- {framework}")), "iOS links {framework}");
        }
    }

    /// A restructured spec fails loudly rather than writing the block somewhere wrong.
    #[test]
    fn a_missing_anchor_is_an_error_and_names_itself() {
        let no_sources = "targets:\n  ClientApp:\n    dependencies:\n      - package: SlopDesk\n        \
                          product: SlopDeskVideoClient\n        CODE_SIGN_STYLE: Automatic\n";
        let why = super::inject(&super::MACOS, no_sources).expect_err("no sources anchor");
        assert!(why.contains("sources"), "the message names the anchor: {why}");
    }

    /// Both names resolve, and a third is refused.
    #[test]
    fn only_the_two_apps_that_exist_resolve() {
        assert_eq!(
            super::by_name("macos").expect("macos").spec,
            "Apps/ClientApp-macOS/project.yml"
        );
        assert_eq!(
            super::by_name("ios").expect("ios").spec,
            "Apps/ClientApp-iOS/project.yml"
        );
        assert!(super::by_name("tvos").is_err());
    }
}
