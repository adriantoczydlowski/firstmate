// The pure parts of the firstmate-context-handoff mod: the per-home switch and the
// carried text. No engine interface here, so the policy runs under plain Node as well as
// under `claude plugin test`; ../hooks/register.tsx is the only file that touches `$`.

export function kTokens(n: number): string {
  return `${Math.round(n / 1000)}k`
}

export type HomeEnvironment = {
  readonly FM_HOME?: string | undefined
  readonly FM_ROOT_OVERRIDE?: string | undefined
  readonly FM_CONFIG_OVERRIDE?: string | undefined
}

function parentDirectory(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  const cut = trimmed.lastIndexOf('/')
  return cut <= 0 ? '/' : trimmed.slice(0, cut)
}

/**
 * The per-home `config/context-handoff` path, resolved as Calm resolves `config/calm`:
 * `FM_CONFIG_OVERRIDE` names the config directory outright, otherwise `FM_HOME`, then
 * `FM_ROOT_OVERRIDE`, then the code root three levels above this mod's folder.
 */
export function switchPath(env: HomeEnvironment, pluginRoot: string): string {
  const root = env.FM_HOME || env.FM_ROOT_OVERRIDE || parentDirectory(parentDirectory(parentDirectory(pluginRoot)))
  return `${env.FM_CONFIG_OVERRIDE || `${root}/config`}/context-handoff`
}

/** `on` is on; absent, unreadable, or anything else is off. */
export function parseSwitch(stored: string | undefined): boolean {
  return stored !== undefined && stored.trim() === 'on'
}

export function carryText(used: number, receipt: string): string {
  return [
    `Handoff carried over from the previous session, which was cleared at ${kTokens(used)} tokens of context used.`,
    'Its /stow completion receipt follows; the durable memory itself is on disk where /stow filed it.',
    '',
    receipt.trim() || '(the /stow turn left no receipt text)',
  ].join('\n')
}
