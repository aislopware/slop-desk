#!/usr/bin/env node
// Generates the built-in VS Code colour themes seeded into the code panel's workbench
// (`Sources/SlopDeskHost/Resources/{dracula,alucard}.json`, shipped by CodeServerManager's
// `slopdesk-foundry` extension seed — the extension id is a stable anchor; the contents are
// the Dracula Pro pair since the round-8 verdict, user-directed 2026-08-07).
//
// The palettes below MIRROR the `SlateTheme.dracula` / `.alucard` literals in
// `Sources/SlopDeskClientUI/DesignSystem/SlateDesign.swift` (Dracula Pro's published glass +
// normalized accents, and Alucard from the public spec; see DESIGN.md). Edit there first,
// then re-run:
//
//   node scripts/foundry-code-theme-gen.mjs
//
// The token grammar keeps the Monokai Pro assignment shape recoloured with each seed's own
// chromatics, so the editor speaks the same register as the rest of the app. Surface-ladder
// steps the published palettes do not define (void/ground/raised, tertiary ink) are DERIVED
// in the Pro hue band; the anchor tones are verbatim.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "Sources", "SlopDeskHost", "Resources");

const SEEDS = [
    {
        // Anchors verbatim from Dracula Pro: face/ink/lift(selection)/ink2(comment) + the
        // normalized accent seven. Blue slot carries the purple (the Pro set has no blue).
        file: "dracula", label: "Dracula", light: false,
        void_: "#17161D", ground: "#1C1B26", face: "#22212C", raised: "#333142", lift: "#454158",
        ink: "#F8F8F2", ink2: "#7970A9", ink3: "#655E91",
        accent: "#9580FF", accentDeep: "#6B4BD6",
        chroma: {
            red: "#FF9580", orange: "#FFCA80", amber: "#FFFF80", green: "#8AFF80",
            cyan: "#80FFEA", blue: "#9580FF", purple: "#9580FF", magenta: "#FF80BF",
        },
        ansi: [
            "#454158", "#FF9580", "#8AFF80", "#FFFF80", "#9580FF", "#FF80BF", "#80FFEA", "#F8F8F2",
            "#7970A9", "#FF9580", "#8AFF80", "#FFFF80", "#9580FF", "#FF80BF", "#80FFEA", "#FFFFFF",
        ],
    },
    {
        // Anchors verbatim from Alucard (Dracula Pro's official light theme, public spec):
        // cream face, near-black ink, #CFCFDE selection, #6C664B comment, darkness-normalized
        // accents. Blue slot carries the purple, matching the dark seed.
        file: "alucard", label: "Alucard", light: true,
        void_: "#E8E4D5", ground: "#F3EFDF", face: "#FFFBEB", raised: "#F5F2E4", lift: "#CFCFDE",
        ink: "#1F1F1F", ink2: "#6C664B", ink3: "#938C6F",
        accent: "#644AC9", accentDeep: "#4B29A7",
        chroma: {
            red: "#CB3A2A", orange: "#A34D14", amber: "#846E15", green: "#14710A",
            cyan: "#036A96", blue: "#644AC9", purple: "#644AC9", magenta: "#A3144D",
        },
        ansi: [
            "#1F1F1F", "#CB3A2A", "#14710A", "#846E15", "#644AC9", "#A3144D", "#036A96", "#CFCFDE",
            "#6C664B", "#CB3A2A", "#14710A", "#846E15", "#644AC9", "#A3144D", "#036A96", "#FFFBEB",
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
        "activityBarBadge.foreground": s.light ? "#FFFFFF" : s.ink,
        "statusBar.background": s.ground,
        "statusBar.foreground": s.ink2,
        "statusBar.border": divider,
        "statusBar.noFolderBackground": s.ground,
        "statusBar.noFolderBorder": divider,
        "statusBar.debuggingBackground": s.ground,
        "statusBarItem.remoteBackground": s.accentDeep,
        "statusBarItem.remoteForeground": s.light ? "#FFFFFF" : s.ink,
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
        "button.foreground": s.light ? "#FFFFFF" : s.void_,
        "button.secondaryBackground": s.raised,
        "button.secondaryForeground": s.ink,
        "badge.background": s.accentDeep,
        "badge.foreground": s.light ? "#FFFFFF" : s.ink,
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
