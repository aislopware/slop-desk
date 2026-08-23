//! The finishing coat injected into the embedded workbench: one stylesheet and four scripts.
//!
//! ## What the host seed cannot do
//! `slopdesk-codeseed` writes code-server's settings before it boots; everything here happens on
//! the CLIENT, inside a page the app does not own, because the workbench either has no setting for
//! it or the setting cannot reach where it needs to.
//!
//! * **The terminal's own mono, as CSS faces.** The seeded `editor.fontFamily` leads with
//!   [`MONO_FONT_FAMILY`] — the face libghostty embeds and actually renders — but a `WebContent`
//!   process cannot see fonts the app registered with `CTFontManager` (registration is
//!   process-scoped), so the bundled variable TTFs ride in as `@font-face` rules over the pool's
//!   `slopdesk-font:` scheme, with [`NERD_FONT_FAMILY`] behind them for the private-use glyphs.
//! * **The Slate softening.** The workbench's corner-radius tokens already sit on Slate's ladder,
//!   but the surfaces the user lives on never adopted them: editor tabs are square full-bleed
//!   rectangles, list selections and scrollbar sliders hard rectangles. [`SLATE_SOFTENING_CSS`]
//!   re-cuts exactly those, touching GEOMETRY only — every colour stays the theme's.
//! * **The empty-editor letterpress.** code-server's stock watermark is ITS logo; the panel is the
//!   app's own surface, so [`SLOPCAT_LETTERPRESS_SVG`] replaces it through a `background-image`
//!   override, riding in as a `data:` URI.
//! * **The recommendation-tips graft.** code-server's web client hand-builds the
//!   `productConfiguration` embedded in the workbench HTML and forwards only the extensions gallery
//!   — never a recommendation-tips key — so the Extensions view's RECOMMENDED section is
//!   permanently empty. [`recommendation_tips_script`] rewrites the boot configuration meta tag,
//!   filling ONLY keys the server did not send, before the workbench script reads it.
//! * **The clipboard bridge.** `WebKit`'s async clipboard API silently drops the workbench's copy:
//!   `navigator.clipboard.writeText` needs a transient user activation VS Code's async copy path
//!   has often already spent, so Cmd-C in the editor never reached `NSPasteboard`.
//!   [`clipboard_bridge_script`] wraps `writeText` and `write` to ALSO post the plain text to the
//!   native handler, keeping the original call as best effort.
//! * **The webview canvas.** VS Code webview content documents are transparent at every layer by
//!   design and scroll at FRAME level, so `WebKit` fills the slivers a scroll exposes before paint
//!   catches up: transparent resolves to WHITE, and no main-frame measure reaches a subframe.
//!   [`webview_canvas_script`] keys the root canvas to the workbench's own theme var.
//! * **The focus-truth corrector.** The workbench autofocuses its restored editor during boot and
//!   carries on believing the window is focused, while the native side refuses that focus.
//!   [`focus_truth_script`] dispatches the blur the page never received.
//!
//! ## Everything here is a pure string builder
//! Nothing in this module touches `WebKit`, a bundle or a preference. The four scripts that take no
//! argument are built ONCE per process and handed out as `&'static str`, so the door that delivers
//! one copies bytes and allocates nothing.

use std::sync::LazyLock;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

/// The CSS family the nerd-font `@font-face` declares — the name the seeded `editor.fontFamily`
/// lists as the private-use fallback.
///
/// Spelled here rather than asked for, deliberately. This crate and `slopdesk-codeseed` cross no
/// door because codeseed is a HOST crate: it carries the whole seed history, and linking it into
/// the FFI artifact would drag those string tables into the iOS binary to fetch two font names. So
/// `code-panel-font-pair` in `slopdesk-invariants` compares the pair instead, which costs nothing
/// at runtime and fails just as loudly. If the injected face and the seeded stack ever disagree the
/// panel silently falls through to the system mono: no error, no crash, just the wrong shapes
/// beside a terminal drawing the right ones.
pub const NERD_FONT_FAMILY: &str = "Symbols Nerd Font";

/// The CSS family the `JetBrains Mono` `@font-face`s declare — the seeded `editor.fontFamily`'s
/// PRIMARY, and codeseed's `settings::MONO_FONT_FAMILY`. Gated, per [`NERD_FONT_FAMILY`].
pub const MONO_FONT_FAMILY: &str = "JetBrains Mono";

