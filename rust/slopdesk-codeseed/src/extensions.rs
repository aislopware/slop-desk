//! The two extensions the app seeds into the operator's profile, and the registry that decides
//! whether the workbench can see them.
//!
//! ## Why a registry write at all
//! `extensions.json` — not the directory scan — is the workbench's source of truth once the file
//! exists: code-server writes an EMPTY `[]` on first boot, and from then on a folder-dropped
//! extension is invisible (observed: the seeded theme fell back to stock dark). Foreign entries are
//! always preserved; ours is replaced only when it drifted.
//!
//! ## Why our folders are ours to overwrite and the settings file is not
//! The folders are namespaced `slopdesk.*`. Nobody else writes them, so drifted bytes mean an older
//! hostd wrote them and the current one should repair them in place — which is how a newer
//! `extension.js` deploys without a version bump. The settings file is shared with the user, and
//! the rule there is the opposite (see `crate::settings`).

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

/// The publisher both seeded extensions share.
pub const PUBLISHER: &str = "slopdesk";

// ── The theme extension ─────────────────────────────────────────────────────────────────────────

/// The theme extension's name.
///
/// NOT `slopdesk-monokai` any more: the folder now carries the app's OWN theme beside the vendored
/// family, and a folder named for one of its passengers ages into a lie. The old name is swept —
/// see [`RETIRED_EXTENSIONS`].
pub const THEME_NAME: &str = "slopdesk-themes";
/// A version bump re-seeds changed theme bytes on the next hostd start (the writer overwrites on
/// content drift) and re-registers the new folder.
pub const THEME_VERSION: &str = "1.0.0";

/// EVERY theme this extension contributes — label, dark-or-light, resource slug.
///
/// The label is what the settings and the ⌘K ⌘T picker select by. This table is the single source
/// of truth: the manifest is generated from it and the seeder writes one file per row.
///
/// ALUCARD LEADS, because it is the one the seed selects (user-directed 2026-08-09): the app's
/// ground cream IS Alucard's published `editor.background`, so the editor canvas and the window's
/// ground are the same colour by ORIGIN rather than by an override forcing them to agree. It is the
/// app's own row — the eight below it are the vendored vsix's, and only THEY are mirrored by
/// `scripts/monokai-sync.sh`, which fails loudly when the upstream set stops matching its own copy
/// of the Monokai rows. All eight still ship: the picker offers the full family, the seed just no
/// longer starts there.
///
/// The two kinds differ in shape as well as origin: a vendored theme names the workbench's whole
/// key set (~600 colours), while ours names only what it means to change.
pub const THEMES: &[(&str, bool, &str)] = &[
    ("Alucard", false, "alucard"),
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

/// Which rows are OURS rather than vendored — the set `scripts/monokai-sync.sh` must never expect
/// to find upstream.
pub const OWN_THEME_RESOURCES: &[&str] = &["alucard"];

/// The theme bytes, embedded.
///
/// Embedded rather than read from a directory beside the binary because this program is invoked
/// from wherever hostd was installed — a bundle, a `.build` directory, a Homebrew cellar — and a
/// seed that silently no-ops when its data is elsewhere is worse than one that cannot be separated
/// from it. Each is the theme verbatim; only the theme DATA is vendored, never the upstream
/// extension's activation code (that code carries the license prompt, which is why the marketplace
/// extension is not installed directly).
const THEME_DATA: &[(&str, &str)] = &[
    ("alucard", include_str!("../resources/alucard.json")),
    ("monokai-pro", include_str!("../resources/monokai-pro.json")),
    (
        "monokai-pro-filter-octagon",
        include_str!("../resources/monokai-pro-filter-octagon.json"),
    ),
    (
        "monokai-pro-filter-ristretto",
        include_str!("../resources/monokai-pro-filter-ristretto.json"),
    ),
    (
        "monokai-pro-filter-spectrum",
        include_str!("../resources/monokai-pro-filter-spectrum.json"),
    ),
    (
        "monokai-pro-filter-machine",
        include_str!("../resources/monokai-pro-filter-machine.json"),
    ),
    (
        "monokai-pro-light",
        include_str!("../resources/monokai-pro-light.json"),
    ),
    (
        "monokai-pro-light-filter-sun",
        include_str!("../resources/monokai-pro-light-filter-sun.json"),
    ),
    (
        "monokai-classic",
        include_str!("../resources/monokai-classic.json"),
    ),
];

/// One theme's bytes by slug.
#[must_use]
pub fn theme_data(resource: &str) -> Option<&'static str> {
    THEME_DATA
        .iter()
        .find(|(slug, _)| *slug == resource)
        .map(|(_, data)| *data)
}

/// Theme files the two-variant era wrote into the extension folder — swept by the seeder so the
/// deployed folder carries exactly the current manifest's files, nothing stale.
const LEGACY_THEME_FILES: &[&str] = &[
    "themes/slopdesk-monokai-color-theme.json",
    "themes/slopdesk-monokai-light-color-theme.json",
];

