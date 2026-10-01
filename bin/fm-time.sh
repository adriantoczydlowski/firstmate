#!/usr/bin/env bash
# fm-time.sh - propose, approve, and report the captain's own work hours.
#
# Firstmate orchestrates but never clocks the captain in: this script scans
# this home's own durable records for evidence that work happened, PROPOSES
# candidate work windows from that evidence, and records nothing until the
# captain approves, corrects, or rejects each one. Live start/stop and
# retroactive log entries are recorded immediately because starting, stopping,
# or logging IS the captain's approval.
#
# Usage:
#   fm-time.sh propose [--since "<YYYY-MM-DD HH:MM>"] [--replace]
#   fm-time.sh list
#   fm-time.sh approve <id> [--start "<YYYY-MM-DD HH:MM>"] [--end "<YYYY-MM-DD HH:MM>"]
#                           [--project <name>] [--task <name>] [--desc <text>]
#   fm-time.sh reject <id>...
#   fm-time.sh split <id> --at "<YYYY-MM-DD HH:MM>"
#   fm-time.sh start [--project <name>] [--task <name>] [--desc <text>]
#   fm-time.sh stop [--desc <text>]
#   fm-time.sh log --start "<YYYY-MM-DD HH:MM>" --end "<YYYY-MM-DD HH:MM>"
#                   [--project <name>] [--task <name>] --desc <text>
#   fm-time.sh report [--month YYYY-MM] [--project <name>]
#   fm-time.sh capture <task-id> [--no-commits]
#                   (called by bin/fm-teardown.sh, not by hand; see "Teardown
#                   capture" below)
#
# Evidence signals (propose). Investigated candidates and why each is used or
# skipped:
#   - state/<id>.status replay        used for every task kind: each line's
#                                      [at=<epoch>] stamp and verb (grammar owned by
#                                      bin/fm-classify-lib.sh) are replayed in time
#                                      order. A working or resolved line opens active
#                                      work, which a paused, blocked, needs-decision,
#                                      done, or failed line closes; the elapsed time
#                                      between is an interval credited as measured,
#                                      not padded. A paused, blocked, or
#                                      needs-decision span closed by a later line is
#                                      a declared wait: it is carved out of every
#                                      credited window for that task (a ping inside it
#                                      is absorbed, an interval or commit span is cut
#                                      around it, a pad never runs into it, and
#                                      windows never merge across it), and it is
#                                      listed as evidence marked "not credited". Work
#                                      still active at the last line is credited the
#                                      pad past it. A done or failed line with no open
#                                      active span is a lone ping. Lines without a
#                                      stamp are skipped. With fewer than two stamped
#                                      lines the file falls back to one last-touch
#                                      ping at its mtime, credited the pad and tagged
#                                      with its tail line.
#                                      Teardown deletes the file, so its lines are
#                                      also replayed from the task's evidence record
#                                      (below); a line present in both counts once.
#   - state/<id>.meta mtime           used: a task's earliest activity often
#                                      predates its first status line, but this
#                                      file is also rewritten well after spawn
#                                      (mode changes, control actions, a merged
#                                      PR's pr= field), so its evidence text
#                                      says only "task record touched", never
#                                      "spawned" - that would overclaim what a
#                                      bare mtime can prove.
#   - data/<id>/report.md mtime       used: scout-report-finalized ping.
#   - data/backlog.md, data/done-archive.md
#                                     used: "(done YYYY-MM-DD)", "(reported
#                                      YYYY-MM-DD)" (tasks-axi writes this for a
#                                      task closed with --report), and "(merged
#                                      YYYY-MM-DD)" (tasks-axi writes this for a
#                                      task closed with --pr) entries all become
#                                      day-only pings (noon local), the only
#                                      signal left for a task torn down without
#                                      an evidence record (below).
#   - state/.wake-queue                used opportunistically: it carries real epoch
#                                      seconds, but the queue is drained on
#                                      acknowledgement, so it holds only whatever is
#                                      CURRENTLY undrained, never a durable history.
#   - session lock (state/.lock)       NOT used: one file, one mtime, no history -
#                                      it names only the current holder, so it cannot
#                                      answer "when was work happening" after the fact.
#   - task commit span                used for ship and scout tasks only, read
#                                      from the evidence record teardown captured:
#                                      the first-to-last commit time on the task's
#                                      own work, an interval credited as measured
#                                      (a single commit is a lone ping). A ship's
#                                      commits are the times its branch's reflog
#                                      recorded each commit made on it (meta
#                                      branch=), which survive a later rebase and
#                                      need no guess at a base ref; a scout's are the
#                                      committer times of its scratch commits that
#                                      no branch or remote reaches (or its branch's
#                                      reflog when it made one). Other kinds, and
#                                      any task without a worktree, have no commits
#                                      and stay on the status replay alone.
#   - project git commit history       NOT used: firstmate's own projects/<name>
#                                      clones sit on their default branch, so this
#                                      would see only merged work, not the in-flight
#                                      branches; the task commit span above covers
#                                      that work instead.
# Every window's evidence list survives into the proposal so `approve` is an
# informed decision, not a rubber stamp of a guess.
#
# Window merging. Evidence pings for the same (project, task) within the
# time-tracking-gap-minutes config setting (default 45 minutes) of each other
# join one window; a bigger gap starts a new one. 45 minutes, not something
# tighter, because this repo's own crewmates are instructed to append status
# only on sparse phase changes rather than routine progress (AGENTS.md section
# 8), so a continuously-worked task can easily go 30-60 minutes between
# evidence pings without having stopped. A lone ping still costs the
# time-tracking-pad-minutes config setting (default 15 minutes) of credited
# time, because a single commit-sized signal is real work, not zero-duration
# work.
#
# After hours. A window's classification is decided by its START time only:
# any day listed in config/time-tracking-weekend-days (default "6,7", ISO
# weekday numbers 1=Monday..7=Sunday, empty = no weekend rule at all so no work
# week is hardcoded) is after hours regardless of clock time; otherwise a start
# before config/time-tracking-workday-start (default 09:00) or at/after
# config/time-tracking-workday-end (default 18:00) is after hours.
#
# Storage. All state lives under this home's gitignored data/time-tracking/,
# never under state/ (supervision-owned) and never inside a project:
#   data/time-tracking/cursor       epoch through which evidence has been fully
#                                    resolved (approved, rejected, or split); the
#                                    floor for the next propose scan.
#   data/time-tracking/proposals.md the current pending batch, one "## <id>" block
#                                    per candidate window; propose refuses to
#                                    generate a new batch while one is pending
#                                    unless --replace is given.
#   data/time-tracking/entries.md   the durable approved ledger, one "## <id>"
#                                    block per recorded window. Plain
#                                    "key=value" lines and one line per evidence
#                                    entry: diffable, and safe to hand-edit because
#                                    duration and after-hours status are always
#                                    recomputed from start/end at report time,
#                                    never trusted from a stored field.
#   data/time-tracking/active       present only between `start` and `stop`.
#   data/time-tracking/evidence/<id>.record
#                                    one task's evidence captured at teardown:
#                                    project=, kind=, branch=, status_mtime=,
#                                    optional commits_first=/commits_last=/
#                                    commits_count= epochs, and one "status=" line
#                                    per status-log line. Read by every propose
#                                    scan, floored by the cursor like any evidence.
#   data/time-tracking/.lock        transient mkdir-based mutex held only for
#                                    the span of a single command's own
#                                    read-modify-write; not part of the durable
#                                    record, and never held across commands.
#
# Configuration (gitignored, one setting per file, absent = default):
#   config/time-tracking-gap-minutes         session-merge gap, minutes (default 45)
#   config/time-tracking-pad-minutes         credited minutes for a lone ping (default 15)
#   config/time-tracking-workday-start       local HH:MM (default 09:00)
#   config/time-tracking-workday-end         local HH:MM (default 18:00)
#   config/time-tracking-weekend-days        comma list, ISO 1-7 (default 6,7)
#
# Teardown capture. bin/fm-teardown.sh deletes state/<id>.status and
# state/<id>.meta, deletes the task branch, and returns the worktree to its pool,
# so it runs `capture` first, after the landed-work checks pass and the worker is
# stopped. `capture` writes the evidence record above from the task record, the
# status log, and the worktree's git history, never changing any of them. A
# rerun merges: status lines are a union, and commit fields are replaced only by
# a capture that found commits, so a retry after the branch is gone keeps them.
# --no-commits skips the git read (teardown passes it when the slot was
# reassigned to another task). Capture is best effort and never blocks cleanup.
#
# Environment:
#   FM_HOME   operational home whose state/, data/, and config/ are used.
#
# Never touches state/.lock, state/.wake-queue, or any other supervision file
# except to read it; never writes to projects/ or a task worktree.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TT="$DATA/time-tracking"

