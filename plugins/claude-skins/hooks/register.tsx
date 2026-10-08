// Claude Skins: /skin <name> restyles what Claude Code already draws.
//
// Two ways of changing a built-in site, side by side:
// - drawing a tree in its place (your prompt rows, Claude's reply blocks);
// - passing the engine's own component rewritten props (the spinner's word
//   and suffix, the turn footer's word, a tail on the prompt hint).
// The skin lives in `$.state`, so every drawn row reads it and redraws when it
// changes, and in `$.store`, so the next session starts in the same skin.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { SkinName } from '../types'
import { choose, skinNamed, spinnerWord } from './skins'

const skinAtom = atom({ plugin: 'skins', key: 'skin' } as const, '')

async function activeSkin($: EngineInterface) {
  return skinNamed(await read($, skinAtom))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const stored = await $.store.get('skin')
    if (typeof stored === 'string' && skinNamed(stored) !== undefined) {
      await update($, skinAtom, () => stored as SkinName)
    }
    await $.command.register({
      name: 'skin',
      description: "Restyle Claude Code's prompts, replies, spinner and footer; no name lists the skins",
      argumentHint: '[netrunner|noir|sensei|mission-control|default]',
    })
    return started
  })

  on('command.run', { command: 'skin' }, async ($, e) => {
    const chosen = choose(e.args, await read($, skinAtom))
    await update($, skinAtom, () => chosen.skin as SkinName)
    await $.store.set('skin', chosen.skin)
    return { text: chosen.text }
  })

  // Your own prompts: a bordered box in the skin's colors.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const skin = await activeSkin($)
    if (skin === undefined || e.props.origin.kind !== 'composer') return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box
        borderStyle={skin.prompt.border}
        borderColor={skin.prompt.borderColor}
        backgroundColor={skin.prompt.backgroundColor}
        paddingX={1}
      >
        <Text color={skin.prompt.color}>{e.props.text}</Text>
      </Box>
    )
  })

  // Claude's reply blocks: the skin's glyph in the gutter, the text as markdown.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const skin = await activeSkin($)
    if (skin === undefined) return next(e)
    const { Box, Text, Markdown } = $.ui.resolve(e)
    return (
      <Box flexDirection="row">
        <Box width={2} flexShrink={0}>
          <Text color={skin.reply.color} bold>
            {e.props.isFirstOfReply ? skin.reply.glyph : ' '}
          </Text>
        </Box>
        <Box flexDirection="column" flexGrow={1}>
          <Markdown text={e.props.text} dimColor={e.props.isSummary === true} />
        </Box>
      </Box>
    )
  })

  // The engine keeps drawing these three; the skin only rewrites their words.
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    const skin = await activeSkin($)
    if (skin === undefined) return next(e)
    return next({ ...e, props: { ...e.props, word: spinnerWord(skin, e.props.word), suffix: skin.spinner.suffix } })
  })

  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    const skin = await activeSkin($)
    if (skin === undefined) return next(e)
    return next({ ...e, props: { ...e.props, word: skin.doneWord } })
  })

  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const skin = await activeSkin($)
    if (skin === undefined || e.props.isWorking) return next(e)
    return next({ ...e, props: { ...e.props, tail: `skin: ${skin.name}` } })
  })
}
