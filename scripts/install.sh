#!/bin/bash
# Install ai-state-machine into ~/.ai-state-machine and wire it into Claude Code, Codex and/or Cursor.
#
# Usage: install.sh [--claude] [--codex] [--cursor] [--plugin] [--uninstall]
#   (no harness flag)  set up every one of them that is installed
#   --claude           Claude Code: status line, plus hooks in settings.json unless --plugin
#   --codex            Codex: hooks in ~/.codex/hooks.json (Codex has no custom status line)
#   --cursor           Cursor CLI: status line in ~/.cursor/cli-config.json, hooks in ~/.cursor/hooks.json
#   --plugin           running from the Claude Code plugin, whose hooks/hooks.json supplies the hooks
#   --uninstall        undo the wiring; ~/.ai-state-machine (your machine.json and history) is kept
#
# Coexists with any existing status line (better-ai-status-line included): the existing
# command is saved to ~/.ai-state-machine/wrapped-statusline[.cursor] and asm runs it, then
# adds its own progress line underneath. Every edited file is backed up first.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASM_HOME="${ASM_HOME:-$HOME/.ai-state-machine}"
asm="$ASM_HOME/bin/asm"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_dir="${CODEX_HOME:-$HOME/.codex}"
cursor_dir="${CURSOR_HOME:-$HOME/.cursor}"
ours_hook="bash \"$asm\" hook"

claude=0 codex=0 cursor=0 plugin=0 uninstall=0
for arg in "$@"; do
  case "$arg" in
    --claude) claude=1 ;;
    --codex) codex=1 ;;
    --cursor) cursor=1 ;;
    --plugin) plugin=1; claude=1 ;;
    --uninstall) uninstall=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done
if [ "$claude$codex$cursor" = 000 ]; then
  { [ -d "$claude_dir" ] || command -v claude >/dev/null; } && claude=1
  { [ -d "$codex_dir" ] || command -v codex >/dev/null; } && codex=1
  { [ -d "$cursor_dir" ] || command -v cursor-agent >/dev/null; } && cursor=1
fi

for dep in jq sqlite3; do
  command -v "$dep" >/dev/null || { echo "ai-state-machine needs $dep (brew install $dep, or your package manager)" >&2; exit 1; }
done

backup() { [ -f "$1" ] && cp "$1" "$1.bak-asm-$(date +%Y%m%d-%H%M%S)" && echo "  backup: $1.bak-asm-…"; return 0; }
write_json() { local tmp; tmp=$(mktemp); jq "${@:2}" "$1" > "$tmp" && mv "$tmp" "$1"; }
ensure_json() { local d=${2:-'{}'}; [ -f "$1" ] || { mkdir -p "$(dirname "$1")"; printf '%s\n' "$d" > "$1"; }; }

# Status line in a Claude-style config ($1 file; $2 harness suffix for asm statusline, "" for Claude).
wire_statusline() {
  local file=$1 h=$2 ours current wrapped="$ASM_HOME/wrapped-statusline${2:+.$2}" label=${3:-$1}
  ours="bash \"$asm\" statusline${h:+ $h}"
  ensure_json "$file"
  current=$(jq -r '.statusLine.command // empty' "$file")
  if [ "$uninstall" = 1 ]; then
    [ "$current" = "$ours" ] || return 0
    backup "$file"
    if [ -s "$wrapped" ]; then
      write_json "$file" --arg cmd "$(cat "$wrapped")" '.statusLine.command = $cmd'
      echo "$label: restored the status line asm was wrapping."
    else
      write_json "$file" 'del(.statusLine)'; echo "$label: removed the asm status line."
    fi
    rm -f "$wrapped"; return 0
  fi
  if [ "$current" = "$ours" ]; then echo "$label: status line already runs asm."; return 0; fi
  backup "$file"
  if [ -n "$current" ]; then
    printf '%s\n' "$current" > "$wrapped"
    write_json "$file" --arg cmd "$ours" '.statusLine.command = $cmd'
    echo "$label: wrapped your existing status line; asm adds its progress line under it."
    echo "  wrapped: $current"
  else
    write_json "$file" --arg cmd "$ours" '.statusLine = {type: "command", command: $cmd, padding: 2}'
    echo "$label: status line set to asm."
  fi
}