/// The theme extension's folder name — `publisher.name-version`.
#[must_use]
pub fn theme_directory_name() -> String {
    format!("{PUBLISHER}.{THEME_NAME}-{THEME_VERSION}")
}

/// The theme extension's manifest, generated from [`THEMES`].
///
/// Written as text rather than serialized from a `Value`, because this file's BYTES are the
/// upgrade signal: the seeder rewrites a manifest whose bytes drifted, and `serde_json`'s map is a
/// `BTreeMap` — serializing would re-order every key alphabetically and make the first boot after
/// this port look like a change to every profile in existence. The authored order also reads the
/// way a person would write a `package.json`, which is what the operator opens.
#[must_use]
pub fn theme_manifest() -> String {
    let themes = THEMES
        .iter()
        .map(|(label, dark, resource)| {
            let ui_theme = if *dark { "vs-dark" } else { "vs" };
            format!(
                "            {{\n                \"label\": \"{label}\",\n                \"uiTheme\": \
                 \"{ui_theme}\",\n                \"path\": \"./themes/{resource}.json\"\n            }}"
            )
        })
        .collect::<Vec<_>>()
        .join(",\n");
    format!(
        r#"{{
    "name": "{THEME_NAME}",
    "displayName": "SlopDesk Themes",
    "description": "Alucard (the app's ground palette) and stock Monokai Pro; seam borders carry the app's divider tint.",
    "publisher": "{PUBLISHER}",
    "version": "{THEME_VERSION}",
    "engines": {{ "vscode": "^1.0.0" }},
    "categories": ["Themes"],
    "contributes": {{
        "themes": [
{themes}
        ]
    }}
}}"#
    )
}

/// Writes the theme extension under `extensions_dir` — the manifest plus one file per [`THEMES`]
/// row.
///
/// OUR files are overwritten when their bytes drifted, [`LEGACY_THEME_FILES`] are swept, and the
/// folder is registered. Returns whether anything changed; failures are silent no-ops.
#[must_use]
pub fn seed_theme_extension(extensions_dir: &Path) -> bool {
    let root = extensions_dir.join(theme_directory_name());
    let mut files: Vec<(PathBuf, String)> = vec![(root.join("package.json"), theme_manifest())];
    for (_, _, resource) in THEMES {
        let Some(data) = theme_data(resource) else {
            return false;
        };
        files.push((root.join(format!("themes/{resource}.json")), data.to_owned()));
    }
    let mut wrote = write_if_drifted(&files);
    for legacy in LEGACY_THEME_FILES {
        if remove_if_present(&root.join(legacy)) {
            wrote = true;
        }
    }
    if register_extension(
        &format!("{PUBLISHER}.{THEME_NAME}"),
        THEME_VERSION,
        &theme_directory_name(),
        extensions_dir,
    ) {
        wrote = true;
    }
    wrote
}

// ── The bridge extension ────────────────────────────────────────────────────────────────────────

/// The bridge extension's name.
///
/// It is the app's own extension — the one piece of CODE, as opposed to theme data, that runs
/// inside the workbench. See `resources/bridge/extension.js` for what it does.
pub const BRIDGE_NAME: &str = "slopdesk-bridge";
/// Bumped whenever the manifest's CONTRIBUTIONS change, not merely its code.
///
/// The seeder rewrites drifted bytes in place, but the workbench caches a scanned extension's
/// `contributes` against its version, so new menu items on an unchanged version can go unnoticed
/// until the profile is rebuilt. 1.1.0 = the terminal commands.
pub const BRIDGE_VERSION: &str = "1.1.0";

/// Folders left behind by earlier versions. Unregistered the moment `extensions.json` points at the
/// new one, but swept anyway so a long-lived profile does not accumulate dead copies of our code.
const LEGACY_BRIDGE_DIRECTORIES: &[&str] = &["slopdesk.slopdesk-bridge-1.0.0"];

/// The bridge extension's entry point, embedded — real JavaScript, kept in a `.js` file so it reads
/// and lints as JavaScript rather than as a string literal.
const BRIDGE_SOURCE: &str = include_str!("../resources/bridge/extension.js");

/// The bridge extension's folder name.
#[must_use]
pub fn bridge_directory_name() -> String {
    format!("{PUBLISHER}.{BRIDGE_NAME}-{BRIDGE_VERSION}")
}

