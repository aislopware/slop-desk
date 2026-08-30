//! The current settings seed, the pristine-upgrade rule, and the client font sync.
//!
//! ## The one rule everything here serves
//! **An operator's own settings are never touched.** The workbench rewrites `settings.json` on any
//! settings edit, so a file byte-identical to a seed this repo once shipped was never edited by a
//! person and may be upgraded; anything else is theirs and stays untouchable. Every function below
//! is either that comparison or a write gated on it.

use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{Map, Value};

use crate::json;
use crate::seed_history::OBSOLETE_SEEDS;

/// The user settings seeded on a pristine host.
///
/// The workbench must come up in the app's own palette (`Alucard`, v26, user-directed 2026-08-09:
/// the light half of the Dracula family the terminal glass already wears, and the theme the
/// window's ground cream `#FFFBEB` was taken from in the first place, so the editor canvas and the
/// ground agree by ORIGIN instead of by an override forcing them to. It is one row of the seeded
/// extension below, which also carries all eight stock Monokai Pro variants for the ⌘K ⌘T picker.
/// NO `autoDetectColorScheme` trio any more — the app has ONE appearance, always light, so the dark
/// arm of that switch could never fire) and LEAN: menu bar hidden, the ACTIVITY-BAR icons
/// folded into the sidebar TOP (`activityBar.location: "top"`, user-directed v12 — fully
/// "hidden" left Search / Source Control / Extensions reachable by chord only). The "top"
/// location FORCE-SHOWS the web title bar (re-confirmed on 4.131, the v6-era observation): it
/// must host the relocated global actions (accounts + manage). No seedable key hides it
/// (`window.customTitleBarVisibility` stays desktop-only/UNREGISTERED — v7 dropped it,
/// pixel-verified equal), so the CLIENT clips the band off instead — the macOS webview mount
/// overhangs its container by the title-bar height (`CodeSidebarWebView.clippedTitleBarHeight`,
/// user-directed v13 era). Command-center/layout/navigation stay off regardless: any other
/// client (iOS later) sees the quiet band, not the stripped-out extras. v13 also slims the
/// editor GUTTER — the panel is a READING surface beside a terminal, where a five-char
/// line-number reserve plus breakpoint glyph margin plus folding arrows spent ~½ of a code
/// column's leading edge on emptiness (user-directed): `lineNumbersMinChars` 3,
/// `glyphMargin` off (no debugger here), `folding` off (the arrows column; ⌘⇧P still folds
/// by command for the rare need). Every key seeded must be REGISTERED in the shipped web
/// workbench's configuration schema (the settings editor flags unknown keys as warnings in a
/// file we authored — the chat.* pair died with v7 for the same reason; the schema is what
/// moved, not the intent, so `chat.disableAIFeatures` returns in v18 now that code-server
/// 4.113+ bundles the Copilot chat extension and registers it again —
/// `chat.commandCenter.enabled` is still absent and stays out).
/// View switching is keyboard-first (⌘⇧E / ⌘⇧F / ⌃⇧G, ⌘, — chords the client webview
/// deliberately passes through), matching the app's zero-chrome register. The sidebar sits on
/// the RIGHT (the panel hangs off the window's right edge, so the file tree hugs that edge
/// and the editor faces the terminal). The editor face IS the terminal's: `JetBrains Mono` —
/// the face libghostty embeds and renders when the preference's "SF Mono" does not resolve
/// (neither dev machine installs it; CoreText verified) — at the terminal's default 13pt,
/// with `editor.lineHeight: 1.32` = the face's own vertical metric
/// ((1020 ascent + 300 descent) / 1000 upm), the exact ratio ghostty rounds into its cell
/// height, so editor lines and terminal rows share a rhythm. The client injects the face as
/// @font-face data URIs (`CodeSidebarPageDressing` — the family names here and there must
/// agree), with "Symbols Nerd Font" behind it for private-use glyphs.
/// The status bar STAYS (v14, user-directed 2026-08-03 — v6..v13 hid it): it is the
/// workbench's own footing (branch, problems, cursor position) and its seam border rides
/// the retinted `statusBar.border`. NOTHING seeds `window.title` (v17 dropped the template v6
/// introduced): the web title bar is clipped off client-side and the panel's strip no longer
/// reads the document title, so the workbench's own default is as invisible as any shape we
/// could pin. Auto-save on focus change: the
/// terminal pane beside the editor is where builds/tests run, and switching to it IS the
/// moment the file must be on disk. Markdown opens straight into the RENDERED preview
/// (`workbench.editorAssociations` → the built-in `vscode.markdown.preview.editor`): in this
/// panel markdown is read (README, docs, agent output), not authored — a reader who wants the
/// source is one "Open Source" click away, the inverse default costs a chord per file. That
/// preview renders mermaid fences as diagrams on Code 1.121+, where the built-in
/// `mermaid-markdown-features` extension landed (code-server 4.121+ — docs/46 records the
/// install); nothing is seeded for it, since its default theme already follows the workbench
/// colours. Below that the fence stays a code block: the panel still works, it just reads the
/// diagram as source.
/// File icons are the Material Icon Theme (v15, user-directed 2026-08-03) — the
/// `bundledMarketplaceExtensions` install that precedes the first spawn, so the id resolves
/// on the very first boot.
/// The reading aids come on (v16, user-directed 2026-08-04): indentation guides pinned
/// explicitly (default-on today, but the named ask deserves a named key), the ACTIVE bracket
/// pair's guide (`editor.guides.bracketPairs: "active"` — the full rainbow is noise at this
/// panel width), sticky scroll (shipped default is OFF — verified in the 4.131 bundle), and
/// trailing-whitespace rendering. The file tree matches: indent guides always visible (stock
/// only shows them on hover) over a 16px indent — the default 8px barely steps a deep Swift
/// tree.
/// The workbench PAINTS ITSELF IN THE APP'S GROUND (ONE ISLAND, user-directed 2026-08-08): the
/// code panel is a SUNKEN column beside the navigator, not an island, so a
/// `workbench.colorCustomizations` block puts every workbench surface — editor, empty group,
/// gutter, sticky scroll, widgets, breadcrumb, sidebar, activity bar, tab strip, panel,
/// integrated terminal, status bar, title bar, quick input, menus — on the client's ground cream
/// `#FFFBEB` and zeroes their borders (`#00000000`), so panel and ground read as one continuous
/// field with no seam. The syntax theme is untouched: only chrome keys are overridden, so
/// Alucard still colours the code itself. Most of that block is now a NO-OP for the editor
/// proper — Alucard already paints it `#FFFBEB` — and it stays because the surfaces around the
/// canvas (Alucard's own `#F3EFDF` sidebar, activity bar and status bar) are what would
/// otherwise step the panel into a second tone.
/// On that flat field SELECTION IS AN OVERLAY, NOT AN INVERSION (v28, user-directed 2026-08-09,
/// reversing v25): the chosen tree row, editor tab, palette row, completion row and menu item
/// are a TINT of the island ink `#22212C` over the ground — `17` (9%) when focused, `0F` (6%)
/// when the list has lost focus, `0A` (4%) on hover. NOTHING sets a selection FOREGROUND.
/// The whole ladder came down one step from its first dose (12/8/5%, user-directed 2026-08-09):
/// the plate read heavy under the tab row. Kept as a LADDER rather than a single softened
/// value — over the ground cream the three rungs land ~7 rgb units apart, which is the least
/// that still says focused / unfocused / hover instead of collapsing into one grey.
/// ⚠️ Do not restore the inverted chip. v25 stamped selection out of the island's solid dark
/// glass with light ink, borrowing the client sidebar's `SlateCompactIsland` — which works
/// there and fails here, because the workbench tree is not a list of plain labels: every row
/// carries a saturated multi-colour `material-icon-theme` glyph, and those are authored for a
/// light bed. Dropping a dark plate under them left a column of badges that answered to no
/// palette in the window. A tint keeps every icon on the bed it was drawn for and still answers
/// "which one", which is all the fill was ever for. Selection OUTLINES stay zeroed: the fill is
/// the state, a ring around it restates it.
/// ⚠️ `#22212C` is `SlateTheme.app`'s glass face, the same duplication the ground cream already
/// carries across this module boundary — if the profile moves, both move together.
/// NOTHING CASTS A SHADOW (v25, user-directed 2026-08-09): every `*.shadow` key the Monokai
/// pair ships — widget, scrollbar, the three sticky-scroll casts, the list filter, the welcome
/// tile, inline chat, the diff editor's unchanged region — goes fully transparent. Those casts
/// exist to lift a widget off an editor of a DIFFERENT tone; here every surface is the one
/// cream, so each one drew a grey smear across a field that is meant to read as continuous.
/// ⚠️ Those colour keys DO NOT REACH THE PART SHADOWS, which is why the seam strips survived
/// v25 (reported and pixel-measured 2026-08-09). The workbench casts its structural shadows —
/// the editor part's inset left and right edges, the title bar, the activity bar, the side bar
/// — from `rgba(0, 0, 0, …)` LITERALS baked into the stylesheet, reachable by no theme token
/// at all; the sole switch is `workbench.shadows`, which toggles a `no-shadows` class whose
/// later-in-source rules zero every one of them. Measured on the running panel, the editor's
/// left edge carried a 20-device-pixel ramp bottoming at `rgb(244, 241, 228)` — the predicted
/// landing of 5% black over the ground cream. `false` is what removes it; the key is
/// hot-observed (`affectsConfiguration` → `updateShadows()`), so it takes effect without a
/// workbench reload.
/// TABS ARE ONE FIXED WIDTH (v28, user-directed 2026-08-09): `tabSizing: "fixed"` with the min
/// and max pinned to the SAME 140, which is what makes it truly fixed rather than merely
/// bounded — a strip whose every plate is the same size stays still while you switch files,
/// where the stock `"fit"` re-measures each plate against its filename and slides the whole row
/// on every open.
/// …AND THE OPEN TAB IS A NOTCH IN ONE HAIRLINE, NOT A SECOND TONE (v32, user-directed
/// 2026-08-09): the open tab is not marked by weight at all. Every surface stays the one
/// ground cream and the whole structure is drawn with a single light line — `editorGroup.border`
/// at `1F` (12%). The client's CSS runs that line along the bottom of the tab strip, lets a
/// closed tab redraw it across its own foot, and turns it up and over the OPEN tab's top
/// corners instead — so the line breaks exactly under the tab you are reading, and that tab
/// opens into the canvas below. The same line outlines the editor and the sidebar as islands.
/// It is the technique of the Islands Dark VS Code theme (surveyed 2026-08-09) with its second
/// tone removed, which is what a one-colour field leaves you: an island you can only draw by
/// its EDGE. Tab hover comes back to a plain 4% ink tint, the same dose a list row takes.
/// ⚠️ v31 gave the strip a real 9% bed so the cream tab could read as the canvas climbing into
/// it — correct in isolation, rejected in place (reported 2026-08-09): the bed does not stop at
/// the last tab. It runs on under the editor-action icons and dead-ends at the sidebar, so the
/// strip read as a grey rectangle pasted across the top of an otherwise cream panel. A tone
/// that has to span a whole part cannot be used to mark something that occupies part of it.
/// ⚠️ And v30 before that had the depth inverted outright — chips of rising ink left the OPEN
/// tab the darkest thing on screen while the canvas it belongs to stayed the lightest. The
/// correction that survives from that survey is the one all three references share (the vendor's
/// Islands spec, the Zed light default, Islands Dark): the open tab is marked by being
/// CONNECTED to the canvas, never by carrying more ink than it.
/// ⚠️ Do not chase the island look by INSETTING the parts. Giving `.part.editor > .content` a
/// margin and a `calc(100% - 8px)` size — how Islands Dark makes its gaps — blanked the editor
/// outright when rendered here: the workbench sizes that element in px and tells Monaco those
/// numbers, so shrinking it in CSS desynchronises the two. With one colour there is nothing to
/// gap ANYWAY; the edge is the whole island.
/// ⚠️⚠️ THE EDITOR MAY NOT DRAW ITSELF ON THE GPU HERE — `editor.experimentalGpuAcceleration`
/// STAYS UNSEEDED (v33 shipped it `"on"`, v34 takes it back out, reported 2026-08-11):
/// with the key on, EVERY file the panel opens fails — the workbench raises `Unable to open
/// '<name>'` and logs `Could not observe device pixel dimensions`. WebGPU was never the
/// problem. Monaco's GPU view context sizes its canvas through
/// `observer.observe(canvas, { box: ["device-pixel-content-box"] })` and rethrows any failure
/// as that error, and a `WKWebView` probe on this macOS answers: `ResizeObserver` present,
/// `box: "content-box"` fine, `"device-pixel-content-box"` → `TypeError`, and
/// `devicePixelContentBoxSize` ABSENT from `ResizeObserverEntry.prototype`. The throw travels
/// out of the editor's construction, so the failure is not a silent fallback to the DOM
/// renderer — it is no editor at all. The v33 probe measured `navigator.gpu`,
/// `requestAdapter()`, `requestDevice()` and a live `getContext("webgpu")` and all four passed;
/// none of them is the gate. The second half of that entry is unchanged and still true: this
/// key would have changed what is DRAWN, not how keys ARRIVE — the sibling input-path option
/// `editor.editContext` defaults on but is `included`-gated on the `EditContext` DOM API, which
/// the same probe finds UNDEFINED, so Monaco keeps the legacy hidden-textarea path in this
/// panel no matter what is seeded. Typing latency lives there and in the mesh round trip.
/// Shimming `ResizeObserver` in the page dressing to fake the missing box is NOT the move: it
/// would have to synthesise the very device-pixel numbers the canvas is sized by, to reach a
/// renderer upstream ships as experimental and tests in Chromium.
/// Every key here is USER-scope-overridable in the workbench
/// (user settings land in this same file and win on conflict-free keys the user later edits —
/// see the pristine-upgrade rule in `seed_user_settings`).
pub const SEEDED_USER_SETTINGS: &str = include_str!("../resources/settings.json");