/// The DOM id of the injected style tag — the script's own re-injection guard keys on it.
pub const STYLE_ELEMENT_ID: &str = "slopdesk-dressing";

/// The `WKScriptMessageHandler` name the clipboard bridge posts copied text to.
pub const CLIPBOARD_HANDLER_NAME: &str = "slopdeskClipboard";

/// The DOM id of the webview-canvas style tag — the canvas script's re-injection guard.
pub const CANVAS_STYLE_ELEMENT_ID: &str = "slopdesk-webview-canvas";

/// The DOM id of the meta tag code-server embeds the workbench boot configuration in — the element
/// the recommendation-tips graft rewrites.
pub const WORKBENCH_CONFIGURATION_META_ID: &str = "vscode-workbench-web-configuration";

/// The page hook [`focus_truth_script`] publishes, so the NATIVE side can replay the blur at the
/// moments the page cannot see.
///
/// A resign, and a remount whose keyboard stays with the terminal: `WebKit` delivers no blur to a
/// view that lost first responder by being unparented. Spelled through a macro so
/// [`FOCUS_TRUTH_SYNC_CALL`] can `concat!` it and stay a constant — the call and the name cannot be
/// allowed to drift, and the only way to be sure of that is one literal.
macro_rules! focus_truth_sync_name {
    () => {
        "__slopdeskSyncFocusTruth"
    };
}

/// The window property [`focus_truth_script`] hangs its checker on.
pub const FOCUS_TRUTH_SYNC_NAME: &str = focus_truth_sync_name!();

/// [`FOCUS_TRUTH_SYNC_NAME`] as a call that is inert on a page which has not run the script yet.
pub const FOCUS_TRUTH_SYNC_CALL: &str = concat!(
    "window.",
    focus_truth_sync_name!(),
    " && window.",
    focus_truth_sync_name!(),
    "();"
);

/// The slopcat mark (`docs/brand/logo-slopcat.svg`) with the brand file's `currentColor` resolved
/// to the theme's tertiary ink and the stock letterpress's opacity baked onto the root.
///
/// A standalone SVG document in a data URI resolves `currentColor` to black, so the colour must be
/// literal here — it is the one ink this module spells, and the whole reason the sheet around it
/// can stay colour-free.
pub const SLOPCAT_LETTERPRESS_SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" opacity=".3">
  <defs>
    <mask id="slopcat-cut">
      <rect width="256" height="256" fill="#000"/>
      <path d="M 74 76 L 81 46 Q 98 54 112 70 Z" fill="#fff" stroke="#fff" stroke-width="10" stroke-linejoin="round"/>
      <path d="M 182 76 L 175 46 Q 158 54 144 70 Z" fill="#fff" stroke="#fff" stroke-width="10" stroke-linejoin="round"/>
      <rect x="56" y="68" width="144" height="120" rx="30" fill="#fff"/>
      <path d="M 90 111 L 114 128 L 90 145" fill="none" stroke="#000" stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
      <rect x="140" y="134" width="34" height="11" rx="5.5" fill="#000"/>
    </mask>
  </defs>
  <rect width="256" height="256" fill="#727072" mask="url(#slopcat-cut)"/>
</svg>"##;

