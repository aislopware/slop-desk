#!/usr/bin/env node
// Generates the FOUNDRY VS Code colour themes seeded into the code panel's workbench
// (`Sources/SlopDeskHost/Resources/foundry-*.json`, shipped by CodeServerManager's
// `slopdesk-foundry` extension seed).
//
// The palettes below MIRROR the FoundrySeed literals in
// `Sources/SlopDeskClientUI/DesignSystem/SlateDesign.swift` (the OKLCH engine's output —
// see DESIGN.md, the Seeded-Engine Rule, and `.impeccable/design.json` for the normative
// specs). Edit the seeds there first, then re-run:
//
//   node scripts/foundry-code-theme-gen.mjs
//
// The token grammar is the Monokai Pro assignment shape (the family the app's palettes
// descend from) recoloured with each seed's own chromatics, so the editor speaks the same
// eight-hue register as the rest of the app.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "Sources", "SlopDeskHost", "Resources");

const DARK_CHROMA = {
    red: "#FB939C", orange: "#F2A56F", amber: "#E5BD66", green: "#8DCD8E",
    cyan: "#66CCD1", blue: "#78BEEF", purple: "#BCAAF4", magenta: "#E399D3",
};

const SEEDS = [
    {
        file: "foundry-ember", label: "Foundry Ember", light: false,
        void_: "#171310", ground: "#201B17", face: "#27221E", raised: "#322C29", lift: "#3E3833",
        ink: "#E6DED6", ink2: "#ADA8A3", ink3: "#7C7874",
        accent: "#60CDCD", accentDeep: "#009898",
        chroma: DARK_CHROMA,
        ansi: [
            "#3A3431", "#FB939C", "#8DCD8E", "#E5BD66", "#56B9DD", "#BCAAF4", "#66CCD1", "#ADA8A3",
            "#7C7874", "#FFBBBF", "#ABE6AC", "#FCD78A", "#7CD1F3", "#D4C8FF", "#8CE4E9", "#E6DED6",
        ],
    },
    {
        file: "foundry-ember-light", label: "Foundry Ember Light", light: true,
        void_: "#DDD8D4", ground: "#EBE5E1", face: "#F6F0ED", raised: "#FFF9F5", lift: "#FFFEFE",
        ink: "#36312C", ink2: "#756F69", ink3: "#9A938D",
        accent: "#007272", accentDeep: "#004D4D",
        chroma: {
            red: "#B43249", orange: "#A35303", amber: "#8E6A00", green: "#357A3A",
            cyan: "#00787D", blue: "#006A9D", purple: "#6E4FB1", magenta: "#9A3A8A",
        },
        ansi: [
            "#36312C", "#B43249", "#357A3A", "#8E6A00", "#006E8C", "#6E4FB1", "#00787D", "#FFFEFE",
            "#9A938D", "#C93450", "#34893C", "#9C7500", "#007A9B", "#7B57C8", "#00858A", "#FFF9F5",
        ],
    },
    {
        file: "foundry-dusk", label: "Foundry Dusk", light: false,
        void_: "#151219", ground: "#1D1A21", face: "#242129", raised: "#2F2C35", lift: "#3A3741",
        ink: "#E5DCE9", ink2: "#ADA7AF", ink3: "#7B777D",
        accent: "#B3B1FC", accentDeep: "#7F77D9",
        chroma: DARK_CHROMA,
        ansi: [
            "#36343C", "#FB939C", "#8DCD8E", "#E5BD66", "#56B9DD", "#BCAAF4", "#66CCD1", "#ADA7AF",
            "#7B777D", "#FFBBBF", "#ABE6AC", "#FCD78A", "#7CD1F3", "#D4C8FF", "#8CE4E9", "#E5DCE9",
        ],
    },
    {
        file: "foundry-graphite", label: "Foundry Graphite", light: false,
        void_: "#131416", ground: "#1B1C1E", face: "#222325", raised: "#2D2E30", lift: "#38393C",
        ink: "#DFDFE3", ink2: "#A9A9AC", ink3: "#78787B",
        accent: "#61C9E7", accentDeep: "#0094B3",
        chroma: DARK_CHROMA,
        ansi: [
            "#343537", "#FB939C", "#8DCD8E", "#E5BD66", "#56B9DD", "#BCAAF4", "#66CCD1", "#A9A9AC",
            "#78787B", "#FFBBBF", "#ABE6AC", "#FCD78A", "#7CD1F3", "#D4C8FF", "#8CE4E9", "#DFDFE3",
        ],
    },
];

// hex + alpha suffix (00–FF from a 0–1 fraction).
const alpha = (hex, a) => hex + Math.round(a * 255).toString(16).padStart(2, "0").toUpperCase();