EVIDENCE_DIR="$TT/evidence"

# bin/fm-classify-lib.sh owns the status-line grammar (verb, [at=] stamp, note);
# status replay reads lines only through its readers.
# shellcheck source=bin/fm-classify-lib.sh
. "$SELF_DIR/fm-classify-lib.sh"

die() { printf 'fm-time: %s\n' "$*" >&2; exit 1; }

# Count of "## pN" blocks in proposals.md. grep -c already prints 0 and no
# other output on zero matches, so no `|| echo 0` fallback is needed - adding
# one would double-print when grep's own "0" line is followed by the fallback.
proposal_count() {
  [ -r "$TT/proposals.md" ] || { printf 0; return; }
  grep -c '^## p' "$TT/proposals.md" 2>/dev/null || true
}

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------- portable time

fm_time_mtime() {  # <path> -> epoch seconds, or nothing on failure
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_time_inode() {  # <path> -> inode number, or nothing on failure
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

now_epoch() { printf '%s\n' "${FM_TIME_NOW_OVERRIDE:-$(date +%s)}"; }

# epoch -> "YYYY-MM-DD HH:MM" local wall clock.
epoch_to_local() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

# "YYYY-MM-DD HH:MM" local -> epoch. Empty output on unparseable input.
local_to_epoch() {
  date -j -f '%Y-%m-%d %H:%M' "$1" '+%s' 2>/dev/null || date -d "$1" '+%s' 2>/dev/null
}

epoch_to_dow() {  # ISO weekday, 1=Monday .. 7=Sunday
  date -r "$1" '+%u' 2>/dev/null || date -d "@$1" '+%u' 2>/dev/null
}

epoch_to_hm() {
  date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null
}

epoch_to_yyyymm() {
  date -r "$1" '+%Y-%m' 2>/dev/null || date -d "@$1" '+%Y-%m' 2>/dev/null
}

fmt_minutes() {  # <minutes> -> "1h15m"
  local m=$1 h
  h=$((m / 60)); m=$((m % 60))
  printf '%dh%02dm' "$h" "$m"
}

# ---------------------------------------------------------------- config

read_config() {  # <file-name> <default>
  local path="$CONFIG/$1" line
  if [ -r "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      if [ -n "$line" ]; then
        printf '%s' "$line"
        return 0
      fi
    done < "$path"
  fi
  printf '%s' "$2"
}

GAP_MINUTES=$(read_config time-tracking-gap-minutes 45)
PAD_MINUTES=$(read_config time-tracking-pad-minutes 15)
WORKDAY_START=$(read_config time-tracking-workday-start 09:00)
WORKDAY_END=$(read_config time-tracking-workday-end 18:00)
WEEKEND_DAYS=$(read_config time-tracking-weekend-days 6,7)

is_after_hours() {  # <epoch> -> yes|no
  local epoch=$1 dow hm
  dow=$(epoch_to_dow "$epoch") || { printf 'no'; return; }
  case ",$WEEKEND_DAYS," in
    *",$dow,"*) printf 'yes'; return ;;
  esac
  hm=$(epoch_to_hm "$epoch") || { printf 'no'; return; }
  if [[ "$hm" < "$WORKDAY_START" || "$hm" > "$WORKDAY_END" || "$hm" == "$WORKDAY_END" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# ---------------------------------------------------------------- own lock

# A tiny mkdir-based mutex over this home's OWN time-tracking files - never
# the supervision session lock (state/.lock), which this script only ever
# reads. mkdir is atomic on every filesystem this script already assumes, so
# this needs no flock dependency (flock is absent on macOS; see
# fm-supervise-daemon.sh's own comment on the same tradeoff). The holder's own
# pid is recorded inside the lock dir the instant it is created, and staleness
# is decided by that pid's liveness (kill -0), not by how long the lock has
# been held: `propose` can legitimately hold this lock across a slow evidence
# scan, and a fixed wall-clock cutoff would let a second command steal the
# lock out from under a still-running one, corrupting proposals.md or entries
# in a lost-update race. LOCK_STALE_SECS is kept only as a narrow fallback for
# the brief window after mkdir succeeds but before the pid file is written
# (e.g. a crash in between): once a pid is on record, its liveness is
# authoritative and the lock is held exactly as long as its owner is alive.
#
# Two further races are guarded explicitly rather than left theoretical,
# because this repo's own operational pattern - many short-lived helper
# processes spawned in quick succession - makes both plausible in practice,
# not just on paper:
#   - PID reuse: kill -0 alone cannot tell a live owner from an unrelated
#     process that reused its pid after it exited. The lock dir also records
#     the owner's process-start timestamp (`ps -o lstart=`, supported by both
#     GNU and BSD ps) alongside its pid; a live pid whose current start time
#     no longer matches the recorded one is a different process wearing the
#     same pid, so it is reclaimed exactly like a dead one. When `ps` cannot
#     report a start time (unsupported ps, sandboxed pid namespace) the check
#     is skipped rather than guessed, falling back to plain kill -0 - refusing
#     to weaken the working case for a case that cannot be verified.
#   - Delete-wrong-instance race: deciding a lock is stale and then acting on
#     it are two separate steps, so a successor could create a fresh live
#     lock at the same path in between. Checking identity right before the
#     delete closes the ordinary case; an earlier version of this fix instead
#     moved the directory aside first and verified after, which is actually
#     worse - moving it away first creates a moment where the path sits
#     empty for a *third* command to claim while the second is still
#     deciding whether to put the (possibly-live) directory back, trading one
#     race for a different one. tt_remove_locked_instance instead captures
#     the directory's inode, re-checks it immediately before the one
#     deleting syscall, and does nothing at all - no move, no restore, no
#     window where the path is vacant - the instant it no longer matches.
#     This does not claim perfect atomicity (no flock, per above) but keeps
#     the unavoidable gap to a single stat immediately ahead of a single
#     delete, the floor for a mkdir-based lock on a single-operator tool one
#     person invokes by hand rather than a server serving concurrent
#     requests. The same helper is used by both a waiter reclaiming a lock it
#     believes abandoned and an owner releasing a lock it confirmed is its
#     own, since both are exactly this "verify identity, then delete"
#     problem.
TT_LOCK="$TT/.lock"
LOCK_STALE_SECS="${FM_TIME_LOCK_STALE_OVERRIDE:-10}"

tt_owner_start() {  # <pid> -> that pid's process-start timestamp, or nothing
  ps -o lstart= -p "$1" 2>/dev/null
}

tt_remove_locked_instance() {  # <expected-inode>
  local expected=$1 cur
  [ -n "$expected" ] || return 0
  cur=$(fm_time_inode "$TT_LOCK" 2>/dev/null) || cur=""
  [ "$cur" = "$expected" ] || return 0
  rm -rf "$TT_LOCK" 2>/dev/null || true
}

tt_lock() {
  mkdir -p "$TT"
  local tries=0 age inode owner_pid owner_start cur_start
  while ! mkdir "$TT_LOCK" 2>/dev/null; do
    inode=$(fm_time_inode "$TT_LOCK" 2>/dev/null) || inode=""
    owner_pid=$(cat "$TT_LOCK/pid" 2>/dev/null) || owner_pid=""
    if [ -n "$owner_pid" ]; then
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        tt_remove_locked_instance "$inode"
        continue
      fi
      owner_start=$(cat "$TT_LOCK/start" 2>/dev/null) || owner_start=""
      if [ -n "$owner_start" ]; then
        cur_start=$(tt_owner_start "$owner_pid") || cur_start=""
        if [ -n "$cur_start" ] && [ "$cur_start" != "$owner_start" ]; then
          tt_remove_locked_instance "$inode"
          continue
        fi
      fi
    else
      age=$(fm_time_mtime "$TT_LOCK" 2>/dev/null) || age=""
      if [ -n "$age" ] && [ "$(( $(now_epoch) - age ))" -ge "$LOCK_STALE_SECS" ]; then
        tt_remove_locked_instance "$inode"
        continue
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || die "another fm-time.sh command appears to be running against this home; try again"
    sleep 0.1
  done
  printf '%s\n' "$$" > "$TT_LOCK/pid"
  tt_owner_start "$$" > "$TT_LOCK/start" 2>/dev/null || : > "$TT_LOCK/start"
  trap tt_release_if_owner EXIT
}

# Removes the lock only if its recorded pid is still this process's own pid,
# and even then only the exact instance just confirmed as this process's own
# (see tt_remove_locked_instance above). Used both as the ordinary unlock
# path and as the EXIT trap handler so a signal arriving between tt_unlock's
# own removal and its `trap -` clear can never blow away a lock a *different*
# command has since acquired: by the time the trap fires, the pid file either
# matches this process (safe to remove) or belongs to someone else / is
# already gone (leave it alone).
tt_release_if_owner() {
  local owner_pid inode
  owner_pid=$(cat "$TT_LOCK/pid" 2>/dev/null) || owner_pid=""
  if [ "$owner_pid" = "$$" ]; then
    inode=$(fm_time_inode "$TT_LOCK" 2>/dev/null) || inode=""
    tt_remove_locked_instance "$inode"
  fi
  return 0
}

tt_unlock() {
  tt_release_if_owner
  trap - EXIT
}

# ---------------------------------------------------------------- cursor

CURSOR_FILE="$TT/cursor"

read_cursor() {
  local c
  if [ -r "$CURSOR_FILE" ]; then
    c=$(head -1 "$CURSOR_FILE" 2>/dev/null)
    case "$c" in *[!0-9]*|'') ;; *) printf '%s' "$c"; return ;; esac
  fi
  # No cursor yet: default floor is 30 days back so a first run is bounded.
  printf '%s' "$(( $(now_epoch) - 30 * 86400 ))"
}

write_cursor() {
  mkdir -p "$TT"
  printf '%s\n' "$1" > "$CURSOR_FILE.tmp"
  mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
}

# ---------------------------------------------------------------- evidence gathering

record_field() {  # <record> <field> -> first value of "<field>=" in a key=value record
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

evidence_text() {  # <text> -> one tab-free line of at most 140 characters
  printf '%s' "$1" | tr -d '\t\n' | cut -c1-140
}

# One evidence TSV line, clipped to the scan floor. An empty <end> is a ping
# (credited the pad); a non-empty one is an interval credited as measured.
emit_evidence() {  # <since> <out> <project> <task> <source> <start> <end> <text>
  local since=$1 out=$2 project=$3 task=$4 source=$5 start=$6 end=$7 text=$8
  if [ -z "$end" ]; then
    [ "$start" -gt "$since" ] || return 0
  else
    [ "$end" -gt "$since" ] || return 0
    [ "$start" -gt "$since" ] || start=$since
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$start" "$project" "$task" "$source" "$text" "$end" >> "$out"
}

# An active span from <start> to <end>; a zero-length one is a lone ping.
emit_active() {  # <since> <out> <project> <task> <start> <end> <text>
  if [ "$6" -gt "$5" ]; then
    emit_evidence "$1" "$2" "$3" "$4" status "$5" "$6" "$7"
  else
    emit_evidence "$1" "$2" "$3" "$4" status "$5" "" "$7"
  fi
}

# Status replay (header lever 1) plus the teardown-captured commit span (lever
# 2) for one task. <live> is state/<id>.status when it still exists; <record> is
# data/time-tracking/evidence/<id>.record when teardown captured one. Lines
# present in both are replayed once.
replay_task_evidence() {  # <since> <out> <task> <project> <live-or-empty> <record-or-empty>
  local since=$1 out=$2 id=$3 project=$4 live=$5 record=$6
  local lines line epoch verb note events="" n=0 idx=0 mtime text

  lines=$( {
    [ -z "$live" ] || cat "$live" 2>/dev/null || true
    [ -z "$record" ] || sed -n 's/^status=//p' "$record" 2>/dev/null || true
  } | awk 'NF && !seen[$0]++')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=$((idx + 1))
    epoch=$(status_line_at_epoch "$line") || continue
    status_line_verb "$line" verb
    note=$(status_line_note "$line")
    events="$events$epoch"$'\t'"$idx"$'\t'"$verb"$'\t'"$(evidence_text "$verb: $note")"$'\n'
    n=$((n + 1))
  done <<< "$lines"

  if [ "$n" -lt 2 ]; then
    # Too few stamped events to replay: the lone last-touch ping, credited the pad.
    if [ -n "$live" ]; then
      mtime=$(fm_time_mtime "$live") || mtime=
      text=$(tail -1 "$live" 2>/dev/null | tr -d '\t' | cut -c1-140)
    else
      mtime=$(record_field "$record" status_mtime)
      text=$(evidence_text "$(sed -n 's/^status=//p' "$record" 2>/dev/null | tail -1)")
    fi
    case "$mtime" in
      ''|*[!0-9]*) ;;
      *) [ "$mtime" -le "$since" ] || printf '%s\t%s\t%s\tstatus\t%s\n' "$mtime" "$project" "$id" "$text" >> "$out" ;;
    esac
  else
    local state=idle seg_start=0 seg_last=0 seg_text="" wait_start=0 wait_text=""
    while IFS=$'\t' read -r epoch _ verb text; do
      [ -n "$epoch" ] || continue
      case "$verb" in
        working|resolved)
          case "$state" in
            active) seg_last=$epoch; continue ;;
            wait) emit_evidence "$since" "$out" "$project" "$id" status-wait "$wait_start" "$epoch" "$wait_text" ;;
          esac
          state=active; seg_start=$epoch; seg_last=$epoch; seg_text=$text
          ;;
        paused|blocked|needs-decision)
          case "$state" in
            wait) continue ;;
            active) emit_active "$since" "$out" "$project" "$id" "$seg_start" "$epoch" "$seg_text" ;;
          esac
          state="wait"; wait_start=$epoch; wait_text=$text
          ;;
        done|failed)
          case "$state" in
            active) emit_active "$since" "$out" "$project" "$id" "$seg_start" "$epoch" "$text" ;;
            wait) emit_evidence "$since" "$out" "$project" "$id" status-wait "$wait_start" "$epoch" "$wait_text" ;;
            *) emit_evidence "$since" "$out" "$project" "$id" status "$epoch" "" "$text" ;;
          esac
          state=idle
          ;;
      esac
    done < <(printf '%s' "$events" | sort -t $'\t' -k1,1n -k2,2n)
    # Work still under way at the last report is credited the pad past it, as a
    # lone ping would be. A wait still open has no end yet, so it carves nothing.
    if [ "$state" = active ]; then
      if [ "$seg_last" -gt "$seg_start" ]; then
        emit_evidence "$since" "$out" "$project" "$id" status "$seg_start" "$((seg_last + PAD_MINUTES * 60))" "$seg_text"
      else
        emit_evidence "$since" "$out" "$project" "$id" status "$seg_start" "" "$seg_text"
      fi
    fi
  fi

  [ -n "$record" ] || return 0
  local first last count branch
  first=$(record_field "$record" commits_first)
  last=$(record_field "$record" commits_last)
  count=$(record_field "$record" commits_count)
  branch=$(record_field "$record" branch)
  case "$first:$last" in
    *[!0-9:]*|:*|*:) return 0 ;;
  esac
  text=$(evidence_text "${count:-?} commit(s) on ${branch:-its worktree}")
  if [ "$last" -gt "$first" ]; then
    emit_evidence "$since" "$out" "$project" "$id" commits "$first" "$last" "$text"
  else
    emit_evidence "$since" "$out" "$project" "$id" commits "$first" "" "$text"
  fi
}

