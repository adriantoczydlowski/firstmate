import type { Args, On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { parseSnapshot, parseWakeQueue, summary } from '../hooks/fleet'

const HOME = '/fm'

const SNAPSHOT = JSON.stringify({
  schema: 'fm-fleet-snapshot.v1',
  generated: '2026-10-08T19:46:19Z',
  fm_home: HOME,
  backlog: { records: [{ state: 'in_flight' }, { state: 'in_flight' }, { state: 'queued' }, { state: 'done' }] },
  tasks: [
    {
      id: 'fix-login',
      kind: 'ship',
      current_state: { state: 'working', source: 'pane', detail: 'harness busy' },
      paths: { status_log: { last_event: { raw: 'working [at=1]: setup done', age_seconds: 300 } } },
      backlog: { title: 'Fix the login' },
      hints: { pending_decision: false },
      pr: { url: null },
    },
    {
      id: 'audit-auth',
      kind: 'scout',
      current_state: { state: 'blocked', source: 'status-log', detail: 'needs the staging token' },
      paths: { status_log: { last_event: { raw: 'needs-decision [at=2]: pick A or B', age_seconds: 90 } } },
      backlog: { title: 'Audit auth' },
      hints: { pending_decision: true },
      pr: { url: 'https://github.com/o/r/pull/7' },
    },
  ],
})

const QUEUE = ['1791488000\t41\tsignal\tfix-login\tworking: setup done', '1791488100\t42\tcheck\tmerge-poll\t'].join('\n') + '\n'

const PANE_PROPS = {
  title: 'Firstmate fleet',
  isFocused: false,
  bodyColumns: 80,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

function engine(on: On, cwd = HOME) {
  const runs: Args<'process.run'>[] = []
  const writes: string[] = []
  const statuses: (string | undefined)[] = []
  mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('env.get', () => ({ value: undefined }))
  on('session.cwd', () => ({ value: cwd }))
  on('process.run', ($, e) => {
    runs.push(e)
    return { value: { exitCode: 0, stdout: SNAPSHOT, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.exists', ($, e) => ({ value: e.path === `${HOME}/state/.wake-queue` }))
  on('fs.read', ($, e) => ({ value: e.path === `${HOME}/state/.wake-queue` ? QUEUE : '' }))
  on('fs.write', ($, e) => {
    writes.push(e.path)
    return { value: undefined }
  })
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', ($, e) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  return { runs, writes, statuses }
}

describe('fleet parsing', () => {
  test('the snapshot reduces to tasks and backlog counts', () => {
    const fleet = parseSnapshot(SNAPSHOT)
    expect(fleet.tasks.map(task => [task.id, task.state, task.hasOpenDecision])).toEqual([
      ['fix-login', 'working', false],
      ['audit-auth', 'blocked', true],
    ])
    expect([fleet.inFlight, fleet.queued]).toEqual([2, 1])
    expect(() => parseSnapshot('{"schema":"other"}')).toThrow()
  })

  test('wake queue rows keep their payload, short rows are skipped', () => {
    const rows = parseWakeQueue(QUEUE + 'garbage\n')
    expect(rows.map(row => [row.seq, row.kind, row.key, row.payload])).toEqual([
      [41, 'signal', 'fix-login', 'working: setup done'],
      [42, 'check', 'merge-poll', ''],
    ])
    expect(summary(parseSnapshot(SNAPSHOT), rows)).toBe('fleet: 1 working · 1 blocked · wakes 2')
  })
})

describe('firstmate-fleet-panel', () => {
  test(
    'the pane draws the snapshot and the wake queue, and nothing is written',
    { options: { fmHome: HOME } },
    async ($, on) => {
      const world = engine(on)
      await $.session.start({ cwd: '/elsewhere', surface: 'terminal', isInteractive: true })
      await $.command.run({
        command: 'fleet',
        args: '',
        origin: { kind: 'composer' },
        presentation: { isFullscreen: true, columns: 160 },
      })

      expect(world.runs.length).toBeGreaterThan(0)
      expect(world.runs.every(run => run.argv[0] === `${HOME}/bin/fm-fleet-snapshot.sh` && run.argv[1] === '--json')).toBe(
        true,
      )
      expect(world.writes, 'read only').toEqual([])

      for (const surface of ['terminal', 'desktop'] as const) {
        const ui = await $.ui.mount({
          plugin: 'firstmate-fleet-panel',
          surface,
          component: 'Pane',
          requestId: 'firstmate-fleet',
          props: PANE_PROPS,
        })
        // The command starts the snapshot in the background; the button runs it and waits.
        await ui.press({ key: 'refresh' })
        const texts = (await ui.findAll({ type: 'Text' })).map(found => found.text)
        expect(texts.some(text => text.includes('fix-login') && text.includes('ship'))).toBe(true)
        expect(texts.some(text => text.includes('audit-auth') && text.includes('decision open'))).toBe(true)
        expect(texts.some(text => text.includes('needs the staging token'))).toBe(true)
        expect(texts.some(text => text.includes('last event') && text.includes('pick A or B'))).toBe(true)
        expect(texts).toContain('Wake queue · 2')
        expect(texts.some(text => text.includes('#42') && text.includes('merge-poll'))).toBe(true)
        expect(texts.some(text => text.includes('2 in flight · 1 queued'))).toBe(true)
      }
      expect(world.statuses.at(-1)).toBe('fleet: 1 working · 1 blocked · wakes 2')
    },
  )

  // A /clear goes on under a new session: its state reads empty and no
  // session.start fires, so /fleet must find the home on its own.
  test('after a /clear, /fleet observes the session directory', async ($, on) => {
    const world = engine(on)
    const opened = await $.command.run({
      command: 'fleet',
      args: '',
      origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 160 },
    })
    expect(opened).toEqual({ text: `Firstmate fleet: observing ${HOME}` })

    const ui = await $.ui.mount({
      plugin: 'firstmate-fleet-panel',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'firstmate-fleet',
      props: PANE_PROPS,
    })
    await ui.press({ key: 'refresh' })
    const texts = (await ui.findAll({ type: 'Text' })).map(found => found.text)
    expect(world.runs.length).toBeGreaterThan(0)
    expect(world.runs.every(run => run.argv[0] === `${HOME}/bin/fm-fleet-snapshot.sh` && run.init?.cwd === HOME)).toBe(true)
    expect(texts.some(text => text.startsWith('snapshot failed'))).toBe(false)
    expect(texts.some(text => text.includes('fix-login') && text.includes('ship'))).toBe(true)
  })

  test('with no home to observe, the pane says so and runs nothing', async ($, on) => {
    const world = engine(on, '')
    const opened = await $.command.run({
      command: 'fleet',
      args: '',
      origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 160 },
    })
    expect(opened.text).toContain('no Firstmate home to observe')

    const ui = await $.ui.mount({
      plugin: 'firstmate-fleet-panel',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'firstmate-fleet',
      props: PANE_PROPS,
    })
    await ui.press({ key: 'refresh' })
    const texts = (await ui.findAll({ type: 'Text' })).map(found => found.text)
    expect(world.runs).toEqual([])
    expect(texts.some(text => text.includes('no Firstmate home to observe: set the fmHome option or FM_HOME'))).toBe(true)
    expect(texts.some(text => text.includes('init.cwd'))).toBe(false)
  })
})
