/** A skin's name; '' draws Claude Code's own look. */
export type SkinName = '' | 'netrunner' | 'noir' | 'sensei' | 'mission-control'

declare module 'claude-code' {
  interface PluginState {
    skins: {
      skin: SkinName
    }
  }
}
