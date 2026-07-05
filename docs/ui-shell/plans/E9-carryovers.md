# E9 carry-over directives (REQUIRED — fold into the E9 plan)

These are folded-in fixes from epic **E4** (Host metadata RPC service — cwd / processes / ports /
git / directory / agent-sessions, committed `bc49bbc`) plus binding scope reductions. Treat each
carry-over as an **additional acceptance criterion** for E9 and each scope reduction as a **hard
exclusion**. E9's primary job (fill the Details panel's Info / Outline / Git / Files tabs from the
E4 host service + add the Outline tab) is the natural place to land them because E9 is where the E4
metadata first becomes **user-visible**: E4's end-to-end workflow deferred four MEDIUM findings to
"the consuming epic," and they surface in exactly the Info/Git/Files tabs E9 ships — rendering the
data and fixing these must happen together.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Agents = Claude Code only initially.** Do NOT build codex / opencode *agent support* in any NEW
  agent-supervision / "working-with-agents" surface E9 might add. Claude Code is the only first-class
  agent E9 may surface as a "work with this agent" affordance (e.g. the Info-tab "View Session
  History" entry point). **Subtlety — keep, do not rip out:** the EXISTING host-metadata session-FILE
  enumeration is a shipped E4 feature and must stay intact — `AgentKind { claude, codex, opencode }`
  in `Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift` (~:186, a forward-tolerant wire enum),
  the `~/.codex/sessions` / opencode roots in `HostMetadataProbe.sessionRoots()`
  (`Sources/SlopDeskHost/HostMetadataProbe.swift` ~:291), and the `readAgentSession` read path
  (~:275) all read **what is on disk** and are NOT agent-driving. The reduction bites only on NEW
  agent-DRIVING / supervision UI and on surfacing codex/opencode as first-class agents — it is NOT a
  license to delete the working host enumeration. (See carry-over 3 for the precise resolution.)
- **No horizontal tab bar.** Do not add a horizontal/top tab-bar layout for the Details panel's four
  tabs (Info / Outline / Git / Files). Render the spec's own tab affordance only (segmented header / left
  rail per the spec) — never a horizontal/top tab-bar variant, not even as a disabled/coming-soon row.
- **No SSH-host filter.** Do not add an SSH-host filter/pill anywhere E9 touches (the Files tree, the
  session-history list, or any inspector surface). (Primary impact is E11 Open Quickly; noted here so
  no Details-panel cross-reference reintroduces it.)

## E4 carry-overs (host metadata — 4 mediums)

1. **Info tab omits the spec's "Working Directory" section and the Copy-Path action E4 committed to ship.**
   In `Sources/SlopDeskClientUI/Columns/InspectorColumn.swift`, `infoContent` (~:197) leads with the
   slopdesk-specific `sessionSection` (~:245); the host cwd appears only as a truncated, read-only
   `SlateKeyValueRow(label: "Dir")` with `.truncationMode(.head)` (~:279-280) buried in that Session
   block, and the ONLY Copy-Path affordance lives in `RemoteFileTreeView`'s per-row context menu. But
   `spec/user-interface__details-panel.md` + `info-panel.png` make the Info tab LEAD with a dedicated
   "WORKING DIRECTORY" section (uppercase label, full path ~13pt, "Copy Path" row beneath), and E4's
   own plan scoped Copy Path **IN** (not deferred). So a committed, non-deferred E4 deliverable is
   absent from its required surface. **Acceptance:** add a "Working Directory" `SlateSectionHeader` +
   prominent path `Text` to `infoContent` **above** `ProcessPortsView` (~:201), with a "Copy Path"
   action row (`doc.on.doc` icon + label) that writes `activeModel.cwd` to `NSPasteboard` /
   `UIPasteboard` — reuse the `copyPath` idiom already in
   `Sources/SlopDeskClientUI/Inspector/RemoteFileTreeView.swift` (~:151). Keep the Session
   status/host/ping block as the remote-specific addition, but restore the spec's Working-Directory
   prominence (this is the ES-E9-1 Info-tab surface).

2. **Host-side output parsers (lsof / git porcelain) are pure but UNTESTED — ES-E9-1 ports & ES-E9-3
   git data extraction is unproven.** In `Sources/SlopDeskHost/HostMetadataProbe.swift`, the
   functions that turn raw `lsof -F cn` into `PortInfo` (`parseLsof` ~:123) and `git status
   --porcelain -b` into `GitStatusPayload` (`parseBranchHeader` ~:186, `parseStatusLine` ~:208,
   `packStatus` ~:243) are the heart of the data E9 renders in the Info-ports and Git tabs — yet they
   have ZERO tests. They are pure `String → struct` functions with no syscall, so the hang-safety rule
   that keeps the probe's *subprocess* methods out of xctest does NOT apply; the client-side
   `GitStatusPresentation` test only proves the inverse of `packStatus`, not that the host parses
   porcelain/lsof correctly (the rename ` -> ` split, index-vs-worktree status chars, `[ahead N,
   behind M]` extraction, port-after-last-colon for `[::1]:443`). A parse bug renders wrong data in
   E9 with no failing test. **Acceptance:** make `parseLsof` / `parseBranchHeader` / `parseStatusLine`
   / `packStatus` `internal static` (or extract them to a pure `GitPorcelainParser` / `LsofParser`
   namespace) and add `SlopDeskHostTests` feeding canned strings — a rename `R  old -> new`,
   untracked `?? f`, staged+worktree `MM f`, detached `## HEAD (no branch)`,
   `## main...origin/main [ahead 2, behind 1]`, and lsof `n*:8080` / `n[::1]:443` / a malformed line —
   asserting the resulting structs and that garbage lines are skipped (revert-to-confirm-fail on each
   guard). No subprocess — preserves hang-safety.

