#!/usr/bin/env bash
# Behavior tests for fm-time.sh: propose from synthetic signals, approval
# (as-is and corrected), retroactive log entries, live start/stop, split, and
# the month-end report's grouping and after-hours split.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FMTIME="$ROOT/bin/fm-time.sh"
TMP_ROOT=$(fm_test_tmproot fm-time)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# touch_at <path> <YYYY-MM-DD> <HH:MM>: portable POSIX `touch -t` mtime set.
touch_at() {
  local path=$1 date=$2 hm=$3 stamp
  stamp="${date//-/}${hm/:/}"
  touch -t "$stamp" "$path"
}

# local_epoch <YYYY-MM-DD HH:MM>: local wall clock -> epoch seconds.
local_epoch() {
  date -j -f '%Y-%m-%d %H:%M' "$1" '+%s' 2>/dev/null || date -d "$1" '+%s'
}

# commit_at <worktree> <epoch> <message>: an empty commit whose committer time,
# and so its reflog entry, is <epoch>.
commit_at() {
  GIT_COMMITTER_DATE="$2 +0000" GIT_AUTHOR_DATE="$2 +0000" \
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$3"
}

# ---------------------------------------------------------------- propose

test_propose_clusters_synthetic_status_and_meta_evidence() {
  local home
  home=$(make_home propose-basic)

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
kind=ship
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  cat > "$home/state/demo-task.status" <<'EOF'
working: doing the thing
done: fixed the widget
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:40

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on synthetic status+meta evidence"
  assert_contains "$out" "1 proposed window" "close-together meta+status pings did not merge into one window"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "[p1]" "proposal id p1 missing from list"
  assert_contains "$list" "project  FnO" "proposal did not attribute the project from state/<id>.meta"
  assert_contains "$list" "task     demo-task" "proposal did not attribute the task id"
  assert_contains "$list" "evidence: " "proposal listed no evidence for the captain to judge"
  assert_contains "$list" "task record touched" "meta-touch evidence line missing"
  assert_contains "$list" "done: fixed the widget" "status-line evidence text missing"

  pass "propose clusters close synthetic status+meta pings into one evidenced window"
}

test_propose_wide_gap_produces_two_windows() {
  local home
  home=$(make_home propose-gap)

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 09:00

  cat > "$home/state/demo-task.status" <<'EOF'
done: unrelated later work
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 20:00

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on wide-gap evidence"
  assert_contains "$out" "2 proposed window" "pings 11 hours apart (past the default gap) incorrectly merged"

  pass "propose starts a new window once the gap exceeds the configured threshold"
}

test_propose_refuses_second_batch_without_replace() {
  local home out err status
  home=$(make_home propose-pending)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 09:00

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null \
    || fail "first propose failed"

  status=0
  err=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" 2>&1 >/dev/null) || status=$?
  expect_code 1 "$status" "propose with a pending batch and no --replace"
  assert_contains "$err" "--replace" "refusal did not mention the --replace escape hatch"

  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" --replace) \
    || fail "propose --replace should succeed over a pending batch"
  assert_contains "$out" "proposed window" "propose --replace did not regenerate a batch"

  pass "propose refuses a second batch while one is pending, unless --replace is given"
}

test_propose_reads_reported_scout_completions_from_backlog() {
  local home
  home=$(make_home propose-reported)

  cat > "$home/data/backlog.md" <<'EOF'
- [x] carry-scout-example - Diagnose the thing data/carry-scout-example/report.md (repo: FnO) (reported 2026-09-05)
EOF

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a scout-style (reported ...) backlog completion"
  assert_contains "$out" "1 proposed window" "a (reported ...) backlog completion produced no proposal"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "project  FnO" "reported-completion proposal did not attribute the (repo: ...) project"
  assert_contains "$list" "task     carry-scout-example" "reported-completion proposal did not attribute the task id"

  pass "propose reads (reported YYYY-MM-DD) scout completions from the backlog, not only (done ...)"
}