/// Keys the WORKBENCH re-materialises on its own after a theme change, whether or not the seed
/// asked for them.
///
/// Observed 2026-08-09 on the live host: minutes after a seed that deliberately OMITS the
/// auto-detect trio, `workbench.preferredLightColorTheme` was back in the file as `"Dark 2026"` — a
/// theme this repo has never shipped. That is machine noise, not an operator's decision, and left
/// unhandled it strands the host: one uninvited key and the file reads as user-owned forever.
///
/// ⚠️ The blindness applies ONLY while the CURRENT seed stays silent about the key — a seed that
/// DOES set one compares it normally, so the "never touch operator settings" guarantee keeps its
/// teeth wherever it can still mean something.
pub const MACHINE_WRITTEN_THEME_KEYS: &[&str] = &[
    "window.autoDetectColorScheme",
    "workbench.preferredDarkColorTheme",
    "workbench.preferredLightColorTheme",
];

/// The three settings keys the CLIENT owns via the `syncCodeFont` metadata verb.
///
/// The seed lays terminal-parity DEFAULTS, then a connected client overwrites them with its live
/// terminal prefs (family / size / effective line-height ratio). One shared file ⇒ the last client
/// to sync wins — the workspace document's last-writer-wins, applied to chrome.
pub const SYNCED_FONT_KEYS: &[&str] = &["editor.fontFamily", "editor.fontSize", "editor.lineHeight"];