/// The bridge extension's manifest.
///
/// `extensionKind: ["workspace"]` pins it to the REMOTE extension host — the one running on this
/// machine, next to the socket and the files; the web worker host has neither.
/// `onStartupFinished` keeps it off the workbench's critical path: the first open command cannot
/// arrive before a window exists to receive it anyway.
///
/// The two contributed commands are the editor's way BACK to the app: they type into a real
/// real pane of the app rather than the workbench's own integrated terminal. They sit in the editor
/// context menu (`navigation` group, so they lead) and the explorer's, and are `enablement`-free on
/// purpose — the host answers a request it cannot serve with a sentence, which is more use than a
/// greyed-out item.
///
/// Text rather than a serialized `Value`, for the reason [`theme_manifest`] records.
#[must_use]
pub fn bridge_manifest() -> String {
    format!(
        r#"{{
    "name": "{BRIDGE_NAME}",
    "displayName": "SlopDesk Bridge",
    "description": "Opens files sent by the SlopDesk host, and runs commands in its terminal panes.",
    "publisher": "{PUBLISHER}",
    "version": "{BRIDGE_VERSION}",
    "engines": {{ "vscode": "^1.0.0" }},
    "extensionKind": ["workspace"],
    "activationEvents": ["onStartupFinished"],
    "main": "./extension.js",
    "contributes": {{
        "commands": [
            {{
                "command": "slopdesk.runSelectionInTerminal",
                "title": "Run Selection in SlopDesk Terminal",
                "category": "SlopDesk"
            }},
            {{
                "command": "slopdesk.changeTerminalDirectory",
                "title": "Change SlopDesk Terminal Directory Here",
                "category": "SlopDesk"
            }}
        ],
        "menus": {{
            "editor/context": [
                {{
                    "command": "slopdesk.runSelectionInTerminal",
                    "when": "editorHasSelection",
                    "group": "navigation@1"
                }},
                {{
                    "command": "slopdesk.changeTerminalDirectory",
                    "when": "editorIsOpen",
                    "group": "navigation@2"
                }}
            ],
            "explorer/context": [
                {{
                    "command": "slopdesk.changeTerminalDirectory",
                    "group": "navigation@9"
                }}
            ]
        }}
    }}
}}"#
    )
}

/// Writes the bridge extension under `extensions_dir` and registers it, on the same terms as the
/// theme seeder.
#[must_use]
pub fn seed_bridge_extension(extensions_dir: &Path) -> bool {
    let root = extensions_dir.join(bridge_directory_name());
    let files = vec![
        (root.join("package.json"), bridge_manifest()),
        (root.join("extension.js"), BRIDGE_SOURCE.to_owned()),
    ];
    let mut wrote = write_if_drifted(&files);
    for legacy in LEGACY_BRIDGE_DIRECTORIES {
        if remove_if_present(&extensions_dir.join(legacy)) {
            wrote = true;
        }
    }
    if register_extension(
        &format!("{PUBLISHER}.{BRIDGE_NAME}"),
        BRIDGE_VERSION,
        &bridge_directory_name(),
        extensions_dir,
    ) {
        wrote = true;
    }
    wrote
}

// ── Retired extensions ──────────────────────────────────────────────────────────────────────────

/// Every theme extension this program has RETIRED, by registry id and by every folder name it ever
/// shipped under.
///
/// The seed deletes each one before writing the live extension, so a host that never saw them is a
/// no-op and an upgraded host loses the leftovers the settings seed no longer selects.
///
/// * `slopdesk-foundry` — the app's own generated workbench themes (four Foundry seeds at 1.0.0,
///   the Dracula / Alucard pair at 2.0.0), retired by the chrome revert (user-directed 2026-08-08).
/// * `slopdesk-monokai` — the vendored family under its OLD folder name, before the theme extension
///   was renamed to carry the app's own Alucard alongside it (2026-08-09). Its themes did not go
///   anywhere; only the folder they live in did, and leaving the old one behind would register the
///   same eight labels twice in the picker.
pub const RETIRED_EXTENSIONS: &[(&str, &[&str])] = &[
    ("slopdesk.slopdesk-foundry", &[
        "slopdesk.slopdesk-foundry-1.0.0",
        "slopdesk.slopdesk-foundry-2.0.0",
    ]),
    ("slopdesk.slopdesk-monokai", &["slopdesk.slopdesk-monokai-1.0.0"]),
];

/// Deletes every retired extension's folders and prunes its registry entry.
#[must_use]
pub fn remove_retired_extensions(extensions_dir: &Path) -> bool {
    let mut changed = false;
    for (id, directories) in RETIRED_EXTENSIONS {
        for name in *directories {
            if remove_if_present(&extensions_dir.join(name)) {
                changed = true;
            }
        }
        if unregister_extension(id, extensions_dir) {
            changed = true;
        }
    }
    changed
}

// ── The registry ────────────────────────────────────────────────────────────────────────────────

