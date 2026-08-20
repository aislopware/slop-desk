// TerminalFindBar — the in-pane ⌘F find overlay. A THIN SwiftUI renderer over two shared values: the
// driver ``TerminalFindBarModel`` (`SlopDeskClientCore`), which owns every match / nav / toggle mutation,
// and ``FindBarPresentation`` / ``FindBarMetrics``, which own every word and every measurement. This file
// is the DRAWING and nothing else — the model left for `SlopDeskClientCore` because its own header always
// said why ("the GUI and the headless unit test drive the exact same logic") while its address said
// otherwise, and the words and metrics followed it so an AppKit find bar reads them rather than agrees
// with them.
//
// The behaviour the model owns, in one line each, so this file can be read without opening it: the
// counter counts the `scrollbackTextLines()` snapshot taken on open while libghostty owns the live
// highlight (a documented divergence); regex / whole-word / case-sensitive modes are ROW-DRIVEN because
// libghostty's matcher is a literal, case-insensitive substring scan; literal mode arms `search:` and
// steps `navigate_search:`. The full argument is in the model's header.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Slate.*` tokens ONLY —
// raw font / radius literals fail `scripts/check-ds-leaks.sh`):
//   [ query field ][ Aa case pill ][ ab whole-word pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ]
//   [ ▣ search-all-tabs ][ × close ]
// (`rectangle.stack` "search all tabs" escalates to cross-tab Global Search ⇧⌘F — see
// ``TerminalFindBarModel/searchAllTabs()``.)
// (The `N of M` counter is required; `find.png` shows no inline counter, so its placement isn't
// screenshot-driven — we keep it before the nav chevrons.)
//
// Behaviour: auto-focus the field on appear; live query → recompute + re-arm highlight;
// ↩ / ⇧↩ next / prev; `Aa` / `.*` toggle case / regex; Esc (or ×) closes + clears highlights.
//
// Hang-safety: NO `GhosttySurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

/// The find bar strip (the view). Owns only its `@FocusState` (field auto-focus) — every match / nav / toggle
/// mutation routes through ``TerminalFindBarModel`` so the GUI and the headless test stay byte-for-byte.
struct TerminalFindBar: View {
    let model: TerminalFindBarModel

    /// Pre-focuses the query field on appear (typing lands immediately).
    @FocusState private var queryFocused: Bool

