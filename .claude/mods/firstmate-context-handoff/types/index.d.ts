export type HandoffPhase = 'idle' | 'suggest' | 'stowing' | 'ready' | 'clearing' | 'dismissed'

declare module 'claude-code' {
  interface PluginState {
    'firstmate-context-handoff': { phase: HandoffPhase; usedTokens: number }
  }
}
