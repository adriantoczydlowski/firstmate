// Reduces Firstmate's own read surfaces to what the pane draws.
// Pure: no `$`, so the tests read it directly.
//
// The fleet comes from bin/fm-fleet-snapshot.sh --json (schema
// fm-fleet-snapshot.v1), the structured contract Firstmate's human views
// render; this file never re-derives a task's state from state/ files.
// The wake queue is state/.wake-queue, one tab-separated row per pending
// wake (epoch, sequence, kind, key, payload) as bin/fm-wake-lib.sh appends it.

import type { CrewState, Fleet, FleetTask, WakeRow } from '../types'

const STATES: readonly CrewState[] = ['working', 'parked', 'done', 'blocked', 'paused', 'failed', 'unknown']

type Json = Record<string, unknown>

const obj = (value: unknown): Json => (value !== null && typeof value === 'object' ? (value as Json) : {})
const str = (value: unknown): string => (typeof value === 'string' ? value : '')
const num = (value: unknown): number | null => (typeof value === 'number' ? value : null)

function taskOf(raw: unknown): FleetTask {
  const task = obj(raw)
  const current = obj(task.current_state)
  const last = obj(obj(obj(task.paths).status_log).last_event)
  const backlog = obj(task.backlog)
  const state = str(current.state) as CrewState
  return {
    id: str(task.id),
    kind: str(task.kind),
    title: str(backlog.title),
    state: STATES.includes(state) ? state : 'unknown',
    source: str(current.source),
    detail: str(current.detail),
    lastEvent: str(last.raw),
    lastEventAge: num(last.age_seconds),
    hasOpenDecision: obj(task.hints).pending_decision === true,
    prUrl: str(obj(task.pr).url) || null,
  }
}

/** Throws when the text is not a v1 snapshot. */
export function parseSnapshot(text: string): Fleet {
  const snapshot = obj(JSON.parse(text))
  if (snapshot.schema !== 'fm-fleet-snapshot.v1') {
    throw new Error(`unexpected snapshot schema ${JSON.stringify(snapshot.schema)}`)
  }
  const records = Array.isArray(obj(snapshot.backlog).records) ? (obj(snapshot.backlog).records as unknown[]) : []
  const states = records.map(record => str(obj(record).state))
  return {
    generated: str(snapshot.generated),
    home: str(snapshot.fm_home),
    tasks: (Array.isArray(snapshot.tasks) ? snapshot.tasks : []).map(taskOf),
    inFlight: states.filter(state => state === 'in_flight').length,
    queued: states.filter(state => state === 'queued').length,
  }
}

/** Rows that do not carry five tab-separated fields are skipped. */
export function parseWakeQueue(text: string): WakeRow[] {
  const rows: WakeRow[] = []
  for (const line of text.split('\n')) {
    const fields = line.split('\t')
    if (fields.length < 5) continue
    const [epoch, seq, kind, key, ...payload] = fields as [string, string, string, string, ...string[]]
    rows.push({ epoch: Number(epoch), seq: Number(seq), kind, key, payload: payload.join('\t') })
  }
  return rows
}

/** `42s`, `5m`, `3h`, `2d`. */
export function age(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds) || seconds < 0) return '?'
  if (seconds < 60) return `${Math.floor(seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`
  return `${Math.floor(seconds / 86400)}d`
}

/** The one-line summary the status line carries. */
export function summary(fleet: Fleet | null, wakes: readonly WakeRow[]): string {
  if (fleet === null) return `fleet: ? · wakes ${wakes.length}`
  const counts = new Map<CrewState, number>()
  for (const task of fleet.tasks) counts.set(task.state, (counts.get(task.state) ?? 0) + 1)
  const parts = STATES.filter(state => counts.has(state)).map(state => `${counts.get(state)} ${state}`)
  return `fleet: ${parts.length === 0 ? 'idle' : parts.join(' · ')} · wakes ${wakes.length}`
}
