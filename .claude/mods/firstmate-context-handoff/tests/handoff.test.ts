// firstmate-context-handoff under `claude plugin test`: the threshold, the two session
// kinds, the main window's two buttons and the worker's self-run handoff.
//
// On 2.1.288 the test kit never routes a plugin's own `$.session.append` to a test's
// `session.append` hook ("no implementation for session.append"), so these tests see
// the mod's attempt through its debug lines; the live lab in the report shows the row
// landing and the model reading it.
import type { On } from 'claude-code'
import { describe, expect, mock, test, type Engine } from 'claude-code/testing'

import { carryText, findStatusPath, handoffPathFor, statusLine } from '../hooks/register'

const PLUGIN = 'firstmate-context-handoff'
const HOME = '/fm/home'
const TASK = 'fix-thing-k3'
const STATUS = `${HOME}/state/${TASK}.status`
const HANDOFF = `${HOME}/data/${TASK}/handoff.md`
const BRIEF = `Report status by appending one line:\n\`echo "{state} [at=<epoch>]: x" >> '${STATUS}'\``
const STOCK = 'STOCK-DRAWING'
const CARRYING = /^carrying \d+ characters of stow receipt/
const RECEIPT = 'Stow receipt: nothing lost. Codeword PELICAN-42.'

type Journal = {
  commands: { command: string; args?: string }[]
  appended: string[]
  processes: string[][]
  fills: string[]
  toasts: string[]
  stats: number
  usageReads: number
  commandLists: number
  logs: string[]
}

type WorldOptions = {
  env?: Record<string, string>
  commands?: string[]
  tokens?: number
  handoffMtime?: number
  refuse?: string[]
  failMessages?: boolean
  /** Holds /stow in the queue until this resolves, as a running turn does. */
  stowDequeued?: Promise<void>
}

