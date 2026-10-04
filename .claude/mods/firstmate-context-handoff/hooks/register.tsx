// firstmate-context-handoff: an early, optional context-reset courtesy for the sessions
// that load this repository's project mods - the captain's main window and a secondmate.
//
// When the session has used THRESHOLD tokens of context (consumption, not remaining),
// and the per-home `config/context-handoff` switch is on, it acts by session kind, told
// apart only by what fm-spawn already sets at launch:
// - main window (no FM_TASK_ID, no COMPACT_ADVISER_DISABLE=1, /stow available): a band
//   above the prompt offers /stow; once the stow turn ends it offers a clear, which
//   runs /clear and appends the stow receipt to the fresh session as a row the model
//   reads and the person does not see.
// - secondmate (COMPACT_ADVISER_DISABLE=1 without FM_TASK_ID, /stow available): nobody
//   watches its pane, so it runs /stow itself, once per crossing, and shows nothing.
// - anything else stays inert: a ship or scout worker (FM_TASK_ID set) is served by the
//   separate firstmate-context-handoff-worker mod fm-spawn loads for it, and a session
//   without /stow is not a Firstmate session.
//
// The switch and the kind are read at each crossing, never below the threshold.
// It hooks no classic.* event, never answers an event in place of the engine, and
// wraps its own work in try/catch around `next(e)`, so a failure here leaves the
// session as it would be without the mod. docs/context-handoff.md owns the contract.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { carryText, kTokens, parseSwitch, switchPath } from '../lib/fm-context-handoff'
import type { HandoffPhase } from '../types'

const THRESHOLD = 250_000

const phase = atom({ plugin: 'firstmate-context-handoff', key: 'phase' } as const, 'idle' as HandoffPhase)
const usedTokens = atom({ plugin: 'firstmate-context-handoff', key: 'usedTokens' } as const, 0)

type Kind = { kind: 'main' } | { kind: 'secondmate' } | { kind: 'inert'; why: string }

// Module state: a reload starts it over, like any module variable. `mirror` copies
// the band's $.state phase so the per-turn check needs no $ call below the threshold.
const S: {
  kind: Promise<Kind> | undefined
  mirror: HandoffPhase
  receipt: string | undefined
  carryPending: string | undefined
  stowRunning: boolean
  firing: boolean
} = {
  kind: undefined,
  mirror: 'idle',
  receipt: undefined,
  carryPending: undefined,
  stowRunning: false,
  firing: false,
}

function debug($: EngineInterface, text: string): void {
  try {
    $.ui.log(text, { to: 'debug' })
  } catch {
    // Best effort.
  }
}

async function setPhase($: EngineInterface, next: HandoffPhase): Promise<void> {
  S.mirror = next
  await update($, phase, () => next)
}

async function switchedOn($: EngineInterface): Promise<boolean> {
  const path = switchPath(
    {
      FM_HOME: await $.env.get('FM_HOME'),
      FM_ROOT_OVERRIDE: await $.env.get('FM_ROOT_OVERRIDE'),
      FM_CONFIG_OVERRIDE: await $.env.get('FM_CONFIG_OVERRIDE'),
    },
    $.plugin.root,
  )
  try {
    return parseSwitch(await $.fs.read(path))
  } catch {
    return false
  }
}

async function detect($: EngineInterface): Promise<Kind> {
  if (await $.env.get('FM_TASK_ID')) return { kind: 'inert', why: 'a ship or scout worker; its own mod serves it' }
  if (!(await switchedOn($))) return { kind: 'inert', why: 'config/context-handoff is not on' }
  const names = new Set((await $.command.list()).map(c => c.name))
  if (!names.has('stow')) return { kind: 'inert', why: 'no /stow in this session' }
  return (await $.env.get('COMPACT_ADVISER_DISABLE')) === '1' ? { kind: 'secondmate' } : { kind: 'main' }
}

async function kindOf($: EngineInterface): Promise<Kind> {
  S.kind ??= detect($).catch((error: unknown): Kind => ({ kind: 'inert', why: String(error) }))
  return S.kind
}

/** The per-turn check: below the threshold and already idle, no $ call at all. */
async function check($: EngineInterface, used: number | undefined): Promise<void> {
  if (used === undefined) return
  if (used < THRESHOLD) {
    // A /clear or a compaction brought the window back under: arm again.
    if (S.mirror !== 'idle' && S.mirror !== 'clearing') await rearm($)
    return
  }
  if (S.mirror !== 'idle' || S.firing) return
  S.firing = true // claim the crossing before the first await
  try {
    const kind = await kindOf($)
    debug($, `crossed ${used} of ${THRESHOLD} tokens; kind ${kind.kind}${kind.kind === 'inert' ? ` (${kind.why})` : ''}`)
    if (kind.kind === 'main') {
      await update($, usedTokens, () => used)
      await setPhase($, 'suggest')
    } else if (kind.kind === 'secondmate') {
      // Nothing more this window: one self-run /stow, no band.
      await setPhase($, 'dismissed')
      // Outside the measuring dispatch: a direct call there holds it until dequeued.
      $.clock.after(0, () => {
        $.command.run({ command: 'stow' }).catch((error: unknown) => debug($, `secondmate /stow refused: ${String(error)}`))
      })
    } else {
      await setPhase($, 'dismissed')
    }
  } catch (error) {
    S.mirror = 'dismissed' // any failure: stay quiet until the window drops back under
    throw error
  } finally {
    S.firing = false
  }
}