# Emits TSV lines: epoch<TAB>project<TAB>task<TAB>source<TAB>text[<TAB>end]
# A sixth end field marks an interval (source status or commits) or, for source
# status-wait, a declared wait that cluster_evidence carves out of the task's
# credited time; lines without it are pings.
gather_evidence() {  # <since-epoch> <out-file>
  local since=$1 out=$2 f id mtime meta project text line kind key payload epoch

  : > "$out"

  local record
  local -A replayed=()
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || break
    id=$(basename "$f" .status)
    project=-
    meta="$STATE/$id.meta"
    if [ -r "$meta" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
      [ -n "$project" ] && project=$(basename "$project") || project=-
    fi
    record="$EVIDENCE_DIR/$id.record"
    [ -r "$record" ] || record=
    if [ "$project" = - ] && [ -n "$record" ]; then
      project=$(record_field "$record" project)
      [ -n "$project" ] || project=-
    fi
    replay_task_evidence "$since" "$out" "$id" "$project" "$f" "$record"
    replayed[$id]=1
  done

  for record in "$EVIDENCE_DIR"/*.record; do
    [ -e "$record" ] || break
    id=$(basename "$record" .record)
    [ -z "${replayed[$id]:-}" ] || continue
    project=$(record_field "$record" project)
    [ -n "$project" ] || project=-
    replay_task_evidence "$since" "$out" "$id" "$project" "" "$record"
  done

  for f in "$STATE"/*.meta; do
    [ -e "$f" ] || break
    id=$(basename "$f" .meta)
    mtime=$(fm_time_mtime "$f") || continue
    [ -n "$mtime" ] && [ "$mtime" -gt "$since" ] || continue
    project=$(sed -n 's/^project=//p' "$f" | head -1)
    [ -n "$project" ] && project=$(basename "$project") || project=-
    printf '%s\t%s\t%s\tmeta\ttask record touched\n' "$mtime" "$project" "$id" >> "$out"
  done

  for f in "$DATA"/*/report.md; do
    [ -e "$f" ] || break
    id=$(basename "$(dirname "$f")")
    mtime=$(fm_time_mtime "$f") || continue
    [ -n "$mtime" ] && [ "$mtime" -gt "$since" ] || continue
    project=-
    meta="$STATE/$id.meta"
    if [ -r "$meta" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
      [ -n "$project" ] && project=$(basename "$project") || project=-
    fi
    printf '%s\t%s\t%s\treport\tscout report finalized\n' "$mtime" "$project" "$id" >> "$out"
  done

  local bf
  for bf in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -r "$bf" ] || continue
    while IFS= read -r line; do
      case "$line" in
        '- [x] '*) ;;
        *) continue ;;
      esac
      id=${line#"- [x] "}
      id=${id%% - *}
      [ -n "$id" ] || continue
      case "$line" in
        *'(done '????-??-??')'*)
          text=$(printf '%s' "$line" | sed -n 's/.*(done \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *'(reported '????-??-??')'*)
          # tasks-axi writes "(reported YYYY-MM-DD)" instead of "(done ...)"
          # when a scout task is closed with --report; without this branch
          # every scout completion (roughly a fifth of this repo's own
          # archive) is silently invisible to propose.
          text=$(printf '%s' "$line" | sed -n 's/.*(reported \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *'(merged '????-??-??')'*)
          # tasks-axi writes "(merged YYYY-MM-DD)" instead of "(done ...)"
          # when a task is closed with --pr (verified against this repo's own
          # tasks-axi binary: `done <id> --pr <url>` produces this marker);
          # without this branch every PR-linked completion is silently
          # invisible to propose.
          text=$(printf '%s' "$line" | sed -n 's/.*(merged \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *) continue ;;
      esac
      [ -n "$text" ] || continue
      epoch=$(local_to_epoch "$text 12:00") || continue
      [ -n "$epoch" ] && [ "$epoch" -gt "$since" ] || continue
      project=$(printf '%s' "$line" | sed -n 's/.*(repo: \([^)]*\)).*/\1/p')
      [ -n "$project" ] || project=-
      payload=$(printf '%s' "$line" \
        | sed 's/^- \[x\] [^ ]* - //' \
        | sed -e 's/ (done [0-9-]*)//' -e 's/ (reported [0-9-]*)//' -e 's/ (merged [0-9-]*)//' -e 's/ (repo: [^)]*)//' \
        | cut -c1-140)
      printf '%s\t%s\t%s\tbacklog\t%s\n' "$epoch" "$project" "$id" "$payload" >> "$out"
    done < "$bf"
  done

  if [ -r "$STATE/.wake-queue" ]; then
    while IFS=$'\t' read -r epoch _seq kind key payload; do
      case "$epoch" in ''|*[!0-9]*) continue ;; esac
      [ "$epoch" -gt "$since" ] || continue
      printf '%s\tfirstmate\t%s\twake\t%s: %s\n' "$epoch" "${key:--}" "$kind" "$payload" >> "$out"
    done < "$STATE/.wake-queue"
  fi
}

# ---------------------------------------------------------------- clustering

# Reads the evidence TSV file (any order) and writes proposal blocks to stdout
# in the "## pN" key=value shape described in the header. Per (project, task):
# declared waits (source status-wait) are carved out first - a ping inside one
# is absorbed, an interval is cut around it, and a pad never runs into one -
# then the surviving pings and interval pieces merge into windows across gaps
# up to the gap setting, but never across a declared wait.
cluster_evidence() {
  sort -t $'\t' -k2,2 -k3,3 -k1,1n "$1" | awk -F'\t' -v gap=$((GAP_MINUTES * 60)) -v pad=$((PAD_MINUTES * 60)) '
    function fmt(ep,   cmd, disp) {
      cmd = "date -r " ep " \"+%Y-%m-%d %H:%M\" 2>/dev/null || date -d @" ep " \"+%Y-%m-%d %H:%M\""
      cmd | getline disp
      close(cmd)
      return disp
    }
    function add_piece(st, cov, cred, item) {
      np++
      pst[np] = st; pcov[np] = cov; pcred[np] = cred; pitem[np] = item
    }
    function process(   i, w, k, nseg, nnew, s, cred, inside, p, q, t, win, target, blocked, line, wkey) {
      np = 0
      split("", ord); split("", winitem)
      for (i = 1; i <= ni; i++) {
        s = is[i] + 0
        if (ie[i] == "") {
          inside = 0
          for (w = 1; w <= nw; w++) if (ws[w] <= s && s < we[w]) inside = 1
          if (inside) continue
          cred = s + pad
          for (w = 1; w <= nw; w++) if (ws[w] > s && ws[w] < cred) cred = ws[w]
          add_piece(s, s, cred, i)
          continue
        }
        split("", sa); split("", sb)
        nseg = 1; sa[1] = s; sb[1] = ie[i] + 0
        for (w = 1; w <= nw; w++) {
          split("", na); split("", nb); nnew = 0
          for (k = 1; k <= nseg; k++) {
            if (ws[w] < sb[k] && we[w] > sa[k]) {
              if (ws[w] > sa[k]) { nnew++; na[nnew] = sa[k]; nb[nnew] = ws[w] }
              if (we[w] < sb[k]) { nnew++; na[nnew] = we[w]; nb[nnew] = sb[k] }
            } else {
              nnew++; na[nnew] = sa[k]; nb[nnew] = sb[k]
            }
          }
          split("", sa); split("", sb)
          for (k = 1; k <= nnew; k++) { sa[k] = na[k]; sb[k] = nb[k] }
          nseg = nnew
        }
        for (k = 1; k <= nseg; k++) if (sb[k] > sa[k]) add_piece(sa[k], sb[k], sb[k], i)
      }
      for (p = 1; p <= np; p++) ord[p] = p
      for (p = 2; p <= np; p++) {
        t = ord[p]
        for (q = p - 1; q >= 1 && pst[ord[q]] > pst[t]; q--) ord[q + 1] = ord[q]
        ord[q + 1] = t
      }
      nwin = 0
      for (q = 1; q <= np; q++) {
        p = ord[q]
        blocked = 0
        if (nwin > 0) {
          if (pst[p] - wcov[nwin] > gap) blocked = 1
          for (w = 1; w <= nw && !blocked; w++) if (ws[w] < pst[p] && we[w] > wcov[nwin]) blocked = 1
        }
        if (nwin == 0 || blocked) {
          nwin++
          wstart[nwin] = pst[p]; wcov[nwin] = pcov[p]; wcred[nwin] = pcred[p]; wn[nwin] = 0
        } else {
          if (pcov[p] > wcov[nwin]) wcov[nwin] = pcov[p]
          if (pcred[p] > wcred[nwin]) wcred[nwin] = pcred[p]
        }
        i = pitem[p]
        wdesc[nwin] = it[i]
        wkey = i SUBSEP nwin
        if (!(wkey in winitem)) {
          winitem[wkey] = 1
          line = is[i] " | " isrc[i] " | " it[i]
          if (ie[i] != "") line = line " (until " fmt(ie[i]) ")"
          wn[nwin]++; wev[nwin, wn[nwin]] = line
        }
      }
      for (w = 1; w <= nw; w++) {
        target = 0
        for (win = 1; win <= nwin; win++) if (wstart[win] <= ws[w]) target = win
        if (target == 0 && nwin > 0) target = 1
        if (target == 0) continue
        wn[target]++
        wev[target, wn[target]] = ws[w] " | status-wait | " wt[w] " (declared wait until " fmt(we[w]) ", not credited)"
      }
      for (win = 1; win <= nwin; win++) {
        pid++
        printf "## p%d\n", pid
        printf "start=%s\n", fmt(wstart[win])
        printf "end=%s\n", fmt(wcred[win])
        printf "project=%s\n", cur_project
        printf "task=%s\n", cur_task
        printf "desc=%s\n", wdesc[win]
        for (k = 1; k <= wn[win]; k++) printf "evidence=%s\n", wev[win, k]
        printf "\n"
      }
      ni = 0; nw = 0
    }
    BEGIN { pid = 0; ni = 0; nw = 0; cur_key = "" }
    {
      key = $2 SUBSEP $3
      if ((ni > 0 || nw > 0) && key != cur_key) process()
      cur_key = key; cur_project = $2; cur_task = $3
      if ($4 == "status-wait" && $6 != "") {
        nw++; ws[nw] = $1 + 0; we[nw] = $6 + 0; wt[nw] = $5
      } else {
        ni++; is[ni] = $1; ie[ni] = $6; isrc[ni] = $4; it[ni] = $5
      }
    }
    END { if (ni > 0 || nw > 0) process() }
  '
}

# ---------------------------------------------------------------- propose / list

cmd_propose() {
  local replace=0 since_opt="" since_epoch out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) replace=1; shift ;;
      --since) since_opt=$2; shift 2 ;;
      *) die "propose: unknown argument: $1" ;;
    esac
  done

  mkdir -p "$TT"
  tt_lock
  if [ "$(proposal_count)" -gt 0 ] && [ "$replace" -ne 1 ]; then
    die "a pending proposal batch already exists; resolve it with approve/reject/split, or pass --replace to discard it and rescan"
  fi

  if [ -n "$since_opt" ]; then
    since_epoch=$(local_to_epoch "$since_opt") || die "propose: unparseable --since value: $since_opt"
  else
    since_epoch=$(read_cursor)
  fi

  local now
  now=$(now_epoch)
  out=$(mktemp "$TT/.evidence.XXXXXX")
  trap 'rm -f "$out"' RETURN
  gather_evidence "$since_epoch" "$out"

  {
    printf '# time-tracking proposals\n'
    printf '# scan_from=%s scan_to=%s generated=%s\n' "$since_epoch" "$now" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '#\n'
    cluster_evidence "$out"
  } > "$TT/proposals.md.tmp"
  mv "$TT/proposals.md.tmp" "$TT/proposals.md"
  rm -f "$out"
  trap - RETURN

  local count
  count=$(proposal_count)
  if [ "$count" -eq 0 ]; then
    # Nothing to resolve, so nothing blocks the cursor from moving forward;
    # otherwise every future propose would keep rescanning this same dead range.
    # Only do this when the scan used the persisted cursor: an explicit --since
    # is a one-off query and must never silently move the standing cursor.
    [ -n "$since_opt" ] || write_cursor "$now"
    : > "$TT/proposals.md"
    printf 'no work windows found in evidence since %s\n' "$(epoch_to_local "$since_epoch")"
  else
    printf '%s proposed window(s) since %s - review with: fm-time.sh list\n' "$count" "$(epoch_to_local "$since_epoch")"
  fi
  tt_unlock
}

