//! Upstream sync for the seeded workbench theme extension.
//!
//! `slopdesk-codeseed` seeds `slopdesk.slopdesk-themes`, and this owns its Monokai rows.
//! `scripts/monokai.pin` records the Monokai Pro vsix version the vendored resources were
//! generated from. The seed carries the THEME DATA ONLY — none of the upstream extension's
//! activation code rides along, which is where its license prompt lives, and why the marketplace
//! extension is not simply installed.
//!
//! ## What a sync does
//! 1. download the pinned vsix (or the newest, with `--latest`),
//! 2. check the vsix's theme contributions still match [`EXPECTED`] — an upstream add, rename or
//!    removal fails LOUDLY here and needs a matching edit to `extensions::THEMES`,
//! 3. transform each theme: drop empty-string colour values (the workbench rejects them per key)
//!    and retint the seven structural seam borders to the app's Slate divider token — the only
//!    colour departures from stock,
//! 4. write the minified results under the slugs the Rust manifest table references,
//! 5. with `--latest`, move the pin.
//!
//! [`EXPECTED`] is a SUBSET of `extensions::THEMES` on purpose: that table also carries the app's
//! own themes, which have no upstream and must never appear in a vsix.
//!
//! ## What still shells out
//! `curl` and `unzip`. Both are a transport and an archive format the OS already implements, and
//! neither is a decision — the same line [`crate::proc`] draws for `xcodebuild` and `git`. What
//! WAS a `python3` heredoc — the contribution comparison, the colour transform, the minified write
//! — is [`transform`] and [`verdict`] here, with tests beside them.

use std::collections::BTreeMap;
use std::path::Path;
use std::{env, fs};

use serde_json::Value;

use super::say;
use crate::proc;

/// The marketplace publisher.
const PUBLISHER: &str = "monokai";
/// The extension id.
const EXTENSION: &str = "theme-monokai-pro-vscode";
/// The gallery API root.
const GALLERY: &str = "https://marketplace.visualstudio.com/_apis/public/gallery";

/// Slate divider, dark: foreground `#fcfcfa` at 0.10.
const DARK_SEAM: &str = "#fcfcfa1a";
/// Slate divider, light: black at 0.08.
const LIGHT_SEAM: &str = "#00000014";

/// The seven structural seams the app retints, and nothing else.
const SEAM_BORDER_KEYS: &[&str] = &[
    "activityBar.border",
    "editorGroup.border",
    "panel.border",
    "sideBar.border",
    "statusBar.border",
    "statusBar.noFolderBorder",
    "titleBar.border",
];

/// The vendored rows of `extensions::THEMES` — label, is-dark, resource slug.
pub const EXPECTED: &[(&str, bool, &str)] = &[
    ("Monokai Pro", true, "monokai-pro"),
    ("Monokai Pro (Filter Octagon)", true, "monokai-pro-filter-octagon"),
    (
        "Monokai Pro (Filter Ristretto)",
        true,
        "monokai-pro-filter-ristretto",
    ),
    (
        "Monokai Pro (Filter Spectrum)",
        true,
        "monokai-pro-filter-spectrum",
    ),
    ("Monokai Pro (Filter Machine)", true, "monokai-pro-filter-machine"),
    ("Monokai Pro Light", false, "monokai-pro-light"),
    (
        "Monokai Pro Light (Filter Sun)",
        false,
        "monokai-pro-light-filter-sun",
    ),
    ("Monokai Classic", true, "monokai-classic"),
];

/// One theme the vsix contributes: its label, its `uiTheme` and the file it lives in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Contribution {
    /// The display name, which is the join key with [`EXPECTED`].
    pub label: String,
    /// `vs-dark` or `vs`.
    pub ui_theme: String,
    /// The path inside `extension/`.
    pub path: String,
}