    // The sizing rung is ASKED FOR BY NAME, never three raw numbers typed here. What these are is a TOUCH
    // target rather than "the iOS size" — the distinction docs/56 §3 asks for — and ``FindBarMetrics`` is
    // where this rung and the pointer rung the AppKit half reads sit side by side, reviewable against each
    // other instead of one per renderer.
    //
    // ↩ / ⇧↩ (next/prev) need a hardware keyboard; the in-bar ∧ / ∨ chevrons are the touch nav path; the
    // app-level ⌘G / ⇧⌘G chords also need a hardware keyboard (a toolbar button for them is TODO).
    private let rung = FindBarMetrics.touch
    private var plate: CGFloat { CGFloat(rung.plate) }
    private var iconSize: CGFloat { CGFloat(rung.iconSize) }
    private var fieldWidth: CGFloat { CGFloat(rung.fieldWidth) }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            queryField
            // find.png's THREE individually-outlined mode chips: case (`Aa`), whole-word (underlined `ab`),
            // and regex (`.*`), in that order — ``FindModePill/inPaneFindBar``, so the order is a value
            // rather than three hand-written call sites. ``FindTogglePillTray`` lays them out identically to
            // global-search.
            FindTogglePillTray {
                ForEach(FindModePill.inPaneFindBar, id: \.self) { mode in
                    FindTogglePill(mode: mode, isOn: isOn(mode), plate: plate) { toggle(mode) }
                }
            }
            counter
            SlatePlateButton(
                symbol: .chevronUp, help: FindBarPresentation.previousMatchHelp, size: iconSize, plate: plate,
            ) {
                model.previous()
            }
            SlatePlateButton(
                symbol: .chevronDown, help: FindBarPresentation.nextMatchHelp, size: iconSize, plate: plate,
            ) {
                model.next()
            }
            // `rectangle.stack` button (find.png) — escalates the in-pane find to cross-tab Global Search (⇧⌘F),
            // seeded with the current query. Wired through ``TerminalFindBarModel/searchAllTabs()`` →
            // ``OverlayCoordinator/openGlobalSearch``.
            SlatePlateButton(
                symbol: .rectangleStack, help: FindBarPresentation.searchAllTabsHelp, size: iconSize, plate: plate,
            ) {
                model.searchAllTabs()
            }
            SlatePlateButton(symbol: .xmark, help: FindBarPresentation.closeHelp, size: iconSize, plate: plate) {
                model.close()
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        // find.png: the card is delineated by FILL + drop SHADOW only — NO hairline stroke around the CARD
        // (verified by pixel-scanning: the pane→shadow gradient runs straight into the card fill, no border
        // line). Only the `Aa`/`ab`/`.*` mode chips keep their OWN hairline outlines (FindTogglePill).
        .background(Slate.Surface.raised, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusControl))
        .slateShadow(.panel)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / cheat-sheet idiom).
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: model.focusToken) { _, _ in
            DispatchQueue.main.async { queryFocused = true }
        }
        // ↩ → next is the field's `.onSubmit`; ⇧↩ → previous reaches THIS container (a single-line field does
        // not submit on shift+return). Guard on `.shift` so the two never double-fire (the PaletteView idiom).
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            model.previous()
            return .handled
        }
        .slateCancelKey { model.close() }
    }

    // MARK: - Mode chips

    /// Whether `mode`'s chip is lit — the controller's own flag, never a mirror.
    private func isOn(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: model.controller.caseSensitive
        case .wholeWord: model.controller.wholeWord
        case .regex: model.controller.isRegex
        }
    }

    /// Flip `mode` through the model, which refreshes the mirror and re-arms the highlight.
    private func toggle(_ mode: FindModePill) {
        switch mode {
        case .caseSensitive: model.toggleCaseSensitive()
        case .wholeWord: model.toggleWholeWord()
        case .regex: model.toggleRegex()
        }
    }

    // MARK: - Query field

    private var queryField: some View {
        TextField(FindBarPresentation.placeholder, text: queryBinding)
            .textFieldStyle(.plain)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.primary)
            .tint(Slate.State.accent) // the active caret is the accent colour
            .focused($queryFocused)
            .frame(width: fieldWidth)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            // find.png: the query text sits in its OWN delineated inset — a distinct FILLED gray rounded field
            // INSIDE the card (not flush). The card is `Surface.raised` (≈ white in light themes), so a flush
            // `Surface.face` field reads as near-invisible; instead the field wears `State.selected`, a
            // translucent neutral wash. CROSS-THEME caveat: `State.selected` is a BLACK wash in light
            // (composites DARKER than the card → recessed inset, matching find.png) but WHITE in dark
            // (composites LIGHTER → reads RAISED, not recessed). No single solid/wash token is reliably
            // recessed-AND-visible on both themes (the only darker-than-card token in dark, `Surface.face`/the
            // backdrop, is near-invisible in light). So rather than chase a darker fill we DELINEATE the field
            // with its own inner `Line.subtle` hairline — a hard boundary that reads as a distinct inset
            // whichever way the fill contrasts. INNER field only; the card's no-border fill+shadow chrome
            // is NOT re-stroked (outer card stays borderless).
            .background(Slate.State.selected, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .onSubmit { model.next() } // plain ↩ → next match
    }

    /// Two-way binding into the controller's query (read the live value, write through `setQuery` so every
    /// keystroke recomputes the counter + re-arms the libghostty highlight).
    private var queryBinding: Binding<String> {
        Binding(get: { model.controller.query }, set: { model.setQuery($0) })
    }

    // MARK: - N of M counter

    @ViewBuilder private var counter: some View {
        if let label = FindBarPresentation.counterText(
            position: model.controller.positionLabel, query: model.controller.query,
        ) {
            Text(label)
                .font(.system(size: Slate.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Slate.Metric.space1)
                // Each keystroke / ⌘G ROLLS the digits to their new value instead of teleporting the whole
                // label — the eye tracks WHICH number moved (the position on nav, the total while typing).
                // Mechanical fade timing (no spring); the transition composes with `monospacedDigit`, so the
                // bar never jitters horizontally while rolling.
                .contentTransition(.numericText())
                .animation(Slate.Anim.smallFade, value: label)
        }
    }
}

