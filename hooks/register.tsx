import type { EngineInterface, Register } from 'claude-code'

// The game is a native SceneKit window (native/main.swift, built to
// bin/skate-gpu). This module launches it, keeps a small JSON status file it
// reads (Claude's state, records, a raise counter) and saves the records it
// reports on stdout as `RUN {"score":..,"bones":..}` lines.

type Status = { working: boolean; activity: string; tools: number; best: number; bones: number; raise: number }

const status: Status = { working: false, activity: '', tools: 0, best: 0, bones: 0, raise: 0 }
// Bones the running window has reported, so each report adds only new ones.
let bonesSeen = 0
let running = false
let building: Promise<boolean> | null = null

const paths = (root: string) => ({
  source: `${root}/native/main.swift`,
  binary: `${root}/bin/skate-gpu`,
  status: `${root}/bin/status.json`,
})

async function writeStatus($: EngineInterface) {
  try {
    await $.fs.write(paths($.plugin.root).status, JSON.stringify(status))
  } catch {
    // bin/ is made by the first build; until then there is no window to tell.
  }
}

async function saveRun($: EngineInterface, score: number, bones: number) {
  const fresh = Math.max(0, bones - bonesSeen)
  bonesSeen = Math.max(bonesSeen, bones)
  const best = Math.max(status.best, Math.floor(score))
  if (best === status.best && fresh === 0) {
    return
  }
  status.best = best
  status.bones += fresh
  await $.store.set('best', status.best)
  await $.store.set('bones', status.bones)
  await writeStatus($)
}

async function build($: EngineInterface, force: boolean) {
  const { source, binary } = paths($.plugin.root)
  if (!force && (await $.fs.exists(binary))) {
    return true
  }
  $.ui.toast('Building the skate park (first run takes about 30 seconds)...')
  // bin/ is not in git, so a fresh clone has to make it.
  await $.process.run(['mkdir', '-p', binary.slice(0, binary.lastIndexOf('/'))])
  const made = await $.process.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', source, '-o', binary], {
    timeoutMs: 300_000,
  })
  if (made.exitCode !== 0) {
    $.ui.log(`skate: build failed: ${made.stderr.slice(0, 2000)}`)
    return false
  }
  return true
}

async function readRuns($: EngineInterface, argv: string[]) {
  let buffer = ''
  try {
    for await (const piece of $.process.spawn({ argv })) {
      if (piece.stream !== 'stdout') continue
      buffer += piece.text
      let nl = buffer.indexOf('\n')
      while (nl >= 0) {
        const line = buffer.slice(0, nl).trim()
        buffer = buffer.slice(nl + 1)
        nl = buffer.indexOf('\n')
        if (!line.startsWith('RUN ')) continue
        try {
          const run = JSON.parse(line.slice(4)) as { score?: unknown; bones?: unknown }
          if (typeof run.score === 'number' && typeof run.bones === 'number') {
            await saveRun($, run.score, run.bones)
          }
        } catch {
          // A line we cannot read is skipped.
        }
      }
    }
  } catch (err) {
    $.ui.log(`skate: the game window stopped: ${String(err)}`, { to: 'debug' })
  } finally {
    running = false
  }
}

async function launch($: EngineInterface, activate: boolean) {
  if (running) {
    if (activate) {
      status.raise += 1
      await writeStatus($)
    }
    return
  }
  building ??= build($, false).finally(() => {
    building = null
  })
  if (!(await building) || running) {
    return
  }
  running = true
  bonesSeen = 0
  status.raise = Math.max(1, status.raise)
  await writeStatus($)
  const { binary, status: statusPath } = paths($.plugin.root)
  // The child lives as long as this loop: it ends when the window closes or the mod unloads.
  void readRuns($, [binary, statusPath, ...(activate ? ['--activate'] : [])])
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'skate',
      description: 'Open the skate window (/skate auto on|off: open it on every prompt; /skate rebuild)',
    })
    status.best = Number((await $.store.get('best')) ?? 0)
    status.bones = Number((await $.store.get('bones')) ?? 0)

    return next(e)
  })

  on('command.run', { command: 'skate' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'auto on' || arg === 'auto off') {
      await $.store.set('auto', arg === 'auto on')
      return { text: `Skate auto-open is ${arg === 'auto on' ? 'on' : 'off'}.` }
    }
    if (arg === 'rebuild') {
      const ok = await build($, true)
      return { text: ok ? 'Skate rebuilt. Close the window, then run /skate to load it.' : 'Skate build failed: see the log line above.' }
    }
    await launch($, true)

    return { text: 'Skate window up. SPACE to drop in, Esc to come back.' }
  })

  on('prompt.submit', async ($, e, next) => {
    if ((await $.store.get('auto')) !== false) {
      void launch($, false)
    }

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    status.working = true
    status.activity = 'thinking'
    await writeStatus($)

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    status.activity = String(e.tool)
    status.tools += 1
    await writeStatus($)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    status.working = false
    status.activity = ''
    await writeStatus($)

    return next(e)
  })
}