function world(on: On, options: WorldOptions = {}) {
  mock.env(on, { HOME: '/Users/me', ...(options.env ?? {}) })
  const clock = mock.clock(on, { now: 1_000_000 })
  const journal: Journal = { commands: [], appended: [], processes: [], fills: [], toasts: [], stats: 0, usageReads: 0, commandLists: 0, logs: [] }
  const state = { tokens: options.tokens, handoffMtime: options.handoffMtime }
  const names = options.commands ?? ['stow', 'clear', 'handoff', 'compact']
  on('command.list', async () => {
    journal.commandLists += 1
    return { value: names.map(name => ({ name, description: name, source: 'builtin' as const })) }
  })
  on('command.run', async (_$, e) => {
    if (options.refuse?.includes(e.command)) throw new Error(`refused ${e.command}`)
    if (e.command === 'stow' && options.stowDequeued) await options.stowDequeued
    journal.commands.push({ command: e.command, ...(e.args ? { args: e.args } : {}) })
    return {}
  })
  on('session.messages', async () => {
    if (options.failMessages) throw new Error('transcript unreadable')
    return { value: [{ role: 'user', text: BRIEF, toolUses: [] }] as never }
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
  on('fs.read', async (_$, e) => ({ deny: `ENOENT: ${e.path}` }))
  on('fs.stat', async (_$, e) => {
    journal.stats += 1
    if (e.path !== HANDOFF || state.handoffMtime === undefined) return { deny: `ENOENT: ${e.path}` }
    return { value: { kind: 'file' as const, size: 10, mtimeMs: state.handoffMtime, isLink: false } }
  })
  on('process.run', async (_$, e) => {
    journal.processes.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('prompt.fill', async (_$, e) => {
    journal.fills.push(e.text)
    return { isFilled: true } as never
  })
  on('ui.toast', async (_$, e) => {
    journal.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', async (_$, e) => {
    journal.logs.push(e.text)
    return { value: undefined }
  })
  on('session.end', async (_$, e) => ({ sessionId: e.sessionId }))
  on('turn.complete', async (_$, e) => ({ text: e.answer }))
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('tool.call', async () => ({ result: 'ok' }) as never)
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [STOCK] }))
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

function band($: Engine) {
  return $.ui.render({
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'above-prompt',
    viewport: { columns: 120, rows: 40 },
    props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 120 },
  } as never)
}

const shown = (tree: unknown) => JSON.stringify(tree)
const isStock = (tree: unknown) => shown(tree).includes(STOCK)

function complete($: Engine, answer: string, isAborted = false) {
  return $.turn.complete({ answer, durationMs: 1, isAborted, turnId: 't', reason: isAborted ? 'aborted' : 'answer' } as never)
}

function bash($: Engine) {
  return $.tool.call({ tool: 'Bash', tool_use_id: 'tu-1', command: 'ls' } as never)
}

describe('helpers', () => {
  test('finds the status path the launch brief names and derives the handoff path', async () => {
    expect(findStatusPath(['nothing here', BRIEF], TASK)).toBe(STATUS)
    expect(findStatusPath([BRIEF], 'other-task')).toBe(undefined)
    expect(handoffPathFor(STATUS, TASK)).toBe(HANDOFF)
    expect(statusLine(1700000000, 251_400, HANDOFF)).toBe(`working [at=1700000000]: context handoff written at 251k tokens used: ${HANDOFF}`)
    expect(carryText(252_000, '  ')).toContain('(the /stow turn left no receipt text)')
  })
})

describe('main window', () => {
  test('stays quiet below 250k tokens used and makes no engine call doing so', async ($, on) => {
    const { journal } = world(on)
    await measure($, 249_999)
    await measure($, undefined)
    expect(isStock(await band($))).toBe(true)
    expect(journal.commandLists).toBe(0)
    expect(journal.usageReads).toBe(0)
  })

  test('offers /stow at 250k used, then clear, then carries the receipt into the fresh session', async ($, on) => {
    const { journal } = world(on)
    await measure($, 250_000)
    expect(shown(await band($))).toContain('250k tokens of context used')
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'stow' })
    expect(journal.commands).toEqual([{ command: 'stow' }])
    expect(shown(await band($))).toContain('Writing the handoff')
    await complete($, RECEIPT)
    expect(shown(await band($))).toContain('Clear and carry handoff')
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'clear' })
    expect(journal.commands).toEqual([{ command: 'stow' }, { command: 'clear' }])
    expect(journal.fills).toEqual([])
    expect(journal.logs.filter(l => CARRYING.test(l))).toHaveLength(1)
  })

  test('a /clear typed by hand while the clear is offered still carries the receipt', async ($, on) => {
    const { journal, clock } = world(on)
    await measure($, 300_000)
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'stow' })
    await complete($, RECEIPT)
    await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } } as never)
    await clock.settle()
    expect(journal.logs.filter(l => CARRYING.test(l))).toHaveLength(1)
    expect(isStock(await band($))).toBe(true)
  })

  test('falls back to filling /clear into the prompt when the engine refuses to run it', async ($, on) => {
    const { journal, clock } = world(on, { refuse: ['clear'] })
    await measure($, 300_000)
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'stow' })
    await complete($, RECEIPT)
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'clear' })
    expect(journal.fills).toEqual(['/clear'])
    expect(journal.toasts[0]).toContain('Press Enter to clear')
    expect(journal.logs.filter(l => CARRYING.test(l))).toHaveLength(0)
    await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } } as never)
    await clock.settle()
    expect(journal.logs.filter(l => CARRYING.test(l))).toHaveLength(1)
  })

  test('a turn that ends before /stow is dequeued is not taken for the receipt', async ($, on) => {
    let release: () => void = () => undefined
    const { clock } = world(on, { stowDequeued: new Promise<void>(resolve => (release = resolve)) })
    await measure($, 300_000)
    await band($)
    const pressing = $.ui.press({ plugin: PLUGIN, key: 'stow' })
    await clock.settle()
    await complete($, 'a fleet wake turn, not the receipt')
    expect(shown(await band($))).toContain('Writing the handoff')
    release()
    await pressing
    await complete($, RECEIPT)
    expect(shown(await band($))).toContain('Clear and carry handoff')
  })

  test('/stow typed by hand while the offer is up counts as the button', async ($, on) => {
    world(on)
    await measure($, 300_000)
    await $.command.run({ command: 'stow' } as never)
    await complete($, RECEIPT)
    expect(shown(await band($))).toContain('Clear and carry handoff')
  })

  test('an interrupted /stow goes back to the offer; Not now hides it until the window drops', async ($, on) => {
    world(on)
    await measure($, 300_000)
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'stow' })
    await complete($, '', true)
    expect(shown(await band($))).toContain('Write handoff (/stow)')
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'dismiss' })
    expect(isStock(await band($))).toBe(true)
    await measure($, 310_000)
    expect(isStock(await band($))).toBe(true)
    await measure($, 20_000)
    await measure($, 260_000)
    expect(shown(await band($))).toContain('260k tokens of context used')
  })

  test('stays inert where /stow does not exist', async ($, on) => {
    world(on, { commands: ['clear', 'compact'] })
    await measure($, 400_000)
    expect(isStock(await band($))).toBe(true)
  })

  test('stays inert in a secondmate: Firstmate-launched with no task id', async ($, on) => {
    const { journal } = world(on, { env: { COMPACT_ADVISER_DISABLE: '1' } })
    await measure($, 400_000)
    expect(isStock(await band($))).toBe(true)
    expect(journal.commands).toHaveLength(0)
  })
})

