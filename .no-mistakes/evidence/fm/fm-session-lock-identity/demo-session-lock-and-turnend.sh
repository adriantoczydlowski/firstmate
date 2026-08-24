#!/usr/bin/env bash
# End-user demo of the three live failures described in the task intent, run
# twice against real processes: once with the scripts from the base commit
# (BEFORE) and once with the branch head (AFTER). Nothing here is stubbed - the
# harness-shaped processes are real executables, their command names are produced
# by the kernel and read back through the same ps the library calls, and the
# suspended holder is really SIGSTOPped. The transcript is the exact stdout and
# stderr an operator sees from bin/fm-lock.sh and from the Claude Stop-hook
# turn-end guard.
#
# Usage: demo-session-lock-and-turnend.sh <worktree> <base-commit> <head-commit>
set -u

WT=$1
BASE=$2
HEAD_REF=$3
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-demo.XXXXXX")
PIDS=""

cleanup() {
  local p
  for p in $PIDS; do kill -CONT "$p" 2>/dev/null || true; kill -TERM "$p" 2>/dev/null || true; done
  rm -rf "$DEMO"
}
trap cleanup EXIT

# Two complete, independent copies of the repo scripts, so BEFORE and AFTER both
# run real files and neither one touches the worktree.
mkdir -p "$DEMO/before" "$DEMO/after"
git -C "$WT" archive "$BASE" | tar -x -C "$DEMO/before"
git -C "$WT" archive "$HEAD_REF" | tar -x -C "$DEMO/after"

# Real executables carrying the two names a live Claude Code install reports on
# this machine: the bare name, and the background pty worker whose task name
# procps cuts to 15 characters.
BINS="$DEMO/bins"
mkdir -p "$BINS"
ln -s /bin/bash "$BINS/claude"
ln -s /bin/bash "$BINS/claude bg-pty-host"

# Every environment signal the library reads, cleared, so nothing inherited from
# the live session running this demo can decide a verdict.
CLEAR=(env -u CLAUDE_PID -u HERDR_ENV -u HERDR_PANE_ID -u TMUX -u TMUX_PANE
  -u ZELLIJ -u ZELLIJ_PANE_ID -u ORCA_PANE_ID -u CMUX_PANE_ID -u FM_HOME
  -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE)

# What a harness-shaped asking process runs: report its own pid and command name,
# then run the real bin/fm-lock.sh and record its output and exit status.
ASK="$DEMO/ask.sh"
cat > "$ASK" <<'ASKSH'
#!/usr/bin/env bash
# $1 = path to fm-lock.sh   $2 = fixture home
printf '%s (%s)\n' "$$" "$(ps -o comm= -p $$ | sed -e 's/^ *//' -e 's/ *$//')" > "$2/asking-pid"
bash "$1" > "$2/lock.out" 2> "$2/lock.err"
printf '%s\n' "$?" > "$2/lock.status"
ASKSH
chmod +x "$ASK"

hr() { printf '\n================ %s ================\n' "$*"; }
sub() { printf '\n--- %s\n' "$*"; }

