#!/bin/bash
# Smoke tests for asm against the default machine, in a throwaway ASM_HOME.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
export ASM_HOME; ASM_HOME=$(mktemp -d)
export ASM_SESSION_ID=t1 ASM_HARNESS=test
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID ASM_MACHINE
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

asm reset --reason "new task" >/dev/null; expect "reset" "(none)" "$(asm get)"
expect "render empty after reset" "" "$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" render)"
asm set plan >/dev/null; asm set dev --force >/dev/null; asm set "pr ready" --force >/dev/null
line=$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" render | sed 's/\x1b\[[0-9;]*m//g')
expect "skipped stages marked" "✓ PLAN › ✓ DEV › ✗ READY FOR REVIEW › ✗ IN REVIEW › ✗ REVIEW DONE › ✗ DRAFT PR ›  PR READY  › MERGING › MERGED › DEPLOYED" "$line"
expect "history kept" "16" "$(sqlite3 "$ASM_HOME/state.db" 'select count(*) from transitions')"
expect "forced move flagged" "1" "$(sqlite3 "$ASM_HOME/state.db" "select count(*) from transitions where allowed = 0")"

echo 'printf "WRAPPED"' > "$ASM_HOME/wrapped-statusline"
out=$(printf '{"session_id":"t1"}' | timeout 60 "$here/bin/asm" statusline | sed 's/\x1b\[[0-9;]*m//g' | head -1)
expect "statusline wraps existing" "WRAPPED" "$out"

ctx=$(printf '{"session_id":"t1","hook_event_name":"SessionStart"}' | timeout 60 "$here/bin/asm" hook | jq -r .hookSpecificOutput.additionalContext | head -1)
expect "SessionStart context" "ai-state-machine tracks this session's workflow stage (machine: dev-workflow). Current stage: PR READY." "$ctx"

rm -rf "$ASM_HOME"
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
