// Firstmate Fleet: a read-only pane over Firstmate's own fleet state.
//
// It runs bin/fm-fleet-snapshot.sh --json (the structured contract Firstmate's
// own fleet view renders) and reads state/.wake-queue. It never drains or
// acknowledges a wake, steers a worker, or edits the backlog: it only reads.
//
// Refresh: the wake queue is one small file, read every 5 seconds. The
// snapshot asks every task's current state (about 5-7 seconds per run), so it
// runs once at session start, every 30 seconds while the pane is open, and on
// the pane's Refresh button; one run at a time.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CrewState, Reading } from '../types'
import { age, parseSnapshot, parseWakeQueue, summary } from './fleet'

const PANE = 'firstmate-fleet'
const TITLE = 'Firstmate fleet'
const WAKES_EVERY_MS = 5_000
const FLEET_EVERY_MS = 30_000
const SNAPSHOT_TIMEOUT_MS = 60_000
const WAKES_SHOWN = 8
const NO_HOME = 'no Firstmate home to observe: set the fmHome option or FM_HOME, or start Claude Code in a Firstmate home'

const EMPTY: Reading = {
  fleet: null,
  fleetError: '',
  fleetAt: 0,
  wakes: [],
  wakesError: '',
  wakesAt: 0,
  isRefreshing: false,
}

const home = atom({ plugin: 'firstmate-fleet-panel', key: 'home' } as const, '')
const reading = atom({ plugin: 'firstmate-fleet-panel', key: 'reading' } as const, EMPTY)
const now = atom({ plugin: 'firstmate-fleet-panel', key: 'now' } as const, 0)

const GLYPH: Record<CrewState, { glyph: string; color: string }> = {
  working: { glyph: '●', color: 'green' },
  parked: { glyph: '◌', color: 'gray' },
  paused: { glyph: '◷', color: 'yellow' },
  blocked: { glyph: '■', color: 'red' },
  failed: { glyph: '✗', color: 'red' },
  done: { glyph: '✓', color: 'cyan' },
  unknown: { glyph: '?', color: 'gray' },
}

async function showStatus($: EngineInterface): Promise<void> {
  const r = await read($, reading)
  $.ui.status(summary(r.fleet, r.wakes))
}

// The observed home: the fmHome option, else $FM_HOME, else the session's
// directory, held in `home` once found. It is found when first needed, not
// only in session.start: a /clear goes on under a new session whose `home`
// reads empty, and no session.start fires for it. Empty when nothing names one.
async function fleetHome($: EngineInterface, configured: string): Promise<string> {
  const held = await read($, home)
  if (held !== '') return held
  const found = configured || (await $.env.get('FM_HOME')) || (await $.session.cwd())
  const root = (found ?? '').replace(/\/+$/, '')
  if (root !== '') await update($, home, () => root)
  return root
}

async function refreshWakes($: EngineInterface, configured: string): Promise<void> {
  const root = await fleetHome($, configured)
  const path = `${root}/state/.wake-queue`
  let wakes = EMPTY.wakes
  let wakesError = ''
  try {
    if (root !== '' && (await $.fs.exists(path))) wakes = parseWakeQueue(await $.fs.read(path))
  } catch (error) {
    wakesError = String(error)
  }
  const at = await $.clock.now()
  await update($, reading, r => ({ ...r, wakes, wakesError, wakesAt: at }))
  await update($, now, () => at)
  await showStatus($)
}

async function refreshFleet($: EngineInterface, configured: string): Promise<void> {
  if ((await read($, reading)).isRefreshing) return
  await update($, reading, r => ({ ...r, isRefreshing: true }))
  let fleet: Reading['fleet'] = null
  let fleetError = ''
  try {
    const root = await fleetHome($, configured)
    if (root === '') throw new Error(NO_HOME)
    const ran = await $.process.run([`${root}/bin/fm-fleet-snapshot.sh`, '--json'], {
      cwd: root,
      // FM_CREW_STATE_NO_FORGE keeps each task's state read local: no forge calls.
      env: { FM_HOME: root, FM_CREW_STATE_NO_FORGE: '1' },
      timeoutMs: SNAPSHOT_TIMEOUT_MS,
    })
    if (ran.exitCode !== 0) throw new Error(ran.stderr.trim().split('\n').at(-1) || `exit ${ran.exitCode}`)
    fleet = parseSnapshot(ran.stdout)
  } catch (error) {
    fleetError = String(error instanceof Error ? error.message : error)
  }
  const at = await $.clock.now()
  await update($, reading, r => ({
    ...r,
    fleet: fleet ?? r.fleet,
    fleetError,
    fleetAt: fleet === null ? r.fleetAt : at,
    isRefreshing: false,
  }))
  await showStatus($)
}

