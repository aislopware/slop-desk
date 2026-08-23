//! The extension-recommendation catalogue the boot-configuration graft carries.
//!
//! ## Why it is a resource rather than a table
//! Every value here is JSON the workbench parses and nothing in this process reads — a Rust
//! `struct` per key would be a schema written twice, once to build and once for VS Code to take
//! apart again. So the catalogue ships as the bytes it is, `include_str!`d into the binary, and the
//! only claim made about it is the one a broken catalogue would violate silently: it must PARSE,
//! and it must not raise a prompt.
//!
//! ## Why it is bundled at all
//! code-server's web client hand-builds the `productConfiguration` embedded in the workbench HTML
//! and forwards only the extensions gallery, never a recommendation-tips key, so the Extensions
//! view's RECOMMENDED section is permanently empty. See
//! [`crate::dressing::recommendation_tips_script`].

/// The catalogue, verbatim — four keys, and every entry advisory.
pub const JSON: &str = include_str!("../resources/recommendation-tips.json");

#[cfg(test)]
// The catalogue is a shipped constant, so `expect` here IS the assertion about it.
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::JSON;

    #[test]
    fn the_catalogue_parses_with_exactly_the_keys_the_workbench_consumes() {
        // The graft parses this IN THE PAGE and swallows the throw, so a malformed catalogue is
        // silent there: this is the only place it can be loud.
        let parsed: serde_json::Value = serde_json::from_str(JSON).expect("the catalogue must be valid JSON");
        let object = parsed
            .as_object()
            .expect("the graft merges keys — the root must be an object");
        let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "configBasedExtensionTips",
                "extensionRecommendations",
                "keymapExtensionTips",
                "languageExtensionTips",
            ],
            "a key the workbench does not read is dead weight in every boot; one it reads and we dropped is \
             a section that silently empties"
        );
        // Two of the four are keyed maps and two are arrays — the workbench reads each differently,
        // and what matters equally for all four is that none is EMPTY: the graft counts a key it
        // filled with nothing as filled, so an emptied one would leave the section blank in exactly
        // the way the graft exists to fix.
        for key in keys {
            let populated = object[key].as_object().is_some_and(|entries| !entries.is_empty())
                || object[key].as_array().is_some_and(|entries| !entries.is_empty());
            assert!(
                populated,
                "{key} is empty — a filled-with-nothing key still counts as filled"
            );
        }
    }

    #[test]
    fn no_entry_raises_an_install_prompt() {
        assert!(
            !JSON.contains("\"important\": true"),
            "an important tip makes the workbench TOAST an install prompt — the panel recommends, it does \
             not interrupt"
        );
    }
}