cmd_list() {
  if [ ! -s "$TT/proposals.md" ] || [ "$(proposal_count)" -eq 0 ]; then
    printf 'no pending proposals. Run: fm-time.sh propose\n'
    return 0
  fi
  awk '
    /^## / { if (id != "") print ""; id = substr($0, 4); print "[" id "]"; next }
    /^evidence=/ { print "  evidence: " substr($0, 10); next }
    /^(start|end|project|task|desc)=/ { split($0, kv, "="); printf "  %-8s %s\n", kv[1], substr($0, length(kv[1]) + 2); next }
  ' "$TT/proposals.md"
}

# Extracts the "## <id> ... (blank line or EOF)" block for <id> from <file>.
extract_block() {  # <file> <id>
  awk -v want="## $2" '
    $0 == want { found = 1; next }
    found && /^## / { exit }
    found && NF == 0 { exit }
    found { print }
  ' "$1"
}

block_field() {  # <block-text> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

remove_block() {  # <file> <id> -> rewrites file without that block
  awk -v want="## $2" '
    BEGIN { skip = 0 }
    $0 == want { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip && NF == 0 { skip = 0; next }
    !skip { print }
  ' "$1"
}

# True (0) once no "## p" block remains in proposals.md.
batch_empty() {
  [ "$(proposal_count)" -eq 0 ]
}

advance_cursor_if_batch_done() {
  if batch_empty; then
    local scan_to
    scan_to=$(sed -n 's/.*scan_to=\([0-9]*\).*/\1/p' "$TT/proposals.md" | head -1)
    [ -n "$scan_to" ] && write_cursor "$scan_to"
    : > "$TT/proposals.md"
  fi
}

next_entry_id() {
  printf 'e-%s-%s\n' "$(now_epoch)" "$$"
}

append_entry() {  # start end project task desc
  mkdir -p "$TT"
  {
    printf '## %s\n' "$(next_entry_id)"
    printf 'start=%s\n' "$1"
    printf 'end=%s\n' "$2"
    printf 'project=%s\n' "${3:--}"
    printf 'task=%s\n' "${4:--}"
    printf 'desc=%s\n' "$5"
    printf '\n'
  } >> "$TT/entries.md"
}

cmd_approve() {
  local id=${1:-} start_ov="" end_ov="" project_ov="" task_ov="" desc_ov=""
  [ -n "$id" ] || die "approve: usage: fm-time.sh approve <id> [--start ..] [--end ..] [--project ..] [--task ..] [--desc ..]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --start) start_ov=$2; shift 2 ;;
      --end) end_ov=$2; shift 2 ;;
      --project) project_ov=$2; shift 2 ;;
      --task) task_ov=$2; shift 2 ;;
      --desc) desc_ov=$2; shift 2 ;;
      *) die "approve: unknown argument: $1" ;;
    esac
  done

  tt_lock
  [ -s "$TT/proposals.md" ] || die "approve: no pending proposals"
  local block
  block=$(extract_block "$TT/proposals.md" "$id")
  [ -n "$block" ] || die "approve: no pending proposal named $id"

  local start end project task desc
  start=${start_ov:-$(block_field "$block" start)}
  end=${end_ov:-$(block_field "$block" end)}
  project=${project_ov:-$(block_field "$block" project)}
  task=${task_ov:-$(block_field "$block" task)}
  desc=${desc_ov:-$(block_field "$block" desc)}

  local s e
  s=$(local_to_epoch "$start") || die "approve: unparseable start: $start"
  e=$(local_to_epoch "$end") || die "approve: unparseable end: $end"
  [ "$e" -gt "$s" ] || die "approve: end must be after start ($start -> $end)"

  append_entry "$start" "$end" "$project" "$task" "$desc"
  remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
  mv "$TT/proposals.md.tmp" "$TT/proposals.md"
  advance_cursor_if_batch_done
  tt_unlock
  printf 'approved %s: %s (%s -> %s)\n' "$id" "$desc" "$start" "$end"
}

