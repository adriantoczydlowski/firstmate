// firstmate-context-handoff-worker under `claude plugin test`: the threshold and the
// worker's self-run handoff, mid-turn and idle, and its one status line.
//
// On 2.1.288 the test kit never routes a plugin's own `$.session.append` to a test's
// `session.append` hook, so these tests see the mod's mid-turn request through its
// debug lines; docs/verification/context-handoff.md holds the live evidence.
import type { On } from 'claude-code'
import { describe, expect, mock, test, type Engine } from 'claude-code/testing'

import { findRecordPaths, findStatusPath, handoffPathFor, lastStatusState, statusLine } from '../hooks/register'

const HOME = '/fm/home'
const TASK = 'fix-thing-k3'
const STATUS = `${HOME}/state/${TASK}.status`
const HANDOFF = `${HOME}/data/${TASK}/handoff.md`
const BRIEF = `Report status by appending one line:\n\`echo "{state} [at=<epoch>]: x" >> '${STATUS}'\``
const RECORD = `${HOME}/state/operational-inbox/1700000000-0a1b2c3d4e5f6a7b.msg`
const DOORBELL = `: Firstmate operational input waiting: read '${RECORD}' and handle its contents as Firstmate operational input.`
const CREW_ENV = { FM_TASK_ID: TASK, COMPACT_ADVISER_DISABLE: '1' }

type Journal = {
  commands: { command: string; args?: string }[]
  appended: string[]
  processes: string[][]
  usageReads: number
  commandLists: number
  logs: string[]
}

type WorldOptions = {
  env?: Record<string, string>
  commands?: string[]
  tokens?: number
  handoffMtime?: number
  failMessages?: boolean
  users?: string[]
  files?: Record<string, string>
}

function world(on: On, options: WorldOptions = {}) {
  mock.env(on, { HOME: '/Users/me', ...(options.env ?? CREW_ENV) })
  const clock = mock.clock(on, { now: 1_000_000 })
  const journal: Journal = { commands: [], appended: [], processes: [], usageReads: 0, commandLists: 0, logs: [] }
  const state = { tokens: options.tokens, handoffMtime: options.handoffMtime }
  const files = options.files ?? { [STATUS]: 'working [at=999000]: started\n' }
  const users = options.users ?? [BRIEF]
  const names = options.commands ?? ['stow', 'clear', 'handoff', 'compact']
  on('command.list', async () => {
    journal.commandLists += 1
    return { value: names.map(name => ({ name, description: name, source: 'builtin' as const })) }
  })
  on('command.run', async (_$, e) => {
    journal.commands.push({ command: e.command, ...(e.args ? { args: e.args } : {}) })
    return {}
  })
  on('session.messages', async () => {
    if (options.failMessages) throw new Error('transcript unreadable')
    return { value: users.map(text => ({ role: 'user', text, toolUses: [] })) as never }
  })
  on('session.root', async () => ({ value: '/work' }))
  on('session.usage', async () => {
    journal.usageReads += 1
    return { value: { startedAt: 0, context: { tokens: state.tokens, window: 1_000_000 }, rateLimits: [] } }
  })
  on('session.append', async (_$, e) => {
    journal.appended.push(e.message.content.map(b => ('text' in b ? b.text : '')).join(''))
    return { message: e.message, uuid: e.uuid }
  })
  on('fs.read', async (_$, e) => (e.path in files ? { value: files[e.path] as string } : { deny: `ENOENT: ${e.path}` }))
  on('fs.stat', async (_$, e) => {
    if (e.path !== HANDOFF || state.handoffMtime === undefined) return { deny: `ENOENT: ${e.path}` }
    return { value: { kind: 'file' as const, size: 10, mtimeMs: state.handoffMtime, isLink: false } }
  })
  on('process.run', async (_$, e) => {
    journal.processes.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', async (_$, e) => {
    journal.logs.push(e.text)
    return { value: undefined }
  })
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('tool.call', async () => ({ result: 'ok' }) as never)
  return {
    clock,
    journal,
    setTokens: (n: number) => (state.tokens = n),
    writeHandoff: (mtime: number) => (state.handoffMtime = mtime),
  }
}

