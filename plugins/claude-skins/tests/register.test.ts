import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { SKINS, choose, spinnerWord } from '../hooks/skins'

const COMMAND = { origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 160 } }

// The engine beneath the plugin: it keeps a store, registers commands, and
// draws the built-in sites from whatever props reach it, so a test can read
// what the skin handed on.
function engine(on: On) {
  const store = new Map<string, unknown>()
  mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('store.get', ($, e) => ({ value: store.get(e.key) }))
  on('store.set', ($, e) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('ui.render', { component: 'Spinner' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: `${e.props.word}${e.props.suffix}` })
  })
  on('ui.render', { component: 'TurnDuration' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: `${e.props.word} for 3s` })
  })
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: `> ${e.props.text}` })
  })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: `● ${e.props.text}` })
  })
  return { store }
}

const prompt = { text: 'fix the tests', origin: { kind: 'composer' as const }, isExpanded: false }
const reply = { text: 'Done: **all green**.', isFirstOfReply: true }
const spinner = { word: 'Sauteing', message: null, suffix: '…', mode: 'responding' as const }

describe('skins', () => {
  test('the command lists, switches, refuses unknown names and turns off', () => {
    expect(choose('', '').text).toContain('mission-control')
    expect(choose('Noir', '')).toEqual({ skin: 'noir', text: 'Skin: noir. Another case. The terminal flickers to life.' })
    expect(choose('nope', 'sensei').skin).toBe('sensei')
    expect(choose('default', 'noir')).toEqual({ skin: '', text: "Case closed. The screen goes dark. Skin off: Claude Code's own look." })
    for (const skin of SKINS) expect(skin.spinner.words).toContain(spinnerWord(skin, 'Sauteing'))
  })
})

describe('skins mod', () => {
  test('a skin restyles prompts, replies, spinner and footer, and persists', async ($, on) => {
    const world = engine(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })

    const plain = await $.ui.mount({ plugin: 'skins', surface: 'terminal', component: 'Spinner', props: spinner })
    expect((await plain.find({ type: 'Text' }))?.text, 'no skin: the engine draws').toBe('Sauteing…')

    expect(await $.command.run({ command: 'skin', args: 'mission-control', ...COMMAND })).toEqual({
      text: 'Skin: mission-control. All systems nominal. Flight is go.',
    })
    expect(world.store.get('skin')).toBe('mission-control')
    const mission = SKINS.find(skin => skin.name === 'mission-control')!

    for (const surface of ['terminal', 'desktop'] as const) {
      const user = await $.ui.mount({ plugin: 'skins', surface, component: 'UserMessage', props: prompt })
      const box = await user.find({ type: 'Box' })
      expect(box?.props.borderStyle).toBe('double')
      expect((await user.find({ type: 'Text' }))?.text).toBe('fix the tests')

      const assistant = await $.ui.mount({ plugin: 'skins', surface, component: 'AssistantMessage', props: reply })
      expect((await assistant.find({ type: 'Text' }))?.text).toBe('▸')
      expect((await assistant.find({ type: 'Markdown' }))?.text).toBe('Done: **all green**.')

      const spin = await $.ui.mount({ plugin: 'skins', surface, component: 'Spinner', props: spinner })
      expect((await spin.find({ type: 'Text' }))?.text).toBe(`${spinnerWord(mission, 'Sauteing')} ▸`)
    }

    const footer = await $.ui.mount({
      plugin: 'skins',
      surface: 'terminal',
      component: 'TurnDuration',
      props: { word: 'Baked', durationMs: 3000 },
    })
    expect((await footer.find({ type: 'Text' }))?.text).toBe('Burned for 3s')

    // A message another agent sent keeps the engine's row.
    const peer = await $.ui.mount({
      plugin: 'skins',
      surface: 'terminal',
      component: 'UserMessage',
      props: { ...prompt, origin: { kind: 'task-notification' as const } },
    })
    expect((await peer.find({ type: 'Text' }))?.text).toBe('> fix the tests')

    await $.command.run({ command: 'skin', args: 'off', ...COMMAND })
    const off = await $.ui.mount({ plugin: 'skins', surface: 'terminal', component: 'TurnDuration', props: { word: 'Baked', durationMs: 3000 } })
    expect((await off.find({ type: 'Text' }))?.text).toBe('Baked for 3s')
  })
})