/// Read `contributes.themes` out of a vsix's `package.json`.
///
/// # Errors
/// When the manifest is not JSON, or has no theme contributions.
pub fn contributions(manifest: &str) -> Result<Vec<Contribution>, String> {
    let document: Value =
        serde_json::from_str(manifest).map_err(|error| format!("package.json is not JSON: {error}"))?;
    let themes = document
        .pointer("/contributes/themes")
        .and_then(Value::as_array)
        .ok_or_else(|| "package.json contributes no themes".to_owned())?;
    themes
        .iter()
        .map(|theme| {
            let field = |key: &str| {
                theme
                    .get(key)
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| format!("a theme contribution has no `{key}`"))
            };
            Ok(Contribution {
                label: field("label")?,
                ui_theme: field("uiTheme")?,
                path: field("path")?,
            })
        })
        .collect()
}

/// Whether the upstream theme SET still matches what the Rust table expects.
///
/// The pair is `(label, uiTheme)` because both matter: a variant that flips dark to light is a
/// change to the seam colour it gets, and a silently accepted one would retint it wrong.
///
/// # Errors
/// When the sets differ, with both sorted lists in the message.
pub fn verdict(contributed: &[Contribution]) -> Result<(), String> {
    let mut want: Vec<(String, String)> = EXPECTED
        .iter()
        .map(|(label, dark, _)| {
            (
                (*label).to_owned(),
                if *dark { "vs-dark" } else { "vs" }.to_owned(),
            )
        })
        .collect();
    let mut got: Vec<(String, String)> = contributed
        .iter()
        .map(|theme| (theme.label.clone(), theme.ui_theme.clone()))
        .collect();
    want.sort();
    got.sort();
    if want == got {
        return Ok(());
    }
    Err(format!(
        "upstream theme set changed — update `extensions::THEMES` AND this module's EXPECTED table.\n  \
         vsix:     {got:?}\n  expected: {want:?}"
    ))
}

/// What a transform did to one theme, for the report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Applied {
    /// Colour keys the theme has after the transform.
    pub colors: usize,
    /// Empty-string colour values dropped.
    pub dropped: usize,
    /// The seam colour written.
    pub seam: &'static str,
}

/// Drop the empty colour values, retint the seams, and answer the MINIFIED bytes.
///
/// # Errors
/// When the theme is not JSON, names itself something other than `label`, has no `colors` object,
/// or lost its `tokenColors`.
pub fn transform(theme_json: &str, label: &str, dark: bool) -> Result<(String, Applied), String> {
    let mut document: Value =
        serde_json::from_str(theme_json).map_err(|error| format!("theme {label:?} is not JSON: {error}"))?;
    let named = document.get("name").and_then(Value::as_str).unwrap_or_default();
    if named != label {
        return Err(format!("theme file for {label:?} names itself {named:?}"));
    }
    if document.get("tokenColors").is_none_or(Value::is_null) {
        return Err(format!("theme {label:?} lost its tokenColors"));
    }
    let seam = if dark { DARK_SEAM } else { LIGHT_SEAM };
    let colors = document
        .get_mut("colors")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| format!("theme {label:?} has no colors object"))?;

    // The workbench rejects an empty string per key — it is not "use the default", it is a parse
    // error that takes the whole theme with it.
    let empties: Vec<String> = colors
        .iter()
        .filter(|(_, value)| value.as_str() == Some(""))
        .map(|(key, _)| key.clone())
        .collect();
    for key in &empties {
        colors.remove(key);
    }
    for key in SEAM_BORDER_KEYS {
        colors.insert((*key).to_owned(), Value::String(seam.to_owned()));
    }
    let applied = Applied {
        colors: colors.len(),
        dropped: empties.len(),
        seam,
    };
    let mut text = serde_json::to_string(&document)
        .map_err(|error| format!("theme {label:?} will not re-encode: {error}"))?;
    text.push('\n');
    Ok((text, applied))
}