test_propose_reads_merged_completions_from_backlog() {
  local home
  home=$(make_home propose-merged)

  # tasks-axi writes "(merged YYYY-MM-DD)" instead of "(done ...)" for a task
  # closed with `done <id> --pr <url>` (verified against a real tasks-axi
  # binary); without handling this marker, every PR-linked completion is
  # invisible to propose.
  cat > "$home/data/backlog.md" <<'EOF'
- [x] carry-ship-example - Ship the thing https://github.com/o/r/pull/42 (repo: FnO) (merged 2026-09-05)
EOF

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a (merged ...) backlog completion"
  assert_contains "$out" "1 proposed window" "a (merged ...) backlog completion produced no proposal"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "project  FnO" "merged-completion proposal did not attribute the (repo: ...) project"
  assert_contains "$list" "task     carry-ship-example" "merged-completion proposal did not attribute the task id"
  assert_not_contains "$list" "merged 2026-09-05" "merged-completion evidence text leaked the raw marker instead of the description"

  pass "propose reads (merged YYYY-MM-DD) PR completions from the backlog, not only (done ...)"
}

# ---------------------------------------------------------------- approve / correction

test_approve_records_entry_and_advances_cursor() {
  local home
  home=$(make_home approve-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null

  local out
  out=$(FM_HOME="$home" "$FMTIME" approve p1) || fail "approve p1 failed"
  assert_contains "$out" "approved p1" "approve did not report success"
  assert_grep "task=demo-task" "$home/data/time-tracking/entries.md" \
    "approved entry missing task attribution"
  assert_present "$home/data/time-tracking/cursor" "approving the only pending proposal did not advance the cursor"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list after approve failed"
  assert_contains "$list" "no pending proposals" "approved proposal still shows as pending"

  pass "approve records the window as a durable entry and clears it from pending"
}

test_approve_correction_overrides_proposed_fields() {
  local home
  home=$(make_home approve-correct)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30
  cat > "$home/state/demo-task.status" <<'EOF'
working: first pass
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:35

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" approve p1 \
    --start "2026-09-05 18:00" --end "2026-09-05 19:30" --desc "corrected description" \
    || fail "corrected approve failed"

  assert_grep "start=2026-09-05 18:00" "$home/data/time-tracking/entries.md" \
    "corrected start time was not recorded"
  assert_grep "end=2026-09-05 19:30" "$home/data/time-tracking/entries.md" \
    "corrected end time was not recorded"
  assert_grep "desc=corrected description" "$home/data/time-tracking/entries.md" \
    "corrected description was not recorded"

  pass "approve accepts start/end/desc corrections over the proposed defaults"
}

test_reject_drops_without_recording() {
  local home
  home=$(make_home reject-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" reject p1 || fail "reject p1 failed"

  if [ -e "$home/data/time-tracking/entries.md" ]; then
    assert_no_grep "demo-task" "$home/data/time-tracking/entries.md" \
      "rejected proposal was recorded as an entry anyway"
  fi
  pass "reject drops a proposal without recording anything"
}

test_split_divides_evidence_at_the_boundary() {
  local home
  home=$(make_home split-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:00
  cat > "$home/state/demo-task.status" <<'EOF'
working: part one
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:10

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" split p1 --at "2026-09-05 18:05" || fail "split failed"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list after split failed"
  assert_contains "$list" "[p1-a]" "split did not produce the first half"
  assert_contains "$list" "[p1-b]" "split did not produce the second half"
  assert_contains "$list" "end      2026-09-05 18:05" "split first half did not end at the boundary"
  assert_contains "$list" "start    2026-09-05 18:05" "split second half did not start at the boundary"

  FM_HOME="$home" "$FMTIME" approve p1-a --desc first >/dev/null || fail "approve p1-a failed"
  FM_HOME="$home" "$FMTIME" approve p1-b --desc second >/dev/null || fail "approve p1-b failed"
  assert_grep "desc=first" "$home/data/time-tracking/entries.md" "first half not recorded"
  assert_grep "desc=second" "$home/data/time-tracking/entries.md" "second half not recorded"

  pass "split divides a proposal's evidence at the given boundary into two approvable halves"
}

# ---------------------------------------------------------------- start / stop / log

test_start_stop_records_a_live_session() {
  local home out
  home=$(make_home live-session)

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" start --project firstmate --task demo --desc "building") \
    || fail "start failed"
  assert_present "$home/data/time-tracking/active" "start did not create an active-session record"

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788805000 "$FMTIME" stop) || fail "stop failed"
  assert_contains "$out" "stopped" "stop did not report success"
  assert_absent "$home/data/time-tracking/active" "stop left the active-session record behind"
  assert_grep "desc=building" "$home/data/time-tracking/entries.md" "start/stop entry missing its description"

  local status err
  status=0
  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810000 "$FMTIME" start --desc again >/dev/null \
    || fail "second start after a stop should succeed"
  err=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810000 "$FMTIME" start --desc other 2>&1 >/dev/null) \
    && status=0 || status=$?
  expect_code 1 "$status" "starting a second live session while one is already running"
  assert_contains "$err" "already running" "double-start refusal used the wrong message"
  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810120 "$FMTIME" stop >/dev/null

  pass "start/stop records a live-tracked entry and refuses a concurrent second start"
}

test_stop_refuses_same_minute_session() {
  local home out status
  home=$(make_home live-session-same-minute)

  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" start --desc "blink" >/dev/null \
    || fail "start failed"

  status=0
  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" stop 2>&1) || status=$?
  expect_code 1 "$status" "stop within the same wall-clock minute as start"
  assert_contains "$out" "wait" "same-minute stop refusal used the wrong message"
  assert_present "$home/data/time-tracking/active" \
    "a refused same-minute stop must leave the live session running, not discard it"
  if [ -e "$home/data/time-tracking/entries.md" ]; then
    assert_no_grep "blink" "$home/data/time-tracking/entries.md" \
      "a refused same-minute stop must not record a zero-duration entry"
  fi

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800061 "$FMTIME" stop) \
    || fail "stop should succeed once a minute has actually elapsed"
  assert_contains "$out" "stopped" "stop did not report success once past the same-minute window"
  assert_grep "desc=blink" "$home/data/time-tracking/entries.md" \
    "session was not recorded once stopped past the same-minute window"

  pass "stop refuses a same-minute session instead of silently recording a lost, zero-duration entry"
}

