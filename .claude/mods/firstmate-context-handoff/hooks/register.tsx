// firstmate-context-handoff (prototype): an early, optional context-reset courtesy.
//
// When the session has used THRESHOLD tokens of context (consumption, not remaining),
// it acts by session kind, told apart only by what fm-spawn already sets at launch:
// - main window (no FM_TASK_ID, no COMPACT_ADVISER_DISABLE=1, /stow available): a band
//   above the prompt offers /stow; once the stow turn ends it offers a clear, which
//   runs /clear and appends the stow receipt to the fresh session as a row the model
//   reads and the person does not see.
// - Firstmate worker (FM_TASK_ID set, /handoff available): no button. The session
//   writes its own handoff to <home>/data/<task>/handoff.md (home read from the status
//   path its launch brief names) and, once that file exists, appends one line to its
//   own status file, the channel every other worker event already uses.
// - anything else (a secondmate: COMPACT_ADVISER_DISABLE=1 without FM_TASK_ID, or a
//   session with neither command) stays inert.
//
// It hooks no classic.* event, never answers an event in place of the engine, and
// wraps its own work in try/catch around `next(e)`, so a failure here leaves the
// session as it would be without the mod.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { HandoffPhase } from '../types'

const PLUGIN = 'firstmate-context-handoff'
const THRESHOLD = 250_000

const phase = atom({ plugin: 'firstmate-context-handoff', key: 'phase' } as const, 'idle' as HandoffPhase)
const usedTokens = atom({ plugin: 'firstmate-context-handoff', key: 'usedTokens' } as const, 0)

type Kind = { kind: 'main' } | { kind: 'crew'; taskId: string } | { kind: 'inert'; why: string }

// Module state: a reload starts it over, like any module variable. `mirror` copies
// the band's $.state phase so the per-turn check needs no $ call below the threshold.
const S: {
  threshold: number | undefined
  kind: Promise<Kind> | undefined
  taskId: string | null | undefined
  mirror: HandoffPhase
  statusPath: string | undefined
  handoffPath: string | undefined
  requestedAt: number
  receipt: string | undefined
  carryPending: string | undefined
  stowRunning: boolean
  firing: boolean
  timing: boolean
  spentMs: number
} = {
  threshold: undefined,
  kind: undefined,
  taskId: undefined,
  mirror: 'idle',
  statusPath: undefined,
  handoffPath: undefined,
  requestedAt: 0,
  receipt: undefined,
  carryPending: undefined,
  stowRunning: false,
  firing: false,
  timing: false,
  spentMs: 0,
}

export function kTokens(n: number): string {
  return `${Math.round(n / 1000)}k`
}

/** The status path the worker's own launch brief names: `'<home>/state/<id>.status'`. */
export function findStatusPath(texts: readonly string[], taskId: string): string | undefined {
  const escaped = taskId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const pattern = new RegExp(`'(/[^'\\n]*/state/${escaped}\\.status)'`)
  for (const text of texts) {
    const match = pattern.exec(text)
    if (match) return match[1]
  }
  return undefined
}

/** `<home>/state/<id>.status` -> `<home>/data/<id>/handoff.md` */
export function handoffPathFor(statusPath: string, taskId: string): string {
  return `${statusPath.slice(0, -`/state/${taskId}.status`.length)}/data/${taskId}/handoff.md`
}

export function statusLine(epochSeconds: number, used: number, handoffPath: string): string {
  return `working [at=${epochSeconds}]: context handoff written at ${kTokens(used)} tokens used: ${handoffPath}`
}

export function carryText(used: number, receipt: string): string {
  return [
    `Handoff carried over from the previous session, which was cleared at ${kTokens(used)} tokens of context used.`,
    'Its /stow completion receipt follows; the durable memory itself is on disk where /stow filed it.',
    '',
    receipt.trim() || '(the /stow turn left no receipt text)',
  ].join('\n')
}

