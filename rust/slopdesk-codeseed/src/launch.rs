//! What the code-server child is launched WITH — argv and the environment it inherits.
//!
//! hostd still owns the spawn: the child is a supervised service process whose handle, log lines
//! and readiness probe are bookkeeping only hostd can hold. What it does not own any more is what
//! goes IN, because every one of these values is a fact about the profile this program seeds.

use crate::paths;

/// The child's argv (after the binary path).
///
/// No folder argument — a positional path is only a DEFAULT; every client names its folder in the
/// workbench URL's `?folder=` query, and one process serves them all. Port `0` = the OS picks; the
/// real port comes back through the child's own announcement line. `0.0.0.0` so mesh clients can
/// reach it — the same exposure as every hostd listener.
///
/// NO `--idle-timeout-seconds`: hostd prewarms this child at boot precisely so the workbench is
/// always warm, and a reaper would undo that every quiet stretch — the cold boot it forces onto the
/// next panel expand costs more than the idle Node runtime it frees.
#[must_use]
pub fn arguments() -> Vec<&'static str> {
    vec![
        "--auth",
        "none",
        "--bind-addr",
        "0.0.0.0:0",
        // The workbench titles itself "{{app}}" in a handful of strings (title bar, PWA name);
        // this is the embedded editor of SlopDesk, not a standalone code-server deployment.
        "--app-name",
        "SlopDesk",
        "--disable-telemetry",
        "--disable-update-check",
        "--disable-workspace-trust",
        "--disable-getting-started-override",
    ]
}

/// The OFFICIAL VS Code Marketplace, handed to every child through `EXTENSIONS_GALLERY`.
///
/// code-server's supported gallery override: its `server-main.js` parses the env var as JSON and
/// REPLACES the built-in Open VSX default wholesale, so the full URL set ships here, mirroring VS
/// Code stable's own `product.json`. Open VSX carries only the slice of the catalog whose
/// publishers opted in — most first-party `ms-*` tooling never did, and the embedded workbench
/// should install from the official catalog. No proxy is needed: the marketplace API answers
/// CORS-open, so the webview workbench reaches it directly.
///
/// NOTE Microsoft's marketplace terms scope the API to VS Code products — this is the operator's
/// own personal setup, the same trade every code-server or `VSCodium` user makes.
pub const MARKETPLACE_EXTENSIONS_GALLERY: &str = concat!(
    r#"{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","#,
    r#""itemUrl":"https://marketplace.visualstudio.com/items","#,
    r#""publisherUrl":"https://marketplace.visualstudio.com/publishers","#,
    r#""resourceUrlTemplate":"https://{publisher}.vscode-unpkg.net/{publisher}/{name}/{version}/{path}","#,
    r#""controlUrl":"https://main.vscode-cdn.net/extensions/marketplace.json","#,
    r#""nlsBaseUrl":"https://www.vscode-unpkg.net/_lp/"}"#,
);

/// The environment ADDITIONS every code-server child (server and one-shot CLI) launches with.
///
/// Returned as a delta rather than a whole environment: hostd passes its own curated environment
/// down, and a program that answered with a full copy of what it happened to inherit would be
/// deciding something it does not know about.
///
/// `EXTENSIONS_GALLERY` is withheld when the operator exported their OWN — the escape hatch IS the
/// env var, not a new flag. `SLOPDESK_CODE_BRIDGE_SOCKET` is what the remote extension host
/// inherits and the seeded bridge extension connects back to; a workbench started outside hostd
/// sees no such var and the extension stays dormant.
#[must_use]
pub fn environment_additions(environment: &paths::Environment) -> Vec<(String, String)> {
    let mut additions = Vec::new();
    // The operator's own gallery passes through untouched; only an unset or empty one is ours to
    // fill in.
    let operator_chose = environment
        .get("EXTENSIONS_GALLERY")
        .is_some_and(|value| !value.is_empty());
    if !operator_chose {
        additions.push((
            "EXTENSIONS_GALLERY".to_owned(),
            MARKETPLACE_EXTENSIONS_GALLERY.to_owned(),
        ));
    }
    additions.push((
        "SLOPDESK_CODE_BRIDGE_SOCKET".to_owned(),
        paths::bridge_socket_in(environment)
            .to_string_lossy()
            .into_owned(),
    ));
    additions
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `expect` IS the assertion.
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    fn environment(pairs: &[(&str, &str)]) -> paths::Environment {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn the_argv_pins_no_folder_no_idle_timeout_and_an_os_chosen_port() {
        let argv = arguments();
        assert!(argv.contains(&"0.0.0.0:0"), "the OS must pick the port");
        assert!(!argv.iter().any(|flag| flag.contains("idle-timeout")));
        assert!(
            !argv
                .iter()
                .any(|flag| !flag.starts_with('-') && flag.contains('/'))
        );
    }

    #[test]
    fn the_gallery_is_the_official_marketplace_and_parses() {
        let gallery: serde_json::Value =
            serde_json::from_str(MARKETPLACE_EXTENSIONS_GALLERY).expect("gallery is JSON");
        assert_eq!(
            gallery["serviceUrl"],
            "https://marketplace.visualstudio.com/_apis/public/gallery",
        );
        assert!(gallery["nlsBaseUrl"].is_string());
    }

    #[test]
    fn an_unset_gallery_is_filled_in_and_the_operators_own_is_left_alone() {
        let seeded = environment_additions(&environment(&[]));
        assert_eq!(
            seeded.first().map(|(key, _)| key.as_str()),
            Some("EXTENSIONS_GALLERY")
        );

        let theirs = environment_additions(&environment(&[("EXTENSIONS_GALLERY", "{}")]));
        assert!(theirs.iter().all(|(key, _)| key != "EXTENSIONS_GALLERY"));

        // Exported but EMPTY is not a choice, it is an accident — ours still goes in.
        let empty = environment_additions(&environment(&[("EXTENSIONS_GALLERY", "")]));
        assert!(empty.iter().any(|(key, _)| key == "EXTENSIONS_GALLERY"));
    }

    #[test]
    fn the_bridge_socket_always_reaches_the_child() {
        let additions = environment_additions(&environment(&[("TMPDIR", "/private/var/t")]));
        let socket = additions
            .iter()
            .find(|(key, _)| key == "SLOPDESK_CODE_BRIDGE_SOCKET")
            .map(|(_, value)| value.as_str());
        assert_eq!(socket, Some("/private/var/t/slopdesk-code-bridge.sock"));
    }
}
