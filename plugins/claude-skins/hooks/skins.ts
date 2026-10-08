// The skins: each one a palette and a few words, applied to sites Claude Code
// already draws. Pure: no `$`, so the tests read it directly.

export type Skin = {
  name: string
  blurb: string
  /** Your prompt rows: a bordered box. */
  prompt: { border: string; borderColor: string; color: string; backgroundColor: string }
  /** Claude's replies: the glyph opening a reply and its color. */
  reply: { glyph: string; color: string }
  /** Words the spinner cycles through while a turn runs, and what follows them. */
  spinner: { words: readonly string[]; suffix: string }
  /** The past-tense words of the line closing a turn (`<doneWord> for 7s`). */
  doneWord: string
  /** Said when the skin is put on, and when it is taken off. */
  welcome: string
  goodbye: string
}

// Palettes, icons, and welcome and goodbye lines come from the skins of
// https://github.com/basicScandal/claude-skins (MIT); spinner and footer words
// follow each skin's personality text there.
export const SKINS: readonly Skin[] = [
  {
    name: 'netrunner',
    blurb: 'cyberpunk netrunner, cyan ICE-breaking colors on black',
    prompt: { border: 'bold', borderColor: '#00E5FF', color: '#80CBC4', backgroundColor: '#0A0A0A' },
    reply: { glyph: '⟐', color: '#00E5FF' },
    spinner: { words: ['Jacking in', 'Breaking ICE', 'Decrypting', 'Running the net'], suffix: ' ◎' },
    doneWord: 'Jacked out',
    welcome: 'Connection established. Neural link active.',
    goodbye: 'Disconnecting neural link. Closing the net.',
  },
  {
    name: 'noir',
    blurb: '1940s detective procedural, black and cream with amber accents',
    prompt: { border: 'single', borderColor: '#D4A857', color: '#F5E6C8', backgroundColor: '#0D0D0D' },
    reply: { glyph: '◆', color: '#D4A857' },
    spinner: { words: ['Working the case', 'Tailing a lead', 'Dusting for prints', 'Canvassing'], suffix: ' ◆' },
    doneWord: 'Worked the case',
    welcome: 'Another case. The terminal flickers to life.',
    goodbye: 'Case closed. The screen goes dark.',
  },
  {
    name: 'sensei',
    blurb: 'Japanese ink wash, warm parchment, charcoal, vermillion seal',
    prompt: { border: 'round', borderColor: '#C41E3A', color: '#2C2C2C', backgroundColor: '#F5F2EB' },
    reply: { glyph: '◆', color: '#C41E3A' },
    spinner: { words: ['Breathing', 'Practicing', 'Grinding ink', 'Sharpening the blade'], suffix: '…' },
    doneWord: 'Practiced',
    welcome: 'The path is clear. Begin.',
    goodbye: 'Rest. Return when ready.',
  },
  {
    name: 'mission-control',
    blurb: 'NASA retro-futurist ops console, amber phosphor on deep navy',
    prompt: { border: 'double', borderColor: '#FFB000', color: '#FFB000', backgroundColor: '#0B1120' },
    reply: { glyph: '▸', color: '#FFB000' },
    spinner: { words: ['Go for launch', 'Telemetry nominal', 'Confirming burn', 'Standby'], suffix: ' ▸' },
    doneWord: 'Burned',
    welcome: 'All systems nominal. Flight is go.',
    goodbye: 'Mission complete. Safe return.',
  },
]

export const skinNamed = (name: string): Skin | undefined => SKINS.find(skin => skin.name === name)

/** A stable pick from the skin's words for the engine's own word, so each turn keeps one. */
export function spinnerWord(skin: Skin, engineWord: string): string {
  let hash = 0
  for (const char of engineWord) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  return skin.spinner.words[hash % skin.spinner.words.length] ?? engineWord
}

/** The /skin command's answer for the given argument, and the skin to switch to ('' for none). */
export function choose(args: string, current: string): { skin: string; text: string } {
  const wanted = args.trim().toLowerCase()
  const list = SKINS.map(skin => `${skin.name === current ? '▸' : ' '} ${skin.name} - ${skin.blurb}`).join('\n')
  const leaving = skinNamed(current)
  if (wanted === '') {
    return { skin: current, text: `Skin: ${current || 'default'}\n${list}\n  default - Claude Code's own look` }
  }
  if (wanted === 'default' || wanted === 'off' || wanted === 'none') {
    return { skin: '', text: `${leaving === undefined ? '' : leaving.goodbye + ' '}Skin off: Claude Code's own look.` }
  }
  const skin = skinNamed(wanted)
  if (skin === undefined) {
    return { skin: current, text: `No skin named "${wanted}". Skins:\n${list}\n  default` }
  }
  return { skin: skin.name, text: `Skin: ${skin.name}. ${skin.welcome}` }
}
