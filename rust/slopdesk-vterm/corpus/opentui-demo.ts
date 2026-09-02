// A modern TUI, in the shape the conformance corpus needs one: a full-screen alternate-screen
// renderer that repaints on a timer, in truecolor, with a moving highlight and a cursor that is
// parked somewhere specific between frames. `@opentui/core` is the framework OpenCode ships on, so
// what it emits is what a real user's screen is made of.
//
// This is not part of the build. It is run once, under `slopdesk-ttyrec`, to produce
// `opentui.sdrec` — see `README.md` beside this file for the exact command.

import { BoxRenderable, TextRenderable, createCliRenderer } from "@opentui/core"

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
const ROWS = 8

const renderer = await createCliRenderer({ exitOnCtrlC: true })

const frame = new BoxRenderable(renderer, {
  border: true,
  borderStyle: "rounded",
  borderColor: "#5f8fff",
  title: " slopdesk conformance ",
  titleAlignment: "center",
  flexGrow: 1,
  padding: 1,
})
renderer.root.add(frame)

const header = new TextRenderable(renderer, { content: "" })
const rows: TextRenderable[] = []
frame.add(header)
for (let index = 0; index < ROWS; index += 1) {
  const row = new TextRenderable(renderer, { content: "" })
  rows.push(row)
  frame.add(row)
}
const footer = new TextRenderable(renderer, { content: "" })
frame.add(footer)

let tick = 0
let selected = 0

function paint(): void {
  const spinner = FRAMES[tick % FRAMES.length]
  const done = tick % 40
  const bar = "█".repeat(done) + "░".repeat(40 - done)
  header.content = `${spinner} building  ${bar}  ${String(done * 2.5).padStart(5)}%`

  for (let index = 0; index < ROWS; index += 1) {
    // Every row's colour moves every frame, so no two consecutive frames share a style run — the
    // case a renderer that caches per-row styling gets wrong.
    const hue = (tick * 7 + index * 31) % 256
    const mark = index === selected ? "▸" : " "
    const wide = index % 3 === 0 ? " 你好" : ""
    rows[index]!.content =
      `${mark} \x1b[38;2;${hue};${(hue * 3) % 256};${255 - hue}mmodule-${String(index).padStart(2, "0")}\x1b[0m` +
      ` ${index % 2 === 0 ? "\x1b[1mok\x1b[0m" : "\x1b[3mwaiting\x1b[0m"}${wide}`
  }

  footer.content = `↑↓ move  q quit   frame ${tick}`
  tick += 1
}

paint()
const timer = setInterval(paint, 60)

renderer.keyInput.on("keypress", (event) => {
  if (event.name === "q") {
    clearInterval(timer)
    renderer.destroy()
    process.exit(0)
  }
  if (event.name === "down") {
    selected = (selected + 1) % ROWS
  }
  if (event.name === "up") {
    selected = (selected + ROWS - 1) % ROWS
  }
  paint()
})