/// Registers `id` in the profile registry beside the seeded folders.
///
/// Entry shape per the server's own validator: `identifier` / `version` / `location {path, scheme}`
/// / `relativeLocation`. A missing registry file is created — the boot that follows keeps our
/// entry. An unparseable registry is someone else's problem state; it is left alone, since the
/// workbench self-heals its own file.
#[must_use]
pub fn register_extension(id: &str, version: &str, directory_name: &str, extensions_dir: &Path) -> bool {
    let registry_path = extensions_dir.join("extensions.json");
    // A registry that will not decode is someone else's problem state — left alone, never
    // replaced. A registry that is not THERE is a first boot, and an empty list is the truth.
    let mut entries: Vec<Entry> = match std::fs::read_to_string(&registry_path) {
        Ok(bytes) => {
            match serde_json::from_str::<Vec<Entry>>(&bytes) {
                Ok(parsed) => parsed,
                Err(_) => return false,
            }
        },
        Err(_) => Vec::new(),
    };
    let Value::Object(ours) = json!({
        "identifier": { "id": id },
        "version": version,
        "location": {
            "$mid": 1,
            "path": extensions_dir.join(directory_name).to_string_lossy(),
            "scheme": "file",
        },
        "relativeLocation": directory_name,
        "metadata": { "installedTimestamp": 0, "pinned": true, "source": "resource" },
    }) else {
        return false;
    };
    match entries.iter().position(|entry| entry_id(entry) == Some(id)) {
        Some(existing) => {
            // Drift check via canonical (sorted-keys) JSON — a registry the workbench rewrote in
            // another key order holds the SAME entry, and rewriting it would make every boot look
            // like a change. serde_json's map is a `BTreeMap`, so serializing already sorts.
            let same = entries
                .get(existing)
                .and_then(|entry| serde_json::to_string(entry).ok())
                .zip(serde_json::to_string(&ours).ok())
                .is_some_and(|(before, after)| before == after);
            if same {
                return false;
            }
            if let Some(slot) = entries.get_mut(existing) {
                *slot = ours;
            }
        },
        None => entries.push(ours),
    }
    write_registry(&registry_path, &entries)
}

/// Removes `id`'s entry from the registry — the inverse of [`register_extension`], on the same
/// terms: foreign entries are preserved, and a missing or unparseable registry is left alone.
#[must_use]
pub fn unregister_extension(id: &str, extensions_dir: &Path) -> bool {
    let registry_path = extensions_dir.join("extensions.json");
    let Ok(bytes) = std::fs::read_to_string(&registry_path) else {
        return false;
    };
    let Ok(entries) = serde_json::from_str::<Vec<Entry>>(&bytes) else {
        return false;
    };
    let kept: Vec<Entry> = entries
        .iter()
        .filter(|entry| entry_id(entry) != Some(id))
        .cloned()
        .collect();
    if kept.len() == entries.len() {
        return false;
    }
    write_registry(&registry_path, &kept)
}

/// Marketplace extensions installed FOR REAL on first boot.
///
/// Unlike the vendored Monokai Pro theme data these run their own code, so only fully-free
/// extensions (no license or purchase prompts in their activation path) qualify. Installed once via
/// `code-server --install-extension` before the first spawn; updates ride the workbench's own
/// extension updater from then on.
///
/// * `pkief.material-icon-theme` — the Material Icon Theme file icons the seed's
///   `workbench.iconTheme` selects (MIT-licensed, data-driven, no nag).
pub const BUNDLED_MARKETPLACE_EXTENSIONS: &[&str] = &["pkief.material-icon-theme"];

/// The bundled ids absent from the profile registry.
///
/// A missing or unparseable registry ⇒ ALL bundled ids are missing: a pristine host has no registry
/// yet, and installing over a broken one lets the CLI rewrite it properly. Ids compare
/// case-insensitively, as the marketplace treats them.
#[must_use]
pub fn missing_bundled_extensions(registry: Option<&str>) -> Vec<&'static str> {
    let installed: Vec<String> = registry
        .and_then(|bytes| serde_json::from_str::<Vec<Entry>>(bytes).ok())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| entry_id(entry).map(str::to_lowercase))
                .collect()
        })
        .unwrap_or_default();
    BUNDLED_MARKETPLACE_EXTENSIONS
        .iter()
        .filter(|id| !installed.contains(&id.to_lowercase()))
        .copied()
        .collect()
}

/// The bundled ids absent from the registry that sits beside `extensions_dir`.
#[must_use]
pub fn missing_bundled_extensions_at(extensions_dir: &Path) -> Vec<&'static str> {
    let registry = std::fs::read_to_string(extensions_dir.join("extensions.json")).ok();
    missing_bundled_extensions(registry.as_deref())
}

/// One registry record. Typed as an OBJECT, not a bare `Value`, so an array carrying anything else
/// fails the decode and the registry is left alone — the same refusal the Swift original's
/// `as? [[String: Any]]` cast performed.
type Entry = Map<String, Value>;

fn entry_id(entry: &Entry) -> Option<&str> {
    entry.get("identifier")?.get("id")?.as_str()
}