async function rearm($: EngineInterface): Promise<void> {
  S.kind = undefined // the next crossing reads the switch and the kind again
  S.stowRunning = false
  S.receipt = undefined
  await setPhase($, 'idle')
}

/** A fresh or resumed session starts with no crossing in flight: wipe every mutable field. */
async function resetSession($: EngineInterface): Promise<void> {
  S.kind = undefined
  S.stowRunning = false
  S.firing = false
  S.receipt = undefined
  await setPhase($, 'idle')
  await update($, usedTokens, () => 0)
}

async function carry($: EngineInterface): Promise<void> {
  const text = S.carryPending
  if (text === undefined) return
  S.carryPending = undefined
  debug($, `carrying ${text.length} characters of stow receipt into the fresh session`)
  await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })
  debug($, 'carried the stow receipt into the fresh session')
}

async function pressStow($: EngineInterface): Promise<void> {
  await setPhase($, 'stowing')
  try {
    // Resolves when /stow is dequeued, after any turn already running or queued, so
    // the next main-loop turn to complete is the stow turn and not, say, a fleet wake.
    await $.command.run({ command: 'stow' })
    S.stowRunning = true
  } catch (error) {
    debug($, `/stow refused: ${String(error)}`)
    await setPhase($, 'suggest')
    $.ui.toast('The handoff could not start; type /stow yourself.')
  }
}

async function pressClear($: EngineInterface): Promise<void> {
  S.carryPending = carryText(await read($, usedTokens), S.receipt ?? '')
  await setPhase($, 'clearing')
  try {
    await $.command.run({ command: 'clear' })
  } catch (error) {
    // Fallback: the keystroke stays the person's; session.end carries the receipt.
    debug($, `/clear refused: ${String(error)}`)
    S.carryPending = undefined
    await setPhase($, 'ready')
    await $.prompt.fill({ text: '/clear' })
    $.ui.toast('Press Enter to clear; the handoff follows into the new session.')
    return
  }
  try {
    await carry($)
  } catch (error) {
    // The session is already fresh; a lost carry leaves it a plain /clear.
    debug($, `carry failed: ${String(error)}`)
  }
}

async function guarded($: EngineInterface, label: string, work: () => Promise<void>): Promise<void> {
  try {
    await work()
  } catch (error) {
    debug($, `${label}: ${String(error)}`)
  }
}

export const register: Register = on => {
  // A resumed or continued session can reuse this module's state from an earlier
  // session's lifetime; wipe it before anything else reads or writes it.
  on('session.start', async ($, e, next) => {
    await guarded($, 'session.start', () => resetSession($))
    return next(e)
  })

  // The cheap trigger: pushed after each main-thread turn, the figures in `e`.
  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('context')) await guarded($, 'measure', () => check($, e.context.tokens))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && S.stowRunning && S.mirror === 'stowing') {
      S.stowRunning = false
      await guarded($, 'turn.complete', async () => {
        if (e.isAborted) {
          await setPhase($, 'suggest')
        } else {
          S.receipt = e.answer
          await setPhase($, 'ready')
        }
      })
    }
    return next(e)
  })

  // /stow typed by hand while the offer is up counts as the button.
  on('command.run', { command: 'stow' }, async ($, e, next) => {
    if (S.mirror === 'suggest' || S.mirror === 'stowing') {
      S.stowRunning = true
      await guarded($, 'command.run', () => setPhase($, 'stowing'))
    }
    return next(e)
  })

  // A /clear typed by hand, or from the fallback fill, still carries the receipt.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    if (e.reason !== 'clear') return result
    await guarded($, 'session.end', async () => {
      const was = S.mirror
      S.kind = undefined
      if (was === 'ready') {
        S.carryPending = carryText(await read($, usedTokens), S.receipt ?? '')
        $.clock.after(0, () => void carry($).catch((error: unknown) => debug($, `carry failed: ${String(error)}`)))
      }
      if (was !== 'idle') await rearm($)
    })
    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Always read the phase, even while idle: the read subscribes this band, so the
    // crossing's $.state write redraws it. Gating on the local mirror skips that.
    const current = await read($, phase)
    if (e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    if (current === 'stowing') {
      return (
        <Box>
          <Text dimColor>Writing the handoff with /stow…</Text>
        </Box>
      )
    }
    const notNow = <Button key="dismiss" hotkey="x" role="dismiss" label="Not now" onPress={() => setPhase($, 'dismissed')} />
    if (current === 'suggest') {
      return (
        <Box gap={1}>
          <Text>{`${kTokens(await read($, usedTokens))} tokens of context used. A fresh session would start lighter.`}</Text>
          <Button key="stow" hotkey="s" variant="primary" label="Write handoff (/stow)" onPress={() => pressStow($)} />
          {notNow}
        </Box>
      )
    }
    if (current === 'ready') {
      return (
        <Box gap={1}>
          <Text>Handoff written.</Text>
          <Button key="clear" hotkey="c" variant="primary" label="Clear and carry handoff" onPress={() => pressClear($)} />
          {notNow}
        </Box>
      )
    }
    return next(e)
  })
}
