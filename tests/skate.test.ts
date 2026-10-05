import { expect, mock, test } from 'claude-code/testing'

const ORIGIN = { kind: 'composer' } as const
const PRESENTATION = { isFullscreen: false, columns: 100 }

test('/skate launches the window with --activate and keeps the records it reports', async ($, on) => {
  mock.store(on, { best: 500, bones: 2 })
  const writes: string[] = []
  const spawned: string[][] = []
  on('fs.exists', () => ({ value: true }))
  on('fs.write', ($, e) => {
    writes.push(e.text)
    return { value: undefined }
  })
  on('process.spawn', async function* ($, e) {
    spawned.push([...e.argv])
    yield { stream: 'stdout', text: 'RUN {"score":900,"bo' }
    yield { stream: 'stdout', text: 'nes":3}\nRUN {"score":1200,"bones":4}\n' }
    return { value: { code: 0, signal: null } }
  })

  await $.session.start({ source: 'startup' } as never)
  const ran = await $.command.run({ command: 'skate', args: '', origin: ORIGIN, presentation: PRESENTATION } as never)
  expect(ran).toMatchObject({ text: expect.stringContaining('Skate window up') })
  expect(spawned).toHaveLength(1)
  expect(spawned[0]![0]).toMatch(/bin\/skate-gpu$/)
  expect(spawned[0]).toContain('--activate')

  // Let the child's output be read.
  for (let i = 0; i < 20 && JSON.parse(writes.at(-1) ?? '{}').best !== 1200; i++) await Promise.resolve()
  const last = JSON.parse(writes.at(-1)!)
  expect(last).toMatchObject({ best: 1200, bones: 6 })
})

test("Claude's turn and tool calls reach the status file", async ($, on) => {
  mock.store(on)
  const writes: string[] = []
  on('fs.write', ($, e) => {
    writes.push(e.text)
    return { value: undefined }
  })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(JSON.parse(writes.at(-1)!)).toMatchObject({ working: true, activity: 'thinking' })
})