cmd_reject() {
  [ "$#" -gt 0 ] || die "reject: usage: fm-time.sh reject <id>..."
  tt_lock
  [ -s "$TT/proposals.md" ] || die "reject: no pending proposals"
  local id
  for id in "$@"; do
    local block
    block=$(extract_block "$TT/proposals.md" "$id")
    [ -n "$block" ] || { printf 'reject: no pending proposal named %s (skipped)\n' "$id"; continue; }
    remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
    mv "$TT/proposals.md.tmp" "$TT/proposals.md"
    printf 'rejected %s\n' "$id"
  done
  advance_cursor_if_batch_done
  tt_unlock
}

cmd_split() {
  local id=${1:-} at=""
  [ -n "$id" ] || die "split: usage: fm-time.sh split <id> --at \"<YYYY-MM-DD HH:MM>\""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) at=$2; shift 2 ;;
      *) die "split: unknown argument: $1" ;;
    esac
  done
  [ -n "$at" ] || die "split: --at is required"

  tt_lock
  [ -s "$TT/proposals.md" ] || die "split: no pending proposals"
  local block
  block=$(extract_block "$TT/proposals.md" "$id")
  [ -n "$block" ] || die "split: no pending proposal named $id"

  local start end project task desc split_epoch start_epoch end_epoch
  start=$(block_field "$block" start)
  end=$(block_field "$block" end)
  project=$(block_field "$block" project)
  task=$(block_field "$block" task)
  desc=$(block_field "$block" desc)
  start_epoch=$(local_to_epoch "$start") || die "split: unparseable stored start: $start"
  end_epoch=$(local_to_epoch "$end") || die "split: unparseable stored end: $end"
  split_epoch=$(local_to_epoch "$at") || die "split: unparseable --at value: $at"
  [ "$split_epoch" -gt "$start_epoch" ] && [ "$split_epoch" -lt "$end_epoch" ] \
    || die "split: --at must fall strictly between $start and $end"

  local evidence before after
  evidence=$(printf '%s\n' "$block" | sed -n 's/^evidence=//p')
  before=""
  after=""
  local line ep
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ep=${line%% | *}
    ep=$(local_to_epoch "$ep" 2>/dev/null || printf '%s' "$ep")
    case "$ep" in
      *[!0-9]*) before="$before$line"$'\n' ;;
      *) if [ "$ep" -lt "$split_epoch" ]; then before="$before$line"$'\n'; else after="$after$line"$'\n'; fi ;;
    esac
  done <<< "$evidence"

  remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
  {
    cat "$TT/proposals.md.tmp"
    printf '## %s-a\n' "$id"
    printf 'start=%s\n' "$start"
    printf 'end=%s\n' "$at"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
    printf '%s' "$before" | sed 's/^/evidence=/'
    printf '\n'
    printf '## %s-b\n' "$id"
    printf 'start=%s\n' "$at"
    printf 'end=%s\n' "$end"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
    printf '%s' "$after" | sed 's/^/evidence=/'
    printf '\n'
  } > "$TT/proposals.md.new"
  mv "$TT/proposals.md.new" "$TT/proposals.md"
  rm -f "$TT/proposals.md.tmp"
  tt_unlock
  printf 'split %s into %s-a (%s -> %s) and %s-b (%s -> %s)\n' "$id" "$id" "$start" "$at" "$id" "$at" "$end"
}