test_log_records_a_retroactive_entry() {
  local home out
  home=$(make_home retro-log)
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 21:30" \
    --project FnO --task carry-widget-fix --desc "retroactively logged debugging") \
    || fail "log failed"
  assert_contains "$out" "logged" "log did not report success"
  assert_grep "desc=retroactively logged debugging" "$home/data/time-tracking/entries.md" \
    "retroactive log entry missing its description"
  assert_grep "task=carry-widget-fix" "$home/data/time-tracking/entries.md" \
    "retroactive log entry missing its task"

  pass "log records a retroactive entry directly, with no proposal step"
}

test_log_without_project_or_task_is_not_blocked() {
  local home out
  home=$(make_home retro-log-no-task)
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" \
    --desc "quick email reply, no task tied to it") \
    || fail "log without --project/--task should not be blocked"
  assert_contains "$out" "logged" "log did not report success"

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "report failed"
  assert_contains "$out" "(unattributed)" "report did not render a missing project/task as readable prose"
  assert_contains "$out" "quick email reply" "unattributed entry's description is missing from the report"

  pass "a missing task id never blocks recording, and the report renders it as readable prose"
}

test_log_refuses_end_before_start() {
  local home status
  home=$(make_home retro-log-bad)
  status=0
  FM_HOME="$home" "$FMTIME" log --start "2026-09-04 21:00" --end "2026-09-04 20:00" \
    --desc bad >/dev/null 2>/tmp/fm-time-test-err3 || status=$?
  expect_code 1 "$status" "log with end before start"
  assert_contains "$(cat /tmp/fm-time-test-err3)" "after" "end-before-start refusal used the wrong message"
  rm -f /tmp/fm-time-test-err3
  pass "log refuses an entry whose end is not after its start"
}

# ---------------------------------------------------------------- own lock