function measure($: Engine, tokens: number | undefined) {
  return $.session.measure({ context: { tokens, window: 1_000_000 }, rateLimits: [], changed: ['context'] } as never)
}

function bash($: Engine, agentId?: string) {
  return $.tool.call({ tool: 'Bash', tool_use_id: 'tu-1', command: 'ls', ...(agentId ? { agentId } : {}) } as never)
}

describe('helpers', () => {
  test('finds the status path the launch brief names and derives the handoff path', async () => {
    expect(findStatusPath(['nothing here', BRIEF], TASK)).toBe(STATUS)
    expect(findStatusPath([BRIEF], 'other-task')).toBe(undefined)
    expect(findRecordPaths(['nothing here', DOORBELL])).toEqual([RECORD])
    expect(lastStatusState('working [at=1]: a\ndone [at=2]: b\n\n')).toBe('done')
    expect(lastStatusState('\n')).toBe(undefined)
    expect(handoffPathFor(STATUS, TASK)).toBe(HANDOFF)
    expect(statusLine(1700000000, 251_400, HANDOFF)).toBe(
      `working [at=1700000000]: context handoff written at 251k tokens used (early courtesy point; note it, no relaunch): ${HANDOFF}`,
    )
  })
})

describe('Firstmate worker', () => {
  test('below 250k used it only reads usage, once per tool call', async ($, on) => {
    const { journal } = world(on, { tokens: 249_999 })
    await bash($)
    await bash($)
    await measure($, 249_999)
    expect(journal.usageReads).toBe(2)
    expect(journal.commandLists).toBe(0)
    expect(journal.commands).toHaveLength(0)
  })

  test('mid-turn crossing: asks for the handoff as a row and runs no command', async ($, on) => {
    const { journal } = world(on, { tokens: 251_000 })
    await bash($)
    expect(journal.logs.some(l => l.startsWith(`worker ${TASK}: requesting the handoff mid-turn`))).toBe(true)
    expect(journal.commands).toHaveLength(0)
  })

  test("a subagent's tool call is left alone", async ($, on) => {
    const { journal } = world(on, { tokens: 251_000 })
    await bash($, 'agent-1')
    expect(journal.usageReads).toBe(0)
    expect(journal.logs.some(l => l.includes('requesting the handoff'))).toBe(false)
  })

  test('idle crossing: runs the real /handoff with the durable path, outside the measuring dispatch', async ($, on) => {
    const { journal, clock } = world(on)
    await measure($, 255_000)
    expect(journal.commands).toHaveLength(0)
    await clock.settle()
    expect(journal.commands).toHaveLength(1)
    expect(journal.commands[0]?.command).toBe('handoff')
    expect(journal.commands[0]?.args).toContain(HANDOFF)
  })

  test('appends exactly one status line once the requested handoff file exists', async ($, on) => {
    const { journal, clock, writeHandoff, setTokens } = world(on)
    await measure($, 255_000)
    await clock.settle()
    await bash($)
    expect(journal.processes).toHaveLength(0)
    writeHandoff(clock.now() + 5)
    setTokens(262_000)
    await bash($)
    expect(journal.processes).toHaveLength(1)
    expect(journal.processes[0]?.at(-1)).toBe(STATUS)
    expect(journal.processes[0]?.at(-2)).toBe(statusLine(Math.floor(clock.now() / 1000), 262_000, HANDOFF))
    await bash($)
    await measure($, 263_000)
    expect(journal.processes).toHaveLength(1)
  })

  test('re-arms once the window drops back under 250k', async ($, on) => {
    const { journal, clock } = world(on)
    await measure($, 255_000)
    await clock.settle()
    await measure($, 40_000)
    await measure($, 256_000)
    await clock.settle()
    expect(journal.commands.map(c => c.command)).toEqual(['handoff', 'handoff'])
  })

  test('an old handoff file from before the request is not reported', async ($, on) => {
    const { journal, clock } = world(on, { tokens: 251_000, handoffMtime: 5 })
    await measure($, 255_000)
    await clock.settle()
    await bash($)
    await bash($)
    expect(journal.processes).toHaveLength(0)
  })

  test('stays quiet when the brief names no status file', async ($, on) => {
    const { journal } = world(on, { env: { ...CREW_ENV, FM_TASK_ID: 'other-task' }, tokens: 251_000 })
    await bash($)
    expect(journal.appended).toHaveLength(0)
    expect(journal.commands).toHaveLength(0)
  })

  test('reads the status path from the launch record its doorbell names', async ($, on) => {
    const { journal, clock, writeHandoff } = world(on, {
      users: [DOORBELL],
      files: { [RECORD]: `<firstmate-operational-input kind="launch-brief">\n${BRIEF}`, [STATUS]: '' },
    })
    await measure($, 255_000)
    await clock.settle()
    expect(journal.commands).toHaveLength(1)
    expect(journal.commands[0]?.args).toContain(HANDOFF)
    writeHandoff(clock.now() + 5)
    await bash($)
    expect(journal.processes[0]?.at(-1)).toBe(STATUS)
  })

  test('stays quiet when the launch record cannot be read', async ($, on) => {
    const { journal, clock } = world(on, { users: [DOORBELL], tokens: 251_000 })
    await measure($, 255_000)
    await clock.settle()
    await bash($)
    expect(journal.commands).toHaveLength(0)
    expect(journal.processes).toHaveLength(0)
    expect(journal.logs.some(l => l.includes(`launch record ${RECORD} unreadable`))).toBe(true)
  })

  for (const last of ['done [at=999500]: PR merged', 'needs-decision [at=999500]: which API?']) {
    test(`writes no status line over a last line of ${last.split(' ')[0]}`, async ($, on) => {
      const { journal, clock, writeHandoff } = world(on, {
        files: { [STATUS]: `working [at=999000]: started\n${last}\n` },
      })
      await measure($, 255_000)
      await clock.settle()
      writeHandoff(clock.now() + 5)
      await bash($)
      await bash($)
      expect(journal.processes).toHaveLength(0)
      expect(journal.logs.some(l => l.includes(`last status line is ${last.split(' ')[0]}`))).toBe(true)
    })
  }

  test('stays quiet without /handoff', async ($, on) => {
    const { journal, clock } = world(on, { commands: ['stow', 'clear'] })
    await measure($, 300_000)
    await clock.settle()
    await bash($)
    expect(journal.commands).toHaveLength(0)
    expect(journal.processes).toHaveLength(0)
  })

  test('stays quiet outside a ship or scout worker', async ($, on) => {
    const { journal, clock } = world(on, { env: { COMPACT_ADVISER_DISABLE: '1' }, tokens: 400_000 })
    await bash($)
    await measure($, 400_000)
    await clock.settle()
    await bash($)
    expect(journal.commands).toHaveLength(0)
    expect(journal.processes).toHaveLength(0)
  })
})

describe('session lifecycle', () => {
  test('a second session.start without an intervening re-arm asks for the handoff again', async ($, on) => {
    const { journal } = world(on, { tokens: 251_000 })
    await bash($)
    expect(journal.logs.filter(l => l.startsWith(`worker ${TASK}: requesting the handoff mid-turn`))).toHaveLength(1)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true } as never)
    await bash($)
    expect(journal.logs.filter(l => l.startsWith(`worker ${TASK}: requesting the handoff mid-turn`))).toHaveLength(2)
  })
})

describe('failure', () => {
  test('a failing engine call passes every event through and goes quiet', async ($, on) => {
    const { journal } = world(on, { tokens: 300_000, failMessages: true })
    expect(await bash($)).toEqual({ result: 'ok' })
    expect(await measure($, 300_000)).toEqual({ changed: ['context'] })
    expect(await bash($)).toEqual({ result: 'ok' })
    expect(journal.appended).toHaveLength(0)
    expect(journal.commands).toHaveLength(0)
  })
})