fn write_registry(path: &Path, entries: &[Entry]) -> bool {
    let Ok(encoded) = serde_json::to_string(entries) else {
        return false;
    };
    if let Some(parent) = path.parent()
        && std::fs::create_dir_all(parent).is_err()
    {
        return false;
    }
    std::fs::write(path, encoded).is_ok()
}

/// Writes each file whose bytes differ from what is already there, creating directories. Returns
/// whether anything was written; the first failure stops the run, reporting what it managed.
fn write_if_drifted(files: &[(PathBuf, String)]) -> bool {
    let mut wrote = false;
    for (path, contents) in files {
        if std::fs::read_to_string(path).ok().as_deref() == Some(contents.as_str()) {
            continue;
        }
        if let Some(parent) = path.parent()
            && std::fs::create_dir_all(parent).is_err()
        {
            return wrote;
        }
        if std::fs::write(path, contents).is_err() {
            return wrote;
        }
        wrote = true;
    }
    wrote
}

/// Deletes a file or directory when it exists. Returns whether it did.
fn remove_if_present(path: &Path) -> bool {
    if !path.exists() {
        return false;
    }
    if path.is_dir() {
        std::fs::remove_dir_all(path).is_ok()
    } else {
        std::fs::remove_file(path).is_ok()
    }
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `expect` IS the assertion.
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use crate::scratch::Scratch;

    fn registry(extensions_dir: &Path) -> Vec<Entry> {
        let bytes =
            std::fs::read_to_string(extensions_dir.join("extensions.json")).expect("a registry was written");
        serde_json::from_str(&bytes).expect("the registry is an array of objects")
    }

    // ── The theme table and its manifest ────────────────────────────────────────────────────────

    /// The seven structural seams the app retints — the ONE colour departure from the vendored
    /// stock, so a resync that lost it would otherwise pass every other assertion.
    const SEAM_BORDER_KEYS: &[&str] = &[
        "activityBar.border",
        "editorGroup.border",
        "panel.border",
        "sideBar.border",
        "statusBar.border",
        "statusBar.noFolderBorder",
        "titleBar.border",
    ];

    /// Every workbench colour must be `#rrggbb` or `#rrggbbaa`. The vsix conversion once carried
    /// five EMPTY-string values (`diffEditor.move.border` and friends), which the workbench rejects
    /// per key; a file we author carries no invalid values.
    fn assert_every_colour_is_valid_hex(label: &str, colours: &Map<String, Value>) {
        for (key, value) in colours {
            let hex = value
                .as_str()
                .unwrap_or_else(|| panic!("{label} {key} is not a string"));
            let digits = hex
                .strip_prefix('#')
                .unwrap_or_else(|| panic!("{label} {key} = {hex}"));
            assert!(
                (digits.len() == 6 || digits.len() == 8) && digits.chars().all(|c| c.is_ascii_hexdigit()),
                "{label} {key} carries an invalid colour value '{hex}'",
            );
        }
    }

    fn theme(resource: &str) -> Map<String, Value> {
        let data = theme_data(resource).unwrap_or_else(|| panic!("{resource} has no bytes"));
        serde_json::from_str(data).unwrap_or_else(|_| panic!("{resource} is not a JSON object"))
    }

    #[test]
    fn every_theme_carries_the_seam_tint_and_no_invalid_colour() {
        for (label, dark, resource) in THEMES {
            let parsed = theme(resource);
            assert_eq!(parsed["name"], *label);
            assert_eq!(parsed["type"], if *dark { "dark" } else { "light" });
            let colours = parsed["colors"].as_object().expect("colors");
            // The vendored vsix names the workbench's whole key set; the app's own theme is
            // hand-authored and only names what it means to change.
            let floor = if OWN_THEME_RESOURCES.contains(resource) {
                100
            } else {
                500
            };
            assert!(
                colours.len() > floor,
                "{label} carries only {} colours",
                colours.len()
            );
            let seam = if *dark { "#fcfcfa1a" } else { "#00000014" };
            for key in SEAM_BORDER_KEYS {
                assert_eq!(colours[*key], seam, "{label} {key}");
            }
            assert_every_colour_is_valid_hex(label, colours);
            assert!(
                !parsed["tokenColors"].as_array().expect("tokenColors").is_empty(),
                "syntax rules ride along — the palette identity ({label})",
            );
        }
    }

    #[test]
    fn the_dark_vendored_theme_is_stock_monokai_pro_under_the_seam_tint() {
        let parsed = theme("monokai-pro");
        let colours = parsed["colors"].as_object().expect("colors");
        // Stock Monokai Pro surfaces — they double as the app's own Slate seeds.
        assert_eq!(colours["editor.background"], "#2d2a2e");
        assert_eq!(colours["sideBar.background"], "#221f22");
        // STOCK SURVIVES (user-directed 2026-08-03, reverting the 17-key chrome-accent
        // neutralization): the filter's yellow accent stays on tabs, lists and links.
        for key in [
            "tab.activeForeground",
            "tab.activeBorder",
            "list.activeSelectionForeground",
            "textLink.foreground",
            "gitDecoration.modifiedResourceForeground",
        ] {
            assert_eq!(colours[key], "#ffd866", "{key} lost the stock accent");
        }
        assert_eq!(colours["tab.activeBackground"], "#2d2a2e");
    }

    #[test]
    fn the_light_vendored_theme_mirrors_it() {
        let parsed = theme("monokai-pro-light");
        let colours = parsed["colors"].as_object().expect("colors");
        assert_eq!(colours["editor.background"], "#faf4f2");
        assert_eq!(colours["editor.foreground"], "#29242a");
        for key in [
            "tab.activeForeground",
            "tab.activeBorder",
            "list.activeSelectionForeground",
            "textLink.foreground",
            "gitDecoration.deletedResourceForeground",
        ] {
            assert_eq!(colours[key], "#e14775", "{key} lost the stock accent");
        }
        assert_eq!(colours["tab.activeBackground"], "#faf4f2");
    }

    #[test]
    fn the_apps_own_theme_publishes_the_grounds_cream() {
        // The whole reason Alucard leads: the window's ground IS this value, so the editor canvas
        // and the ground agree by ORIGIN rather than by an override forcing them to.
        let parsed = theme("alucard");
        assert_eq!(parsed["colors"]["editor.background"], "#FFFBEB");
    }

    #[test]
    fn every_contributed_command_is_registered_by_the_extension_source() {
        let manifest: Value = serde_json::from_str(&bridge_manifest()).expect("the manifest is JSON");
        for command in manifest["contributes"]["commands"].as_array().expect("commands") {
            let id = command["command"].as_str().expect("a command id");
            assert!(
                BRIDGE_SOURCE.contains(&format!("registerCommand(\"{id}\"")),
                "{id} is contributed but never registered",
            );
        }
    }

    #[test]
    fn every_row_of_the_table_has_theme_bytes_behind_it() {
        for (label, _, resource) in THEMES {
            let data = theme_data(resource).unwrap_or_else(|| panic!("{label} has no bytes"));
            assert!(
                serde_json::from_str::<Value>(data).is_ok(),
                "{label}'s theme file is not JSON",
            );
        }
    }

    #[test]
    fn the_manifest_agrees_with_the_table_row_for_row() {
        let manifest: Value = serde_json::from_str(&theme_manifest()).expect("the manifest is JSON");
        let contributed = manifest["contributes"]["themes"]
            .as_array()
            .expect("themes array");
        assert_eq!(contributed.len(), THEMES.len());
        for (contributed, (label, dark, resource)) in contributed.iter().zip(THEMES) {
            assert_eq!(contributed["label"], *label);
            assert_eq!(contributed["uiTheme"], if *dark { "vs-dark" } else { "vs" });
            assert_eq!(contributed["path"], format!("./themes/{resource}.json"));
        }
        assert_eq!(manifest["name"], THEME_NAME);
        assert_eq!(manifest["publisher"], PUBLISHER);
        assert_eq!(manifest["version"], THEME_VERSION);
    }

    #[test]
    fn alucard_leads_and_is_the_apps_own_row() {
        assert_eq!(THEMES[0].0, "Alucard", "the seed selects the first row");
        assert!(OWN_THEME_RESOURCES.contains(&THEMES[0].2));
    }

    #[test]
    fn the_vendored_rows_are_exactly_the_ones_the_sync_script_mirrors() {
        let vendored: Vec<&str> = THEMES
            .iter()
            .map(|(_, _, resource)| *resource)
            .filter(|resource| !OWN_THEME_RESOURCES.contains(resource))
            .collect();
        assert_eq!(vendored.len(), 8, "the vsix ships eight variants");
        assert!(vendored.iter().all(|resource| resource.starts_with("monokai")));
    }

    #[test]
    fn no_two_rows_share_a_label_or_a_resource() {
        let labels: BTreeSet<&str> = THEMES.iter().map(|(label, ..)| *label).collect();
        let resources: BTreeSet<&str> = THEMES.iter().map(|(_, _, r)| *r).collect();
        assert_eq!(
            labels.len(),
            THEMES.len(),
            "a duplicate label appears twice in the picker"
        );
        assert_eq!(resources.len(), THEMES.len());
    }

    #[test]
    fn the_bridge_manifest_contributes_both_terminal_commands() {
        let manifest: Value = serde_json::from_str(&bridge_manifest()).expect("the manifest is JSON");
        assert_eq!(manifest["name"], BRIDGE_NAME);
        assert_eq!(manifest["version"], BRIDGE_VERSION);
        assert_eq!(
            manifest["extensionKind"][0], "workspace",
            "the REMOTE host holds the socket"
        );
        assert_eq!(manifest["activationEvents"][0], "onStartupFinished");
        let commands = manifest["contributes"]["commands"].as_array().expect("commands");
        let ids: Vec<&str> = commands.iter().filter_map(|c| c["command"].as_str()).collect();
        assert_eq!(ids, [
            "slopdesk.runSelectionInTerminal",
            "slopdesk.changeTerminalDirectory"
        ],);
    }

    #[test]
    fn every_contributed_menu_item_names_a_contributed_command() {
        let manifest: Value = serde_json::from_str(&bridge_manifest()).expect("the manifest is JSON");
        let declared: BTreeSet<String> = manifest["contributes"]["commands"]
            .as_array()
            .expect("commands")
            .iter()
            .filter_map(|c| c["command"].as_str().map(str::to_owned))
            .collect();
        let menus = manifest["contributes"]["menus"].as_object().expect("menus");
        for (where_, items) in menus {
            for item in items.as_array().expect("menu items") {
                let id = item["command"].as_str().expect("a menu item names a command");
                assert!(
                    declared.contains(id),
                    "{where_} offers {id}, which is not contributed"
                );
            }
        }
    }

    // ── The seeders ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_pristine_profile_gets_both_extensions_and_a_registry() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(seed_theme_extension(dir));
        assert!(seed_bridge_extension(dir));

        let themes = dir.join(theme_directory_name());
        assert_eq!(
            std::fs::read_to_string(themes.join("package.json"))
                .ok()
                .as_deref(),
            Some(theme_manifest().as_str()),
        );
        for (_, _, resource) in THEMES {
            assert!(
                themes.join(format!("themes/{resource}.json")).exists(),
                "{resource} is missing"
            );
        }
        let bridge = dir.join(bridge_directory_name());
        assert!(bridge.join("extension.js").exists());

        let entries = registry(dir);
        let ids: BTreeSet<&str> = entries.iter().filter_map(|entry| entry_id(entry)).collect();
        assert_eq!(
            ids,
            BTreeSet::from(["slopdesk.slopdesk-bridge", "slopdesk.slopdesk-themes"]),
        );
    }

    #[test]
    fn seeding_twice_writes_nothing_the_second_time() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(seed_theme_extension(dir));
        assert!(seed_bridge_extension(dir));
        assert!(
            !seed_theme_extension(dir),
            "an unchanged profile is not rewritten"
        );
        assert!(!seed_bridge_extension(dir));
    }

    #[test]
    fn our_own_drifted_bytes_are_repaired_in_place() {
        // How a hostd carrying a newer `extension.js` upgrades the deployed copy with no bump.
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(seed_bridge_extension(dir));
        let js = dir.join(bridge_directory_name()).join("extension.js");
        std::fs::write(&js, "// an older hostd wrote this\n").expect("overwrite");
        assert!(seed_bridge_extension(dir));
        assert_ne!(
            std::fs::read_to_string(&js).ok().as_deref(),
            Some("// an older hostd wrote this\n"),
        );
    }

    #[test]
    fn the_two_variant_eras_theme_files_are_swept() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        let root = dir.join(theme_directory_name());
        std::fs::create_dir_all(root.join("themes")).expect("directories");
        for legacy in LEGACY_THEME_FILES {
            std::fs::write(root.join(legacy), "{}").expect("legacy file");
        }
        assert!(seed_theme_extension(dir));
        for legacy in LEGACY_THEME_FILES {
            assert!(!root.join(legacy).exists(), "{legacy} survived the sweep");
        }
    }

    #[test]
    fn an_older_bridge_folder_does_not_accumulate() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        let legacy = dir.join(LEGACY_BRIDGE_DIRECTORIES[0]);
        std::fs::create_dir_all(&legacy).expect("legacy folder");
        assert!(seed_bridge_extension(dir));
        assert!(!legacy.exists());
    }

    // ── The retired sweep ───────────────────────────────────────────────────────────────────────

    #[test]
    fn a_host_that_never_saw_the_retired_extensions_is_a_no_op() {
        let scratch = Scratch::new();
        assert!(!remove_retired_extensions(scratch.path()));
    }

    #[test]
    fn every_retired_folder_and_its_registry_entry_go() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        for (id, directories) in RETIRED_EXTENSIONS {
            for name in *directories {
                std::fs::create_dir_all(dir.join(name)).expect("retired folder");
            }
            assert!(register_extension(id, "1.0.0", directories[0], dir));
        }
        assert!(remove_retired_extensions(dir));
        for (id, directories) in RETIRED_EXTENSIONS {
            for name in *directories {
                assert!(!dir.join(name).exists(), "{name} survived");
            }
            assert!(
                registry(dir).iter().all(|e| entry_id(e) != Some(*id)),
                "{id} is still registered"
            );
        }
    }

    #[test]
    fn the_retired_ids_are_not_the_live_ones() {
        let live = [
            format!("{PUBLISHER}.{THEME_NAME}"),
            format!("{PUBLISHER}.{BRIDGE_NAME}"),
        ];
        for (id, _) in RETIRED_EXTENSIONS {
            assert!(!live.contains(&(*id).to_owned()), "{id} is retired AND seeded");
        }
    }

    // ── The registry ────────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_foreign_entry_is_never_disturbed() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        let theirs = r#"[{"identifier":{"id":"pkief.material-icon-theme"},"version":"5.37.0"}]"#;
        std::fs::write(dir.join("extensions.json"), theirs).expect("registry");
        assert!(register_extension("slopdesk.slopdesk-themes", "1.0.0", "d", dir));
        let entries = registry(dir);
        assert_eq!(entries.len(), 2);
        assert_eq!(entry_id(&entries[0]), Some("pkief.material-icon-theme"));
        assert_eq!(entries[0]["version"], "5.37.0");
    }

    #[test]
    fn an_unchanged_entry_is_not_rewritten() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        assert!(!register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
    }

    #[test]
    fn a_reordered_registry_still_reads_as_unchanged() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        // What the workbench does when it rewrites the file in its own key order.
        let reflowed = serde_json::to_string_pretty(&registry(dir)).expect("re-encodes");
        std::fs::write(dir.join("extensions.json"), reflowed).expect("registry");
        assert!(
            !register_extension("a.b", "1.0.0", "a.b-1.0.0", dir),
            "key order is not drift"
        );
    }

    #[test]
    fn a_drifted_version_is_replaced_rather_than_duplicated() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        assert!(register_extension("a.b", "2.0.0", "a.b-2.0.0", dir));
        let entries = registry(dir);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["version"], "2.0.0");
        assert_eq!(entries[0]["relativeLocation"], "a.b-2.0.0");
    }

    #[test]
    fn the_entry_carries_the_shape_the_servers_validator_wants() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        let entry = registry(dir).remove(0);
        assert_eq!(entry["identifier"]["id"], "a.b");
        assert_eq!(entry["location"]["scheme"], "file");
        assert_eq!(entry["location"]["$mid"], 1);
        assert_eq!(
            entry["location"]["path"],
            dir.join("a.b-1.0.0").to_string_lossy().as_ref(),
        );
        assert_eq!(entry["relativeLocation"], "a.b-1.0.0");
        assert_eq!(entry["metadata"]["pinned"], true);
    }

    #[test]
    fn an_unparseable_registry_is_someone_elses_problem_state() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        std::fs::write(dir.join("extensions.json"), "not json").expect("registry");
        assert!(!register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        assert!(!unregister_extension("a.b", dir));
        assert_eq!(
            std::fs::read_to_string(dir.join("extensions.json"))
                .ok()
                .as_deref(),
            Some("not json")
        );
    }

    #[test]
    fn unregistering_something_absent_changes_nothing() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert!(!unregister_extension("a.b", dir), "there is no registry at all");
        assert!(register_extension("a.b", "1.0.0", "a.b-1.0.0", dir));
        assert!(!unregister_extension("c.d", dir));
        assert_eq!(registry(dir).len(), 1);
    }

    // ── The bundled marketplace set ─────────────────────────────────────────────────────────────

    #[test]
    fn no_registry_means_every_bundled_id_is_missing() {
        assert_eq!(missing_bundled_extensions(None), BUNDLED_MARKETPLACE_EXTENSIONS);
        assert_eq!(
            missing_bundled_extensions(Some("not json")),
            BUNDLED_MARKETPLACE_EXTENSIONS
        );
    }

    #[test]
    fn an_installed_bundled_id_is_not_reinstalled_whatever_its_case() {
        let installed = r#"[{"identifier":{"id":"PKief.material-icon-theme"}}]"#;
        assert!(missing_bundled_extensions(Some(installed)).is_empty());
    }

    #[test]
    fn a_registry_of_other_peoples_extensions_still_reports_ours_missing() {
        let installed = r#"[{"identifier":{"id":"eamodio.gitlens"}}]"#;
        assert_eq!(
            missing_bundled_extensions(Some(installed)),
            BUNDLED_MARKETPLACE_EXTENSIONS
        );
    }

    #[test]
    fn the_seeded_extensions_are_not_also_bundled_marketplace_ids() {
        for id in BUNDLED_MARKETPLACE_EXTENSIONS {
            assert!(!id.starts_with(PUBLISHER), "{id} is seeded, not installed");
        }
    }

    #[test]
    fn the_at_path_form_reads_the_registry_beside_the_folders() {
        let scratch = Scratch::new();
        let dir = scratch.path();
        assert_eq!(missing_bundled_extensions_at(dir), BUNDLED_MARKETPLACE_EXTENSIONS);
        let installed = r#"[{"identifier":{"id":"pkief.material-icon-theme"}}]"#;
        std::fs::write(dir.join("extensions.json"), installed).expect("registry");
        assert!(missing_bundled_extensions_at(dir).is_empty());
    }
}