# Claude/Codex hooks.json shape: add asm to SessionStart, UserPromptSubmit and PostToolUse
# (idempotent), or remove it. $1 file, $2 PostToolUse matcher ("" for none).
wire_hooks() {
  local file=$1 matcher=$2
  ensure_json "$file"; backup "$file"
  write_json "$file" --arg cmd "$ours_hook" --arg m "$matcher" --argjson rm "$uninstall" '
    def strip: map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0));
    def entry($ev): {hooks: [{type: "command", command: $cmd, timeout: 10}]}
      + (if $ev == "PostToolUse" and $m != "" then {matcher: $m} else {} end);
    .hooks //= {}
    | reduce ("SessionStart", "UserPromptSubmit", "PostToolUse") as $ev (.;
        .hooks[$ev] = (((.hooks[$ev] // []) | strip) + (if $rm == 1 then [] else [entry($ev)] end)))
    | .hooks |= with_entries(select(.value | length > 0))'
}

# Cursor hooks.json shape: {"version": 1, "hooks": {"event": [{"command": ..., "matcher": ...}]}}.
wire_cursor_hooks() {
  local file="$cursor_dir/hooks.json"
  ensure_json "$file" '{"version": 1}'; backup "$file"
  write_json "$file" --arg cmd "$ours_hook" --argjson rm "$uninstall" '
    def entry($ev): {command: $cmd} + (if $ev == "postToolUse" then {matcher: "^Shell$"} else {} end);
    .version //= 1 | .hooks //= {}
    | reduce ("sessionStart", "beforeSubmitPrompt", "postToolUse") as $ev (.;
        .hooks[$ev] = (((.hooks[$ev] // []) | map(select(.command != $cmd))) + (if $rm == 1 then [] else [entry($ev)] end)))
    | .hooks |= with_entries(select(.value | length > 0))'
}

if [ "$uninstall" = 0 ]; then
  # Central home: the CLI, the default machine, your machine.json and the history database.
  mkdir -p "$ASM_HOME/bin"
  cp "$here/bin/asm" "$asm"; chmod +x "$asm"
  cp "$here/machine.default.json" "$ASM_HOME/machine.default.json"
  if [ ! -f "$ASM_HOME/machine.json" ]; then
    cp "$here/machine.default.json" "$ASM_HOME/machine.json"
    echo "Created $ASM_HOME/machine.json (edit it to customise states, transitions and triggers)."
  fi
  ASM_HOME="$ASM_HOME" bash "$asm" validate "$ASM_HOME/machine.json"
fi

if [ "$claude" = 1 ]; then
  wire_statusline "$claude_dir/settings.json" "" "Claude Code"
  if [ "$plugin" = 0 ]; then
    wire_hooks "$claude_dir/settings.json" "Bash|Skill"
    [ "$uninstall" = 1 ] && echo "Claude Code: removed asm hooks." || echo "Claude Code: hooks added to $claude_dir/settings.json."
  fi
fi

if [ "$codex" = 1 ]; then
  wire_hooks "$codex_dir/hooks.json" ""
  if [ "$uninstall" = 1 ]; then echo "Codex: removed asm hooks."
  else
    echo "Codex: hooks added to $codex_dir/hooks.json."
    grep -qE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$codex_dir/config.toml" 2>/dev/null \
      || echo "  Codex hooks may be off: add 'hooks = true' under [features] in $codex_dir/config.toml."
    echo "  Codex's status line only shows built-in items, so run 'asm get' or 'asm log' there."
  fi
fi

if [ "$cursor" = 1 ]; then
  wire_statusline "$cursor_dir/cli-config.json" cursor "Cursor"
  wire_cursor_hooks
  [ "$uninstall" = 1 ] && echo "Cursor: removed asm hooks." || echo "Cursor: hooks added to $cursor_dir/hooks.json."
fi

[ "$uninstall" = 1 ] && echo "Kept $ASM_HOME (machine.json and state.db history)." || echo "Done. Restart running sessions to pick up the hooks."