# ---------------------------------------------------------------- start / stop / log

cmd_start() {
  local project=- task=- desc=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --desc) desc=$2; shift 2 ;;
      *) die "start: unknown argument: $1" ;;
    esac
  done
  mkdir -p "$TT"
  tt_lock
  [ -e "$TT/active" ] && die "start: a live session is already running; run: fm-time.sh stop"
  {
    printf 'start=%s\n' "$(epoch_to_local "$(now_epoch)")"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
  } > "$TT/active"
  tt_unlock
  printf 'started tracking%s\n' "$([ -n "$desc" ] && printf ': %s' "$desc")"
}

cmd_stop() {
  local desc_ov=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --desc) desc_ov=$2; shift 2 ;;
      *) die "stop: unknown argument: $1" ;;
    esac
  done
  tt_lock
  [ -e "$TT/active" ] || die "stop: no live session is running; run: fm-time.sh start"
  local start project task desc end start_epoch end_epoch
  start=$(sed -n 's/^start=//p' "$TT/active" | head -1)
  project=$(sed -n 's/^project=//p' "$TT/active" | head -1)
  task=$(sed -n 's/^task=//p' "$TT/active" | head -1)
  desc=$(sed -n 's/^desc=//p' "$TT/active" | head -1)
  [ -n "$desc_ov" ] && desc=$desc_ov
  end=$(epoch_to_local "$(now_epoch)")
  start_epoch=$(local_to_epoch "$start") || die "stop: unparseable stored start: $start"
  end_epoch=$(local_to_epoch "$end") || die "stop: unparseable end: $end"
  # A start/stop within the same wall-clock minute would otherwise record an
  # entry whose stored start and end are identical once truncated to minute
  # granularity - report then silently discards it as invalid, losing the
  # tracked session. Refuse it up front instead, leaving the active session
  # in place so the captain can just wait a moment and stop again.
  [ "$end_epoch" -gt "$start_epoch" ] || die "stop: wait until the current minute has elapsed before stopping"
  append_entry "$start" "$end" "$project" "$task" "$desc"
  rm -f "$TT/active"
  tt_unlock
  printf 'stopped: %s (%s -> %s)\n' "${desc:-(no description)}" "$start" "$end"
}