function stripFrontmatter(text: string): string {
  return text.startsWith('---') ? text.replace(/^---\n[\s\S]*?\n---\n?/, '') : text
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

async function thresholdOf($: EngineInterface): Promise<number> {
  if (S.threshold !== undefined) return S.threshold
  // Lab knobs only: a lower threshold so a short session crosses it, and timing lines.
  const lab = await $.env.get('FM_CONTEXT_HANDOFF_LAB_THRESHOLD')
  S.timing = (await $.env.get('FM_CONTEXT_HANDOFF_LAB_TIMING')) === '1'
  S.threshold = lab !== undefined && /^\d+$/.test(lab) ? Number(lab) : THRESHOLD
  return S.threshold
}

async function detect($: EngineInterface): Promise<Kind> {
  const taskId = await $.env.get('FM_TASK_ID')
  const names = new Set((await $.command.list()).map(c => c.name))
  if (taskId) return names.has('handoff') ? { kind: 'crew', taskId } : { kind: 'inert', why: 'worker without /handoff' }
  if ((await $.env.get('COMPACT_ADVISER_DISABLE')) === '1') return { kind: 'inert', why: 'Firstmate-launched, no task (secondmate)' }
  return names.has('stow') ? { kind: 'main' } : { kind: 'inert', why: 'no /stow in this session' }
}

async function kindOf($: EngineInterface): Promise<Kind> {
  S.kind ??= detect($).catch((error: unknown): Kind => ({ kind: 'inert', why: String(error) }))
  return S.kind
}

/** The per-turn check: below the threshold and already idle, no $ call at all. */
async function check($: EngineInterface, used: number | undefined, isTurnRunning: boolean): Promise<void> {
  if (used === undefined) return
  const limit = S.threshold ?? (await thresholdOf($))
  if (used < limit) {
    // A /clear or a compaction brought the window back under: arm again.
    if (S.mirror !== 'idle' && S.mirror !== 'clearing') await rearm($)
    return
  }
  if (S.mirror !== 'idle' || S.firing) return
  S.firing = true // claim the crossing before the first await
  try {
    const kind = await kindOf($)
    debug($, `crossed ${used} of ${limit} tokens; kind ${kind.kind}${kind.kind === 'inert' ? ` (${kind.why})` : ''}`)
    if (kind.kind === 'main') {
      await update($, usedTokens, () => used)
      await setPhase($, 'suggest')
    } else if (kind.kind === 'crew') {
      await requestHandoff($, kind.taskId, used, isTurnRunning)
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
  S.stowRunning = false
  S.statusPath = undefined
  S.handoffPath = undefined
  S.receipt = undefined
  await setPhase($, 'idle')
}

// ---- worker ----------------------------------------------------------------------

async function handoffSkillText($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  const paths = [`${await $.session.root()}/.claude/skills/handoff/SKILL.md`]
  if (home) paths.push(`${home}/.claude/skills/handoff/SKILL.md`)
  for (const path of paths) {
    try {
      return stripFrontmatter(await $.fs.read(path)).trim()
    } catch {
      // Next candidate.
    }
  }
  return undefined
}

async function requestHandoff($: EngineInterface, taskId: string, used: number, isTurnRunning: boolean): Promise<void> {
  const users = (await $.session.messages()).filter(m => m.role === 'user').map(m => m.text)
  const statusPath = findStatusPath(users, taskId)
  if (statusPath === undefined) {
    debug($, `worker ${taskId}: no status path in the transcript; staying quiet`)
    await setPhase($, 'dismissed')
    return
  }
  S.statusPath = statusPath
  S.handoffPath = handoffPathFor(statusPath, taskId)
  S.requestedAt = await $.clock.now()
  await setPhase($, 'stowing')
  const where = `Save the handoff document to ${S.handoffPath} (Firstmate's durable location for this task; create the folder if missing) instead of the temporary directory, replacing any older one.`
  if (isTurnRunning) {
    // No command runs until the turn ends, and a worker's turn can run for hours: hand
    // the model the same procedure as a row it reads at the loop's next step.
    const skill = await handoffSkillText($)
    const text = [
      `[${PLUGIN}] This session has used ${kTokens(used)} tokens of context.`,
      'Write a handoff now so the task survives a context reset, then carry on with the task as before.',
      where,
      'Do not append a status line for it: the handoff mod reports it once the file exists.',
      '',
      skill === undefined ? 'Follow your /handoff procedure.' : `The /handoff procedure:\n\n${skill}`,
    ].join('\n')
    debug($, `worker ${taskId}: requesting the handoff mid-turn, ${text.length} characters`)
    await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })
    debug($, `worker ${taskId}: handoff requested mid-turn`)
  } else {
    // Idle: run the real /handoff, outside the measuring dispatch (a direct call there
    // holds that dispatch until the command is dequeued).
    $.clock.after(0, () => {
      $.command
        .run({ command: 'handoff', args: `Continuation of Firstmate task ${taskId}. ${where}` })
        .catch((error: unknown) => debug($, `worker ${taskId}: /handoff refused: ${String(error)}`))
    })
  }
}

async function reportHandoff($: EngineInterface): Promise<void> {
  if (S.handoffPath === undefined || S.statusPath === undefined || S.mirror !== 'stowing') return
  let stat
  try {
    stat = await $.fs.stat(S.handoffPath)
  } catch {
    return
  }
  if (stat.kind !== 'file' || stat.mtimeMs < S.requestedAt) return
  await setPhase($, 'dismissed')
  const used = (await $.session.usage()).context.tokens ?? 0
  const line = statusLine(Math.floor((await $.clock.now()) / 1000), used, S.handoffPath)
  // O_APPEND through the shell, exactly as the worker's own `echo ... >>` does.
  const run = await $.process.run(['/bin/sh', '-c', 'printf "%s\\n" "$1" >> "$2"', 'sh', line, S.statusPath])
  debug($, `worker: status line appended (exit ${run.exitCode})`)
}

// ---- main window ---------------------------------------------------------------------

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
    if ((await $.env.get('FM_CONTEXT_HANDOFF_LAB_NO_CLEAR')) === '1') throw new Error('lab: clear withheld')
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

async function timed($: EngineInterface, label: string, work: () => Promise<void>): Promise<void> {
  const t0 = Date.now()
  try {
    await work()
  } catch (error) {
    debug($, `${label}: ${String(error)}`)
  }
  if (S.timing) {
    S.spentMs += Date.now() - t0
    debug($, `timing ${label} ${Date.now() - t0}ms (session total ${S.spentMs}ms)`)
  }
}

// ---- hooks -----------------------------------------------------------------------------

export const register: Register = on => {
  // The cheap trigger: pushed after each main-thread turn, the figures in `e`.
  on('session.measure', async ($, e, next) => {
    await timed($, 'measure', async () => {
      if (S.threshold === undefined) await thresholdOf($)
      if (S.timing) debug($, `measure: ${e.context.tokens ?? 'no'} tokens used of a ${e.context.window} window`)
      if (e.changed.includes('context')) await check($, e.context.tokens, false)
      if (S.mirror === 'stowing' && S.handoffPath !== undefined) await reportHandoff($)
    })
    return next(e)
  })

  // Worker only: a worker's single turn can run past the threshold for hours, so look
  // after each of its tool calls. Every other session pays one env read, then nothing.
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (S.taskId === null || e.agentId !== undefined) return result
    await timed($, 'tool.call', async () => {
      if (S.taskId === undefined) S.taskId = (await $.env.get('FM_TASK_ID')) ?? null
      if (S.taskId === null) return
      if (S.mirror === 'stowing' && S.handoffPath !== undefined) await reportHandoff($)
      else if (S.mirror === 'idle') await check($, (await $.session.usage()).context.tokens, true)
    })
    return result
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && S.stowRunning && S.mirror === 'stowing' && S.handoffPath === undefined) {
      S.stowRunning = false
      await timed($, 'turn.complete', async () => {
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
      await timed($, 'command.run', () => setPhase($, 'stowing'))
    }
    return next(e)
  })

  // A /clear typed by hand, or from the fallback fill, still carries the receipt.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    if (e.reason !== 'clear') return result
    await timed($, 'session.end', async () => {
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
    if (e.props.hasSurvey || S.handoffPath !== undefined) return next(e)
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
