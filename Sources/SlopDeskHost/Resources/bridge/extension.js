// slopdesk.slopdesk-bridge — the app's own VS Code extension, seeded into the embedded
// workbench's profile by `CodeServerManager.seedBridgeExtension`.
//
// WHY IT EXISTS. Before this, "open this file in the editor" ran `code-server -r <path>`: a fresh
// Node CLI process that routes through the per-user session socket, retried 10x2s because the
// session only registers once some webview has finished booting the workbench. The bridge replaces
// that with a socket the extension host holds open: hostd writes one line, the editor opens the
// file in the same tick.
//
// SHAPE. This is the CLIENT. hostd owns the `AF_UNIX` listener (`CodeBridgeServer`) and hands its
// path down through `SLOPDESK_CODE_BRIDGE_SOCKET`, which every code-server child inherits
// (`CodeServerManager.childEnvironment`). No env var (a workbench someone launched by hand) => the
// extension activates and does nothing at all.
//
// PROTOCOL. Newline-delimited JSON, host-local, NOT the golden wire protocol (docs/20 covers the
// three network paths; this crosses no network and is versioned by the `v` field alone).
//   extension -> host  {"t":"hello","v":1,"root":"<workspace folder fsPath>"}
//   host -> extension  {"t":"open","path":"/abs/path","line":12,"col":3}   (line/col optional)
//   extension -> host  {"t":"run","v":1,"id":"7","root":"…","cwd":"…","text":"npm test"}
//   extension -> host  {"t":"cd","v":1,"id":"8","root":"…","path":"/abs/dir"}
//   host -> extension  {"t":"result","id":"7","ok":true,"pane":"zsh — proj"}
//                      {"t":"result","id":"7","ok":false,"message":"…"}
// The host routes an open to the connection whose workspace folder CONTAINS the target, which is
// how a file lands in its own project's window rather than whichever window registered last.
//
// THE TERMINAL COMMANDS. This workbench has an integrated terminal, and it is the wrong one: a
// shell there has no agent detection, no PTY fan-out to the other clients, no replay. So the two
// contributed commands type into a real SlopDesk pane instead, and the HOST picks which one
// (`CodeBridgeTerminalRouter` — focus is a client-side fact the extension host cannot see). The
// host also builds the `cd` command line, so the shell quoting has one tested home; `cd` sends a
// directory, never a command string.
//
// Validate-then-drop throughout: a malformed line, an unknown verb or a path that will not open is
// ignored. This extension runs inside the user's editor — it must never be the reason a workbench
// fails to come up.

const vscode = require("vscode");
const net = require("net");
const path = require("path");

const PROTOCOL_VERSION = 1;
const RECONNECT_DELAY_MS = 5000;
// A host that went away takes its code-server child with it, so a socket that refuses this many
// times in a row is not coming back; stop burning a timer for the rest of the editor's life.
const MAX_RECONNECT_ATTEMPTS = 60;

let socket = null;
let timer = null;
let attempts = 0;
let buffer = "";
let disposed = false;
// Requests waiting on a `result`, keyed by the correlation id we minted. The host answers every
// one it parses; an unanswered entry simply ages out with the connection (see `dropPending`),
// because a silent command is a worse outcome than a late apology.
let pending = new Map();
let nextRequestID = 1;

/** The first workspace folder's host path — the window's identity to the router. */
function workspaceRoot() {
    const folders = vscode.workspace.workspaceFolders;
    return folders && folders.length > 0 ? folders[0].uri.fsPath : "";
}

function send(message) {
    if (!socket || socket.destroyed) return;
    try {
        socket.write(JSON.stringify(message) + "\n");
    } catch (_) {
        // The host went away mid-write; the close handler schedules the retry.
    }
}

function scheduleReconnect(socketPath) {
    if (disposed || timer || attempts >= MAX_RECONNECT_ATTEMPTS) return;
    attempts += 1;
    timer = setTimeout(() => {
        timer = null;
        connect(socketPath);
    }, RECONNECT_DELAY_MS);
}

function connect(socketPath) {
    if (disposed) return;
    buffer = "";
    socket = net.createConnection(socketPath);
    socket.setEncoding("utf8");
    socket.on("connect", () => {
        attempts = 0;
        send({ t: "hello", v: PROTOCOL_VERSION, root: workspaceRoot() });
    });
    socket.on("data", (chunk) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            handle(line);
            newline = buffer.indexOf("\n");
        }
    });
    // Errors surface as a close; swallowing them here is what keeps a refused connect from
    // reaching Node's unhandled-error path and taking the extension host with it.
    socket.on("error", () => {});
    socket.on("close", () => {
        socket = null;
        dropPending("SlopDesk: the host went away.");
        scheduleReconnect(socketPath);
    });
}