/// The keys the CURRENT seed writes — the guard on [`MACHINE_WRITTEN_THEME_KEYS`].
fn seeded_keys() -> BTreeSet<String> {
    serde_json::from_str::<Map<String, Value>>(SEEDED_USER_SETTINGS)
        .map(|object| object.keys().cloned().collect())
        .unwrap_or_default()
}

/// Whether `existing` is a former seed this program may upgrade.
///
/// Byte-identical to one is the fast path; otherwise the comparison goes FORMAT-BLIND, FONT-BLIND
/// and MACHINE-BLIND: canonical JSON with the client-synced font keys ([`SYNCED_FONT_KEYS`]) and
/// the workbench's own theme bookkeeping ([`MACHINE_WRITTEN_THEME_KEYS`]) dropped from both sides.
/// A file whose only divergence from a former seed is one of those is still OURS — nobody chose it;
/// any other divergence is the user's and stays untouchable. Unparseable (JSONC comments etc.) ⇒
/// the user's.
#[must_use]
pub fn is_pristine_former_seed(existing: &str) -> bool {
    if OBSOLETE_SEEDS.contains(&existing) {
        return true;
    }
    let Some(canonical) = canonical_for_pristine_check(existing) else {
        return false;
    };
    OBSOLETE_SEEDS
        .iter()
        .any(|seed| canonical_for_pristine_check(seed).is_some_and(|other| other == canonical))
}

