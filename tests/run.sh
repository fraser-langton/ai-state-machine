#!/bin/bash
# Smoke tests for asm against the default machine, in a throwaway ASM_HOME.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
export ASM_HOME; ASM_HOME=$(mktemp -d)
export ASM_SESSION_ID=t1 ASM_HARNESS=test
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID ASM_MACHINE
cd "$ASM_HOME"   # outside $HOME, so no real .ai-state-machine/machine.json is found walking up
fail=0
asm() { timeout 60 "$here/bin/asm" "$@" </dev/null; }
hook() { printf '%s' "$1" | timeout 60 "$here/bin/asm" hook; }
expect() { # expect <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
ev() { printf '{"session_id":"t1","hook_event_name":"%s",%s}' "$1" "$2"; }
bash_ev() { ev PostToolUse "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(jq -Rn --arg c "$1" '$c')}"; }

expect "validate" "ok: $here/bin/../machine.default.json" "$(asm validate)"
expect "unset" "(none)" "$(asm get)"
asm set plan >/dev/null
asm set "ready for review" >/dev/null 2>&1; expect "disallowed move refused" "1" "$?"
expect "still PLAN" "PLAN" "$(asm get)"
asm set dev >/dev/null; asm set ready-for-review --reason "tests done" >/dev/null
hook "$(ev UserPromptSubmit '"prompt":"/code-review high"')"; expect "prompt /code-review" "IN REVIEW" "$(asm get)"
asm set "review done" >/dev/null
hook "$(ev UserPromptSubmit '"prompt":"please /code-review later"')"; expect "mention ignored" "REVIEW DONE" "$(asm get)"
hook "$(bash_ev 'git add -A && git commit -m fix')"; expect "commit after REVIEW DONE" "READY FOR REVIEW" "$(asm get)"
hook "$(bash_ev 'git commit -m more')"; expect "commit when not REVIEW DONE" "READY FOR REVIEW" "$(asm get)"
hook "$(ev PostToolUse '"tool_name":"Skill","tool_input":{"skill":"codex-review"}')"; expect "skill codex-review" "IN REVIEW" "$(asm get)"
asm set "review done" >/dev/null
hook "$(bash_ev 'gh pr create --draft --title x')"; expect "gh pr create --draft" "DRAFT PR" "$(asm get)"
hook "$(bash_ev 'gh pr view 5')"; expect "gh pr view ignored" "DRAFT PR" "$(asm get)"
hook "$(bash_ev 'gh pr ready 5')"; expect "gh pr ready" "PR READY" "$(asm get)"
hook "$(ev UserPromptSubmit '"prompt":"/merge-when-ready 5"')"; expect "/merge-when-ready" "MERGING" "$(asm get)"
hook "$(bash_ev 'gh pr merge 5 --auto --squash')"; expect "--auto ignored" "MERGING" "$(asm get)"
hook "$(ev PostToolUse '"tool_name":"exec_command","tool_input":{"command":["bash","-lc","gh pr merge 5 --squash --admin"]}')"
expect "codex-style array command merge" "MERGED" "$(asm get)"

line=$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" render | sed 's/\x1b\[[0-9;]*m//g')
expect "render" "✓ PLAN › ✓ DEV › ✓ READY FOR REVIEW › ✓ IN REVIEW › ✓ REVIEW DONE › ✓ DRAFT PR › ✓ PR READY › ✓ MERGING ›  MERGED  › DEPLOYED" "$line"

# Cursor: camelCase events, Shell tool, command in tool_input.
cur_ev() { printf '{"session_id":"t1","hook_event_name":"%s",%s}' "$1" "$2"; }
asm set "pr ready" --force >/dev/null
hook "$(cur_ev beforeSubmitPrompt '"prompt":"/merge-when-ready 7"')"; expect "cursor beforeSubmitPrompt" "MERGING" "$(asm get)"
ASM_HARNESS= hook "$(cur_ev postToolUse '"tool_name":"Shell","tool_input":{"command":"gh pr merge 7 --squash"}')"; expect "cursor postToolUse Shell" "MERGED" "$(asm get)"
expect "cursor harness recorded" "cursor" "$(sqlite3 "$ASM_HOME/state.db" "select harness from transitions order by id desc limit 1")"
ctx=$(printf '{"session_id":"t1","hook_event_name":"sessionStart"}' | timeout 60 "$here/bin/asm" hook | jq -r '.additional_context' | head -1)
expect "cursor sessionStart context" "ai-state-machine tracks this session's workflow stage (machine: dev-workflow). Current stage: MERGED." "$ctx"

# Hooks that don't fire, and the progress line, start no programs: run them with an empty PATH.
nopath() { PATH=/var/empty /bin/bash "$here/bin/asm" "$@"; }
out=$(printf '%s' "$(bash_ev 'ls -la')" | nopath hook 2>&1; echo "rc=$?")
expect "non-firing hook needs no programs" "rc=0" "$out"
out=$(printf '%s' "$(ev UserPromptSubmit '"prompt":"hello"')" | nopath hook 2>&1; echo "rc=$?")
expect "plain prompt needs no programs" "rc=0" "$out"
out=$(printf '{"session_id":"t1"}' | nopath render 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | head -c 8)
expect "render needs no programs" "✓ PLAN" "$out"

asm reset --reason "new task" >/dev/null; expect "reset" "(none)" "$(asm get)"
expect "render empty after reset" "" "$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" render)"
asm set plan >/dev/null; asm set dev --force >/dev/null; asm set "pr ready" --force >/dev/null
line=$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" render | sed 's/\x1b\[[0-9;]*m//g')
expect "skipped stages marked" "✓ PLAN › ✓ DEV › ✗ READY FOR REVIEW › ✗ IN REVIEW › ✗ REVIEW DONE › ✗ DRAFT PR ›  PR READY  › MERGING › MERGED › DEPLOYED" "$line"
expect "history kept" "19" "$(sqlite3 "$ASM_HOME/state.db" 'select count(*) from transitions')"
expect "forced moves flagged" "2" "$(sqlite3 "$ASM_HOME/state.db" "select count(*) from transitions where allowed = 0")"