function workbenchColors(s) {
    // The structural seam tint: the app's `Slate` divider form — ink @ 10% on dark, black @ 8%
    // on light — so the workbench's seams match the split dividers around the webview.
    const divider = s.light ? alpha("#000000", 0.08) : alpha(s.ink, 0.10);
    const hover = s.light ? alpha("#000000", 0.045) : alpha(s.ink, 0.05);
    const c = s.chroma;
    const colors = {
        // Base
        focusBorder: alpha(s.accent, 0.4),
        foreground: s.ink2,
        descriptionForeground: s.ink3,
        disabledForeground: s.ink3,
        errorForeground: c.red,
        "textLink.foreground": s.accent,
        "textLink.activeForeground": s.accent,
        "selection.background": s.lift,
        "widget.shadow": alpha("#000000", s.light ? 0.16 : 0.4),
        "sash.hoverBorder": s.accent,

        // Editor
        "editor.background": s.face,
        "editor.foreground": s.ink,
        "editorLineNumber.foreground": s.ink3,
        "editorLineNumber.activeForeground": s.ink2,
        "editorCursor.foreground": s.accent,
        "editor.selectionBackground": s.lift,
        "editor.inactiveSelectionBackground": s.raised,
        "editor.lineHighlightBackground": alpha(s.ink, 0.04),
        "editor.lineHighlightBorder": "#00000000",
        "editor.findMatchBackground": alpha(c.amber, 0.3),
        "editor.findMatchHighlightBackground": alpha(c.amber, 0.15),
        "editorWhitespace.foreground": alpha(s.ink3, 0.4),
        "editorIndentGuide.background1": divider,
        "editorIndentGuide.activeBackground1": alpha(s.ink3, 0.8),
        "editorBracketMatch.background": "#00000000",
        "editorBracketMatch.border": s.accent,
        "editorError.foreground": c.red,
        "editorWarning.foreground": c.amber,
        "editorInfo.foreground": c.blue,
        "editorHint.foreground": s.ink3,
        "editorLink.activeForeground": s.accent,
        "editorWidget.background": s.raised,
        "editorWidget.border": divider,
        "editorHoverWidget.background": s.raised,
        "editorHoverWidget.border": divider,
        "editorSuggestWidget.background": s.raised,
        "editorSuggestWidget.border": divider,
        "editorSuggestWidget.selectedBackground": s.lift,
        "editorSuggestWidget.highlightForeground": s.accent,
        "editorGutter.modifiedBackground": c.amber,
        "editorGutter.addedBackground": c.green,
        "editorGutter.deletedBackground": c.red,
        "diffEditor.insertedTextBackground": alpha(c.green, 0.12),
        "diffEditor.removedTextBackground": alpha(c.red, 0.12),

        // Chrome bands (the app's surface ladder: sidebar/status on ground, editor face)
        "sideBar.background": s.ground,
        "sideBar.foreground": s.ink2,
        "sideBar.border": divider,
        "sideBarTitle.foreground": s.ink,
        "sideBarSectionHeader.background": s.ground,
        "sideBarSectionHeader.foreground": s.ink2,
        "sideBarSectionHeader.border": divider,
        "activityBar.background": s.ground,
        "activityBar.foreground": s.ink,
        "activityBar.inactiveForeground": s.ink3,
        "activityBar.border": divider,
        "activityBarBadge.background": s.accentDeep,
        "activityBarBadge.foreground": s.light ? s.lift : s.ink,
        "statusBar.background": s.ground,
        "statusBar.foreground": s.ink2,
        "statusBar.border": divider,
        "statusBar.noFolderBackground": s.ground,
        "statusBar.noFolderBorder": divider,
        "statusBar.debuggingBackground": s.ground,
        "statusBarItem.remoteBackground": s.accentDeep,
        "statusBarItem.remoteForeground": s.light ? s.lift : s.ink,
        "titleBar.activeBackground": s.face,
        "titleBar.activeForeground": s.ink2,
        "titleBar.inactiveBackground": s.face,
        "titleBar.inactiveForeground": s.ink3,
        "titleBar.border": divider,
        "panel.background": s.face,
        "panel.border": divider,
        "panelTitle.activeForeground": s.ink,
        "panelTitle.activeBorder": s.accent,
        "panelTitle.inactiveForeground": s.ink3,
        "editorGroup.border": divider,
        "editorGroupHeader.tabsBackground": s.ground,
        "editorGroupHeader.tabsBorder": divider,

        // Tabs: active = the lit face, inactive rests on ground — light does the work, no underline.
        "tab.activeBackground": s.face,
        "tab.activeForeground": s.ink,
        "tab.inactiveBackground": s.ground,
        "tab.inactiveForeground": s.ink3,
        "tab.border": divider,
        "tab.activeBorderTop": "#00000000",

        // Lists & inputs
        "list.activeSelectionBackground": s.raised,
        "list.activeSelectionForeground": s.ink,
        "list.inactiveSelectionBackground": s.raised,
        "list.hoverBackground": hover,
        "list.focusBackground": s.raised,
        "list.highlightForeground": s.accent,
        "tree.indentGuidesStroke": divider,
        "input.background": s.light ? s.raised : s.ground,
        "input.foreground": s.ink,
        "input.border": divider,
        "input.placeholderForeground": s.ink3,
        "inputValidation.errorBackground": s.raised,
        "inputValidation.errorBorder": c.red,
        "dropdown.background": s.raised,
        "dropdown.foreground": s.ink,
        "dropdown.border": divider,
        "checkbox.background": s.light ? s.raised : s.ground,
        "checkbox.border": divider,
        "button.background": s.accent,
        "button.foreground": s.light ? s.lift : s.void_,
        "button.secondaryBackground": s.raised,
        "button.secondaryForeground": s.ink,
        "badge.background": s.accentDeep,
        "badge.foreground": s.light ? s.lift : s.ink,
        "progressBar.background": s.accent,
        "scrollbarSlider.background": alpha(s.ink, 0.1),
        "scrollbarSlider.hoverBackground": alpha(s.ink, 0.18),
        "scrollbarSlider.activeBackground": alpha(s.ink, 0.26),
        "pickerGroup.foreground": s.accent,
        "quickInput.background": s.raised,
        "quickInputList.focusBackground": s.lift,
        "menu.background": s.raised,
        "menu.foreground": s.ink,
        "menu.selectionBackground": s.lift,
        "notifications.background": s.raised,
        "notifications.border": divider,
        "notificationCenterHeader.background": s.raised,
        "settings.headerForeground": s.ink,
        "settings.modifiedItemIndicator": c.amber,
        "peekView.border": s.accent,
        "peekViewEditor.background": s.ground,
        "peekViewResult.background": s.ground,
        "peekViewTitle.background": s.ground,

        // Git decorations
        "gitDecoration.modifiedResourceForeground": c.amber,
        "gitDecoration.untrackedResourceForeground": c.green,
        "gitDecoration.addedResourceForeground": c.green,
        "gitDecoration.deletedResourceForeground": c.red,
        "gitDecoration.ignoredResourceForeground": s.ink3,
        "gitDecoration.conflictingResourceForeground": c.magenta,

        // Integrated terminal — the seed's own ANSI ramp, one register with libghostty's panes.
        "terminal.background": s.face,
        "terminal.foreground": s.ink,
        "terminal.selectionBackground": s.lift,
        "terminalCursor.foreground": s.accent,
    };
    const names = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow", "BrightBlue",
        "BrightMagenta", "BrightCyan", "BrightWhite",
    ];
    names.forEach((n, i) => { colors[`terminal.ansi${n}`] = s.ansi[i]; });
    return colors;
}