/// LOCKED MODE-PILL RENDERING — screenshot-matched, final; do NOT re-litigate.
/// `find.png` AND `global-search.png` (verified by zooming both) show the `Aa` / underlined-`ab` / `.*` mode
/// pills as INDIVIDUALLY-OUTLINED rounded chips — each with its OWN resting plate + `Line.subtle` hairline,
/// gapped, sitting DIRECTLY on the bar. There is NO shared segmented backing tray. Bare glyphs, resting plates,
/// and a shared tray are all tempting alternatives that don't match the screenshots — individually-outlined
/// chips is the correct reading; re-flagging either alternative is not a new finding.
/// Non-negotiable invariants: (1) every idle chip is visually DELINEATED (own plate + hairline, never a bare
/// glyph); (2) the find bar and global-search query bar render the pills IDENTICALLY — both via
/// ``FindModePill`` + ``FindTogglePillAppearance`` + ``FindTogglePill``.
///
/// `FindTogglePillTray` is therefore just a TRANSPARENT layout container — an `HStack` with the screenshot's
/// inter-chip gap and NO background / border of its own (delineation lives on each ``FindTogglePill``). Reused
/// by BOTH the find bar and the global-search query bar (the EXACT same control). `Slate.*` tokens only.
struct FindTogglePillTray<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // No shared plate/border here — the chips delineate themselves; the tray only spaces them with a gap.
        HStack(spacing: Slate.Metric.space1) {
            content
        }
    }
}

/// A compact `Aa` / `ab` / `.*` toggle pill (the find-bar mode buttons), inside a ``FindTogglePillTray``.
/// LOCKED rendering (see the tray's doc comment): each chip is INDIVIDUALLY outlined.
/// Factored to file scope (internal) so the GlobalSearch surface reuses the EXACT pill. `Slate.*` tokens only.
///
/// WHAT the chip says is a ``FindModePill``, not three parameters, and HOW it looks is a
/// ``FindTogglePillAppearance``, not an inline table: the glyph, the help and the underline travel together,
/// and so do the plate, the ring and the ink. Both values are read by the Mac's AppKit results panel
/// (``SlopDeskMacUI/MacFindTogglePillView``) as well, which cannot see a SwiftUI call site at all — a pill
/// spelled at a call site could only stay identical across three surfaces by luck.
struct FindTogglePill: View {
    let mode: FindModePill
    let isOn: Bool
    var plate: CGFloat = Slate.Metric.plate
    let action: () -> Void

    @State private var hovering = false

    /// The shared verdict. This view's only remaining appearance decision is which TOKEN each case maps to.
    private var appearance: FindTogglePillAppearance {
        FindTogglePillAppearance.resolve(isOn: isOn, hovering: hovering)
    }

    /// This renderer's ink ladder — three lines, one per case (the `ToastPresentation` idiom).
    private var ink: Color {
        switch appearance {
        case .idle,
             .hovering: Slate.Text.secondary
        case .on: Slate.State.accent
        }
    }

    /// Each chip carries its OWN resting plate (find.png / global-search.png): idle = a subtle
    /// `Surface.face` plate, hover = a `State.hover` plate, on = the accent wash. No shared tray.
    private var plateFill: Color {
        switch appearance {
        case .idle: Slate.Surface.face
        case .hovering: Slate.State.hover
        case .on: Slate.State.accentMuted
        }
    }

    /// Every chip is individually outlined: idle/hover wear a `Line.subtle` hairline so the chip is
    /// delineated (never a bare glyph); the ON chip swaps in the accent ring.
    private var ring: Color {
        switch appearance {
        case .idle,
             .hovering: Slate.Line.subtle
        // ``Slate/Opacity/accentRing`` (stage F batch P6). It matters MORE here than at the vi pill:
        // this chip's other renderer is `MacFindTogglePillView`'s neighbour in `MacGlobalSearch`,
        // which spelled the same `0.5` across the framework boundary where nothing could compare
        // them — and this file's own header pins the two bars as rendering the pills identically.
        case .on: Slate.State.accent.opacity(Slate.Opacity.accentRing)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(mode.label)
                .underline(mode.underlined)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold, design: .monospaced))
                .foregroundStyle(ink)
                .frame(minWidth: plate, minHeight: plate)
                .padding(.horizontal, Slate.Metric.space1)
                .background(plateFill, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .strokeBorder(ring, lineWidth: Slate.Metric.hairline),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp(mode.help)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }
}
#endif
