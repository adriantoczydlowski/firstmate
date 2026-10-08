/** A task's current state as bin/fm-crew-state.sh names it. */
export type CrewState = 'working' | 'parked' | 'done' | 'blocked' | 'paused' | 'failed' | 'unknown'

/** One row of the fleet snapshot's tasks[], reduced to what the pane draws. */
export type FleetTask = {
  id: string
  kind: string
  title: string
  state: CrewState
  source: string
  detail: string
  /** The latest status-log line: a wake event, not current state. */
  lastEvent: string
  lastEventAge: number | null
  hasOpenDecision: boolean
  prUrl: string | null
}

/** The part of one fm-fleet-snapshot.sh --json run the pane draws. */
export type Fleet = {
  generated: string
  home: string
  tasks: FleetTask[]
  inFlight: number
  queued: number
}

/** One row of state/.wake-queue: epoch, sequence, kind, key, payload. */
export type WakeRow = {
  epoch: number
  seq: number
  kind: string
  key: string
  payload: string
}

/** What the last refresh read, and when, in `$.clock.now()` milliseconds. */
export type Reading = {
  fleet: Fleet | null
  fleetError: string
  fleetAt: number
  wakes: WakeRow[]
  wakesError: string
  wakesAt: number
  isRefreshing: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'firstmate-fleet-panel': {
      home: string
      reading: Reading
      now: number
    }
  }
}
