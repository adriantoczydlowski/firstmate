# Captain-wait recheck cadence: before vs after

Scenario reproduced through the real `bin/fm-watch.sh` (attended mode, no away
record), mirroring the 2026-09-26 audit: three parked tasks
(`remove-entry-hour-gates`, `gwk-round3-oferta-akademia`,
`gwk-round4-tickets-seats`) each declaring `paused [on=captain]: ...`, with
their recheck throttles aged on staggered clocks (5000s / 5170s / 5340s) far
past a 240s demo cadence. A control home holds one task with an external
`paused: awaiting the upstream 4.2 release ...` wait. Driver:
`captain-wait-cadence-demo.sh <root> <label>`.

| Commit | Captain-wait first sighting | Captain-wait rechecks after throttle aged | External-wait recheck |
|---|---|---|---|
| base `8091d3e` | surfaced once each, labelled "awaiting external" | **watcher exited immediately with a recheck wake** (`recheck wake rows appended in phase 2: 1`; the other two follow on later cycles) | delivered |
| target `522a1d3` | surfaced once each, labelled "awaiting the captain ... surfaced once and not rechecked" | **none across 4 full poll cycles** (`recheck wake rows appended in phase 2: 0`) | delivered |

Reason line the captain sees at the target, once per declaration:

    stale: test:fm-gwk-round3-oferta-akademia (paused 501s, awaiting the captain - the wait names the captain, surfaced once and not rechecked; answer the wait or release it)

Reason line the captain saw at the base, once per declaration AND again on every cadence:

    stale: test:fm-gwk-round3-oferta-akademia (paused 529s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)

Full transcripts: `captain-wait-cadence-base.txt`, `captain-wait-cadence-target.txt`.
Targeted suites (`bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-daemon.test.sh tests/fm-afk-return.test.sh`): `targeted-tests.log`.