cmd_log() {
  local start="" end="" project=- task=- desc=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --start) start=$2; shift 2 ;;
      --end) end=$2; shift 2 ;;
      --project) project=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --desc) desc=$2; shift 2 ;;
      *) die "log: unknown argument: $1" ;;
    esac
  done
  [ -n "$start" ] && [ -n "$end" ] || die "log: --start and --end are required"
  [ -n "$desc" ] || die "log: --desc is required"
  local s e
  s=$(local_to_epoch "$start") || die "log: unparseable --start: $start"
  e=$(local_to_epoch "$end") || die "log: unparseable --end: $end"
  [ "$e" -gt "$s" ] || die "log: --end must be after --start"
  tt_lock
  append_entry "$start" "$end" "$project" "$task" "$desc"
  tt_unlock
  printf 'logged: %s (%s -> %s)\n' "$desc" "$start" "$end"
}

# ---------------------------------------------------------------- report

cmd_report() {
  local month="" project_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --month) month=$2; shift 2 ;;
      --project) project_filter=$2; shift 2 ;;
      *) die "report: unknown argument: $1" ;;
    esac
  done
  [ -n "$month" ] || month=$(epoch_to_yyyymm "$(now_epoch)")
  [ -e "$TT/entries.md" ] || { printf 'no time entries recorded yet.\n'; return 0; }

  local tmp
  tmp=$(mktemp "$TT/.report.XXXXXX")
  trap 'rm -f "$tmp"' RETURN

  awk -v RS='' -v FS='\n' '
    /^## / {
      start=""; end=""; project=""; task=""; desc=""
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^start=/) start = substr(line, 7)
        else if (line ~ /^end=/) end = substr(line, 5)
        else if (line ~ /^project=/) project = substr(line, 9)
        else if (line ~ /^task=/) task = substr(line, 6)
        else if (line ~ /^desc=/) desc = substr(line, 6)
      }
      if (start != "") print start "\t" end "\t" project "\t" task "\t" desc
    }
  ' "$TT/entries.md" > "$tmp"

  local total=0 after_total=0 count=0 invalid=0
  local -A proj_total proj_after
  local -A key_total key_after key_desc
  local line s e p t d s_epoch e_epoch dur ah ym

  while IFS=$'\t' read -r s e p t d; do
    ym=${s%% *}
    ym=${ym%-*}
    [ "$ym" = "$month" ] || continue
    [ -z "$project_filter" ] || [ "$p" = "$project_filter" ] || continue
    s_epoch=$(local_to_epoch "$s") || { invalid=$((invalid + 1)); continue; }
    e_epoch=$(local_to_epoch "$e") || { invalid=$((invalid + 1)); continue; }
    if [ "$e_epoch" -le "$s_epoch" ]; then invalid=$((invalid + 1)); continue; fi
    dur=$(( (e_epoch - s_epoch) / 60 ))
    ah=$(is_after_hours "$s_epoch")
    total=$((total + dur))
    count=$((count + 1))
    [ "$ah" = yes ] && after_total=$((after_total + dur))
    proj_total[$p]=$(( ${proj_total[$p]:-0} + dur ))
    [ "$ah" = yes ] && proj_after[$p]=$(( ${proj_after[$p]:-0} + dur ))
    key_total["$p"$'\t'"$t"]=$(( ${key_total["$p"$'\t'"$t"]:-0} + dur ))
    [ "$ah" = yes ] && key_after["$p"$'\t'"$t"]=$(( ${key_after["$p"$'\t'"$t"]:-0} + dur ))
    if [ -n "$d" ]; then
      case "${key_desc["$p"$'\t'"$t"]:-}" in
        *"$d"*) ;;
        '') key_desc["$p"$'\t'"$t"]="$d" ;;
        *) key_desc["$p"$'\t'"$t"]="${key_desc["$p"$'\t'"$t"]}; $d" ;;
      esac
    fi
  done < "$tmp"
  rm -f "$tmp"
  trap - RETURN

  printf 'Time tracking report - %s\n' "$month"
  if [ "$count" -eq 0 ]; then
    printf 'no entries recorded for this month%s.\n' "$([ -n "$project_filter" ] && printf ' for project %s' "$project_filter")"
    [ "$invalid" -gt 0 ] && printf '(%d entr%s skipped: end not after start; check hand edits)\n' \
      "$invalid" "$([ "$invalid" -eq 1 ] && printf y || printf ies)"
    return 0
  fi
  printf 'total: %s tracked across %d entr%s\n' "$(fmt_minutes "$total")" "$count" "$([ "$count" -eq 1 ] && printf y || printf ies)"
  printf '  after hours (weekend or outside %s-%s local): %s\n' "$WORKDAY_START" "$WORKDAY_END" "$(fmt_minutes "$after_total")"
  printf '  business hours: %s\n' "$(fmt_minutes "$((total - after_total))")"
  [ "$invalid" -gt 0 ] && printf '(%d entr%s skipped: end not after start; check hand edits)\n' \
    "$invalid" "$([ "$invalid" -eq 1 ] && printf y || printf ies)"
  printf '\nby project / task:\n'

  local p_key kt task_name p_prefix
  local -a sorted_projects sorted_tasks
  mapfile -t sorted_projects < <(printf '%s\n' "${!proj_total[@]}" | sort)
  for p_key in "${sorted_projects[@]}"; do
    printf '  %s  %s' "$([ "$p_key" = - ] && printf '(unattributed)' || printf '%s' "$p_key")" "$(fmt_minutes "${proj_total[$p_key]}")"
    [ "${proj_after[$p_key]:-0}" -gt 0 ] && printf ' (%s after hours)' "$(fmt_minutes "${proj_after[$p_key]}")"
    printf '\n'
    # Stock macOS Bash 3.2's $(...)/<(...) parser naively counts parens to
    # find the substitution's closing ")"; a case pattern's own closing ")" -
    # even a plain literal one - confuses that counter unless the pattern has
    # a leading "(" (POSIX-legal, a no-op everywhere else). This affects every
    # case statement whose source text sits inside a command or process
    # substitution, regardless of what the pattern itself contains.
    p_prefix="$p_key"$'\t'
    mapfile -t sorted_tasks < <(
      for kt in "${!key_total[@]}"; do
        case "$kt" in ("$p_prefix"*) printf '%s\n' "$kt" ;; esac
      done | sort
    )
    for kt in "${sorted_tasks[@]}"; do
      task_name=${kt#*$'\t'}
      printf '    %s  %s' "$([ "$task_name" = - ] && printf '(unattributed)' || printf '%s' "$task_name")" "$(fmt_minutes "${key_total[$kt]}")"
      [ "${key_after[$kt]:-0}" -gt 0 ] && printf ' (%s after hours)' "$(fmt_minutes "${key_after[$kt]}")"
      printf '\n'
      [ -n "${key_desc[$kt]:-}" ] && printf '      %s\n' "${key_desc[$kt]}"
    done
  done
}