/// Sorted-keys canonical JSON with the keys no divergence can be blamed on the user removed — the
/// comparator behind [`is_pristine_former_seed`]. `None` when the text is not a JSON object.
fn canonical_for_pristine_check(text: &str) -> Option<String> {
    let mut object: Map<String, Value> = serde_json::from_str(text).ok()?;
    let seeded = seeded_keys();
    for key in SYNCED_FONT_KEYS {
        object.remove(*key);
    }
    for key in MACHINE_WRITTEN_THEME_KEYS {
        if !seeded.contains(*key) {
            object.remove(*key);
        }
    }
    serde_json::to_string(&Value::Object(object)).ok()
}

/// Writes [`SEEDED_USER_SETTINGS`] to `path` when no file exists there — or when the existing file
/// is a former seed (pristine, never user-edited ⇒ safe to upgrade).
///
/// Returns whether it wrote. Any failure is a silent no-op: a seed is a nicety, and the workbench
/// works unthemed.
#[must_use]
pub fn seed_user_settings(path: &Path) -> bool {
    if path.exists() {
        let Ok(existing) = std::fs::read_to_string(path) else {
            return false;
        };
        if !is_pristine_former_seed(&existing) {
            return false;
        }
        return std::fs::write(path, SEEDED_USER_SETTINGS).is_ok();
    }
    if let Some(parent) = path.parent()
        && std::fs::create_dir_all(parent).is_err()
    {
        return false;
    }
    std::fs::write(path, SEEDED_USER_SETTINGS).is_ok()
}

/// The editor `fontFamily` stack for a synced terminal family.
///
/// The family FIRST (single-quoted; quote characters stripped defensively — they cannot survive
/// into a CSS family list), then the seeded fallback stack (the injected `JetBrains Mono` faces,
/// the system mono, the nerd symbols). A family already heading the stack is not repeated.
#[must_use]
pub fn editor_font_family_stack(family: &str) -> String {
    let fallback = editor_font_fallback_stack();
    let cleaned = family.replace(['\'', '"'], "");
    let cleaned = cleaned.trim();
    if cleaned.is_empty() || cleaned == MONO_FONT_FAMILY {
        return fallback;
    }
    format!("'{cleaned}', {fallback}")
}

/// The primary editor face: the one libghostty embeds and actually renders, so the panel and the
/// terminal beside it are the same shapes.
///
/// Named rather than typed out because it is read in three places that must agree — the stack this
/// module builds, the already-heading-the-stack check that stops it being listed twice, and the
/// client's injected `@font-face`. The check was the interesting one: it used to hold its own copy
/// of the word, so renaming the face in the stack alone would have made the stack list it twice
/// while every test that only asserts `starts_with` kept passing.
pub const MONO_FONT_FAMILY: &str = "JetBrains Mono";

/// The private-use fallback behind it, for the glyphs a programming face has no codepoint for.
pub const NERD_FONT_FAMILY: &str = "Symbols Nerd Font";

/// The stack a client that names no family of its own gets.
///
/// Byte-identical to the `editor.fontFamily` in `resources/settings.json`, and pinned to it by
/// test: the seed is what a fresh install writes and this is what a font sync rewrites, so a drift
/// between them would change the editor's face the first time the user touched the font setting and
/// never change it back.
#[must_use]
pub fn editor_font_fallback_stack() -> String {
    format!("'{MONO_FONT_FAMILY}', ui-monospace, '{NERD_FONT_FAMILY}', monospace")
}