start_named() {  # <exec-path> <env-assignments...>
  local bin=$1; shift
  "${CLEAR[@]}" "$@" "$bin" -c 'while :; do sleep 0.2; done; :' >/dev/null 2>&1 &
  local pid=$! i=0
  PIDS="$PIDS $pid"
  while [ "$i" -lt 200 ]; do
    [ -n "$(ps -o comm= -p "$pid" 2>/dev/null)" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.05; i=$((i + 1))
  done
  echo "demo: fixture process for $bin never became visible" >&2
  exit 1
}

# Run the real bin/fm-lock.sh from inside a harness-shaped process that is
# orphaned away from this shell, which is the shape a rehosted session has: the
# launcher exits immediately, the tree reparents, and the ancestry walk therefore
# terminates inside the fixture instead of reaching the live session running
# this demo.
ask_from_session() {  # <exec-path> <side> <home> <env-assignments...>
  local bin=$1 side=$2 home=$3 i=0
  shift 3
  "${CLEAR[@]}" "$@" FM_HOME="$home" \
    bash -c '"$0" "$1" "$2" "$3" &' "$bin" "$ASK" "$DEMO/$side/bin/fm-lock.sh" "$home"
  while [ "$i" -lt 600 ] && [ ! -s "$home/lock.status" ]; do sleep 0.05; i=$((i + 1)); done
}

report_ask() {  # <home>
  local home=$1
  printf '$ bin/fm-lock.sh\n'
  cat "$home/lock.out" "$home/lock.err" 2>/dev/null
  printf 'exit status: %s\n' "$(tr -d '[:space:]' < "$home/lock.status" 2>/dev/null)"
  printf 'state/.lock now: %s\n' "$(tr -d '[:space:]' < "$home/state/.lock" 2>/dev/null)"
}

# --------------------------------------------------------------------------
# DEFECT 1(a): a Claude background session launched from the same window runs
# under `claude bg-pty-host`, a tree reparented away from the window that never
# reaches the window's own claude pid holding the lock. Both carry the same pane.
# Exactly one session exists.
# --------------------------------------------------------------------------
scenario_rehosted() {  # <side>
  local side=$1 home="$DEMO/$side/home-a" window
  mkdir -p "$home/state"
  window=$(start_named "$BINS/claude" HERDR_ENV=1 HERDR_PANE_ID=demo-pane-a)
  printf '%s\n' "$window" > "$home/state/.lock"
  sub "state/.lock names the window session pid $window ($(ps -o comm= -p "$window" | tr -d ' '))"
  ask_from_session "$BINS/claude bg-pty-host" "$side" "$home" \
    HERDR_ENV=1 HERDR_PANE_ID=demo-pane-a CLAUDE_PID="$window"
  sub "the background session it launched asks for the lock from pid $(cat "$home/asking-pid" 2>/dev/null)"
  report_ask "$home"
  kill -TERM "$window" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# DEFECT 1(b): after a session resume the window's previous `claude --resume`
# sits in state T (stopped by Ctrl-Z). kill -0 succeeds on it, so the lock stays
# pointed at something that will never let go.
# --------------------------------------------------------------------------
scenario_suspended() {  # <side>
  local side=$1 home="$DEMO/$side/home-b" holder i=0
  mkdir -p "$home/state"
  holder=$(start_named "$BINS/claude")
  kill -STOP "$holder"
  while [ "$i" -lt 200 ]; do
    case "$(ps -o state= -p "$holder" 2>/dev/null | tr -d '[:space:]')" in T*) break ;; esac
    sleep 0.05; i=$((i + 1))
  done
  printf '%s\n' "$holder" > "$home/state/.lock"
  sub "state/.lock names pid $holder, in state '$(ps -o state= -p "$holder" | tr -d ' ')' (stopped) and still answering kill -0"
  printf '$ bin/fm-lock.sh status\n'
  "${CLEAR[@]}" FM_HOME="$home" bash "$DEMO/$side/bin/fm-lock.sh" status 2>&1
  ask_from_session "$BINS/claude" "$side" "$home"
  sub "the resumed session asks for the lock from pid $(cat "$home/asking-pid" 2>/dev/null)"
  report_ask "$home"
  kill -CONT "$holder" 2>/dev/null || true
  kill -TERM "$holder" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# THE SAFETY PROPERTY: a genuinely separate concurrent session must still be
# refused. Same harness, live, in a DIFFERENT pane and with no launch
# relationship in either direction - a second agent started by hand.
# --------------------------------------------------------------------------
scenario_separate_session() {  # <side>
  local side=$1 home="$DEMO/$side/home-d" other
  mkdir -p "$home/state"
  other=$(start_named "$BINS/claude" HERDR_ENV=1 HERDR_PANE_ID=demo-pane-other)
  printf '%s\n' "$other" > "$home/state/.lock"
  sub "state/.lock names an unrelated live session pid $other in pane demo-pane-other"
  ask_from_session "$BINS/claude" "$side" "$home" HERDR_ENV=1 HERDR_PANE_ID=demo-pane-mine
  sub "a second, unrelated session in pane demo-pane-mine asks from pid $(cat "$home/asking-pid" 2>/dev/null)"
  report_ask "$home"
  printf '(the lock must still name the other session, %s)\n' "$other"
  kill -TERM "$other" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# DEFECT 2: the Stop auto-arm never claimed this home, so there is no failure
# episode to advance and the attended fail-open was unreachable. Work is in
# flight and no watcher exists, which is the state the guard blocks on.
# FM_CLAUDE_TURNEND_BLOCK_BUDGET defaults to 3.
# --------------------------------------------------------------------------
scenario_turnend() {  # <side>
  local side=$1 home="$DEMO/$side/home-c" src="$DEMO/$side" f i out status
  mkdir -p "$home/state" "$home/bin" "$home/docs"
  git init -q "$home"; git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  for f in fm-turnend-guard.sh fm-turnend-guard-grok.sh fm-operational-input.sh \
    fm-supervision-instructions.sh fm-harness.sh fm-primary-scope-lib.sh \
    fm-supervision-lib.sh fm-wake-lib.sh fm-hook-host-lib.sh; do
    cp "$src/bin/$f" "$home/bin/$f"
  done
  chmod +x "$home"/bin/*.sh
  cp -R "$src/docs/supervision-protocols" "$home/docs/supervision-protocols"
  : > "$home/state/task1.meta"
  sub "primary home, one task in flight, no watcher, state/.claude-autoarm-epoch $([ -e "$home/state/.claude-autoarm-epoch" ] && echo present || echo absent)"
  for i in 1 2 3 4 5; do
    out=$(printf '{"stop_hook_active":false,"session_id":"demo-session"}' \
      | CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
        bash "$home/bin/fm-turnend-guard.sh" --claude 2>&1); status=$?
    printf '\nturn end %s -> exit %s\n' "$i" "$status"
    printf '%s\n' "$out" | head -8
    printf '\n'
  done
}

for side in before after; do
  case $side in
    before) hr "BEFORE (base $BASE)" ;;
    after) hr "AFTER (branch head $HEAD_REF)" ;;
  esac
  printf '\n### DEFECT 1(a): a background session beside the window, one real session\n'
  scenario_rehosted "$side"
  printf '\n### DEFECT 1(b): a suspended holder after a session resume\n'
  scenario_suspended "$side"
  printf '\n### SAFETY: a genuinely separate concurrent session is still refused\n'
  scenario_separate_session "$side"
  printf '\n### DEFECT 2: turn end with an auto-arm that never claimed this home\n'
  scenario_turnend "$side"
done
hr DONE
