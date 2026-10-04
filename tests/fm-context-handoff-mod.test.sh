#!/usr/bin/env bash
# Portable checks for the two Claude Code context-handoff mods that need no Claude Code
# binary, so CI enforces them wherever Node runs:
#   - placement: the main-window part (.claude/mods/firstmate-context-handoff) is
#     linked into the project's .claude/skills auto-load path like Calm, while the
#     worker part (.claude/mods/firstmate-context-handoff-worker) is linked nowhere,
#     so only fm-spawn's --plugin-dir ever loads it;
#   - shape: each is one hooks module with no command, skill, agent, or classic hook,
#     and each tracks the tsconfig.json a folder load writes, so loading leaves no
#     untracked file in tracked material;
#   - the pure policy: the per-home switch path and value, the carried text, and the
#     worker's status-path, handoff-path, and status-line helpers.
# The engine-bound behavior runs under tests/fm-context-handoff-mod-plugin.test.sh and
# fm-spawn's launch wiring under tests/fm-spawn-dispatch-profile.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAIN="$ROOT/.claude/mods/firstmate-context-handoff"
WORKER="$ROOT/.claude/mods/firstmate-context-handoff-worker"
TMP_ROOT=$(fm_test_tmproot fm-context-handoff-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the context-handoff mod checks"; exit 0; }

run_node() {  # <script-file>
  FM_TEST_MAIN_MOD=$MAIN FM_TEST_WORKER_MOD=$WORKER node --input-type=module <"$1"
}

test_placement() {
  local link resolved entry
  link="$ROOT/.agents/skills/firstmate-context-handoff"
  [ -L "$link" ] || fail "the main-window part is not linked into .agents/skills, so Claude Code's project scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/firstmate-context-handoff link does not resolve"
  [ "$resolved" = "$(cd "$MAIN" && pwd -P)" ] || fail "the .agents/skills/firstmate-context-handoff link resolves to $resolved, not the main-window part"
  [ -f "$ROOT/.claude/skills/firstmate-context-handoff/hooks/hooks.json" ] \
    || fail "the project's .claude/skills path does not reach the main-window part's hooks module"
  for entry in "$ROOT"/.agents/skills/* "$ROOT"/.claude/skills/*; do
    [ -e "$entry" ] || continue
    [ "$(cd "$entry" 2>/dev/null && pwd -P)" != "$(cd "$WORKER" && pwd -P)" ] \
      || fail "$entry reaches the worker part, so every session of this project would load it"
  done
  [ ! -e "$MAIN/SKILL.md" ] && [ ! -e "$WORKER/SKILL.md" ] \
    || fail "a context-handoff mod carries a SKILL.md and would load as a skill on every harness"
  pass "the main-window part is linked into the project's auto-load path and the worker part is linked nowhere"
}

test_shape() {
  local out mod
  for mod in "$MAIN" "$WORKER"; do
    git -C "$ROOT" ls-files --error-unmatch "${mod#"$ROOT"/}/tsconfig.json" >/dev/null 2>&1 \
      || fail "${mod##*/} does not track the tsconfig.json a folder load writes, which would show as untracked"
  done
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, existsSync } from "node:fs";
const parts = [
  { dir: process.env.FM_TEST_MAIN_MOD, name: "firstmate-context-handoff", module: "./register.tsx" },
  { dir: process.env.FM_TEST_WORKER_MOD, name: "firstmate-context-handoff-worker", module: "./register.ts" },
];
for (const part of parts) {
  const manifest = JSON.parse(readFileSync(\`\${part.dir}/.claude-plugin/plugin.json\`, "utf8"));
  if (manifest.name !== part.name) throw new Error(\`manifest name \${manifest.name}\`);
  for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
    if (key in manifest) throw new Error(\`\${part.name} declares \${key}, which would load outside its hooks module\`);
  }
  const hooks = JSON.parse(readFileSync(\`\${part.dir}/hooks/hooks.json\`, "utf8"));
  if (JSON.stringify(Object.keys(hooks).sort()) !== JSON.stringify(["description", "modules"])) {
    throw new Error(\`\${part.name} hooks.json declares more than its module: a classic hook would run\`);
  }
  if (JSON.stringify(hooks.modules) !== JSON.stringify([part.module])) throw new Error(\`\${part.name} names a different module\`);
  if (!existsSync(\`\${part.dir}/hooks/\${part.module.slice(2)}\`)) throw new Error(\`\${part.name}: the hooks module is missing\`);
  const tsconfig = JSON.parse(readFileSync(\`\${part.dir}/tsconfig.json\`, "utf8"));
  if (tsconfig.extends !== "./.claude-plugin/types/tsconfig.json") throw new Error(\`\${part.name}: tsconfig.json does not extend the engine-written types\`);
}
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "each context-handoff part is one hooks module with no command, skill, agent, or classic hook, and tracks its tsconfig.json"
}

test_pure_policy() {
  local out
  cat >"$TMP_ROOT/policy.mjs" <<JS
import { pathToFileURL } from "node:url";
const main = await import(pathToFileURL(process.env.FM_TEST_MAIN_MOD + "/lib/fm-context-handoff.ts").href);
const worker = await import(pathToFileURL(process.env.FM_TEST_WORKER_MOD + "/hooks/register.ts").href);
const eq = (actual, expected, what) => {
  if (actual !== expected) throw new Error(\`\${what}: expected \${JSON.stringify(expected)}, got \${JSON.stringify(actual)}\`);
};
const root = "/code/.claude/mods/firstmate-context-handoff";
eq(main.switchPath({}, root), "/code/config/context-handoff", "code-root fallback");
eq(main.switchPath({}, "/code/.claude/skills/firstmate-context-handoff"), "/code/config/context-handoff", "auto-load path fallback");
eq(main.switchPath({ FM_HOME: "/h", FM_ROOT_OVERRIDE: "/r" }, root), "/h/config/context-handoff", "FM_HOME first");
eq(main.switchPath({ FM_ROOT_OVERRIDE: "/r" }, root), "/r/config/context-handoff", "FM_ROOT_OVERRIDE second");
eq(main.switchPath({ FM_HOME: "/h", FM_CONFIG_OVERRIDE: "/c" }, root), "/c/context-handoff", "FM_CONFIG_OVERRIDE outright");
eq(main.parseSwitch("on\n"), true, "on");
eq(main.parseSwitch(" on "), true, "trimmed on");
for (const value of [undefined, "", "off\n", "yes", "ON"]) eq(main.parseSwitch(value), false, \`value \${JSON.stringify(value)}\`);
if (!main.carryText(252_000, "R").startsWith("Handoff carried over from the previous session, which was cleared at 252k")) throw new Error("carry text");
const status = "/fm/home/state/fix-k3.status";
const brief = \`echo "{state} [at=<epoch>]: x" >> '\${status}'\`;
eq(worker.findStatusPath(["no path", brief], "fix-k3"), status, "status path from the brief");
eq(worker.findStatusPath([brief], "fix-k"), undefined, "a different task id");
eq(worker.handoffPathFor(status, "fix-k3"), "/fm/home/data/fix-k3/handoff.md", "handoff path");
const line = worker.statusLine(1700000000, 251_400, "/fm/home/data/fix-k3/handoff.md");
if (!/^working \[at=1700000000\]: context handoff written at 251k tokens used .*: \/fm\/home\/data\/fix-k3\/handoff\.md$/.test(line)) throw new Error(\`status line \${line}\`);
console.log("policy-ok");
JS
  out=$(run_node "$TMP_ROOT/policy.mjs" 2>&1) || fail "pure policy: $out"
  assert_contains "$out" "policy-ok" "pure policy check did not complete"
  pass "the switch resolves like config/calm and reads only on as on; the worker derives its status, handoff path, and working line"
}

test_placement
test_shape
test_pure_policy