3. **Codex agent sessions are never enumerated; `AgentKind.codex` + the codex `sessionRoots` entry are
   dead scaffolding — resolve by DEFERRING, not by building OR ripping out.** In
   `Sources/SlopDeskHost/HostMetadataProbe.swift`, `listAgentSessions(project:)` (~:268) calls only
   `claudeSessions` (~:302) + `opencodeSessions` (~:310) — codex is missing — yet `AgentKind.codex`
   exists and `sessionRoots()` (~:291) includes `~/.codex/sessions`, reachable via `readAgentSession`
   but never discoverable via enumeration. The E4 review flagged this as a silently-dropped plan
   deliverable. **Under the binding "agents = Claude Code only initially" reduction, the resolution is
   the deferral branch, executed precisely:** (a) do **NOT** add a `codexSessions(project:)`
   enumerator — that is NEW codex support and is out of scope while Claude is the only first-class
   agent; (b) do **NOT** delete `AgentKind.codex`, the `~/.codex/sessions` root, or the
   `readAgentSession` read path — that is the shipped E4 host file-enumeration / read capability that
   reads what is on disk and must stay (the read path already works for an absolute codex id even when
   not auto-discovered); (c) clear the "dead scaffolding implies working support" concern by
   **documenting the deferral**: an honest comment at `listAgentSessions` / `sessionRoots` stating
   codex auto-enumeration is intentionally deferred (Claude-first), plus a one-line note in
   `docs/DECISIONS.md`. **Acceptance for E9's UI:** the Info-tab "View Session History" surface lists
   Claude sessions as the first-class agent; E9 adds NO new codex/opencode agent-driving affordance and
   surfaces neither as a first-class "work with this agent" action. (Read-only transcript *viewing* of
   whatever the host already enumerates is the host-read path, not agent-driving — keep it.)

4. **Opaque payloads (`readAgentSession`, `gitDiff`) are read fully into host memory before the 15 MiB
   cap is applied.** `MetadataResponseBuilder.cappedOpaque()` truncates to `maxOpaquePayloadBytes`
   (15 MiB), but `Sources/SlopDeskHost/HostMetadataProbe.swift` materializes the ENTIRE source
   first: `readAgentSession` does `Data(contentsOf: URL(...))` on the whole session file (~:287), and
   `gitDiff` drains the subprocess pipe with `runProcessData`'s `readDataToEndOfFile()` (~:409). These
   are exactly E9's consumers — the Git tab's read-only inline diff overlay (`gitDiff`) and the
   agent-session transcript viewer (`readAgentSession`). Long agent JSONL transcripts are realistically
   tens-to-hundreds of MB and a large `git diff` can be too; each request loads the full file/diff into
   RAM only to throw most of it away, an unbounded per-request memory spike — the plan specified capping
   "BEFORE reading" and bounding "diff/session bytes ≤ the 16 MiB frame cap." **Acceptance:** bound the
   read at the source — for the session file use `FileHandle(forReadingFrom:).read(upToCount:
   maxOpaquePayloadBytes + 1)` (or a length-limited stream read) instead of `Data(contentsOf:)`; for
   the subprocess, drain the pipe with a running byte budget and stop/terminate once it exceeds the
   cap. Then `cappedOpaque()` only ever trims an already-bounded tail.

## NOT for E9 (routed elsewhere — do not action here)

- **Remote-FS "open" story (Reveal in Finder / Open in VS Code·Cursor·Xcode·Typora).** These target a
  REMOTE host path; no local Finder/app can open it. E4 deferred them (P2 — needs a remote-open/SSHFS
  story). E9 ships only **Copy Path** (carry-over 1) plus the in-scope local case "open on host where
  host is the Mac" (BACKLOG E9 scope, B7); the general remote-open belongs to a later remote-FS epic,
  not E9.
- **Git "Commit" / "Fork" buttons.** Mutating the host repo needs host-side command execution beyond
  read-only status+diff. E4/E9 Git tab is **read-only by design** (branch / ahead-behind / changed
  files / inline diff). Commit/Fork is a future host-exec / mutating-verb epic, not E9.
- **Agent "Resume" / "Send to Chat" / "Fork in…".** Spawn-with-`--resume` and composer routing are
  the agent epics (history / composer); E9 only renders + lists read-only transcripts. (This is also
  why E9 must not build codex/opencode agent-driving — see the scope reduction and carry-over 3.)