# ---------------------------------------------------------------- capture

# Local commit moments on <branch>: the times its reflog recorded each commit
# made on it, which survive a later rebase and need no guess at a base ref.
branch_commit_epochs() {  # <worktree> <branch>
  git -C "$1" reflog show --date=unix --format='%gd%x09%gs' "refs/heads/$2" -- 2>/dev/null \
    | awk -F'\t' '$2 ~ /^commit/ { e = $1; sub(/.*@\{/, "", e); sub(/\}.*/, "", e); if (e ~ /^[0-9]+$/) print e }' \
    || true
}

cmd_capture() {
  local id=${1:-} commits=1
  [ -n "$id" ] || die "capture: a task id is required"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-commits) commits=0; shift ;;
      *) die "capture: unknown argument: $1" ;;
    esac
  done
  case "$id" in */*|.*|'') die "capture: invalid task id: $id" ;; esac

  local meta="$STATE/$id.meta" live="$STATE/$id.status" record="$EVIDENCE_DIR/$id.record"
  local project="" kind="" branch="" worktree="" status_mtime="" old=""
  if [ -r "$meta" ]; then
    project=$(record_field "$meta" project)
    [ -z "$project" ] || project=$(basename "$project")
    kind=$(record_field "$meta" kind)
    branch=$(record_field "$meta" branch)
    worktree=$(record_field "$meta" worktree)
  fi
  [ -r "$record" ] && old=$record
  if [ -n "$old" ]; then
    [ -n "$project" ] || project=$(record_field "$old" project)
    [ -n "$kind" ] || kind=$(record_field "$old" kind)
    [ -n "$branch" ] || branch=$(record_field "$old" branch)
  fi
  if [ -e "$live" ]; then
    status_mtime=$(fm_time_mtime "$live") || status_mtime=
  fi
  [ -n "$status_mtime" ] || [ -z "$old" ] || status_mtime=$(record_field "$old" status_mtime)

  # Commit evidence exists only where a task worktree does: ship and scout.
  local epochs=""
  if [ "$commits" -eq 1 ] && [ -n "$worktree" ] && [ -d "$worktree" ]; then
    case "$kind" in
      ship)
        [ -n "$branch" ] || branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        [ -z "$branch" ] || epochs=$(branch_commit_epochs "$worktree" "$branch")
        ;;
      scout)
        # Scouts never push and usually commit on a detached HEAD: their own
        # scratch commits are the ones no branch or remote reaches.
        branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        if [ -n "$branch" ]; then
          epochs=$(branch_commit_epochs "$worktree" "$branch")
        else
          epochs=$(git -C "$worktree" log --format=%ct HEAD --not --branches --remotes -- 2>/dev/null || true)
        fi
        ;;
    esac
  fi
  local first="" last="" count=0
  if [ -n "$epochs" ]; then
    first=$(printf '%s\n' "$epochs" | sort -n | head -1)
    last=$(printf '%s\n' "$epochs" | sort -n | tail -1)
    count=$(printf '%s\n' "$epochs" | grep -c .)
  elif [ -n "$old" ]; then
    # A rerun after the branch or slot is gone keeps the earlier capture.
    first=$(record_field "$old" commits_first)
    last=$(record_field "$old" commits_last)
    count=$(record_field "$old" commits_count)
  fi

  mkdir -p "$EVIDENCE_DIR"
  {
    printf '# fm-time.sh evidence record for %s, captured at teardown\n' "$id"
    printf 'project=%s\n' "$project"
    printf 'kind=%s\n' "$kind"
    printf 'branch=%s\n' "$branch"
    printf 'status_mtime=%s\n' "$status_mtime"
    if [ -n "$first" ] && [ -n "$last" ]; then
      printf 'commits_first=%s\n' "$first"
      printf 'commits_last=%s\n' "$last"
      printf 'commits_count=%s\n' "$count"
    fi
    {
      [ -z "$old" ] || sed -n 's/^status=//p' "$old"
      [ ! -r "$live" ] || cat "$live"
    } | awk 'NF && !seen[$0]++ { print "status=" $0 }'
  } > "$record.tmp.$$"
  mv "$record.tmp.$$" "$record"
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  propose) shift; cmd_propose "$@" ;;
  list)    shift; cmd_list "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  reject)  shift; cmd_reject "$@" ;;
  split)   shift; cmd_split "$@" ;;
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  log)     shift; cmd_log "$@" ;;
  report)  shift; cmd_report "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