describe('Firstmate worker', () => {
  const crewEnv = { FM_TASK_ID: TASK, COMPACT_ADVISER_DISABLE: '1' }

  test('mid-turn crossing: asks for the handoff as a row, runs no command and draws no button', async ($, on) => {
    const { journal } = world(on, { env: crewEnv, tokens: 251_000 })
    await bash($)
    expect(journal.logs.some(l => l.startsWith(`worker ${TASK}: requesting the handoff mid-turn`))).toBe(true)
    expect(journal.commands).toHaveLength(0)
    expect(isStock(await band($))).toBe(true)
  })

  test('idle crossing: runs the real /handoff with the durable path, outside the measuring dispatch', async ($, on) => {
    const { journal, clock } = world(on, { env: crewEnv })
    await measure($, 255_000)
    expect(journal.commands).toHaveLength(0)
    await clock.settle()
    expect(journal.commands).toHaveLength(1)
    expect(journal.commands[0]?.command).toBe('handoff')
    expect(journal.commands[0]?.args).toContain(HANDOFF)
  })

  test('appends exactly one status line once the requested handoff file exists', async ($, on) => {
    const { journal, clock, writeHandoff, setTokens } = world(on, { env: crewEnv })
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

  test('an old handoff file from before the request is not reported', async ($, on) => {
    const { journal, clock } = world(on, { env: crewEnv, tokens: 251_000, handoffMtime: 5 })
    await measure($, 255_000)
    await clock.settle()
    await bash($)
    await bash($)
    expect(journal.processes).toHaveLength(0)
  })

  test('stays quiet when the brief names no status file', async ($, on) => {
    const { journal } = world(on, { env: { ...crewEnv, FM_TASK_ID: 'other-task' }, tokens: 251_000 })
    await bash($)
    expect(journal.appended).toHaveLength(0)
    expect(journal.commands).toHaveLength(0)
  })

  test('outside a worker, a tool call reads the environment once and nothing else', async ($, on) => {
    const { journal } = world(on, { tokens: 400_000 })
    await bash($)
    await bash($)
    await bash($)
    expect(journal.usageReads).toBe(0)
    expect(journal.commandLists).toBe(0)
  })
})

describe('failure', () => {
  test('a failing engine call passes every event through and goes quiet', async ($, on) => {
    const { journal } = world(on, { env: { FM_TASK_ID: TASK }, tokens: 300_000, failMessages: true })
    expect(await bash($)).toEqual({ result: 'ok' })
    expect(await measure($, 300_000)).toEqual({ changed: ['context'] })
    expect(await bash($)).toEqual({ result: 'ok' })
    expect(isStock(await band($))).toBe(true)
    expect(journal.appended).toHaveLength(0)
    expect(journal.commands).toHaveLength(0)
  })
})
