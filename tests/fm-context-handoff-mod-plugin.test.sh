#!/usr/bin/env bash
# The two Claude Code context-handoff mods under the real installed Claude Code:
# `claude plugin validate --strict` on each folder (and on the main-window part's
# `.claude/skills` auto-load path), pinning the events each hooks and the environment
# each reads, then each mod's own `claude plugin test` suite, which drives the hooks
# module in the engine's host against a mocked clock, environment, file system, and
# drawing surface. No model turn is submitted and no credential is spent, so the guard
# runs by default wherever `claude` is installed; the portable checks that need no
# Claude Code binary live in tests/fm-context-handoff-mod.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_CONTEXT_HANDOFF_PLUGIN_TEST claude

MAIN="$ROOT/.claude/mods/firstmate-context-handoff"
WORKER="$ROOT/.claude/mods/firstmate-context-handoff-worker"
AUTOLOAD_PATH="$ROOT/.claude/skills/firstmate-context-handoff"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-context-handoff-mod-plugin)

expect_in_report() {
  local report=$1 needle=$2 what=$3
  case "$report" in
    *"$needle"*) : ;;
    *)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION: $what (missing '$needle')"
      ;;
  esac
}

validate() {  # <path> -> report on stdout
  local report
  if ! report=$(claude plugin validate --strict "$1" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION refused the mod at $1 under strict validation"
  fi
  printf '%s' "$report"
}

test_validate_main_window_part() {
  local path report
  for path in "$MAIN" "$AUTOLOAD_PATH"; do
    report=$(validate "$path")
    # The scan is the engine's own reading of the module: the events it will hook
    # and the environment names it may read. Anything more or less is a drift.
    expect_in_report "$report" "hooks: session.measure, turn.complete, command.run{command=stow}, session.end, ui.render{component=AbovePrompt}" \
      "the scan of $path hooks a different set of events"
    expect_in_report "$report" "env reads: COMPACT_ADVISER_DISABLE, FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE, FM_TASK_ID" \
      "the scan of $path reads a different environment"
    expect_in_report "$report" "env writes: nothing" "the scan of $path writes the environment"
    case "$report" in
      *"tool.call"*|*"turn.step"*|*"prompt.submit"*|*"classic."*|*"process.run"*|*"http.fetch"*|*"env.set"*)
        printf '%s\n' "$report" >&2
        fail "Claude Code $CLAUDE_VERSION scanned an event or capability the main-window part must not use at $path"
        ;;
    esac
  done
  pass "Claude Code $CLAUDE_VERSION validates the main-window part strictly at its folder and its auto-load path, hooking only the measure, turn end, /stow, session end, and the band above the prompt"
}

test_validate_worker_part() {
  local report
  report=$(validate "$WORKER")
  expect_in_report "$report" "hooks: session.measure, tool.call" "the worker part hooks a different set of events"
  expect_in_report "$report" "env reads: FM_TASK_ID, HOME" "the worker part reads a different environment"
  expect_in_report "$report" "env writes: nothing" "the worker part writes the environment"
  case "$report" in
    *"turn.step"*|*"prompt.submit"*|*"classic."*|*"ui.render"*|*"http.fetch"*|*"env.set"*)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION scanned an event or capability the worker part must not use"
      ;;
  esac
  pass "Claude Code $CLAUDE_VERSION validates the worker part strictly, hooking only the measure and the tool call"
}

test_plugin_suites() {
  local mod report
  for mod in "$MAIN" "$WORKER"; do
    if ! report=$(cd "$TMP_ROOT" && claude plugin test "$mod" 2>&1); then
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION failed the plugin test suite of ${mod##*/}"
    fi
    printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION ran no plugin test of ${mod##*/}"
    }
    printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION reported plugin test failures in ${mod##*/}"
    }
  done
  pass "Claude Code $CLAUDE_VERSION runs both context-handoff plugin test suites clean: switch, buttons, carry, secondmate /stow, and the worker's handoff and status line"
}

test_validate_main_window_part
test_validate_worker_part
test_plugin_suites
