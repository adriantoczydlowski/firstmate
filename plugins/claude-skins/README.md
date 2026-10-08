# Skins

An experimental Claude Code mod that restyles Claude Code's own interface.
`/skin <name>` switches between a few looks for your prompts, Claude's replies, the spinner, and the turn footer.
It is a general-purpose take on the idea behind seasonal theme mods.

The plugin is named `skins`, not `claude-skins`, because Claude Code reserves plugin names that start with `claude-` for Anthropic's own plugins and `claude plugin validate` refuses them.
The folder keeps the requested `claude-skins` name.

## What it shows

| Skin | Prompts | Reply glyph | Spinner words | Footer |
| --- | --- | --- | --- | --- |
| `netrunner` | bold cyan border on black | `⟐` | Jacking in, Breaking ICE, Decrypting | Jacked out for 7s |
| `noir` | amber border, cream on black | `◆` | Working the case, Tailing a lead | Worked the case for 7s |
| `sensei` | rounded vermillion border on parchment | `◆` | Breathing, Grinding ink, Practicing | Practiced for 7s |
| `mission-control` | double amber border on navy | `▸` | Go for launch, Telemetry nominal | Burned for 7s |

- `/skin <name>` puts a skin on and answers with its welcome line, such as "Another case. The terminal flickers to life."
- `/skin` with no name lists the skins and marks the active one.
- `/skin default` (or `off`) returns to Claude Code's own look, with the outgoing skin's goodbye line.
- The prompt hint line ends with `skin: <name>` while a skin is active.
- The chosen skin is kept across sessions.

The skins' identities - names, hex palettes, icons, and welcome and goodbye lines - are ported from [basicScandal/claude-skins](https://github.com/basicScandal/claude-skins) (MIT), and the spinner and footer words follow each skin's personality text there.
That project drives its skins through settings hooks and a shell engine; this mod applies the same identities through the mods API instead.
Its other skins (Nebula, Mythos, Retro86, and more) are not ported; each would be one more entry in `hooks/skins.ts`.

## Patterns it demonstrates

Both ways of changing what Claude Code already draws:

- Drawing a tree in place of a built-in site: your prompt rows (`UserMessage`, only the prompts you typed) become a bordered `Box`, and Claude's reply blocks (`AssistantMessage`) become a gutter glyph beside a `Markdown` element.
- Handing the engine's own component rewritten props with `next({ ...e, props })`: the spinner's word and suffix (`Spinner`), the footer's word (`TurnDuration`), and a `tail` on the prompt hint (`PromptHint`).

The active skin lives in `$.state`, so every drawn row reads it and redraws the moment it changes, earlier rows included, and in `$.store`, so the next session starts in the same skin.

## Try it

From this repository's root:

```bash
claude plugin validate plugins/claude-skins
claude plugin test plugins/claude-skins
claude --plugin-dir plugins/claude-skins
```

Then type `/skin noir` and send a prompt.

## Notes and limitations

- This is an experiment, not a supported Firstmate surface.
- When another installed mod draws the spinner row itself, that drawing wins and the skin's spinner words do not show; the prompt, reply, footer, and hint changes still apply.
- Messages from other agents, teammates, and background tasks keep Claude Code's own rows.
- The reply rows are redrawn with `Markdown`, so they follow the mod's layout rather than every detail of the built-in reply row.
