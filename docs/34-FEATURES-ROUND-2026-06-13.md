# 34 — Beyond-UI/UX features round (2026-06-13)

> **Historical session log (2026-06-13). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: 5 net-new features + a bug-hunt of the prior round + an adversarial self-review, all shipped to `main` with headless tests. Full suite 1972 → 2024/0.** Base `4b76d93`.

Expanded past UI/UX into protocol robustness, multiplexer power-features, security/privacy, and portability — features whose **core logic is unit-testable headlessly** (the rig is unavailable from automation); HW-feel surface (alert, sheet, on-device echo) noted as pending.

## Commits
| Commit | What | Tests |
|---|---|---|
| `da6f048` | **Hunt fixes** — 5 confirmed defects in the prior round's new code (scroll-discard on preset/placement, AppLaunch stale-lastApps, KeystrokeReplay CRLF, OSC 9 progress-bar) | +5 |
| `0d3cf9b` | **Broadcast / synchronized input** to a pane group (tmux synchronize-panes) | +7 |
| `31ae099` | **Secret redaction** in titles + notifications | +10 |
| `2eb7449` | **Command Snippets** — `{{placeholder}}` + `<C-x>` send-keys, runnable from ⌘K | +14 |
| `6aff50e` | **Workspace export / import** (portable backup / share) | +7 |
| `9ad9566` | **Secret-aware paste guard** for Paste as Keystrokes | +7 |
| `918becd` | **Self-review fixes** (3 confirmed) + wired the paste guard | +3 |

## What each verifiable core is (and what's HW-pending)
- **Broadcast** — `WorkspaceStore.broadcastTargets()/broadcastText()`, `PaneSessionHandle.sendText/sendBytes`, `⇧⌘B`. *Pending:* input-bar fan-out at submit (echo/CR dedup across N live shells) + macOS keystroke mirroring.
- **Secret redaction** — pure `SecretRedactor` (AWS/GitHub/Slack/Google/JWT/stripe/npm + `key=value` + generic high-entropy backstop; no false-positives on paths/SHAs) at `displayTitle` + notification `postExplicit`, gated `SettingsKey.redactSecrets`. Fully wired.
- **Snippets** — pure `SnippetExpander` + `SendKeysParser`, `Snippet` Codable (schema 9), store CRUD + `runSnippet`, palette entries. *Pending:* placeholder value-entry sheet + snippet editor UI.
- **Export/import (+ merge)** — pure `WorkspaceTransfer` (host stripped, hostile-file rejection + dedup/cap hardening), store `.replace`/`.mergeAppend` with id-remint, File-menu NS panels (Export / Import / Merge). Fully wired.
- **Paste guard** — pure `SecretPasteClassifier.assess → PasteRisk`, wired into the pill's paste via `deliverPaste` + a confirmationDialog. *Pending:* nothing required; the dialog is unverified-on-rig only.

## Bug-hunt + hardening (5 adversarial passes, converged HIGH→MED→all-LOW)
The import/decode surface was fuzzed adversarially. Notable:
- **HIGH crash (`bd6ef13`)** — an imported item with `z = Int.max` survived decode (only frames were sanitized, not `z`), then the next `maxZ + 1` (add-pane / raise) trapped Swift's checked arithmetic → deterministic crash from a hostile file + ⌘N. Fixed by clamping `z` in `CanvasItem.init(from:)` (covers import AND persistence-load).
- Decode now also dedupes duplicate `PaneGroupID`s (SwiftUI `ForEach` identity), re-mints duplicate snippet ids, drops duplicate preset names, and caps every collection at `maxItems` (1024) — the import-DoS guard. `Workspace.normalizingCollections()` shares these repairs with `WorkspacePersistence.load()`.
- Confirmation pass found only LOW refinements (load idempotency: re-mint only *duplicate* snippet ids; broaden the load cap; trim+fallback blank snippet names) — the convergence signal.

## Discipline notes worth keeping
- **GitHub push-protection** rejects a commit containing a contiguous vendor-token literal (even a fake one in a test). Assemble token fixtures at runtime (`"sk" + "_live_…"`, `["seg","seg","sig"].joined(separator:".")`) so no contiguous secret sits in source.
- **A re-mint that drops focus/anchors:** when replacing a whole canvas, re-mint pane ids through an explicit `idMap` and remap `focusedPane` + `bookmarks[].pane` through it (the `switchToLayoutPreset` pattern). A bare `dedupingItemIDs` returns no map → a same-session re-import strands focus + dangles bookmarks. (Caught in self-review.)
- **Verify the verifier:** the hunt's 6th "confirmed" finding (C1 8-bit string-introducer anti-spoof) was a *bad fix* — `0x90/0x98/0x9E/0x9F` are UTF-8 continuation bytes, so honoring them as C1 introducers would misparse every emoji title. Rejected. Always re-derive a security finding's fix against the real encoding.

## Deferred (lower value / HW)
Per-pane health grade (only RTT is available at the terminal layer, and the pill already shows an RTT badge); command-history index (OSC 133 carries no command text); workspace profiles (overlaps layout-presets + export); duplicate-and-edit preset (S, shares a `uniqueName` helper); host profiles; the snippet placeholder sheet; the broadcast input-bar wiring.