function handle(line) {
    let message;
    try {
        message = JSON.parse(line);
    } catch (_) {
        return;
    }
    if (!message || typeof message !== "object") return;
    if (message.t === "open") openFile(message);
    else if (message.t === "result") settle(message);
}

/** Reports one finished `run`/`cd`: the status bar on success, a warning the user must read on refusal. */
function settle(message) {
    const request = pending.get(String(message.id));
    if (!request) return;
    pending.delete(String(message.id));
    if (message.ok) {
        const where = typeof message.pane === "string" && message.pane ? ` — ${message.pane}` : "";
        vscode.window.setStatusBarMessage(`${request.label}${where}`, 4000);
        return;
    }
    vscode.window.showWarningMessage(
        typeof message.message === "string" && message.message
            ? message.message
            : "SlopDesk: the command could not be delivered.",
    );
}

function dropPending(reason) {
    if (pending.size === 0) return;
    pending.clear();
    vscode.window.showWarningMessage(reason);
}

/** Sends one correlated request, or tells the user why it could not go at all. */
function request(message, label) {
    if (!socket || socket.destroyed) {
        vscode.window.showWarningMessage("SlopDesk: not connected to the host.");
        return;
    }
    const id = String(nextRequestID++);
    pending.set(id, { label });
    send(Object.assign({ v: PROTOCOL_VERSION, id, root: workspaceRoot() }, message));
}

async function openFile(message) {
    const file = message.path;
    if (typeof file !== "string" || !file.startsWith("/")) return;
    try {
        const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
        // `preview: false` pins the tab — an opened file survives the next open, matching how the
        // app's own panes behave (nothing the user asked for silently disappears).
        const options = { preview: false };
        const position = caret(message);
        if (position) {
            options.selection = new vscode.Range(position, position);
        }
        await vscode.window.showTextDocument(document, options);
    } catch (_) {
        // Gone, binary, unreadable — the host already answered its client; nothing left to do.
    }
}

/** 1-based `line`/`col` from the wire as a 0-based `Position`, or `null` when unspecified. */
function caret(message) {
    const line = message.line;
    if (!Number.isInteger(line) || line < 1) return null;
    const column = Number.isInteger(message.col) && message.col > 0 ? message.col - 1 : 0;
    return new vscode.Position(line - 1, column);
}

/**
 * "Run Selection in SlopDesk Terminal" — the selected text, or the caret's line when nothing is
 * selected (the same courtesy every REPL-send command in this editor extends).
 */
function runSelectionInTerminal() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage("SlopDesk: no editor is open.");
        return;
    }
    const selection = editor.selection;
    const raw = selection.isEmpty
        ? editor.document.lineAt(selection.active.line).text
        : editor.document.getText(selection);
    const text = raw.replace(/\s+$/, "");
    if (!text) {
        vscode.window.showWarningMessage("SlopDesk: nothing to run.");
        return;
    }
    request({ t: "run", cwd: directoryOf(editor.document.uri), text }, "Ran in SlopDesk");
}

/**
 * "Change SlopDesk Terminal Directory Here" — from the explorer (the clicked entry) or the editor
 * (the open file). The host builds the `cd` line; this end only resolves WHICH directory.
 */
async function changeTerminalDirectory(target) {
    const uri = target && target.fsPath ? target : vscode.window.activeTextEditor?.document.uri;
    if (!uri || uri.scheme !== "file") {
        vscode.window.showWarningMessage("SlopDesk: no file or folder to change to.");
        return;
    }
    let directory = uri.fsPath;
    try {
        const stat = await vscode.workspace.fs.stat(uri);
        if (stat.type !== vscode.FileType.Directory) directory = path.dirname(uri.fsPath);
    } catch (_) {
        directory = path.dirname(uri.fsPath);
    }
    request({ t: "cd", path: directory }, "Changed SlopDesk terminal directory");
}

/** The directory a document lives in — what a command about it should run FROM. */
function directoryOf(uri) {
    return uri && uri.scheme === "file" ? path.dirname(uri.fsPath) : undefined;
}

function activate(context) {
    // The commands register even with no socket: a menu item that is simply absent reads as a
    // broken build, while one that explains it cannot reach the host reads as what it is.
    context.subscriptions.push(
        vscode.commands.registerCommand("slopdesk.runSelectionInTerminal", runSelectionInTerminal),
        vscode.commands.registerCommand("slopdesk.changeTerminalDirectory", changeTerminalDirectory),
    );
    const socketPath = process.env.SLOPDESK_CODE_BRIDGE_SOCKET;
    if (!socketPath) return;
    disposed = false;
    connect(socketPath);
}

function deactivate() {
    disposed = true;
    if (timer) {
        clearTimeout(timer);
        timer = null;
    }
    if (socket) {
        socket.destroy();
        socket = null;
    }
}

module.exports = { activate, deactivate };