/// The Slate softening rules — geometry only (radius, insets), colours untouched.
///
/// Values are the Slate ladder verbatim: the tab plate 10 (`islandRadiusCompact`), control 6
/// (`radiusControl`), card 8 (`radiusCard`), small 4 (`radiusSmall`); the 4px tab inset rides the
/// 4pt grid (`space1`).
///
/// The tab plate reads `islandRadiusCompact`, NOT `radiusTab` (user-directed 2026-08-09 — 6 read as
/// too tight for a plate this size). It is the same chip the app cuts for a selected sidebar row,
/// so it takes the same corner; list ROWS stay on 6, because 10 on a 22px row is close enough to a
/// capsule to lose the rectangle the tree reads by.
///
/// * TABS are cut like BROWSER TABS (user-directed 2026-08-09, replacing the free-floating plate):
///   inset 4px off the strip's top and left but flush with its BOTTOM, and rounded on the top two
///   corners only, so the open tab opens into the canvas underneath it. Nothing here says WHICH tab
///   is open by weight: the open tab is outlined on three sides and open on the fourth, a notch cut
///   into the canvas. It is the ONLY line this sheet draws, and it sets no colour — it reads
///   `var(--vscode-editorGroup-border)`, which the host seed fills. The per-tab 1px dividers are
///   dropped.
/// * Lists and trees (explorer rows, palette rows): the selection and hover fill rounds to 6.
/// * Scrollbar sliders round to 5 — half their 10px width, a capsule rather than a bar.
/// * Inputs step from the stock 4 up to the control rung 6; menus, hovers and find ride the card
///   rung 8. The widgets the workbench ALREADY tokenized sit on their own vars and are left alone.
pub const SLATE_SOFTENING_CSS: &str = r#"/* The plate height is made by RE-SCOPING the workbench's own `--editor-group-tab-height` on
   the tab, not by overriding stock rules one at a time: every stock rule keyed on the var —
   the tab's height, the label's line-height, and both tab-icon forms' heights
   (`.monaco-icon-label::before` for font glyphs, `.monaco-icon-label-iconpath` for SVG
   icons, each pinned to the FULL var by the stock sheet; a per-rule shrink here once left
   the SVG form centering on the 35px box, 4px below the label's line) — derives the shrunk
   value by itself. The strip and everything outside `.tab` still see the full var. The
   derived value must be CAPTURED on an ancestor first: `--x: calc(var(--x) - 4px)` on the
   tab itself is a cyclic custom-property reference, which invalidates the property. */
.monaco-workbench .part.editor > .content .editor-group-container > .title {
    --slate-tab-plate: calc(var(--editor-group-tab-height) - 4px);
}
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab {
    --editor-group-tab-height: var(--slate-tab-plate);
    margin: 4px 0 0 4px;
    border-radius: 10px 10px 0 0;
    border-right: none !important;
    border-left: none !important;
}
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab:last-child {
    margin-right: 4px;
}
/* The strip's baseline and the notch in it. The line runs along the FOOT of the tab row and of
   the action icons beside it, painted as a background-image so the tabs — which are opaque and
   flush with that foot — sit on top of it; a closed tab then redraws it across its own foot,
   and the open one turns it up and over its top corners instead. The break under the open tab
   is what says "this one opens into the canvas". Colour comes from the workbench's own
   `editorGroup.border` var (the host seed sets it): this sheet stays free of colour literals,
   which is what keeps it from drifting when the theme moves.
   ⚠️ The doubled seam reported here on 2026-08-09 was NOT this line. It was the client's own
   rule under the panel tab row, a few pixels above it (`CodePanelSurfaces`); that one is the
   one that went. */
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container,
.monaco-workbench .part.editor > .content .editor-group-container > .title .editor-actions {
    background-image: linear-gradient(to top, var(--vscode-editorGroup-border) 1px, transparent 1px);
    background-repeat: no-repeat;
    background-position: bottom;
}
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab {
    box-shadow: inset 0 -1px 0 0 var(--vscode-editorGroup-border);
}
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab.active {
    box-shadow:
        inset 1px 0 0 0 var(--vscode-editorGroup-border),
        inset -1px 0 0 0 var(--vscode-editorGroup-border),
        inset 0 1px 0 0 var(--vscode-editorGroup-border);
}
/* ⚠️⚠️ THE PANEL'S LEADING EDGE CARRIES NO VERTICAL LINE — settled, in any hand, after three
   rounds on 2026-08-09 (all three user-rejected):
     1. a FULL-HEIGHT rail on the parts, from this sheet — clutter beside the tab outline;
     2. a native chrome rule drawn by the client column (`Slate.Line.panelEdge`) — the wrong
        hand: a second mark in chrome ink beside the workbench's own baseline;
     3. the workbench's own line, `inset 1px 0 0 0 var(--vscode-editorGroup-border)` on the
        EDITOR CONTAINER — geometrically exactly what was asked for (measured live: the
        container's box starts at the title's foot, y=65 under a 35px strip at y=30, and ends
        at the status bar, so it ran from the open tab's foot down and never up beside the
        tabs) and still not wanted. The panel stands on the ground with nothing marking where
        it begins, which is the same way every other column stands on it.
   Do not propose a fourth. Two measurements are worth keeping if this is ever reopened: an
   inset `box-shadow` on a PART renders NOTHING (children carry their own opaque background and
   paint over the parent's shadow — every sampled pixel down the left edge and the
   editor/sidebar seam came back ground cream), whereas the same shadow on `.editor-container`
   DOES show through Monaco at every sampled row. So the container is the mount that works, and
   an overlay pseudo-element is only needed on the parts. */
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-top-container,
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-bottom-container {
    display: none !important;
}
/* The label's fade-out overlay goes entirely, and the label truncates with a real ellipsis
   instead. The overlay is `right: 0; top: 1px; bottom: 1px` with SQUARE corners, and the
   workbench fills it at runtime with `linear-gradient(to left, flatten(tab background),
   transparent)` — an OPAQUE approximation. Against a translucent plate that colour never
   matches, and having no radius of its own it kept standing straight where the plate's corner
   curved away, leaving a 1px square ear at the top-right and bottom-right. Stock `sizing-fit`
   never carried the class; pinning tabs to a fixed width is what turned it on. This is the
   same pair of rules the workbench's own modern-UI mode applies. */
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
    > .tab.sizing-fixed > .tab-label > .monaco-icon-label-container::after,
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
    > .tab.sizing-shrink > .tab-label > .monaco-icon-label-container::after {
    display: none !important;
}
.monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
    > .tab.sizing-fixed > .tab-label > .monaco-icon-label-container {
    flex: 1 !important;
    min-width: 0;
    text-overflow: ellipsis !important;
}
.monaco-workbench .monaco-list-row {
    border-radius: 6px;
}
.monaco-workbench .monaco-scrollable-element > .scrollbar > .slider {
    border-radius: 5px;
}
.monaco-workbench .monaco-inputbox {
    border-radius: 6px;
}
.monaco-workbench .monaco-select-box {
    border-radius: 6px !important;
}
.monaco-workbench .monaco-button {
    border-radius: 6px;
}
.monaco-editor .find-widget {
    border-radius: 8px;
}
.monaco-hover {
    border-radius: 8px;
}
.context-view .monaco-menu {
    border-radius: 8px;
}
.monaco-workbench > .notifications-toasts .notification-toast-container > .notification-toast {
    border-radius: 8px;
    overflow: hidden;
}"#;

/// The injected sheet.
///
/// Each font URL is a `slopdesk-font:` address the pool's scheme handler answers; `None` means the
/// bundle has no such resource, and the sheet then simply omits that face — the softening and the
/// letterpress are independent jobs and still ship.
#[must_use]
pub fn style_sheet(
    nerd_font_url: Option<&str>,
    mono_upright_url: Option<&str>,
    mono_italic_url: Option<&str>,
) -> String {
    let mut sheet = String::new();
    if let Some(source) = mono_upright_url {
        font_face(
            &mut sheet,
            MONO_FONT_FAMILY,
            source,
            Some("font-style: normal;\n    font-weight: 100 800;"),
        );
    }
    if let Some(source) = mono_italic_url {
        font_face(
            &mut sheet,
            MONO_FONT_FAMILY,
            source,
            Some("font-style: italic;\n    font-weight: 100 800;"),
        );
    }
    if let Some(source) = nerd_font_url {
        font_face(&mut sheet, NERD_FONT_FAMILY, source, None);
    }
    sheet.push_str(SLATE_SOFTENING_CSS);
    // Matches the stock rule's specificity class-for-class via `!important` — the override must win
    // for every theme class the workbench applies.
    sheet.push_str(
        "\n.monaco-workbench .editor-group-watermark .letterpress {\n    background-image: \
         url(\"data:image/svg+xml;base64,",
    );
    BASE64.encode_string(SLOPCAT_LETTERPRESS_SVG, &mut sheet);
    sheet.push_str("\") !important;\n}");
    sheet
}

/// One `@font-face` block, appended. `descriptors` carries the style and weight lines for the
/// variable faces, and is `None` for the single-face nerd font.
fn font_face(sheet: &mut String, family: &str, source: &str, descriptors: Option<&str>) {
    sheet.push_str("@font-face {\n    font-family: \"");
    sheet.push_str(family);
    sheet.push_str("\";\n    src: url(\"");
    sheet.push_str(source);
    sheet.push_str("\") format(\"truetype\");\n    ");
    if let Some(descriptors) = descriptors {
        sheet.push_str(descriptors);
        sheet.push_str("\n    ");
    }
    sheet.push_str("font-display: block;\n}\n\n");
}

/// The dressing user script: append `sheet` once per document.
///
/// Injected at document END, so `head` exists; the id guard makes a re-run — a soft SPA navigation,
/// say — a no-op.
#[must_use]
pub fn user_script(sheet: &str) -> String {
    format!(
        r#"(function () {{
    if (document.getElementById("{STYLE_ELEMENT_ID}")) {{ return; }}
    var style = document.createElement("style");
    style.id = "{STYLE_ELEMENT_ID}";
    style.textContent = {literal};
    (document.head || document.documentElement).appendChild(style);
}})();"#,
        literal = javascript_string_literal(sheet),
    )
}

