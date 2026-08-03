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
// The host routes an open to the connection whose workspace folder CONTAINS the target, which is
// how a file lands in its own project's window rather than whichever window registered last.
//
// Validate-then-drop throughout: a malformed line, an unknown verb or a path that will not open is
// ignored. This extension runs inside the user's editor — it must never be the reason a workbench
// fails to come up.

const vscode = require("vscode");
const net = require("net");

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

function activate() {
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