const isPaneOpen = async ($: EngineInterface) => (await $.ui.panes()).some(pane => pane.id === PANE)

export const register: Register = (on, options) => {
  const configured = typeof options.fmHome === 'string' ? options.fmHome : ''

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'fleet',
      description: "Show or hide a read-only pane of Firstmate's tasks in flight and wake queue",
    })

    $.clock.every(WAKES_EVERY_MS, () => void refreshWakes($, configured).catch(() => undefined))
    $.clock.every(FLEET_EVERY_MS, () => {
      void (async () => {
        if (await isPaneOpen($)) await refreshFleet($, configured)
      })().catch(() => undefined)
    })
    void refreshWakes($, configured).catch(() => undefined)
    void refreshFleet($, configured).catch(() => undefined)
    return started
  })

  on('command.run', { command: 'fleet' }, async $ => {
    if (await isPaneOpen($)) {
      await $.ui.close({ id: PANE })
      return { text: 'Firstmate fleet pane closed.' }
    }
    await $.ui.open({ id: PANE, title: TITLE })
    void refreshFleet($, configured).catch(() => undefined)
    const root = await fleetHome($, configured)
    return { text: root === '' ? `Firstmate fleet: ${NO_HOME}` : `Firstmate fleet: observing ${root}` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const r = await read($, reading)
    const at = await read($, now)
    const root = await read($, home)
    const fleet = r.fleet
    const tasks = fleet?.tasks ?? []
    const wakes = r.wakes.slice(-WAKES_SHOWN).reverse()
    const snapshotAge = fleet === null ? null : Math.max(0, (at - r.fleetAt) / 1000)

    return (
      <Box flexDirection="column">
        <Text bold wrap="truncate-start">
          {root}
        </Text>
        <Text dimColor>
          backlog: {fleet?.inFlight ?? '?'} in flight · {fleet?.queued ?? '?'} queued · snapshot{' '}
          {fleet === null ? 'pending' : `${age(snapshotAge)} ago`}
        </Text>
        {r.fleetError !== '' && (
          <Text color="red" wrap="truncate-end">
            snapshot failed: {r.fleetError}
          </Text>
        )}

        <Box marginTop={1}>
          <Text bold>Tasks · {tasks.length}</Text>
        </Box>
        {fleet !== null && tasks.length === 0 && <Text dimColor>No tasks in flight.</Text>}
        {tasks.map(task => {
          const look = GLYPH[task.state]
          return (
            <Box key={`t:${task.id}`} flexDirection="column">
              <Text wrap="truncate-end">
                <Text color={look.color}>{look.glyph} </Text>
                <Text bold>{task.id}</Text>
                <Text dimColor> {task.kind}</Text>
                {task.hasOpenDecision && <Text color="magenta"> · decision open</Text>}
              </Text>
              <Text wrap="truncate-end">
                {'  '}
                <Text color={look.color}>{task.state}</Text>
                <Text dimColor>
                  {' '}
                  via {task.source}
                  {task.detail === '' ? '' : ` · ${task.detail}`}
                </Text>
              </Text>
              {task.lastEvent !== '' && (
                <Text dimColor wrap="truncate-end">
                  {'  '}last event ({age(task.lastEventAge)} ago): {task.lastEvent}
                </Text>
              )}
              {task.prUrl !== null && (
                <Text color="blue" wrap="truncate-end">
                  {'  '}
                  {task.prUrl}
                </Text>
              )}
            </Box>
          )
        })}

        <Box marginTop={1}>
          <Text bold>Wake queue · {r.wakes.length}</Text>
        </Box>
        {r.wakesError !== '' && (
          <Text color="red" wrap="truncate-end">
            wake queue unreadable: {r.wakesError}
          </Text>
        )}
        {r.wakes.length === 0 && r.wakesError === '' && <Text dimColor>Empty: nothing waiting for firstmate.</Text>}
        {wakes.map(wake => (
          <Text key={`w:${wake.seq}`} wrap="truncate-end">
            <Text color="yellow">#{wake.seq} </Text>
            <Text bold>{wake.kind}</Text>
            <Text> {wake.key}</Text>
            <Text dimColor>
              {' '}
              {age(at / 1000 - wake.epoch)} ago{wake.payload === '' ? '' : ` · ${wake.payload}`}
            </Text>
          </Text>
        ))}
        {r.wakes.length > WAKES_SHOWN && <Text dimColor>… {r.wakes.length - WAKES_SHOWN} older</Text>}
        <Box marginTop={1} flexDirection="row" gap={1}>
          <Button key="refresh" label={r.isRefreshing ? 'refreshing…' : 'refresh'} hotkey="r" onPress={() => refreshFleet($, configured)} />
          <Text dimColor>read only · wakes every 5s · fleet every 30s while open</Text>
        </Box>
      </Box>
    )
  })
}