/// Folds a client's font spec into the live settings file.
///
/// Parse → patch the three [`SYNCED_FONT_KEYS`] → write back canonical (sorted-keys pretty JSON,
/// which the workbench's settings watcher applies live).
///
/// Returns whether the file changed; an already-in-sync file is deliberately NOT rewritten (every
/// ensure round syncs — a no-change write would churn the workbench's file watcher). A missing or
/// unparseable file is a no-op: the sync is a nicety layered over the seed, never a file creator,
/// and a JSONC-commented file is the user's, not ours to rewrite.
#[must_use]
pub fn sync_editor_font(path: &Path, family: &str, size: f64, line_height: f64) -> bool {
    let Ok(existing) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(mut settings) = serde_json::from_str::<Map<String, Value>>(&existing) else {
        return false;
    };
    settings.insert(
        "editor.fontFamily".to_owned(),
        Value::String(editor_font_family_stack(family)),
    );
    settings.insert("editor.fontSize".to_owned(), json::readable_number(size));
    settings.insert("editor.lineHeight".to_owned(), json::readable_number(line_height));
    let value = Value::Object(settings);
    let Ok(updated) = serde_json::to_string_pretty(&value) else {
        return false;
    };
    // Format-blind "nothing to do": both sides canonicalized WITH the font keys included.
    if json::canonical(&existing).is_some_and(|before| Some(before) == json::canonical(&updated)) {
        return false;
    }
    std::fs::write(path, updated).is_ok()
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
    use crate::scratch::Scratch;

    fn seeded() -> Map<String, Value> {
        serde_json::from_str(SEEDED_USER_SETTINGS).expect("the seed is JSON")
    }

    // ── The seed itself ─────────────────────────────────────────────────────────────────────────

    #[test]
    fn the_seed_is_an_object_the_workbench_can_read() {
        let object = seeded();
        assert!(!object.is_empty());
        assert_eq!(object["workbench.colorTheme"], "Alucard");
    }

    #[test]
    fn the_seed_names_a_theme_the_seeded_extension_actually_contributes() {
        let theme = seeded()["workbench.colorTheme"].as_str().map(str::to_owned);
        assert!(
            crate::extensions::THEMES
                .iter()
                .any(|(label, ..)| Some(*label) == theme.as_deref()),
            "the seed selects {theme:?}, which no row of THEMES contributes",
        );
    }

    #[test]
    fn the_seed_is_silent_about_the_machine_written_theme_keys() {
        // The blindness in `canonical_for_pristine_check` is only sound while this holds.
        let object = seeded();
        for key in MACHINE_WRITTEN_THEME_KEYS {
            assert!(
                !object.contains_key(*key),
                "the seed sets {key}, which the blindness assumes it does not"
            );
        }
    }

    #[test]
    fn the_seed_lays_all_three_font_keys_for_a_client_to_overwrite() {
        let object = seeded();
        for key in SYNCED_FONT_KEYS {
            assert!(object.contains_key(*key), "the seed omits {key}");
        }
    }

    #[test]
    fn the_current_seed_is_not_also_listed_as_obsolete() {
        assert!(
            !OBSOLETE_SEEDS.contains(&SEEDED_USER_SETTINGS),
            "the live seed is in the retired corpus — every host would rewrite it forever",
        );
    }

    #[test]
    fn the_seed_is_lean_chrome_with_the_activity_bar_folded_into_the_sidebar_top() {
        let s = seeded();
        assert_eq!(s["workbench.startupEditor"], "none");
        assert_eq!(s["window.commandCenter"], false);
        assert_eq!(s["workbench.layoutControl.enabled"], false);
        assert_eq!(s["editor.minimap.enabled"], false);
        // v12: fully "hidden" left Search / Source Control / Extensions reachable by chord only.
        // "top" force-shows the web title bar; the CLIENT clips that band off
        // (`CodeSidebarWebView.clippedTitleBarHeight`).
        assert_eq!(s["workbench.activityBar.location"], "top");
        assert_eq!(s["window.menuBarVisibility"], "hidden");
        // v14: the status bar RETURNS — no visibility key at all, so the workbench keeps its stock
        // footing (branch, problems, cursor) under the retinted seam.
        assert!(!s.contains_key("workbench.statusBar.visible"));
        // The file tree hugs the window's right edge — the panel hangs off it.
        assert_eq!(s["workbench.sideBar.location"], "right");
        assert_eq!(s["files.autoSave"], "onFocusChange");
        // v18: this panel is seeded with the AI surfaces off.
        assert_eq!(s["chat.disableAIFeatures"], true);
        // v15: the id the bundled marketplace install provides, so it resolves on the first boot.
        assert_eq!(s["workbench.iconTheme"], "material-icon-theme");
        assert_eq!(s["workbench.editor.decorations.badges"], false);
        assert_eq!(
            s["workbench.editorAssociations"]["*.md"],
            "vscode.markdown.preview.editor"
        );
    }

    #[test]
    fn the_seeded_gutter_reads_code_rather_than_debugging_it() {
        // v13 (user-directed): three-char line numbers, no breakpoint glyph margin, no folding
        // arrows — a five-char reserve plus two icon columns spent ~half a code column's leading
        // edge on emptiness.
        let s = seeded();
        assert_eq!(s["editor.lineNumbersMinChars"], 3);
        assert_eq!(s["editor.glyphMargin"], false);
        assert_eq!(s["editor.folding"], false);
    }

    #[test]
    fn the_seeded_reading_aids_are_on() {
        // v16 (user-directed 2026-08-04): structure guides in the editor AND the file tree. Sticky
        // scroll and always-on tree guides are genuine non-defaults in the shipped bundle.
        let s = seeded();
        assert_eq!(s["editor.guides.indentation"], true);
        assert_eq!(s["editor.guides.bracketPairs"], "active");
        assert_eq!(s["editor.stickyScroll.enabled"], true);
        assert_eq!(s["editor.renderWhitespace"], "trailing");
        assert_eq!(s["workbench.tree.renderIndentGuides"], "always");
        assert_eq!(s["workbench.tree.indent"], 16);
    }

    #[test]
    fn every_seeded_key_is_one_the_shipped_workbench_registers() {
        // The settings editor flags unknown keys as warnings in a file we authored. These are
        // desktop-only or absent from the shipped workbench and must never come back. v17 also
        // dropped `window.title`: the web title bar is clipped off client-side and the panel's
        // strip stopped reading the document title, so no surface is left for a shape to reach.
        // v9 dropped the compact tab density: 22px minus the Slate plate recut left 14px plates,
        // too squat beside the app's own.
        let s = seeded();
        for key in [
            "window.customTitleBarVisibility",
            "chat.commandCenter.enabled",
            "window.title",
            "window.density.editorTabHeight",
        ] {
            assert!(!s.contains_key(key), "{key} is back in the seed");
        }
    }

    #[test]
    fn the_seeded_editor_face_is_the_terminals() {
        // JetBrains Mono is what libghostty actually renders (its embedded default; "SF Mono"
        // resolves on neither machine) at the terminal's 13pt, with the bundled nerd face behind
        // it. The family NAMES must match `CodeSidebarPageDressing`'s own.
        let s = seeded();
        let family = s["editor.fontFamily"].as_str().expect("a family stack");
        assert!(family.starts_with("'JetBrains Mono'"));
        assert!(family.contains("ui-monospace"));
        assert!(family.contains("'Symbols Nerd Font'"));
        assert_eq!(s["editor.fontSize"], 13);
        // Line-rhythm parity: (1020 + 300) / 1000 is the face's own vertical metric — the exact
        // ratio ghostty rounds into its cell height.
        assert_eq!(s["editor.lineHeight"], 1.32);
    }

    #[test]
    fn the_seed_never_asks_for_the_gpu_renderer_or_the_edit_context_input_path() {
        // Both keys are REGISTERED in the 4.131 bundle — the reason they stay unseeded is the DOM,
        // not the schema. The GPU view context sizes its canvas through
        // `observe(canvas, { box: ["device-pixel-content-box"] })`, and a WKWebView probe answers
        // `TypeError` to that box. The workbench rethrows it out of the editor's construction, so
        // `"on"` is not a fallback to the DOM renderer — it is `Unable to open '<file>'` for every
        // file. v33 shipped it on for one day; it lives on only in the retired corpus so those
        // hosts recover. Its sibling rides the `EditContext` DOM API, which WebKit does not ship.
        let s = seeded();
        assert!(!s.contains_key("editor.experimentalGpuAcceleration"));
        assert!(!s.contains_key("editor.editContext"));
    }

    #[test]
    fn the_seeded_tabs_are_one_fixed_width() {
        // Pinned as a trio: `fixed` alone only BOUNDS the plate, and a min below the max lets the
        // strip resize per filename again — the exact behaviour the setting was chosen to stop.
        let s = seeded();
        assert_eq!(s["workbench.editor.tabSizing"], "fixed");
        let min = s["workbench.editor.tabSizingFixedMinWidth"]
            .as_i64()
            .expect("a min");
        let max = s["workbench.editor.tabSizingFixedMaxWidth"]
            .as_i64()
            .expect("a max");
        assert_eq!(min, max, "a min below the max is bounded, not fixed");
        assert!(min >= 38, "below the workbench's own floor");
    }

    #[test]
    fn nothing_in_the_seeded_chrome_casts_a_shadow() {
        // On a field where every surface is the one cream, a cast is a smear rather than a lift.
        let s = seeded();
        let colours = s["workbench.colorCustomizations"]
            .as_object()
            .expect("colour block");
        let shadows: Vec<&String> = colours
            .keys()
            .filter(|key| key.to_lowercase().contains("shadow"))
            .collect();
        assert!(!shadows.is_empty());
        for key in shadows {
            assert_eq!(colours[key], "#00000000", "{key} still casts");
        }
        // The STRUCTURAL casts the block above cannot reach: the editor part's inset seams, the
        // title bar, the activity bar and the side bar cast from `rgba()` literals in the workbench
        // stylesheet, keyed to no colour token. This switch is the only thing that zeroes them.
        assert_eq!(s["workbench.shadows"], false, "the part shadows are back");
    }

    #[test]
    fn selection_is_a_tint_and_never_an_inversion() {
        let s = seeded();
        let colours = s["workbench.colorCustomizations"]
            .as_object()
            .expect("colour block");
        // Every chosen row is the island ink laid over the ground at 12%.
        for key in [
            "list.activeSelectionBackground",
            "list.focusBackground",
            "quickInputList.focusBackground",
            "editorSuggestWidget.selectedBackground",
            "menu.selectionBackground",
        ] {
            assert_eq!(colours[key], "#22212C17", "{key} is not the selection tint");
        }
        // The regression guard for the reversal: a solid plate needs light ink to stay legible, so
        // an inverted chip and a foreground override arrive together. Every row here carries a
        // saturated multi-colour file icon authored for a light bed, which cannot follow a dark
        // one.
        let inverting: Vec<&String> = colours
            .keys()
            .filter(|key| {
                (key.contains("election") || key.contains("focus") || key.contains("Focus"))
                    && (key.ends_with("Foreground") || key.ends_with("IconForeground"))
            })
            .collect();
        assert!(
            inverting.is_empty(),
            "selection is inverting again: {inverting:?}"
        );
    }

    #[test]
    fn one_light_line_draws_the_whole_tab_structure() {
        // A bed here was the v31 error: a tone that has to span a whole part cannot mark something
        // that occupies part of it, so it ran on past the last tab as a grey rectangle.
        let s = seeded();
        let colours = s["workbench.colorCustomizations"]
            .as_object()
            .expect("colour block");
        assert_eq!(
            colours["editorGroup.border"], "#22212C1F",
            "the one structural line went out"
        );
        assert_eq!(
            colours["editorGroupHeader.tabsBackground"], "#FFFBEB",
            "the strip grew a bed"
        );
        assert_eq!(
            colours["tab.activeBackground"], "#FFFBEB",
            "the open tab is not the ground"
        );
        assert_eq!(colours["tab.unfocusedActiveBackground"], "#FFFBEB");
        for key in ["tab.inactiveBackground", "tab.unfocusedInactiveBackground"] {
            assert_eq!(colours[key], "#00000000", "{key} put a chip back on a closed tab");
        }
        for key in ["tab.hoverBackground", "tab.unfocusedHoverBackground"] {
            assert_eq!(colours[key], "#22212C0A", "{key} is not the plain hover tint");
        }
    }

    // ── The pristine check ──────────────────────────────────────────────────────────────────────

    #[test]
    fn every_retired_seed_is_recognised_verbatim() {
        for (index, seed) in OBSOLETE_SEEDS.iter().enumerate() {
            assert!(
                is_pristine_former_seed(seed),
                "retired seed v{} was not recognised",
                index + 1
            );
        }
    }

    #[test]
    fn every_retired_seed_is_json() {
        for (index, seed) in OBSOLETE_SEEDS.iter().enumerate() {
            assert!(
                serde_json::from_str::<Map<String, Value>>(seed).is_ok(),
                "retired seed v{} is not a JSON object",
                index + 1,
            );
        }
    }

    #[test]
    fn a_reformatted_former_seed_is_still_pristine() {
        let reflowed =
            serde_json::to_string(&serde_json::from_str::<Value>(OBSOLETE_SEEDS[0]).expect("seed is JSON"))
                .expect("re-encodes");
        assert_ne!(
            reflowed, OBSOLETE_SEEDS[0],
            "the fixture must actually differ in bytes"
        );
        assert!(is_pristine_former_seed(&reflowed));
    }

    #[test]
    fn a_client_synced_font_does_not_make_a_former_seed_the_users() {
        let mut object: Map<String, Value> =
            serde_json::from_str(OBSOLETE_SEEDS[OBSOLETE_SEEDS.len() - 1]).expect("seed is JSON");
        object.insert(
            "editor.fontFamily".to_owned(),
            Value::String("'Fira Code'".to_owned()),
        );
        object.insert("editor.fontSize".to_owned(), json::readable_number(17.0));
        object.insert("editor.lineHeight".to_owned(), json::readable_number(1.41));
        let synced = serde_json::to_string(&Value::Object(object)).expect("re-encodes");
        assert!(
            is_pristine_former_seed(&synced),
            "a synced font is not a user edit"
        );
    }

    #[test]
    fn the_workbenchs_own_theme_bookkeeping_does_not_strand_the_host() {
        // Observed on the live host: the workbench re-materialised a theme this repo never shipped.
        let mut object: Map<String, Value> =
            serde_json::from_str(OBSOLETE_SEEDS[OBSOLETE_SEEDS.len() - 1]).expect("seed is JSON");
        object.insert(
            "workbench.preferredLightColorTheme".to_owned(),
            Value::String("Dark 2026".to_owned()),
        );
        let noisy = serde_json::to_string(&Value::Object(object)).expect("re-encodes");
        assert!(is_pristine_former_seed(&noisy));
    }

    #[test]
    fn one_real_user_edit_makes_the_file_untouchable() {
        let mut object: Map<String, Value> = serde_json::from_str(OBSOLETE_SEEDS[0]).expect("seed is JSON");
        object.insert("editor.wordWrap".to_owned(), Value::String("on".to_owned()));
        let edited = serde_json::to_string(&Value::Object(object)).expect("re-encodes");
        assert!(!is_pristine_former_seed(&edited));
    }

    #[test]
    fn a_jsonc_commented_file_is_the_users() {
        assert!(!is_pristine_former_seed(
            "// mine\n{\"workbench.colorTheme\": \"Alucard\"}"
        ));
    }

    #[test]
    fn an_empty_or_unrelated_file_is_not_a_former_seed() {
        assert!(!is_pristine_former_seed(""));
        assert!(!is_pristine_former_seed("{}"));
        assert!(!is_pristine_former_seed("[]"));
    }

    // ── The seeder ──────────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_pristine_host_gets_the_seed_and_the_directories_it_needs() {
        let scratch = Scratch::new();
        let path = scratch.path().join("User/settings.json");
        assert!(seed_user_settings(&path));
        assert_eq!(
            scratch.read("User/settings.json").as_deref(),
            Some(SEEDED_USER_SETTINGS)
        );
    }

    #[test]
    fn seeding_twice_writes_once() {
        let scratch = Scratch::new();
        let path = scratch.path().join("User/settings.json");
        assert!(seed_user_settings(&path));
        assert!(!seed_user_settings(&path), "the live seed is not a former seed");
    }

    #[test]
    fn a_former_seed_is_upgraded_in_place() {
        let scratch = Scratch::new();
        let path = scratch.write("settings.json", OBSOLETE_SEEDS[0]);
        assert!(seed_user_settings(&path));
        assert_eq!(
            scratch.read("settings.json").as_deref(),
            Some(SEEDED_USER_SETTINGS)
        );
    }

    #[test]
    fn a_users_file_survives_the_seeder_untouched() {
        let scratch = Scratch::new();
        let mine = "{\"editor.wordWrap\": \"on\"}";
        let path = scratch.write("settings.json", mine);
        assert!(!seed_user_settings(&path));
        assert_eq!(scratch.read("settings.json").as_deref(), Some(mine));
    }

    // ── The font stack ──────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_synced_family_leads_the_seeded_fallbacks() {
        assert_eq!(
            editor_font_family_stack("Fira Code"),
            "'Fira Code', 'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
        );
    }

    #[test]
    fn quotes_in_a_family_name_cannot_reach_the_css_list() {
        assert_eq!(
            editor_font_family_stack("\"Fira' Code\""),
            "'Fira Code', 'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
        );
    }

    /// The seed file and the stack this module builds are the same bytes.
    ///
    /// They are written by two different events — a fresh install seeds the file, a font sync
    /// rewrites the key — so a drift between them is invisible until the user touches the font
    /// setting once, at which point the editor's face changes and never changes back.
    #[test]
    fn the_seeded_stack_and_the_built_one_are_the_same_bytes() {
        assert_eq!(
            seeded().get("editor.fontFamily").and_then(Value::as_str),
            Some(editor_font_fallback_stack().as_str()),
        );
    }

    #[test]
    fn the_head_of_the_stack_is_never_repeated() {
        let stack = editor_font_family_stack("JetBrains Mono");
        assert_eq!(
            stack,
            "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace"
        );
        assert_eq!(stack.matches("JetBrains Mono").count(), 1);
    }

    #[test]
    fn an_empty_family_falls_back_rather_than_writing_an_empty_quote() {
        assert_eq!(
            editor_font_family_stack("   "),
            "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
        );
    }

    // ── The font sync ───────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_sync_patches_exactly_the_three_font_keys() {
        let scratch = Scratch::new();
        let path = scratch.write("settings.json", SEEDED_USER_SETTINGS);
        assert!(sync_editor_font(&path, "Fira Code", 17.0, 1.41));
        let after: Map<String, Value> =
            serde_json::from_str(&scratch.read("settings.json").expect("written")).expect("JSON");
        let before = seeded();
        assert_eq!(after["editor.fontSize"].to_string(), "17");
        assert_eq!(after["editor.lineHeight"].to_string(), "1.41");
        assert!(
            after["editor.fontFamily"]
                .as_str()
                .is_some_and(|stack| stack.starts_with("'Fira Code'"))
        );
        for (key, value) in &before {
            if SYNCED_FONT_KEYS.contains(&key.as_str()) {
                continue;
            }
            assert_eq!(after.get(key), Some(value), "{key} was disturbed by a font sync");
        }
        assert_eq!(after.len(), before.len(), "a font sync must not add or drop keys");
    }

    #[test]
    fn an_already_synced_file_is_not_rewritten() {
        let scratch = Scratch::new();
        let path = scratch.write("settings.json", SEEDED_USER_SETTINGS);
        assert!(sync_editor_font(&path, "Fira Code", 17.0, 1.41));
        assert!(
            !sync_editor_font(&path, "Fira Code", 17.0, 1.41),
            "no-change write churns the watcher"
        );
    }

    #[test]
    fn a_synced_file_stays_a_pristine_former_seed() {
        // The whole point of the font-blind comparison: a client sync must never strand the host.
        let scratch = Scratch::new();
        let path = scratch.write("settings.json", OBSOLETE_SEEDS[OBSOLETE_SEEDS.len() - 1]);
        assert!(sync_editor_font(&path, "Fira Code", 17.0, 1.41));
        assert!(is_pristine_former_seed(
            &scratch.read("settings.json").expect("written")
        ));
    }

    #[test]
    fn a_sync_never_creates_a_file() {
        let scratch = Scratch::new();
        let path = scratch.path().join("absent.json");
        assert!(!sync_editor_font(&path, "Fira Code", 17.0, 1.41));
        assert!(!path.exists());
    }

    #[test]
    fn a_commented_file_is_left_for_its_owner() {
        let scratch = Scratch::new();
        let jsonc = "// mine\n{\"editor.fontSize\": 12}";
        let path = scratch.write("settings.json", jsonc);
        assert!(!sync_editor_font(&path, "Fira Code", 17.0, 1.41));
        assert_eq!(scratch.read("settings.json").as_deref(), Some(jsonc));
    }
}
