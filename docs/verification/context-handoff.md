# Context handoff verification

This record holds the empirical evidence behind the support bounds in [`context-handoff.md`](../context-handoff.md).
`tests/fm-context-handoff-mod-plugin.test.sh` refreshes the engine checks wherever `claude` is installed; the live runs below are manual.

## 2026-10-03 Claude Code 2.1.288

### Engine checks

```text
$ claude --version
2.1.288 (Claude Code)

$ claude plugin validate --strict .claude/mods/firstmate-context-handoff
  ❯ ./register.tsx hooks: session.measure, turn.complete, command.run{command=stow}, session.end, ui.render{component=AbovePrompt}
  ❯ ./register.tsx env writes: nothing
  ❯ ./register.tsx env reads: COMPACT_ADVISER_DISABLE, FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE, FM_TASK_ID
✔ Validation passed

$ claude plugin validate --strict .claude/mods/firstmate-context-handoff-worker
  ❯ ./register.ts hooks: session.measure, tool.call
  ❯ ./register.ts env writes: nothing
  ❯ ./register.ts env reads: FM_TASK_ID, HOME
✔ Validation passed

$ claude plugin test .claude/mods/firstmate-context-handoff
 18 pass
 0 fail

$ claude plugin test .claude/mods/firstmate-context-handoff-worker
 12 pass
 0 fail
```

`tsc -p .` with TypeScript 5.6 against the engine-written declarations is clean in both folders.
The 2.1.288 test kit never routes a plugin's own `$.session.append` to a test's `session.append` hook, so the suites observe the append through the mods' debug lines and the live runs below carry the proof that the row lands.

### Worker part at the real threshold

A headless Sonnet 5.5 worker (`claude -p`, `--plugin-dir .claude/mods/firstmate-context-handoff-worker`, `FM_TASK_ID=live-task`, `COMPACT_ADVISER_DISABLE=1`, a scratch Firstmate home, a copy of the `/handoff` skill) was told to read fourteen large files in one turn, with a status path named in its prompt in the launch brief's quoted form.
The crossing fired mid-turn at the real 250,000 threshold, the model wrote the handoff to the durable path, and the worker part appended its one line (`<lab>` is the scratch folder):

```text
[DEBUG] hooks module firstmate-context-handoff-worker@inline loaded (worker, environment 2, tier user); events: session.measure,tool.call
[DEBUG] [firstmate-context-handoff-worker] $.ui.log (to debug): crossed 251830 of 250000 tokens; kind crew
[DEBUG] [firstmate-context-handoff-worker] $.ui.log (to debug): worker live-task: requesting the handoff mid-turn, 1295 characters
[DEBUG] [firstmate-context-handoff-worker] $.ui.log (to debug): worker live-task: handoff requested mid-turn
[DEBUG] $.process.run (firstmate-context-handoff-worker): /bin/sh exited 0 in 6ms, 0 + 0 chars
[DEBUG] [firstmate-context-handoff-worker] $.ui.log (to debug): worker: status line appended (exit 0)

$ cat <lab>/home/state/live-task.status
working [at=1791021783]: context handoff written at 272k tokens used (early courtesy point; note it, no relaunch): <lab>/home/data/live-task/handoff.md
done [at=1791021842]: x
```

The worker then finished its remaining reads and appended its own `done` line, so the request did not derail the task.

### Main-window part, prototype lab

The main-window flow is unchanged from the prototype except for the switch and the secondmate path, and was proven live on 2.1.288 in a lab with a lowered threshold and a stand-in `/stow` whose receipt carried the codeword `PELICAN-42`:

- A band button calling `$.command.run({ command: 'clear' })` ended the session with reason `clear`, and the same loaded module appended the receipt to the fresh session.
- Asked for its codeword after the clear, the fresh session answered `PELICAN-42`, with only the `/clear` row on screen.
- With the clear refused, `/clear` filled into the prompt, one Enter cleared, and the receipt still followed.
- `$.command.run` is refused only from a `tool.call` hook while that turn runs; a press handler, `turn.complete`, and `$.clock.after(0, …)` from `session.measure` all run it.

```text
ui.focus AbovePrompt above-prompt (person) onto firstmate-context-handoff's clear: moved
$.command.run (firstmate-context-handoff): 6 chars queued
hooks module firstmate-context-handoff@inline session.end settled in 2.6ms
[firstmate-context-handoff] carried the handoff by session.append: {"message":{"type":"user","role":"user","isMeta":true, ...
```

Measured engine overhead per hooked event in that lab: `session.measure` 1.2-7.3 ms per turn, `ui.render` above the prompt 2.4-6.4 ms per redraw after a first warm-up, and a `tool.call` hook 3.1-9.9 ms added to each tool call, which is why the tool-call check lives only in the worker part.

### Loading from a folder

A `--plugin-dir` load writes `.claude-plugin/types/` (holding its own `*` ignore file) and a `tsconfig.json` beside `.claude-plugin/`, and leaves an existing `tsconfig.json` untouched:

```text
$ cat tsconfig.json            # written by a load into a folder without one
{
  "extends": "./.claude-plugin/types/tsconfig.json"
}

# a folder whose tsconfig.json differs, after the same load: unchanged
{
  "extends": "./.claude-plugin/types/tsconfig.json",
  "compilerOptions": {"noEmit": true}
}
```

Both mods therefore track that file, and a headless `claude -p` load of both folders straight from a Firstmate checkout left `git status` with no untracked or modified file under `.claude/mods/`.

### Not verified live

- The real `/stow` turn in a real Firstmate primary, including how its supervision and the start-up digest interleave with the carried row after `/clear`.
- The main window and the secondmate at the real 250,000 crossing; the secondmate's self-run `/stow` is covered by the plugin suite only.
- The worker's idle crossing at the real threshold; it was proven in the prototype lab at a lowered threshold.
- The desktop surface and the fullscreen terminal layout.