test_lock_blocks_while_owner_process_is_still_alive() {
  local home lock_dir sleeper_pid status err elapsed start_s
  home=$(make_home lock-live-owner)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  sleep 60 &
  sleeper_pid=$!
  printf '%s\n' "$sleeper_pid" > "$lock_dir/pid"
  # A far-past mtime: an age-only staleness check (the pre-fix behavior)
  # would treat this as abandoned and steal it even though its recorded
  # owner is still running.
  touch -t 202001010000 "$lock_dir"

  status=0
  start_s=$SECONDS
  err=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc x 2>&1) \
    || status=$?
  elapsed=$((SECONDS - start_s))

  kill "$sleeper_pid" 2>/dev/null
  wait "$sleeper_pid" 2>/dev/null

  expect_code 1 "$status" "log against a lock recorded as held by a still-alive owner"
  assert_contains "$err" "appears to be running" "a live lock owner's hold was stolen instead of respected"
  [ "$elapsed" -ge 5 ] || fail "the lock was released far too quickly for a live owner to have been respected (waited ${elapsed}s)"

  pass "tt_lock never reclaims a lock whose recorded owner process is still alive, no matter its age"
}

test_lock_reclaimed_promptly_from_a_dead_owner() {
  local home lock_dir dead_pid status out elapsed start_s
  home=$(make_home lock-dead-owner)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  ( exit 0 ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  printf '%s\n' "$dead_pid" > "$lock_dir/pid"
  # Deliberately fresh mtime: an age-only staleness check would refuse to
  # reclaim this for LOCK_STALE_SECS even though the recorded owner is
  # already dead; liveness must decide this, not age.

  start_s=$SECONDS
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc reclaimed 2>&1)
  status=$?
  elapsed=$((SECONDS - start_s))

  expect_code 0 "$status" "log against a lock abandoned by a dead owner"
  assert_contains "$out" "logged" "log did not succeed once the dead owner's lock was reclaimed"
  [ "$elapsed" -lt 5 ] || fail "a lock with a dead recorded owner should reclaim immediately, not wait out a staleness timer (took ${elapsed}s)"

  pass "tt_lock reclaims a lock immediately once its recorded owner is confirmed dead, even when the lock is fresh"
}

test_lock_reclaimed_when_owner_pid_was_reused() {
  local home lock_dir live_pid status out elapsed start_s
  home=$(make_home lock-reused-pid)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  # A live process, but recorded alongside a start timestamp that does not
  # match its real one: this is what a reused pid looks like on disk after
  # its original owner exited and an unrelated process picked up the same
  # pid number. kill -0 alone cannot tell this apart from a genuine live
  # owner; only the recorded start time can.
  sleep 60 &
  live_pid=$!
  printf '%s\n' "$live_pid" > "$lock_dir/pid"
  printf '%s\n' "Mon Jan  1 00:00:00 1990" > "$lock_dir/start"
  touch -t 202001010000 "$lock_dir"

  start_s=$SECONDS
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc reclaimed 2>&1)
  status=$?
  elapsed=$((SECONDS - start_s))

  kill "$live_pid" 2>/dev/null
  wait "$live_pid" 2>/dev/null

  expect_code 0 "$status" "log against a lock whose recorded owner pid was reused by an unrelated live process"
  assert_contains "$out" "logged" "log did not succeed once the reused-pid lock was reclaimed"
  [ "$elapsed" -lt 5 ] || fail "a lock whose owner start time no longer matches should reclaim immediately (took ${elapsed}s)"

  pass "tt_lock reclaims a lock whose live recorded pid no longer matches its recorded start time (pid reuse)"
}

# ---------------------------------------------------------------- report