echo 'printf "WRAPPED"' > "$ASM_HOME/wrapped-statusline"
out=$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" statusline | sed 's/\x1b\[[0-9;]*m//g' | head -1)
expect "statusline wraps existing" "WRAPPED" "$out"

ctx=$(printf '{"session_id":"t1","hook_event_name":"SessionStart"}' | timeout 60 "$here/bin/asm" hook | jq -r .hookSpecificOutput.additionalContext | head -1)
expect "SessionStart context" "ai-state-machine tracks this session's workflow stage (machine: dev-workflow). Current stage: PR READY." "$ctx"

# Per-repo machines: the nearest .ai-state-machine/machine.json wins over the user's.
repo="$ASM_HOME/repo"; mkdir -p "$repo/.ai-state-machine" "$repo/src/deep"
cat > "$repo/.ai-state-machine/machine.json" <<'JSON'
{ "name": "tickets",
  "states": [ {"name": "TODO", "color": 244}, {"name": "DOING", "color": 39}, {"name": "DONE", "color": 82} ],
  "transitions": { "TODO": ["DOING"], "DOING": ["DONE"] },
  "triggers": [ {"label": "git commit", "on": "command", "match": "git commit", "to": "DONE"} ] }
JSON
( cd "$repo/src/deep"
  expect "which finds repo machine" "$repo/src/deep/../../.ai-state-machine/machine.json" "$(asm which | sed "s#^$repo#$repo/src/deep/../..#")"
  export ASM_SESSION_ID=t2
  expect "set from a repo subfolder" "(none) -> DOING" "$(asm set doing)"
  asm set todo >/dev/null 2>&1; expect "repo machine enforces its own transitions" "1" "$?"
)
expect "user/default machine used outside the repo" "$here/bin/../machine.default.json" "$(asm which)"
line=$(printf '{"session_id":"t2","workspace":{"current_dir":"%s"}}' "$repo" | timeout 60 "$here/bin/asm" render | sed 's/\x1b\[[0-9;]*m//g')
expect "status line uses the session folder's machine" " DOING  › DONE" "${line#*› }"
expect "machine name recorded" "tickets" "$(sqlite3 "$ASM_HOME/state.db" "select machine from transitions where session_id = 't2' order by id desc limit 1")"
expect "diagram edge with trigger label" "    DOING --> DONE : auto · git commit" "$(cd "$repo" && asm diagram | grep 'DOING --> DONE')"
mkdir -p "$ASM_HOME/other" && (cd "$ASM_HOME/other" && git init -q && asm init >/dev/null)
expect "init gives a repo its own machine" "1" "$([ -f "$ASM_HOME/other/.ai-state-machine/machine.json" ] && echo 1)"

cd /; rm -rf "$ASM_HOME"
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