/// [`user_script`] over [`style_sheet`] — the one string the pool actually installs.
///
/// Composed here rather than at the door's far side so the boundary carries ONE call and one
/// buffer: the sheet is several kilobytes of CSS plus a base64 SVG, and handing it out only to have
/// it handed straight back would copy all of it twice for nothing.
#[must_use]
pub fn dressing_script(
    nerd_font_url: Option<&str>,
    mono_upright_url: Option<&str>,
    mono_italic_url: Option<&str>,
) -> String {
    user_script(&style_sheet(nerd_font_url, mono_upright_url, mono_italic_url))
}

/// The recommendation-tips script, grafting `tips_json` into the workbench's boot configuration.
///
/// Document START, main frame only. Fills ONLY the keys the server did not send, so a future
/// code-server that ships its own tips wins.
///
/// TIMING: at document start the document is still empty, so the graft arms a `MutationObserver`
/// and rewrites the attribute the moment the meta node is parsed in. The observer's microtask runs
/// before the workbench's external boot script can execute — the parser must fetch it first — so
/// the workbench only ever reads the grafted configuration. A malformed attribute leaves the page
/// untouched: recommendations degrade to the stock empty section, never a broken workbench.
#[must_use]
pub fn recommendation_tips_script(tips_json: &str) -> String {
    format!(
        r#"(function () {{
    if (window.__slopdeskRecommendationTips) {{ return; }}
    window.__slopdeskRecommendationTips = true;
    var tips = JSON.parse({literal});
    function graft() {{
        var meta = document.getElementById("{WORKBENCH_CONFIGURATION_META_ID}");
        if (!meta) {{ return false; }}
        try {{
            var settings = JSON.parse(meta.getAttribute("data-settings"));
            var product = settings.productConfiguration || (settings.productConfiguration = {{}});
            var changed = false;
            for (var key in tips) {{
                if (!(key in product)) {{ product[key] = tips[key]; changed = true; }}
            }}
            if (changed) {{ meta.setAttribute("data-settings", JSON.stringify(settings)); }}
        }} catch (e) {{}}
        return true;
    }}
    if (graft()) {{ return; }}
    var observer = new MutationObserver(function () {{
        if (graft()) {{ observer.disconnect(); }}
    }});
    observer.observe(document.documentElement || document, {{ childList: true, subtree: true }});
}})();"#,
        literal = javascript_string_literal(tips_json),
    )
}