test_report_groups_by_month_and_splits_after_hours() {
  local home
  home=$(make_home report-basic)

  # After-hours: a weekday evening entry (2026-09-02 is a Wednesday).
  FM_HOME="$home" "$FMTIME" log --start "2026-09-02 19:00" --end "2026-09-02 20:00" \
    --project FnO --task widget-fix --desc "evening fix" >/dev/null
  # Business hours: same day, mid-afternoon.
  FM_HOME="$home" "$FMTIME" log --start "2026-09-02 14:00" --end "2026-09-02 15:00" \
    --project FnO --task widget-fix --desc "afternoon follow-up" >/dev/null
  # A different month entirely, must not appear in the September report.
  FM_HOME="$home" "$FMTIME" log --start "2026-08-15 10:00" --end "2026-08-15 11:00" \
    --project FnO --task widget-fix --desc "august work" >/dev/null

  local out
  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "report failed"
  assert_contains "$out" "2026-09" "report header missing the requested month"
  assert_contains "$out" "total: 2h00m" "report total did not sum both September entries"
  assert_contains "$out" "after hours" "report did not label after-hours time"
  assert_contains "$out" "1h00m" "report is missing the 1-hour after-hours contribution"
  assert_not_contains "$out" "august work" "August entry leaked into the September report"

  pass "report sums entries for the requested month only and separates after-hours time"
}

test_report_month_boundary_uses_entry_start_date() {
  local home out
  home=$(make_home report-boundary)
  FM_HOME="$home" "$FMTIME" log --start "2026-08-31 23:00" --end "2026-09-01 01:00" \
    --project FnO --task overnight --desc "crossed midnight into September" >/dev/null

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-08) || fail "august report failed"
  assert_contains "$out" "total: 2h00m" "an entry starting in August was not counted in the August report"

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "september report failed"
  assert_contains "$out" "no entries recorded" "an entry that only ENDS in September was wrongly counted there too"

  pass "report attributes a midnight-crossing entry to its start month, not its end month"
}

test_time_tracking_never_writes_supervision_state() {
  local home before_lock before_wake
  home=$(make_home no-supervision-touch)
  printf 'pid-marker\n' > "$home/state/.lock"
  printf '111\t1\tcheck\tk\tp\n' > "$home/state/.wake-queue"
  before_lock=$(cat "$home/state/.lock")
  before_wake=$(cat "$home/state/.wake-queue")

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" approve p1 >/dev/null
  FM_HOME="$home" "$FMTIME" report --month 2026-09 >/dev/null

  [ "$(cat "$home/state/.lock")" = "$before_lock" ] || fail "fm-time.sh modified the session lock file"
  [ "$(cat "$home/state/.wake-queue")" = "$before_wake" ] || fail "fm-time.sh modified the durable wake queue"

  pass "propose/approve/report only read state/.lock and state/.wake-queue, never write them"
}


# ---------------------------------------------------------------- status replay and commit spans

test_single_stamped_status_line_keeps_the_pad_fallback() {
  local home t0 out list
  home=$(make_home replay-single)
  t0=$(local_epoch "2026-09-07 10:00")
  printf 'done [at=%s]: fixed the widget\n' "$t0" > "$home/state/solo.status"
  touch_at "$home/state/solo.status" 2026-09-07 14:00

  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a one-line status log"
  assert_contains "$out" "1 proposed window" "a one-line status log did not yield exactly one window"
  list=$(FM_HOME="$home" "$FMTIME" list)
  assert_contains "$list" "start    2026-09-07 14:00" "a one-line status log no longer pings at its mtime"
  assert_contains "$list" "end      2026-09-07 14:15" "a one-line status log no longer credits the flat pad"

  pass "a status log with one stamped line keeps the last-touch ping and flat pad"
}