function tokenColors(s) {
    const c = s.chroma;
    const rule = (name, scope, foreground, fontStyle) => ({
        name, scope, settings: { foreground, ...(fontStyle ? { fontStyle } : {}) },
    });
    return [
        rule("Comment", ["comment", "punctuation.definition.comment"], s.ink3, "italic"),
        rule("String", ["string", "punctuation.definition.string"], c.amber),
        rule("Regular expression", ["string.regexp"], c.magenta),
        rule("Number / constant", ["constant.numeric", "constant.language", "constant.character", "constant.other"], c.purple),
        rule("Keyword / storage", ["keyword", "storage.type", "storage.modifier", "keyword.operator.new", "keyword.operator.expression"], c.red),
        rule("Operator", ["keyword.operator"], c.red),
        rule("Function", ["entity.name.function", "support.function", "meta.function-call.generic"], c.green),
        rule("Type / class", ["entity.name.type", "entity.name.class", "entity.other.inherited-class", "support.type", "support.class"], c.cyan),
        rule("Parameter", ["variable.parameter"], c.orange, "italic"),
        rule("Variable", ["variable", "support.variable"], s.ink),
        rule("Object property", ["variable.other.property", "support.variable.property"], s.ink),
        rule("Tag", ["entity.name.tag"], c.red),
        rule("Tag attribute", ["entity.other.attribute-name"], c.cyan, "italic"),
        rule("Punctuation", ["punctuation", "meta.brace"], s.ink2),
        rule("Decorator / annotation", ["meta.decorator", "punctuation.decorator", "storage.type.annotation"], c.cyan),
        rule("Invalid", ["invalid"], c.red),
        rule("Markup heading", ["markup.heading", "entity.name.section"], c.amber, "bold"),
        rule("Markup bold", ["markup.bold"], s.ink, "bold"),
        rule("Markup italic", ["markup.italic"], s.ink, "italic"),
        rule("Markup link", ["markup.underline.link"], s.accent),
        rule("Markup quote", ["markup.quote"], s.ink3, "italic"),
        rule("Markup inline code", ["markup.inline.raw", "markup.fenced_code.block"], c.green),
        rule("Markup list bullet", ["punctuation.definition.list.begin.markdown", "markup.list.bullet"], c.red),
        rule("Diff inserted", ["markup.inserted"], c.green),
        rule("Diff deleted", ["markup.deleted"], c.red),
        rule("Diff changed", ["markup.changed"], c.amber),
    ];
}

for (const seed of SEEDS) {
    const theme = {
        $schema: "vscode://schemas/color-theme",
        name: seed.label,
        type: seed.light ? "light" : "dark",
        semanticHighlighting: true,
        colors: workbenchColors(seed),
        tokenColors: tokenColors(seed),
    };
    const path = join(OUT_DIR, `${seed.file}.json`);
    writeFileSync(path, `${JSON.stringify(theme, null, 4)}\n`);
    console.log(`wrote ${path}`);
}