/// [`recommendation_tips_script`] over the bundled catalogue, built once per process.
#[must_use]
pub fn bundled_recommendation_tips_script() -> &'static str {
    static SCRIPT: LazyLock<String> = LazyLock::new(|| recommendation_tips_script(crate::tips::JSON));
    &SCRIPT
}

/// The focus-truth corrector, built once per process.
///
/// The workbench autofocuses its restored editor during boot and carries on believing the window is
/// focused — but the native side refuses that focus (the webview takes the keyboard only from a
/// click), and a page that was NEVER natively focused never receives a blur to learn otherwise: the
/// restored editor's caret blinks alongside the focused terminal's cursor. So re-check
/// `document.hasFocus()` — the engine's truth, which never went true — and dispatch the missing
/// blur: across the boot window on a timer, and then on every `focusin` for the rest of the page's
/// life. The boot timers alone were not enough; the workbench re-focuses its editor long after boot
/// (a remount, a layout change, a file opening), and each of those pulls put the caret back beside
/// the terminal's with the timers long expired (user-reported 2026-08-10). The listener runs the
/// check a beat late so a click that legitimately hands the panel the keyboard has settled its
/// native focus first, and it costs nothing when the page really is focused.
///
/// Synthetic EVENTS only — never `blur()` itself, which would clear `document.activeElement` and
/// break the real focus hand-off: `WebKit` re-fires `focus` on the preserved element when the view
/// actually takes the keyboard, and that is what puts the caret back.
#[must_use]
pub fn focus_truth_script() -> &'static str {
    static SCRIPT: LazyLock<String> = LazyLock::new(|| {
        format!(
            r#"(function () {{
    if (window.__slopdeskFocusTruth) {{ return; }}
    window.__slopdeskFocusTruth = true;
    function sync() {{
        if (document.hasFocus()) {{ return; }}
        var el = document.activeElement;
        if (el && el !== document.body) {{ el.dispatchEvent(new FocusEvent("blur")); }}
        window.dispatchEvent(new FocusEvent("blur"));
    }}
    window.{FOCUS_TRUTH_SYNC_NAME} = sync;
    document.addEventListener("focusin", function () {{ setTimeout(sync, 60); }}, true);
    [1500, 4000, 9000, 20000].forEach(function (ms) {{ setTimeout(sync, ms); }});
}})();"#
        )
    });
    &SCRIPT
}