/// The newest version the marketplace has for this extension.
///
/// # Errors
/// When the query fails or answers a shape with no version in it.
fn latest_version(root: &Path) -> Result<String, String> {
    let query = format!(
        r#"{{"filters":[{{"criteria":[{{"filterType":7,"value":"{PUBLISHER}.{EXTENSION}"}}]}}],"flags":529}}"#
    );
    let answer = proc::capture(
        "curl",
        &[
            "-fsS",
            "-X",
            "POST",
            &format!("{GALLERY}/extensionquery"),
            "-H",
            "Content-Type: application/json",
            "-H",
            "Accept: application/json;api-version=3.0-preview.1",
            "-d",
            &query,
        ],
        root,
    )?;
    let document: Value =
        serde_json::from_str(&answer).map_err(|error| format!("the gallery answered non-JSON: {error}"))?;
    document
        .pointer("/results/0/extensions/0/versions/0/version")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "the gallery answer carries no version".to_owned())
}

/// Download, verify, transform and write.
///
/// # Errors
/// When the pin is unreadable, the download or unzip fails, the theme set drifted, or a theme
/// cannot be transformed.
pub fn run(root: &Path, latest: bool) -> Result<(), String> {
    let pin_file = root.join("scripts/monokai.pin");
    let version = if latest {
        let newest = latest_version(root)?;
        say("monokai-sync", &format!("latest marketplace version: {newest}"));
        newest
    } else {
        fs::read_to_string(&pin_file)
            .map_err(|error| format!("{}: {error}", pin_file.display()))?
            .trim()
            .to_owned()
    };
    say("monokai-sync", &format!("syncing Monokai Pro themes @ {version}"));

    let work = env::temp_dir().join(format!("slopdesk-monokai-{}", std::process::id()));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|error| format!("{}: {error}", work.display()))?;
    let vsix = work.join("monokai.vsix");

    // The `vspackage` endpoint answers gzip-wrapped zip bytes; `--compressed` unwraps the gzip.
    proc::run(
        "curl",
        &[
            "-fsSL",
            "--compressed",
            "-o",
            &vsix.to_string_lossy(),
            &format!("{GALLERY}/publishers/{PUBLISHER}/vsextensions/{EXTENSION}/{version}/vspackage"),
        ],
        root,
    )?;
    let unpacked = work.join("vsix");
    proc::run(
        "unzip",
        &["-qo", &vsix.to_string_lossy(), "-d", &unpacked.to_string_lossy()],
        root,
    )?;

    let extension_dir = unpacked.join("extension");
    let manifest = fs::read_to_string(extension_dir.join("package.json"))
        .map_err(|error| format!("the vsix has no package.json: {error}"))?;
    let contributed = contributions(&manifest)?;
    verdict(&contributed)?;

    let paths: BTreeMap<&str, &str> = contributed
        .iter()
        .map(|theme| (theme.label.as_str(), theme.path.as_str()))
        .collect();
    let resources = root.join("rust/slopdesk-codeseed/resources");
    for (label, dark, slug) in EXPECTED {
        let relative = paths
            .get(label)
            .ok_or_else(|| format!("the vsix contributes no theme called {label:?}"))?;
        let source = extension_dir.join(relative);
        let theme = fs::read_to_string(&source).map_err(|error| format!("{}: {error}", source.display()))?;
        let (bytes, applied) = transform(&theme, label, *dark)?;
        let out = resources.join(format!("{slug}.json"));
        fs::write(&out, bytes).map_err(|error| format!("{}: {error}", out.display()))?;
        println!(
            "  {slug}.json: {} colors, {} empty dropped, seams -> {}",
            applied.colors, applied.dropped, applied.seam
        );
    }
    let _ = fs::remove_dir_all(&work);

    if latest {
        fs::write(&pin_file, format!("{version}\n"))
            .map_err(|error| format!("{}: {error}", pin_file.display()))?;
        say("monokai-sync", &format!("pin advanced to {version}"));
    }
    say(
        "monokai-sync",
        "done — review the diff, run make test-touched, commit",
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    /// A theme file shaped like the upstream ones, with an empty value and a stock seam.
    fn theme(label: &str) -> String {
        format!(
            r##"{{"name":"{label}","tokenColors":[{{"scope":"comment"}}],
               "colors":{{"editor.background":"#222222","editor.lineHighlightBorder":"",
                          "panel.border":"#123456","sideBar.border":"#654321"}}}}"##
        )
    }

    /// Empty values go, the seven seams are retinted, and the answer is minified with one newline.
    #[test]
    fn a_transform_drops_the_empties_and_retints_the_seams() {
        let (bytes, applied) = super::transform(&theme("Monokai Pro"), "Monokai Pro", true).expect("dark");
        assert_eq!(applied.dropped, 1, "the empty-string value is dropped");
        assert_eq!(applied.seam, super::DARK_SEAM);
        // one real colour + the seven seams
        assert_eq!(applied.colors, 8);
        assert!(bytes.ends_with("}\n"), "one trailing newline");
        assert!(!bytes.contains(": "), "minified");
        assert!(!bytes.contains("lineHighlightBorder"), "the empty key is gone");
        for key in super::SEAM_BORDER_KEYS {
            assert!(
                bytes.contains(&format!("\"{key}\":\"{}\"", super::DARK_SEAM)),
                "{key} retinted"
            );
        }
    }

    /// A light variant gets the light seam — the reason `uiTheme` is part of the drift check.
    #[test]
    fn a_light_theme_gets_the_light_seam() {
        let (bytes, applied) =
            super::transform(&theme("Monokai Pro Light"), "Monokai Pro Light", false).expect("light");
        assert_eq!(applied.seam, super::LIGHT_SEAM);
        assert!(bytes.contains(super::LIGHT_SEAM));
        assert!(!bytes.contains(super::DARK_SEAM));
    }

    /// A theme whose `name` moved, or that lost its tokens, is refused rather than written.
    #[test]
    fn a_theme_that_renamed_itself_or_lost_its_tokens_is_refused() {
        let renamed = super::transform(&theme("Monokai Pro"), "Monokai Classic", true);
        assert!(renamed.is_err(), "the label and the file must agree");

        let no_tokens = r#"{"name":"Monokai Pro","colors":{}}"#;
        assert!(super::transform(no_tokens, "Monokai Pro", true).is_err());
    }

    /// The eight the table expects.
    fn all_eight() -> Vec<super::Contribution> {
        super::EXPECTED
            .iter()
            .map(|(label, dark, slug)| {
                super::Contribution {
                    label: (*label).to_owned(),
                    ui_theme: if *dark { "vs-dark" } else { "vs" }.to_owned(),
                    path: format!("./themes/{slug}.json"),
                }
            })
            .collect()
    }

    /// The set that matches passes; an add, a removal and a flipped `uiTheme` each fail.
    #[test]
    fn an_upstream_theme_set_change_is_loud() {
        assert!(super::verdict(&all_eight()).is_ok(), "the shipped set");

        let mut added = all_eight();
        added.push(super::Contribution {
            label: "Monokai Pro (Filter Coffee)".to_owned(),
            ui_theme: "vs-dark".to_owned(),
            path: "./themes/coffee.json".to_owned(),
        });
        assert!(super::verdict(&added).is_err(), "a new variant needs a Rust edit");

        let mut removed = all_eight();
        removed.pop();
        assert!(
            super::verdict(&removed).is_err(),
            "a dropped variant is not silently skipped"
        );

        let mut flipped = all_eight();
        flipped[0].ui_theme = "vs".to_owned();
        assert!(
            super::verdict(&flipped).is_err(),
            "dark→light changes the seam it gets"
        );
    }

    /// The manifest read, including the shape with no themes at all.
    #[test]
    fn the_manifest_yields_label_uitheme_and_path() {
        let manifest = r#"{"contributes":{"themes":[
            {"label":"Monokai Pro","uiTheme":"vs-dark","path":"./themes/pro.json"}]}}"#;
        let read = super::contributions(manifest).expect("one theme");
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].label, "Monokai Pro");
        assert_eq!(read[0].path, "./themes/pro.json");

        assert!(super::contributions(r#"{"contributes":{}}"#).is_err());
        assert!(super::contributions("nope").is_err());
    }
}