test_status_replay_credits_active_intervals_and_excludes_a_paused_span() {
  local home t0 out list report
  home=$(make_home replay-paused)
  t0=$(local_epoch "2026-09-07 10:00")
  cat > "$home/state/demo-task.status" <<EOF
working [at=$t0]: setup done
paused [at=$((t0 + 1800))]: waiting on the validation run
resolved [at=$((t0 + 3000))]: validation returned a finding
done [at=$((t0 + 5400))]: PR checks green
EOF
  printf 'project=%s/projects/FnO\nkind=ship\n' "$home" > "$home/state/demo-task.meta"
  touch_at "$home/state/demo-task.meta" 2026-09-07 10:00
  # A firstmate-side record touch inside the declared wait is not work.
  mkdir -p "$home/data/demo-task"
  printf 'report\n' > "$home/data/demo-task/report.md"
  touch_at "$home/data/demo-task/report.md" 2026-09-07 10:40

  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a multi-transition status log"
  assert_contains "$out" "2 proposed window" "a 20-minute declared pause did not split the work into two windows"
  list=$(FM_HOME="$home" "$FMTIME" list)
  assert_contains "$list" "start    2026-09-07 10:00" "first active interval does not start at the working line"
  assert_contains "$list" "end      2026-09-07 10:30" "first active interval does not end at the paused line"
  assert_contains "$list" "start    2026-09-07 10:50" "second active interval does not start at the resolved line"
  assert_contains "$list" "end      2026-09-07 11:30" "second active interval does not end at the done line, unpadded"
  assert_contains "$list" "not credited" "the declared wait is not listed as uncredited evidence"
  assert_not_contains "$list" "scout report finalized" "a ping inside the declared wait was credited"

  FM_HOME="$home" "$FMTIME" approve p1 >/dev/null || fail "approve p1 failed"
  FM_HOME="$home" "$FMTIME" approve p2 >/dev/null || fail "approve p2 failed"
  report=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "report failed"
  assert_contains "$report" "total: 1h10m" "replayed work did not total the 70 active minutes, excluding the 20-minute pause"

  pass "status replay credits measured active intervals and excludes a declared paused span"
}

test_teardown_capture_records_a_ship_branch_commit_span() {
  local home repo wt t0 record out list
  home=$(make_home capture-ship)
  repo="$home/project"
  wt="$home/wt"
  t0=$(local_epoch "2026-09-08 09:00")
  git init -q -b main "$repo"
  commit_at "$repo" "$((t0 - 86400))" "baseline"
  git -C "$repo" worktree add -q -b fm/ship-x "$wt" main
  commit_at "$wt" "$((t0 + 600))" "first"
  commit_at "$wt" "$((t0 + 2400))" "second"
  commit_at "$wt" "$((t0 + 4200))" "third"
  cat > "$home/state/ship-x.meta" <<EOF
project=$repo
kind=ship
branch=fm/ship-x
worktree=$wt
EOF
  printf 'done [at=%s]: ready on branch\n' "$((t0 + 4500))" > "$home/state/ship-x.status"
  touch_at "$home/state/ship-x.status" 2026-09-08 10:15

  FM_HOME="$home" "$FMTIME" capture ship-x || fail "capture failed on a ship worktree"
  record="$home/data/time-tracking/evidence/ship-x.record"
  assert_present "$record" "capture wrote no evidence record"
  assert_grep "commits_first=$((t0 + 600))" "$record" "commit span does not start at the first branch commit"
  assert_grep "commits_last=$((t0 + 4200))" "$record" "commit span does not end at the last branch commit"
  assert_grep 'commits_count=3' "$record" "commit span did not count the three branch commits (or counted the baseline)"
  assert_grep 'status=done [at=' "$record" "status log line was not captured"

  # Teardown then deletes the branch, the status log, and the task record; a
  # rerun after that keeps the earlier commit span.
  git -C "$wt" checkout -q --detach
  git -C "$wt" branch -q -D fm/ship-x
  FM_HOME="$home" "$FMTIME" capture ship-x || fail "capture rerun failed after the branch was deleted"
  assert_grep 'commits_count=3' "$record" "a capture rerun after branch deletion dropped the commit span"
  rm -f "$home/state/ship-x.status" "$home/state/ship-x.meta"

  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a captured evidence record"
  assert_contains "$out" "1 proposed window" "commit span and done ping did not merge into one window"
  list=$(FM_HOME="$home" "$FMTIME" list)
  assert_contains "$list" "start    2026-09-08 09:10" "window does not start at the first commit"
  assert_contains "$list" "end      2026-09-08 10:30" "window does not end at the padded done ping after the last commit"
  assert_contains "$list" "project  project" "project attribution was not kept in the evidence record"
  assert_contains "$list" "3 commit(s) on fm/ship-x" "commit-span evidence is not listed"

  pass "teardown capture records a ship branch's first-to-last commit span, and propose credits it after cleanup"
}

