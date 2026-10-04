# Context handoff

Context handoff is Firstmate's early, optional context-reset courtesy for Claude Code sessions.
Once a session has used 250k tokens of context, it writes a handoff for the next session: behind a button in the captain's main window, and by itself in a session nobody watches.
This page is for operators who turn it on and need to know when it acts, what it shows, what it writes, and which file owns each part.

## Harness support and default

| Harness | Support |
| --- | --- |
| Claude Code | Supported through two Claude Code mods, as the rest of this page describes. |
| Codex, Pi, and every other harness | Nothing: no part loads, and their launches are unchanged. |

Context handoff is off by default.
It acts only while the per-home `config/context-handoff` switch reads `on`; [`configuration.md`](configuration.md#context-handoff-switch-configcontext-handoff) owns the file.

## Turning it on and off

```sh
printf 'on\n' > config/context-handoff    # on
printf 'off\n' > config/context-handoff   # off; deleting the file is the same
```

Run either from the Firstmate home, or write `$FM_HOME/config/context-handoff`.
The primary home's file is inherited into every secondmate home at the next convergence, so one choice covers the fleet.

When each part reads the switch:

| Session | Reads the switch | A change takes effect |
| --- | --- | --- |
| Main window or secondmate | At each crossing, never below the threshold | At the next crossing, once a `/clear`, a compaction, or a new session has brought the window back under 250k |
| Ship or scout worker | When `fm-spawn` launches or relaunches it | At the next spawn or relaunch; a running worker keeps what it launched with |

## The two parts

| Part | Folder | Loaded into | How |
| --- | --- | --- | --- |
| Main-window part | `.claude/mods/firstmate-context-handoff` | Every Claude Code session of a Firstmate checkout the person trusts: the captain's main window, a secondmate's home, and a worker whose project is Firstmate itself | Auto-adopted through the `.claude/skills/firstmate-context-handoff` entry (a symlink into `.claude/mods`), exactly as Calm is |
| Worker part | `.claude/mods/firstmate-context-handoff-worker` | Claude ship and scout workers, in any project | `fm-spawn` adds `--plugin-dir` for it to the worker's launch while the switch is on; nothing links it into the auto-load path |

The split keeps each session to the hooks it needs.
The worker part's per-tool-call check is the one hook a main window has no use for, and it would cost every tool call there an extra engine round trip (measured at 3-7 ms) for nothing.

## The threshold

Both parts compare `context.tokens` from Claude Code's per-session measurement against a fixed **250,000**.
That figure is the input tokens the last response was answered over, uncached, cache-written, and cache-read together: tokens consumed, not tokens remaining.
It fires when `context.tokens >= 250000`, whatever the window size.

| Window | 250k used is | Result |
| --- | --- | --- |
| 1,000,000 (Sonnet 5.5, Opus 5.5) | 25% used, about 750k still free | Fires as intended, far earlier than the 25%-remaining checkpoint. |
| Between 250k and 1M | A larger share of the window | Fires proportionally later, for example at half of a 500k window. |
| Smaller than 250k (Haiku 4.5's 200k) | More than the whole window | **Never fires.** Claude Code's own compaction acts first. |

The measurement arrives after each main-thread turn.
Below the threshold the per-turn check makes no engine call, reads no file, and reads no environment.
A worker also checks after each of its own tool calls, because a worker's single turn can run past the threshold for hours; that check reads the session's usage once per tool call, below the threshold too, and does nothing else there.
After a `/clear` or a compaction brings the window back under 250k, each part re-arms for the next crossing.

## How a session's kind is told apart

The parts tell sessions apart only from what `fm-spawn` already sets at launch, read at each crossing:

| Kind | Recognized by | Served by |
| --- | --- | --- |
| Ship or scout worker | `FM_TASK_ID` is set, which only ship and scout panes receive | The worker part; the main-window part stays inert there |
| Secondmate | `COMPACT_ADVISER_DISABLE=1` without `FM_TASK_ID`; every agent Firstmate launches carries that variable and the captain's own session never does | The main-window part |
| Main window | Neither variable, and `/stow` is available | The main-window part |

A session with neither command it needs stays inert: the main-window part needs `/stow`, which is a Firstmate project skill, so it never acts in the captain's Claude sessions in other projects, and the worker part needs `/handoff`.

## Main window

At the crossing a band appears above the prompt:

```text
252k tokens of context used. A fresh session would start lighter. [ Write handoff (/stow) ] [ Not now ]
```

| Action | What happens and what appears |
| --- | --- |
| **Write handoff (/stow)** (key `s`, or a click) | Runs `/stow`, which shows as a normal command row and turn. The band reads `Writing the handoff with /stow…`. A `/stow` typed by hand while the offer is up counts as the button. |
| The `/stow` turn ends | The band reads `Handoff written. [ Clear and carry handoff ] [ Not now ]`. The receipt is that turn's final answer, taken from the first turn to finish after `/stow` started, never from a fleet wake turn that ended in between. |
| **Clear and carry handoff** (key `c`) | Runs `/clear`, then appends the `/stow` receipt to the fresh session as a row the model reads and the screen does not show. Only the `/clear` row is visible. The fresh session starts no turn of its own; the receipt waits for the captain's next message. |
| A `/clear` typed by hand while the clear is offered | Carries the receipt the same way. |
| **Not now** (key `x`) | Hides the offer until the window drops back under 250k, then it re-arms. |
| An interrupted `/stow` turn | The first offer comes back. |

The band's keys work after focusing it with `ctrl+x tab`; a click works too.

## Secondmate

Nobody watches a secondmate's pane, so it gets no band.
At the crossing it runs `/stow` itself, once, outside the turn that measured the crossing, and does nothing else that window.
It does not clear its session: the stow files its durable memory, and the secondmate carries on.

## Worker

Nobody watches a worker's pane either, so a ship or scout worker gets no band.
At the crossing it writes its own handoff to **`<home>/data/<task-id>/handoff.md`**, where `<home>` is the Firstmate home whose status file the worker's launch brief names.
The worker part looks for that quoted status path in the worker's own prompt text first; a Claude worker's prompt is the launch doorbell from `bin/fm-operational-input.sh`, so it then reads the operational-inbox record each doorbell names and looks there.
That path survives teardown, and it is the durable handoff location for every Firstmate worker.

| Worker state at the crossing | What happens |
| --- | --- |
| Mid-turn, after one of its own tool calls (the usual case) | A row the model reads at its next step asks it to write the handoff to that path with the `/handoff` procedure and then carry on with the task. The row is not drawn; the handoff's file write shows like any other tool call. |
| Idle, at the end of a turn | Runs the real `/handoff` with that path as its argument, which shows as a normal command row. |

Once `handoff.md` exists and is newer than the request, the worker part appends one line to the worker's own status file, the same file and append the worker's own status lines use:

```text
working [at=<epoch>]: context handoff written at 252k tokens used (early courtesy point; note it, no relaunch): <home>/data/<task-id>/handoff.md
```

A handoff file left from before the request is never reported, and only one line is written per crossing.
The line is written only while the status file is empty or its last line is still a `working` or `resolved` state; when the worker has already reported `done`, `needs-decision`, or any other state, the handoff is still written but no line goes over that state, so firstmate keeps reading what the worker last said.

### What firstmate does with the line

The `working` line wakes firstmate like any status change and opens no decision.
Firstmate **only notes it**: it does not relaunch the worker on that handoff.
250k used is an early courtesy point, and a relaunch there would throw away three quarters of a healthy session.
The handoff stays on disk for the moment a relaunch is actually needed, such as the 25%-remaining checkpoint or a recovery.

## Session resets

Both parts wipe their in-memory state at `session.start`, so a resumed or continued session (for example Claude Code's native `--continue`) never reuses phase, receipt, or usage figures left over from an earlier session's lifetime; each part re-arms as if freshly loaded.
The main-window part keeps one exception: a carry already pending for the next session (queued by **Clear and carry handoff** or a hand-typed `/clear`) survives the reset, so the receipt still lands in the fresh session even when that session's own `session.start` fires before the deferred carry runs.

## Failure behavior

| Situation | What the person sees |
| --- | --- |
| The switch is off or absent | A plain session: no band, no self-run command, no status line; `/stow`, `/handoff`, and `/clear` behave as always. |
| A part is not loaded (not Claude Code, mods turned off, `--safe-mode`, or the worker launched before the switch was on) | The same plain session. |
| Below the threshold | Nothing; the per-turn check makes no engine call, and a worker's per-tool-call check only reads the session's usage. |
| A hook throws or times out | The hook is skipped and the event proceeds untouched; one dim line in the session names the skipped hook, because Claude Code watches both parts' folders. |
| A part does not load | One dim line at start names the module that did not load; the session is otherwise normal. |
| A call fails at the crossing (transcript unreadable, command list unavailable) | That part goes quiet for the rest of the window; every event still passes through. |
| `/stow` refused | The offer comes back with the notice `The handoff could not start; type /stow yourself.` |
| `/clear` refused | `/clear` is filled into the prompt with the notice `Press Enter to clear; the handoff follows into the new session.`; Enter clears and the receipt follows. |
| The carry fails after the clear | A plain `/clear`: a fresh session without the receipt, while the stowed memory stays on disk. |
| The worker's brief names no status file, its launch record cannot be read, or the worker has no `/handoff` | No row, no command, no status line. |
| Idle, the worker's own `/handoff` run is refused (busy, engine error) | No handoff file, no status line; the worker goes quiet on that crossing and waits for the next one. |
| The worker's status file cannot be read, or its last line is a state other than `working` or `resolved` | The handoff is written; no status line. |
| The worker part's folder is missing when a worker launches | `fm-spawn` warns and launches the worker without it. |

## Support bounds

- Claude Code only.
- Both parts are built against Claude Code's mods API, which its own declarations call early access and which Claude Code states may change between releases without notice.
- Verified on Claude Code 2.1.288; [`verification/context-handoff.md`](verification/context-handoff.md) records what was proven live and what was not.
- The real `/stow` turn in a real Firstmate primary, with its supervision and the start-up digest interleaving with the carried row after `/clear`, has not been exercised live; the main-window flow was proven in a lab with a stand-in `/stow` and a lowered threshold.
- The worker part needs a `/handoff` command in the worker's session; without one it stays inert.
- The desktop surface and the fullscreen terminal layout are unverified.

## Owning files

- `.claude/mods/firstmate-context-handoff/hooks/register.tsx` owns the main-window and secondmate behavior, and `lib/fm-context-handoff.ts` beside it the switch path, the switch value, and the carried text.
- `.claude/mods/firstmate-context-handoff-worker/hooks/register.ts` owns the worker behavior, the handoff path, and the status line.
- [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns loading the worker part into a launch.
- [`configuration.md`](configuration.md#context-handoff-switch-configcontext-handoff) owns the switch file.

Each mod tracks the `tsconfig.json` Claude Code writes beside `.claude-plugin/` when it loads a mod from a folder, so a `--plugin-dir` load leaves no untracked file in a Firstmate checkout; the generated `.claude-plugin/types/` ignores itself.

## Regression entry points

```sh
tests/fm-context-handoff-mod.test.sh
tests/fm-context-handoff-mod-plugin.test.sh
tests/fm-spawn-dispatch-profile.test.sh
```
