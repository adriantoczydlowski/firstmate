// firstmate-context-handoff under `claude plugin test`: the threshold, the per-home
// switch, the main window's two buttons, and the secondmate's self-run /stow.
//
// On 2.1.288 the test kit never routes a plugin's own `$.session.append` to a test's
// `session.append` hook ("no implementation for session.append"), so these tests see
// the mod's attempt through its debug lines; the live lab evidence in
// docs/verification/context-handoff.md shows the row landing and the model reading it.
import type { On } from 'claude-code'
import { describe, expect, mock, test, type Engine } from 'claude-code/testing'

import { carryText, parseSwitch, switchPath } from '../hooks/register'

const PLUGIN = 'firstmate-context-handoff'
const CONFIG = '/fm/home/config'
const SWITCH = `${CONFIG}/context-handoff`
const STOCK = 'STOCK-DRAWING'
const CARRYING = /^carrying \d+ characters of stow receipt/
const RECEIPT = 'Stow receipt: nothing lost. Codeword PELICAN-42.'

type Journal = {
  commands: { command: string; args?: string }[]
  fills: string[]
  toasts: string[]
  reads: string[]
  usageReads: number
  commandLists: number
  logs: string[]
}

type WorldOptions = {
  env?: Record<string, string>
  commands?: string[]
  /** The stored switch file; undefined means absent. */
  switch?: string | undefined
  refuse?: string[]
  failCommandList?: boolean
  /** Holds /stow in the queue until this resolves, as a running turn does. */
  stowDequeued?: Promise<void>
}

function world(on: On, options: WorldOptions = {}) {
  mock.env(on, { HOME: '/Users/me', FM_CONFIG_OVERRIDE: CONFIG, ...(options.env ?? {}) })
  const clock = mock.clock(on, { now: 1_000_000 })
  const journal: Journal = { commands: [], fills: [], toasts: [], reads: [], usageReads: 0, commandLists: 0, logs: [] }
  const stored = 'switch' in options ? options.switch : 'on\n'
  const names = options.commands ?? ['stow', 'clear', 'handoff', 'compact']
  on('command.list', async () => {
    journal.commandLists += 1
    if (options.failCommandList) throw new Error('command list unavailable')
    return { value: names.map(name => ({ name, description: name, source: 'builtin' as const })) }
  })
  on('command.run', async (_$, e) => {
    if (options.refuse?.includes(e.command)) throw new Error(`refused ${e.command}`)
    if (e.command === 'stow' && options.stowDequeued) await options.stowDequeued
    journal.commands.push({ command: e.command, ...(e.args ? { args: e.args } : {}) })
    return {}
  })
  on('session.usage', async () => {
    journal.usageReads += 1
    return { value: { startedAt: 0, context: { tokens: undefined, window: 1_000_000 }, rateLimits: [] } }
  })
  on('fs.read', async (_$, e) => {
    journal.reads.push(e.path)
    if (e.path === SWITCH && stored !== undefined) return { value: stored }
    return { deny: `ENOENT: ${e.path}` }
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
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [STOCK] }))
  return { clock, journal }
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

describe('helpers', () => {
  test('resolves the switch like config/calm and reads only on as on', async () => {
    expect(switchPath({ FM_HOME: '/h' }, '/code/.claude/mods/firstmate-context-handoff')).toBe('/h/config/context-handoff')
    expect(switchPath({ FM_ROOT_OVERRIDE: '/r' }, '/code/.claude/mods/firstmate-context-handoff')).toBe('/r/config/context-handoff')
    expect(switchPath({ FM_HOME: '/h', FM_CONFIG_OVERRIDE: '/c' }, '/x')).toBe('/c/context-handoff')
    expect(switchPath({}, '/code/.claude/mods/firstmate-context-handoff')).toBe('/code/config/context-handoff')
    expect(switchPath({}, '/code/.claude/skills/firstmate-context-handoff')).toBe('/code/config/context-handoff')
    expect(parseSwitch('on\n')).toBe(true)
    expect(parseSwitch('  on ')).toBe(true)
    expect(parseSwitch('off\n')).toBe(false)
    expect(parseSwitch('yes')).toBe(false)
    expect(parseSwitch(undefined)).toBe(false)
    expect(carryText(252_000, '  ')).toContain('(the /stow turn left no receipt text)')
  })
})

describe('switch', () => {
  test('absent: stays inert past 250k and never lists commands', async ($, on) => {
    const { journal } = world(on, { switch: undefined })
    await measure($, 400_000)
    expect(isStock(await band($))).toBe(true)
    expect(journal.commandLists).toBe(0)
    expect(journal.commands).toHaveLength(0)
  })

  test('off: stays inert past 250k', async ($, on) => {
    const { journal } = world(on, { switch: 'off\n' })
    await measure($, 400_000)
    expect(isStock(await band($))).toBe(true)
    expect(journal.commands).toHaveLength(0)
  })

  test('is not read below the threshold', async ($, on) => {
    const { journal } = world(on)
    await measure($, 249_999)
    await measure($, 120_000)
    expect(journal.reads).toHaveLength(0)
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
    expect(journal.reads).toHaveLength(0)
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

  test('a refused /stow brings the offer back with a toast', async ($, on) => {
    const { journal } = world(on, { refuse: ['stow'] })
    await measure($, 300_000)
    await band($)
    await $.ui.press({ plugin: PLUGIN, key: 'stow' })
    expect(journal.toasts[0]).toContain('type /stow yourself')
    expect(shown(await band($))).toContain('Write handoff (/stow)')
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
})

describe('other session kinds', () => {
  test('a secondmate runs /stow itself once per crossing and draws no button', async ($, on) => {
    const { journal, clock } = world(on, { env: { COMPACT_ADVISER_DISABLE: '1' } })
    await measure($, 400_000)
    expect(journal.commands).toHaveLength(0)
    await clock.settle()
    expect(journal.commands).toEqual([{ command: 'stow' }])
    expect(isStock(await band($))).toBe(true)
    await measure($, 410_000)
    await clock.settle()
    expect(journal.commands).toHaveLength(1)
    await measure($, 30_000)
    await measure($, 255_000)
    await clock.settle()
    expect(journal.commands).toHaveLength(2)
  })

  test('a secondmate with the switch off does nothing', async ($, on) => {
    const { journal, clock } = world(on, { env: { COMPACT_ADVISER_DISABLE: '1' }, switch: undefined })
    await measure($, 400_000)
    await clock.settle()
    expect(journal.commands).toHaveLength(0)
  })

  test('a ship or scout worker is left to its own mod: no button, no command, no switch read', async ($, on) => {
    const { journal, clock } = world(on, { env: { FM_TASK_ID: 'fix-thing-k3', COMPACT_ADVISER_DISABLE: '1' } })
    await measure($, 400_000)
    await clock.settle()
    expect(isStock(await band($))).toBe(true)
    expect(journal.commands).toHaveLength(0)
    expect(journal.reads).toHaveLength(0)
  })
})

describe('failure', () => {
  test('a failing engine call passes every event through and goes quiet', async ($, on) => {
    const { journal } = world(on, { failCommandList: true })
    expect(await measure($, 300_000)).toEqual({ changed: ['context'] })
    expect(isStock(await band($))).toBe(true)
    await measure($, 320_000)
    expect(journal.commandLists).toBe(1)
  })
})