/// The webview-canvas script, built once per process.
///
/// Document START — the first paint must already have the colour — and ALL frames: the markdown
/// preview lives two iframes deep. Gives every document an opaque root canvas in the workbench's
/// own editor colour, so a frame-level scroll exposes theme-coloured slivers instead of `WebKit`'s
/// white.
///
/// The rule is UNLAYERED on purpose: the webview host's `_defaultStyles` sets the body background
/// to transparent inside a cascade layer, and any unlayered rule outranks a layered one. The var
/// reference stays live — the host posts the theme AFTER document load and re-posts on every theme
/// flip, and the computed canvas follows; a frame without VS Code vars falls back to transparent,
/// changing nothing there.
#[must_use]
pub fn webview_canvas_script() -> &'static str {
    static SCRIPT: LazyLock<String> = LazyLock::new(|| {
        format!(
            r#"(function () {{
    if (document.getElementById("{CANVAS_STYLE_ELEMENT_ID}")) {{ return; }}
    var root = document.head || document.documentElement;
    if (!root) {{ return; }}
    var style = document.createElement("style");
    style.id = "{CANVAS_STYLE_ELEMENT_ID}";
    style.textContent = "html {{ background-color: var(--vscode-editor-background, transparent); }}";
    root.appendChild(style);
}})();"#
        )
    });
    &SCRIPT
}

/// The clipboard-bridge script, built once per process.
///
/// Document START, so the wrap is in place before the workbench captures the API. Wraps
/// `navigator.clipboard.writeText` and `write` to ALSO post the plain text to the native
/// [`CLIPBOARD_HANDLER_NAME`] handler; the original call still runs as best effort with its
/// rejection swallowed — the native write already succeeded, and a surfaced rejection would make VS
/// Code toast a copy error that is not true here.
#[must_use]
pub fn clipboard_bridge_script() -> &'static str {
    static SCRIPT: LazyLock<String> = LazyLock::new(|| {
        format!(
            r#"(function () {{
    if (window.__slopdeskClipboardBridged) {{ return; }}
    window.__slopdeskClipboardBridged = true;
    function post(text) {{
        try {{ window.webkit.messageHandlers.{CLIPBOARD_HANDLER_NAME}.postMessage(String(text)); }} catch (e) {{}}
    }}
    var clipboard = navigator.clipboard;
    if (!clipboard) {{ return; }}
    var writeText = clipboard.writeText && clipboard.writeText.bind(clipboard);
    clipboard.writeText = function (text) {{
        post(text);
        if (writeText) {{ return writeText(text).catch(function () {{}}); }}
        return Promise.resolve();
    }};
    var write = clipboard.write && clipboard.write.bind(clipboard);
    clipboard.write = function (items) {{
        try {{
            Array.prototype.forEach.call(items || [], function (item) {{
                if (item && item.types && item.types.indexOf("text/plain") >= 0) {{
                    item.getType("text/plain")
                        .then(function (blob) {{ return blob.text(); }})
                        .then(post)
                        .catch(function () {{}});
                }}
            }});
        }} catch (e) {{}}
        if (write) {{ return write(items).catch(function () {{}}); }}
        return Promise.resolve();
    }};
}})();"#
        )
    });
    &SCRIPT
}

