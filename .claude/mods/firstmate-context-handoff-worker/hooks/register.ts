// firstmate-context-handoff-worker: the worker half of the context-handoff courtesy.
//
// fm-spawn loads this mod with --plugin-dir into a Claude ship or scout worker, in any
// project, only while the launching home's `config/context-handoff` switch is on. Nobody
// watches a worker's pane, so there is no button: when the session has used THRESHOLD
// tokens of context (consumption, not remaining) the worker writes its own handoff to
// <home>/data/<task>/handoff.md (home read from the status path its launch brief names)
// and, once that file exists, appends one line to its own status file, the channel
// every other worker event already uses. Without FM_TASK_ID, /handoff, or a status path
// in the brief it stays inert.
//
// A worker's single turn can run past the threshold for hours, and session.measure
// fires only when a turn ends, so it also checks after each main-thread tool call.
// It hooks no classic.* event, never answers an event in place of the engine, and
// wraps its own work in try/catch around `next(e)`, so a failure here leaves the
// session as it would be without the mod. docs/context-handoff.md owns the contract.
import type { EngineInterface, Register } from 'claude-code'

const PLUGIN = 'firstmate-context-handoff-worker'
const THRESHOLD = 250_000

type Phase = 'idle' | 'requested' | 'done'
type Kind = { kind: 'crew'; taskId: string } | { kind: 'inert'; why: string }

// Module state: a reload starts it over, like any module variable.
const S: {
  kind: Promise<Kind> | undefined
  phase: Phase
  statusPath: string | undefined
  handoffPath: string | undefined
  requestedAt: number
  firing: boolean
} = {
  kind: undefined,
  phase: 'idle',
  statusPath: undefined,
  handoffPath: undefined,
  requestedAt: 0,
  firing: false,
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
  return `working [at=${epochSeconds}]: context handoff written at ${kTokens(used)} tokens used (early courtesy point; note it, no relaunch): ${handoffPath}`
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

async function detect($: EngineInterface): Promise<Kind> {
  const taskId = await $.env.get('FM_TASK_ID')
  if (!taskId) return { kind: 'inert', why: 'not a Firstmate ship or scout worker' }
  const names = new Set((await $.command.list()).map(c => c.name))
  return names.has('handoff') ? { kind: 'crew', taskId } : { kind: 'inert', why: 'worker without /handoff' }
}

/** The per-turn check: below the threshold and already idle, no $ call at all. */
async function check($: EngineInterface, used: number | undefined, isTurnRunning: boolean): Promise<void> {
  if (used === undefined) return
  if (used < THRESHOLD) {
    // A /clear or a compaction brought the window back under: arm again.
    if (S.phase !== 'idle') rearm()
    return
  }
  if (S.phase !== 'idle' || S.firing) return
  S.firing = true // claim the crossing before the first await
  try {
    S.kind ??= detect($).catch((error: unknown): Kind => ({ kind: 'inert', why: String(error) }))
    const kind = await S.kind
    debug($, `crossed ${used} of ${THRESHOLD} tokens; kind ${kind.kind}${kind.kind === 'inert' ? ` (${kind.why})` : ''}`)
    if (kind.kind === 'crew') await requestHandoff($, kind.taskId, used, isTurnRunning)
    else S.phase = 'done'
  } catch (error) {
    S.phase = 'done' // any failure: stay quiet until the window drops back under
    throw error
  } finally {
    S.firing = false
  }
}

function rearm(): void {
  S.phase = 'idle'
  S.statusPath = undefined
  S.handoffPath = undefined
}

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
    S.phase = 'done'
    return
  }
  S.statusPath = statusPath
  S.handoffPath = handoffPathFor(statusPath, taskId)
  S.requestedAt = await $.clock.now()
  S.phase = 'requested'
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
  if (S.handoffPath === undefined || S.statusPath === undefined || S.phase !== 'requested') return
  let stat
  try {
    stat = await $.fs.stat(S.handoffPath)
  } catch {
    return
  }
  if (stat.kind !== 'file' || stat.mtimeMs < S.requestedAt) return
  S.phase = 'done'
  const used = (await $.session.usage()).context.tokens ?? 0
  const line = statusLine(Math.floor((await $.clock.now()) / 1000), used, S.handoffPath)
  // O_APPEND through the shell, exactly as the worker's own `echo ... >>` does.
  const run = await $.process.run(['/bin/sh', '-c', 'printf "%s\\n" "$1" >> "$2"', 'sh', line, S.statusPath])
  debug($, `worker: status line appended (exit ${run.exitCode})`)
}

async function guarded($: EngineInterface, label: string, work: () => Promise<void>): Promise<void> {
  try {
    await work()
  } catch (error) {
    debug($, `${label}: ${String(error)}`)
  }
}

export const register: Register = on => {
  // The cheap trigger: pushed after each main-thread turn, the figures in `e`.
  on('session.measure', async ($, e, next) => {
    await guarded($, 'measure', async () => {
      if (e.changed.includes('context')) await check($, e.context.tokens, false)
      if (S.phase === 'requested') await reportHandoff($)
    })
    return next(e)
  })

  // A worker's single turn can run past the threshold for hours, so look after each of
  // its own tool calls; a subagent's calls are left alone.
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || S.phase === 'done') return result
    await guarded($, 'tool.call', async () => {
      if (S.phase === 'requested') await reportHandoff($)
      else await check($, (await $.session.usage()).context.tokens, true)
    })
    return result
  })
}
