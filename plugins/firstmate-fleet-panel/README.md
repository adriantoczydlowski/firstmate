# Firstmate Fleet Panel

An experimental Claude Code mod that shows Firstmate's own fleet in a pane: each task in flight with its current state, its latest status event, and the wake queue.
It is a Firstmate-specific take on the live agents panel in the community `savvy-progress` mod, reading Firstmate's records instead of the session's subagents.

## What it shows

Type `/fleet` to open or close the pane.

- The observed Firstmate home and its backlog counts (in flight, queued).
- One entry per task with recorded metadata: its id and kind, its current state and where that state came from, the latest status-log line with its age, an open-decision marker, and the PR URL when one is recorded.
- The wake queue, newest first: sequence number, wake kind, key, age, and payload.
- A status line under the prompt, such as `fleet: 2 working · 1 blocked · wakes 3`, kept current even while the pane is closed.

The mod only reads.
It never drains or acknowledges a wake, steers a worker, or edits the backlog.

## Where the data comes from

- The fleet is `bin/fm-fleet-snapshot.sh --json` of the observed home, the same structured contract `bin/fm-fleet-view.sh` renders, so a task's state is `bin/fm-crew-state.sh`'s verdict and is never re-derived here.
  The mod runs it with `FM_CREW_STATE_NO_FORGE=1`, so no state read calls the forge.
  The snapshot's own documented side effect still applies: it may refresh its cached copies of remote secondmate summaries.
- The wake queue is `state/.wake-queue`, read as a file.
  `bin/fm-wake-drain.sh` is deliberately not used, because draining claims and retires rows.

The observed home is the `fmHome` option when set, else `$FM_HOME`, else the session's working directory.

## Refresh

- The wake queue is one small file, so it is read every 5 seconds.
- The snapshot asks every task's current state and takes several seconds on a busy home, so it runs once at session start, every 30 seconds while the pane is open, and when you press the pane's refresh button (`r`).
  Only one snapshot runs at a time.

## Patterns it demonstrates

- Background work started in `session.start` and kept going with `$.clock.every`.
- Host commands through `$.process.run` with a bounded timeout and an explicit environment.
- Pane state in `$.state`, declared in `types/index.d.ts`, so a reload keeps what the pane shows.
- A `userConfig` option with an environment-variable fallback read through `$.env.get`.

## Try it

From this repository's root, with the home you want to observe:

```bash
claude plugin validate plugins/firstmate-fleet-panel
claude plugin test plugins/firstmate-fleet-panel
FM_HOME=/path/to/your/firstmate/home claude --plugin-dir plugins/firstmate-fleet-panel
```

Then type `/fleet`.
In the fullscreen layout the pane docks to the right; on the main screen it opens inline.

## Notes and limitations

- This is an experiment, not a supported Firstmate surface.
- A status-log line is a wake event, not current state; the pane labels it "last event" for that reason.
- Remote secondmate rows show whatever the snapshot reports for them, which is often `unknown`.
- Only the 8 newest wakes are listed; the header counts them all.