test_teardown_capture_records_scout_scratch_commits_only() {
  local home repo wt t0 record
  home=$(make_home capture-scout)
  repo="$home/project"
  wt="$home/wt"
  t0=$(local_epoch "2026-09-09 13:00")
  git init -q -b main "$repo"
  commit_at "$repo" "$((t0 - 86400))" "baseline"
  git -C "$repo" worktree add -q --detach "$wt" main
  commit_at "$wt" "$t0" "scratch one"
  commit_at "$wt" "$((t0 + 1500))" "scratch two"
  printf 'project=%s\nkind=scout\nworktree=%s\n' "$repo" "$wt" > "$home/state/scout-y.meta"

  FM_HOME="$home" "$FMTIME" capture scout-y || fail "capture failed on a scout worktree"
  record="$home/data/time-tracking/evidence/scout-y.record"
  assert_grep "commits_first=$t0" "$record" "scout span does not start at its first scratch commit"
  assert_grep "commits_last=$((t0 + 1500))" "$record" "scout span does not end at its last scratch commit"
  assert_grep 'commits_count=2' "$record" "scout span counted commits a branch already reaches"

  pass "teardown capture records a scout's unpushed scratch commits as its span"
}

test_captured_status_log_is_replayed_once_after_teardown() {
  local home t0 out list
  home=$(make_home replay-record)
  t0=$(local_epoch "2026-09-10 15:00")
  cat > "$home/state/gone.status" <<EOF
working [at=$t0]: investigating
done [at=$((t0 + 2700))]: report written
EOF
  printf 'project=%s/projects/FnO\nkind=task\n' "$home" > "$home/state/gone.meta"
  touch_at "$home/state/gone.meta" 2026-09-10 15:00
  FM_HOME="$home" "$FMTIME" capture gone || fail "capture failed on a task without a worktree"
  assert_no_grep 'commits_' "$home/data/time-tracking/evidence/gone.record" \
    "a task without a worktree gained commit evidence"

  # Before cleanup both copies exist; they must count once.
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00")
  assert_contains "$out" "1 proposed window" "live status log and its captured copy were not deduplicated"
  list=$(FM_HOME="$home" "$FMTIME" list)
  assert_contains "$list" "end      2026-09-10 15:45" "deduplicated replay did not end at the done line"

  rm -f "$home/state/gone.status" "$home/state/gone.meta"
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" --replace)
  assert_contains "$out" "1 proposed window" "the captured status log was not replayed after cleanup"
  list=$(FM_HOME="$home" "$FMTIME" list)
  assert_contains "$list" "start    2026-09-10 15:00" "captured replay lost the working line"
  assert_contains "$list" "end      2026-09-10 15:45" "captured replay lost the done line"
  assert_contains "$list" "project  FnO" "captured replay lost the project attribution"

  pass "a captured status log replays after cleanup, and once while both copies exist"
}

test_propose_clusters_synthetic_status_and_meta_evidence
test_propose_wide_gap_produces_two_windows
test_propose_refuses_second_batch_without_replace
test_propose_reads_reported_scout_completions_from_backlog
test_propose_reads_merged_completions_from_backlog
test_approve_records_entry_and_advances_cursor
test_approve_correction_overrides_proposed_fields
test_reject_drops_without_recording
test_split_divides_evidence_at_the_boundary
test_start_stop_records_a_live_session
test_stop_refuses_same_minute_session
test_log_records_a_retroactive_entry
test_log_without_project_or_task_is_not_blocked
test_log_refuses_end_before_start
test_lock_blocks_while_owner_process_is_still_alive
test_lock_reclaimed_promptly_from_a_dead_owner
test_lock_reclaimed_when_owner_pid_was_reused
test_report_groups_by_month_and_splits_after_hours
test_report_month_boundary_uses_entry_start_date
test_time_tracking_never_writes_supervision_state
test_single_stamped_status_line_keeps_the_pad_fallback
test_status_replay_credits_active_intervals_and_excludes_a_paused_span
test_teardown_capture_records_a_ship_branch_commit_span
test_teardown_capture_records_scout_scratch_commits_only
test_captured_status_log_is_replayed_once_after_teardown
