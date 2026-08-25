// CodeBridgeTerminalRouter — the door over `rust/slopdesk-muxsession::bridge_router`.
//
// The embedded workbench ships its own integrated terminal. That shell is outside everything this
// app provides — no agent detection, no PTY fan-out to the other clients, no replay, no scrollback
// journal — so the editor's "run this" affordances are pointed at a real SlopDesk pane instead
// (`Resources/bridge/extension.js` contributes the menu items; `CodeBridgeServer` carries them).
//
// Pointing them somewhere means CHOOSING, and the editor cannot choose: focus is a client-side
// fact, and a project may have several panes across several clients. The rules that pick — cwd
// confinement, no agent, a SHELL in the foreground, then the closest-to-the-acting-file ranking —
// and the two sentences a refusal shows are the crate's, and are pinned there. What is left here is
// the flattening: a live session list this process alone can see, laid out as records into one blob
// the way `docs/55` §4 asks for an array.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// One candidate pane, flattened from the host's live session for the router's benefit.
struct CodeBridgePane: Sendable, Equatable {
    let paneId: String
    /// What the editor tells the user the command landed in. Carried past the door untouched — a
    /// title has no bearing on the choice, so the crate never sees it.
    let title: String
    /// The host-observed cwd (OSC-7 / prompt-edge probe), `nil` until observed. A pane whose cwd is
    /// unknown is never chosen: containment is what keeps a command inside its own project.
    let cwd: String?
    /// Whether an agent was detected in this pane (`AgentControlState.presence`).
    let hasAgent: Bool
    /// The foreground process basename (`PTYForegroundProbe`), `""` when it could not be read.
    let foreground: String
}

enum CodeBridgeTerminalRouter {
    /// Why no pane could take the command. Each maps to one sentence the editor shows the user —
    /// the point being that a refusal explains itself, since the alternative (silence) reads as
    /// a broken feature.
    enum Refusal: Error, Equatable {
        /// No pane of this project is open anywhere.
        case noPaneInProject
        /// Panes exist, but every one is running something or hosting an agent.
        case noIdlePane

        /// The door's code for this refusal. `malformed` has no case here on purpose: it means a
        /// record left its blob, which this file builds, so it can only ever be a bug on THIS side
        /// — and the honest thing to show the user is still "nothing could take it".
        var code: Int32 {
            switch self {
            case .noPaneInProject: SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT
            case .noIdlePane: SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE
            }
        }
    }

    /// The pane that should receive a command issued from the workbench rooted at `root`, or why
    /// none can. `directory` is where the command is ABOUT (the acting file's folder) — used only
    /// to rank, never to filter, so a project with one shell always works no matter which file is
    /// open.
    static func choose(
        among panes: [CodeBridgePane], root: String, near directory: String?,
    ) -> Result<CodeBridgePane, Refusal> {
        var blob = [UInt8]()
        let records = panes.map { pane -> SlopDeskBridgePaneRecord in
            let paneId = span(of: pane.paneId, into: &blob)
            let cwd = span(of: pane.cwd ?? "", into: &blob)
            let foreground = span(of: pane.foreground, into: &blob)
            return SlopDeskBridgePaneRecord(
                pane_id_offset: paneId.offset,
                pane_id_len: paneId.length,
                cwd_offset: cwd.offset,
                cwd_len: cwd.length,
                has_cwd: pane.cwd != nil,
                foreground_offset: foreground.offset,
                foreground_len: foreground.length,
                has_agent: pane.hasAgent,
            )
        }
        let index = records.withUnsafeBufferPointer { table in
            blob.withUnsafeBufferPointer { text in
                ffiLend(root) { rootPointer in
                    ffiLend(directory ?? "") { directoryPointer in
                        slopdesk_code_bridge_choose(
                            table.baseAddress, table.count,
                            text.baseAddress, text.count,
                            rootPointer.baseAddress, rootPointer.count,
                            directoryPointer.baseAddress, directoryPointer.count,
                            directory != nil,
                        )
                    }
                }
            }
        }
        guard index >= 0, Int(index) < panes.count else {
            return .failure(index == SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE ? .noIdlePane : .noPaneInProject)
        }
        return .success(panes[Int(index)])
    }

    /// The bytes a command line becomes on the PTY: the text, then a carriage RETURN — the byte a
    /// real Return key sends (the tty's `ICRNL` turns it into the newline the shell reads). Same
    /// convention as the agent-control `run` verb, deliberately: two ways to type into a pane
    /// should not disagree about what Enter is.
    static func keystrokes(for text: String) -> Data {
        ffiLend(text) { input in
            Data(ffiAnswerBytes(capacity: input.count + 1) { out, cap in
                slopdesk_code_bridge_keystrokes(input.baseAddress, input.count, out, cap)
            })
        }
    }

    /// `cd <dir>` for the pane. The quoting matters more than it looks: a project path with a
    /// space or a quote in it would otherwise become several arguments, and this text is typed
    /// into a live shell.
    static func changeDirectoryCommandLine(_ directory: String) -> String {
        ffiLend(directory) { input in
            ffiAnswerText(capacity: input.count + 8) { out, cap in
                slopdesk_code_bridge_cd_line(input.baseAddress, input.count, out, cap)
            }
        }
    }

    /// The sentence the editor shows when nothing could take the command.
    static func message(for refusal: Refusal) -> String {
        ffiAnswerText(capacity: 128) { out, cap in
            slopdesk_code_bridge_message(refusal.code, out, cap)
        }
    }

    // MARK: Marshalling

    /// Appends `value`'s UTF-8 to `blob` and answers where it landed.
    private static func span(of value: String, into blob: inout [UInt8]) -> (offset: Int, length: Int) {
        let offset = blob.count
        blob.append(contentsOf: value.utf8)
        return (offset, blob.count - offset)
    }
}
