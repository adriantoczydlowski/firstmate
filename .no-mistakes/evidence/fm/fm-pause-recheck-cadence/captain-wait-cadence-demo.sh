#!/usr/bin/env bash
# captain-wait-cadence-demo.sh <firstmate-root> <label>
#
# Reproduces the 2026-09-26 audit scenario against a REAL bin/fm-watch.sh:
# three parked tasks whose declared wait is on the captain, each with a
# staggered recheck clock, watched in attended mode (no away record). Phase 1
# lets each wait surface its one sighting. Phase 2 ages every recheck throttle
# far past the cadence and runs the watcher through several poll cycles,
# counting how many recheck wakes reach the captain. A control task in a
# separate home declares an EXTERNAL wait and must still be rechecked.
set -u
ROOT=$(cd -P -- "$1" && pwd -P); LABEL=$2
export ROOT
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-wait-demo)
CADENCE=240

say() { printf '%s\n' "$*"; }
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
file_mtime() { if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
set_mtime() { local stamp; stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S); touch -t "$stamp" "$2"; }
seen_sig() { printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$1")" "$(size_of "$1")" "$(_fm_open_decisions_file_ident "$1")"; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_poll_cycle() {  # <state> <pid>
  local state=$1 pid=$2 beat first now i=0; beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt 300 ]; do kill -0 "$pid" 2>/dev/null || return 1; first=$(file_mtime "$beat"); [ -n "$first" ] && break; sleep 0.1; i=$((i+1)); done
  while [ "$i" -lt 300 ]; do kill -0 "$pid" 2>/dev/null || return 1; now=$(file_mtime "$beat"); [ -n "$now" ] && [ "$now" != "$first" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
ack_cycle() {  # <state>
  local state=$1 err seq gen; err="$state/.demo-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$1/.wake-queue" 2>/dev/null || echo 0
}
run_watch() {  # <state> <fakebin> <windows> <capture> <out> [extra env...]
  local state=$1 fakebin=$2 windows=$3 capture=$4 out=$5; shift 5
  env "$@" PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$windows" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=$CADENCE FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  PID=$!
}
add_task() {  # <state> <task> <status-line> <capture>
  local state=$1 task=$2 line=$3 capture=$4 window key
  window="test:fm-$task"; key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf '%s\n' "$line" > "$state/$task.status"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/$task.status"
  printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}
export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'

say "=== [$LABEL] root=$ROOT"
say "=== [$LABEL] FM_PAUSE_RESURFACE_SECS_DEFAULT=$FM_PAUSE_RESURFACE_SECS_DEFAULT (demo cadence ${CADENCE}s)"

# ---------------------------------------------------------------- scenario 1
dir=$(make_case captain-home); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
printf 'idle after agent exit\n' > "$capture"
add_task "$state" remove-entry-hour-gates     "paused [on=captain]: awaiting the captain's answers on the entry-hour gate questions" "$capture"
add_task "$state" gwk-round3-oferta-akademia  "paused [on=captain]: awaiting the captain's merge word (project deferred by the captain)" "$capture"
add_task "$state" gwk-round4-tickets-seats    "paused [on=captain]: awaiting the captain's merge word (project deferred by the captain)" "$capture"
TASKS='remove-entry-hour-gates gwk-round3-oferta-akademia gwk-round4-tickets-seats'
WINDOWS=$(printf 'fm-remove-entry-hour-gates\nfm-gwk-round3-oferta-akademia\nfm-gwk-round4-tickets-seats')

say ""; say "--- [$LABEL] scenario 1: three tasks parked on a wait on the captain, attended mode (no away record)"
say "--- [$LABEL] phase 1: let each wait surface its first sighting"
for round in 1 2 3 4 5 6; do
  run_watch "$state" "$fakebin" "$WINDOWS" "$capture" "$out"; pid=$PID
  if ! wait_for_exit "$pid" 100; then reap "$pid"; say "    round $round: watcher stayed quiet through its budget (nothing left to surface)"; break; fi
  say "    round $round: watcher exited with reason line(s):"; sed 's/^/        /' "$out"
  ack_cycle "$state" || say "    (ack failed)"
done
say "--- [$LABEL] phase 2: age every recheck throttle on staggered clocks far past the ${CADENCE}s cadence"
: > "$state/.wake-queue.phase1-mark"; before_rows=$(wc -l < "$state/.wake-queue" 2>/dev/null | tr -d ' ')
i=0
for t in $TASKS; do
  key=$(printf 'test:fm-%s' "$t" | tr ':/.' '___'); thr="$state/.paused-resurfaced-$key"
  if [ -e "$thr" ]; then set_mtime "$(( $(date +%s) - 5000 - i * 170 ))" "$thr"; say "    throttle for fm-$t aged to $(( 5000 + i * 170 ))s (contents: $(cat "$thr" | cut -c1-40)...)"; else say "    NO throttle recorded for fm-$t"; fi
  i=$((i+1))
done
printf 'idle after agent exit, tick\n' > "$capture"
run_watch "$state" "$fakebin" "$WINDOWS" "$capture" "$out" FM_WATCH_HANDLING_SUCCESSOR=1; pid=$PID
cycles=0
for c in 1 2 3 4; do
  if wait_poll_cycle "$state" "$pid"; then cycles=$((cycles+1)); else break; fi
done
sleep 0.5
if kill -0 "$pid" 2>/dev/null; then say "    watcher still running after $cycles full poll cycles: no wake sent to the captain"; reap "$pid"
else wait "$pid" 2>/dev/null || true; say "    watcher EXITED after $cycles poll cycle(s) with reason line(s):"; sed 's/^/        /' "$out"; fi
after_rows=$(wc -l < "$state/.wake-queue" 2>/dev/null | tr -d ' ')
say "    recheck wake rows appended in phase 2: $(( ${after_rows:-0} - ${before_rows:-0} ))"
say "    triage log tail:"; tail -n 6 "$state/.watch-triage.log" 2>/dev/null | sed 's/^/        /'
S1=$(( ${after_rows:-0} - ${before_rows:-0} ))

# ---------------------------------------------------------------- scenario 2
dir=$(make_case external-home); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
printf 'idle after agent exit\n' > "$capture"
add_task "$state" upstream-release-wait "paused: awaiting the upstream 4.2 release before the port can continue" "$capture"
say ""; say "--- [$LABEL] scenario 2 (control): one task parked on an EXTERNAL wait, same cadence"
run_watch "$state" "$fakebin" "fm-upstream-release-wait" "$capture" "$out"; pid=$PID
if wait_for_exit "$pid" 100; then say "    phase 1: first sighting:"; sed 's/^/        /' "$out"; ack_cycle "$state" || true; else reap "$pid"; say "    phase 1: never surfaced"; fi
key=$(printf 'test:fm-upstream-release-wait' | tr ':/.' '___'); thr="$state/.paused-resurfaced-$key"
[ -e "$thr" ] && set_mtime "$(( $(date +%s) - 5000 ))" "$thr" && say "    throttle aged to 5000s"
printf 'idle after agent exit, tick\n' > "$capture"
run_watch "$state" "$fakebin" "fm-upstream-release-wait" "$capture" "$out" FM_WATCH_HANDLING_SUCCESSOR=1; pid=$PID
if wait_for_exit "$pid" 100; then say "    phase 2: watcher EXITED with the recheck (expected for an external wait):"; sed 's/^/        /' "$out"; S2=1
else reap "$pid"; say "    phase 2: external wait was NOT rechecked"; S2=0; fi

say ""; say "=== [$LABEL] RESULT: captain-wait recheck wakes in phase 2 = $S1 (want 0); external-wait recheck delivered = $S2 (want 1)"
rm -rf "$TMP_ROOT"
