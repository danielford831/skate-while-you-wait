# Skate While You Wait

A Claude Code mod that opens a GPU-rendered, arcade street skating game in
its own macOS window while Claude works. Your tool calls drop glowing tokens onto
the street, and the HUD shows what Claude is doing right now.

- Native SceneKit / Metal window: HDR bloom, sunset shadows, motion blur, 120 fps
- Ollies, kickflips, heelflips, tre flips, indy grabs, rail grinds and kickers
- Combos multiply; every bail adds the bones you broke to your **injury report**
- Best score and total broken bones are kept across sessions

## Controls

| Key | Move |
| --- | --- |
| SPACE / ↑ | Ollie (on the ground or a rail) |
| ← / → (air) | Kickflip / Heelflip |
| ↓ (air) | Indy Grab |
| ↑ (air) | Tre Flip |
| R | New run |
| Esc | Hide the window, back to Claude |

## Commands

- `/skate`: open the window and focus it
- `/skate auto on|off`: open it (unfocused) on every prompt
- `/skate rebuild`: recompile `native/main.swift`

## Install

Requires macOS with the Xcode command line tools (`xcrun swiftc`). The game
builds itself to `bin/skate-gpu` the first time it launches.

**Before you install:** a Claude Code mod runs with your user's permissions.
This one compiles `native/main.swift` on your machine and runs the result, so
read that file and `hooks/register.tsx` first. The repo ships no prebuilt
binary. The game makes no network calls. It only reads `bin/status.json`, which
holds Claude's tool names and counts, never your prompts or files.

```sh
claude --plugin-dir /path/to/skate-while-you-wait
```

## How it fits together

- `hooks/register.tsx`: the hooks module. It launches `bin/skate-gpu`, writes
  Claude's state to `bin/status.json`, and saves the `RUN {"score":..,"bones":..}`
  lines the game prints.
- `native/main.swift`: the game: simulation, SceneKit scene, SpriteKit HUD.
- `tests/`: `claude plugin test .`