/// `text` as a double-quoted JavaScript string literal.
///
/// Hand-rolled rather than run through a JSON encoder for the JS-specific hazard JSON does not
/// cover: U+2028 and U+2029 are legal inside a JSON string but TERMINATE a pre-ES2019 JS line, so a
/// catalogue carrying one would end the assignment mid-expression and take the whole script with
/// it.
#[must_use]
pub fn javascript_string_literal(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            control if (control as u32) < 0x20 => {
                out.push_str("\\u00");
                out.push(char::from_digit((control as u32) >> 4, 16).unwrap_or('0'));
                out.push(char::from_digit((control as u32) & 0xF, 16).unwrap_or('0'));
            },
            plain => out.push(plain),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::{
        CANVAS_STYLE_ELEMENT_ID, CLIPBOARD_HANDLER_NAME, FOCUS_TRUTH_SYNC_CALL, FOCUS_TRUTH_SYNC_NAME,
        MONO_FONT_FAMILY, NERD_FONT_FAMILY, SLATE_SOFTENING_CSS, SLOPCAT_LETTERPRESS_SVG, STYLE_ELEMENT_ID,
        bundled_recommendation_tips_script, clipboard_bridge_script, dressing_script, focus_truth_script,
        javascript_string_literal, recommendation_tips_script, style_sheet, user_script,
        webview_canvas_script,
    };

    #[test]
    fn the_sheet_carries_a_face_and_the_letterpress_override() {
        let sheet = style_sheet(Some("slopdesk-font:nerd"), None, None);
        assert!(sheet.contains("@font-face {"));
        assert!(sheet.contains(&format!("font-family: \"{NERD_FONT_FAMILY}\"")));
        assert!(sheet.contains("src: url(\"slopdesk-font:nerd\") format(\"truetype\")"));
        assert!(sheet.contains(".editor-group-watermark .letterpress"));
        assert!(sheet.contains("data:image/svg+xml;base64,"));
    }

    #[test]
    fn both_variable_mono_faces_declare_the_same_family_and_differ_by_style() {
        let sheet = style_sheet(
            None,
            Some("slopdesk-font:mono"),
            Some("slopdesk-font:mono-italic"),
        );
        assert_eq!(
            sheet
                .matches(&format!("font-family: \"{MONO_FONT_FAMILY}\""))
                .count(),
            2,
            "the upright and the italic are ONE family — two families is the fallback to system mono"
        );
        assert!(sheet.contains("font-style: normal;"));
        assert!(sheet.contains("font-style: italic;"));
        assert_eq!(
            sheet.matches("font-weight: 100 800;").count(),
            2,
            "both faces are variable"
        );
    }

    #[test]
    fn a_missing_face_still_softens_and_still_dresses_the_letterpress() {
        let sheet = style_sheet(None, None, None);
        assert!(
            !sheet.contains("@font-face"),
            "no URL, no face — never a src the handler would 404"
        );
        assert!(sheet.contains(SLATE_SOFTENING_CSS));
        assert!(sheet.contains(".editor-group-watermark .letterpress"));
    }

    #[test]
    fn the_softening_recuts_tabs_as_browser_tabs_and_touches_no_colour() {
        assert!(
            SLATE_SOFTENING_CSS.contains("border-radius: 10px 10px 0 0;"),
            "the plate opens downward into the canvas"
        );
        assert!(SLATE_SOFTENING_CSS.contains("--editor-group-tab-height: var(--slate-tab-plate);"));
        assert!(
            !SLATE_SOFTENING_CSS.contains('#'),
            "a hex literal here is a colour this sheet may not set — the theme owns every ink"
        );
        for banned in ["rgb(", "rgba(", "hsl("] {
            assert!(
                !SLATE_SOFTENING_CSS.contains(banned),
                "{banned} is a colour literal"
            );
        }
        assert!(
            SLATE_SOFTENING_CSS.contains("var(--vscode-editorGroup-border)"),
            "the one line it draws reads the workbench's own border var"
        );
    }

    #[test]
    fn the_letterpress_is_the_slopcat_with_literal_ink() {
        assert!(SLOPCAT_LETTERPRESS_SVG.starts_with("<svg"));
        assert!(
            SLOPCAT_LETTERPRESS_SVG.contains("opacity="),
            "the stock watermark's subtlety is baked onto the root"
        );
        assert!(
            !SLOPCAT_LETTERPRESS_SVG.contains("currentColor"),
            "a standalone SVG in a data URI resolves currentColor to BLACK — the ink must be literal"
        );
        assert!(
            SLOPCAT_LETTERPRESS_SVG.contains("#727072"),
            "the theme's tertiary ink, baked"
        );
    }

    #[test]
    fn the_font_families_are_the_two_the_seed_names() {
        assert_eq!(MONO_FONT_FAMILY, "JetBrains Mono");
        assert_eq!(NERD_FONT_FAMILY, "Symbols Nerd Font");
    }

    #[test]
    fn the_user_script_guards_on_the_style_element_id_and_embeds_the_sheet_as_a_literal() {
        let script = user_script("a { content: \"x\"; }\nb {}");
        assert!(script.contains(&format!("document.getElementById(\"{STYLE_ELEMENT_ID}\")")));
        assert!(script.contains(&format!("style.id = \"{STYLE_ELEMENT_ID}\"")));
        assert!(
            script.contains(r#"style.textContent = "a { content: \"x\"; }\nb {}";"#),
            "the sheet rides as ONE literal — a raw splice would end the assignment at its first quote"
        );
    }

    #[test]
    fn the_dressing_script_is_the_user_script_over_the_sheet() {
        let composed = dressing_script(Some("n"), Some("u"), Some("i"));
        assert_eq!(
            composed,
            user_script(&style_sheet(Some("n"), Some("u"), Some("i")))
        );
    }

    #[test]
    fn the_clipboard_bridge_wraps_both_write_entry_points_and_posts_to_the_handler() {
        let script = clipboard_bridge_script();
        assert!(script.contains("clipboard.writeText = function"));
        assert!(script.contains("clipboard.write = function"));
        assert!(script.contains(&format!("messageHandlers.{CLIPBOARD_HANDLER_NAME}.postMessage")));
        assert!(
            script.contains("catch(function () {})"),
            "the original call's rejection is swallowed — the native write already succeeded"
        );
    }

    #[test]
    fn the_canvas_script_paints_the_root_with_the_live_theme_var_and_nothing_else() {
        let script = webview_canvas_script();
        assert!(script.contains(&format!("document.getElementById(\"{CANVAS_STYLE_ELEMENT_ID}\")")));
        assert!(
            script.contains("html { background-color: var(--vscode-editor-background, transparent); }"),
            "the var must stay LIVE so a theme flip re-resolves it, and fall back to transparent"
        );
        assert!(
            !script.contains("body {"),
            "the BODY rule is the layered one this is not"
        );
    }

    #[test]
    fn the_focus_truth_script_replays_the_missed_blur_only_while_the_engine_says_unfocused() {
        let script = focus_truth_script();
        assert!(
            script.contains("if (document.hasFocus()) { return; }"),
            "the engine's truth is the gate"
        );
        assert!(script.contains("new FocusEvent(\"blur\")"));
        assert!(
            !script.contains(".blur()"),
            "blur() would clear activeElement and break the hand-off"
        );
    }

    #[test]
    fn the_focus_truth_check_outlives_the_boot_timers() {
        let script = focus_truth_script();
        assert!(
            script.contains("addEventListener(\"focusin\""),
            "the workbench re-focuses long after boot — timers alone left the caret doubled"
        );
        assert!(
            script.contains("[1500, 4000, 9000, 20000]"),
            "and the boot window is still covered"
        );
        assert!(script.contains(&format!("window.{FOCUS_TRUTH_SYNC_NAME} = sync")));
        assert!(FOCUS_TRUTH_SYNC_CALL.contains(&format!("window.{FOCUS_TRUTH_SYNC_NAME} &&")));
    }

    #[test]
    fn the_literal_escapes_every_javascript_hazard() {
        assert_eq!(javascript_string_literal("a\"b\\c\nd\re"), r#""a\"b\\c\nd\re""#);
        assert_eq!(
            javascript_string_literal("x\u{2028}y\u{2029}z\u{01}"),
            r#""x\u2028y\u2029z\u0001""#,
            "the two line terminators JSON would have let through, and a C0 control"
        );
        assert_eq!(javascript_string_literal(""), r#""""#);
    }

    #[test]
    fn the_tips_graft_fills_only_missing_keys_and_ships_the_bundled_catalogue() {
        let script = recommendation_tips_script("{\"k\": 1}");
        assert!(script.contains(r#"JSON.parse("{\"k\": 1}")"#));
        assert!(
            script.contains("if (!(key in product))"),
            "a server that ships its own tips wins"
        );
        assert!(
            script.contains("MutationObserver"),
            "at document start the meta tag is not parsed in yet"
        );
        assert!(bundled_recommendation_tips_script().contains("extensionRecommendations"));
    }
}
