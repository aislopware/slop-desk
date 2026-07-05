# E7 carry-over directives (REQUIRED — fold into the E7 plan)

These are folded-in fixes from earlier epics plus binding scope reductions. Treat each
carry-over as an **additional acceptance criterion** for E7 and each scope reduction as a
**hard exclusion**. E7's primary job (Settings sections parity) is the natural place to land
them because E7 ships the settings rows that expose these policies — exposing a policy and
fixing its behavior must happen together.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **No horizontal tab bar.** Do not add a horizontal/top tab-bar layout option anywhere in
  settings or UI. If the settings spec exposes a "tab bar position" (top vs left) row, render ONLY the
  vertical/sidebar choice — omit the horizontal variant entirely (do not offer it as a
  disabled/coming-soon row either).
- **No SSH-host filter.** Do not add an SSH-host filter/pill in any settings surface. (Primary
  impact is E11 Open Quickly; noted here so no settings cross-reference reintroduces it.)

## E1 carry-overs (keybindings — 3 mediums)

1. **Registry enum-case comments show pre-reconciliation chords (doc drift).** In
   `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift`, update the
   stale per-case chord comments to the reconciled chords: focus = `⌃⌘`, divider = `⌃⌘⇧`,
   zoom = `⌘⇧↩`.
2. **ES-E1-4 "without reflowing PTY grid" claim is false.** A font-size change DOES SIGWINCH /
   reflow the grid (per spec). Either correct the comment + acceptance note to say so, OR
   implement a true no-reflow font change. Default: correct the note (no-reflow is not how the
   remote PTY works).
3. **`KeybindGrammar.isValidBaseKey` validate-then-vanish.** It accepts
   `space`/`escape`/`delete`/`backspace`/`forwarddelete` that no downstream mapper resolves —
   so a binding to them validates but silently does nothing. Either drop those base keys from
   the grammar, OR add the corresponding `KeyChord.Key` cases so they actually resolve. Also
   verify `⌘+` (`⌘⇧=`) folds to `⌘=` for `increase_font_size`.

## E3 carry-overs (close/cwd/new-tab policies — become user-visible once E7 ships their rows)

4. **Close-confirmation dialog hardcodes "A process is still running."**
   `CloseConfirmationPanel.body` in
   `Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift` hardcodes that subtitle, which is
   false for the `always` and `multiple_tabs` policies (idle shell / >1 tab — no process). Pass
   the resolved `CloseConfirmationPolicy` (or a precomputed reason string) into the panel and
   branch the subtitle: process → "A process is still running…"; always → "Are you sure you want
   to close this tab?"; multipleTabs → "This window has multiple tabs." (The macOS NSAlert path
   already uses softer copy — match intent.)
5. **`⌘⇧W` is bound to Close Tab, but the spec's `⌘⇧W` is Close Window.** Per the spec keybindings
   table (`user-interface__window-tab-split.md` lines 99/103/104): `⌘⇧W` = Close window, `⌘W` =
   close focused pane/tab/window cascade, `⌘⇧T` = reopen tab; the spec has NO dedicated Close-Tab
   chord. Reconcile in `WorkspaceBindingRegistry.swift`: rebind `⌘⇧W` to a new `.closeWindow`
   action routed to `store.requestCloseWindow()` (with the in-app confirmation surface). If a
   Close-Tab chord is still wanted, give it a chord not claimed by the spec or leave tab-close to
   the `⌘W` cascade. **Record the decision in `docs/DECISIONS.md`** as the E1 keymap fixes were.
6. **New-tab-position store wiring is untested (ES-E3-3).** Add a store/action-level test (mirror
   `CloseConfirmationStoreTests`): set `shell.newTabPosition = "after-current"`, seed a 3-tab
   session with the MIDDLE tab active, call `store.newTab(kind:)` and `store.openChooserPane(.newTab)`,
   assert the new tab landed at `activeIndex+1` and became selected; add an `= end` case proving
   append with a middle-active tab. (Prevents a silent regression to hardcoded `.end`.)
7. **The "New Window" working-directory policy is unwired (dead accessor).**
   `SettingsKey.workingDirectoryNewWindow` (default `home`) is read NOWHERE; its doc comment
   claims a fire-site that doesn't exist. Since E7 ships the working-directory settings rows,
   WIRE it: resolve+stamp the cwd in `WorkspaceStore.newSession(name:kind:)` the same way
   `newTab`/`splitActivePane` stamp `PaneSpec.lastKnownCwd` + `deferInheritedCwd` for terminal
   kind. (Do not just drop the key — New Window cwd is a real settings feature per the spec.)
8. **Pane close is gated by the Tab close-confirmation policy on EVERY pane close, incl. non-last
   (diverges from the spec).** In `WorkspaceStore.closeConfirmationNeeded(scope: .pane, …)`, apply the
   Tab/Window close-confirmation policy ONLY when the pane close would cascade a tab/window away
   (reuse the existing `tabRemovedByClosing(pane)` signal — and the session-last-tab → window
   scope). For a non-cascading mid-tab pane close, fall back to the `process` busy-shell guard
   alone. Keep the `.tab`/`.window` scopes as-is.

## NOT for E7 (routed elsewhere — do not action here)

- E3 medium "cwd-freshness source (OSC-7 equivalent / refresh-on-command-completion) is untested"
  is a **HW-only** verification leg → handled in **Phase 3** self-verify (`cd /tmp` in a pane,
  `⌘T`, confirm new pane is in `/tmp`), not E7.
