#!/bin/bash
# Install ai-state-machine into ~/.ai-state-machine and wire it into Claude Code and/or Codex.
#
# Usage: install.sh [--claude] [--codex] [--plugin] [--uninstall]
#   (no harness flag)  set up whichever of Claude Code and Codex are installed
#   --claude           Claude Code: status line, plus hooks in settings.json unless --plugin
#   --codex            Codex: hooks in ~/.codex/hooks.json (Codex has no custom status line)
#   --plugin           running from the Claude Code plugin, whose hooks/hooks.json supplies the hooks
#   --uninstall        undo the wiring; ~/.ai-state-machine (your machine.json and history) is kept
#
# Coexists with any existing Claude Code status line (better-ai-status-line included):
# the existing command is saved to ~/.ai-state-machine/wrapped-statusline and asm runs it,
# then adds its own progress line underneath. Every edited file is backed up first.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASM_HOME="${ASM_HOME:-$HOME/.ai-state-machine}"
asm="$ASM_HOME/bin/asm"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings="$claude_dir/settings.json"
codex_hooks="${CODEX_HOME:-$HOME/.codex}/hooks.json"
ours_statusline="bash \"$asm\" statusline"
ours_hook="bash \"$asm\" hook"

claude=0 codex=0 plugin=0 uninstall=0
for arg in "$@"; do
  case "$arg" in
    --claude) claude=1 ;;
    --codex) codex=1 ;;
    --plugin) plugin=1; claude=1 ;;
    --uninstall) uninstall=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done
if [ "$claude" = 0 ] && [ "$codex" = 0 ]; then
  { [ -d "$claude_dir" ] || command -v claude >/dev/null; } && claude=1
  { [ -d "$(dirname "$codex_hooks")" ] || command -v codex >/dev/null; } && codex=1
fi

for dep in jq sqlite3; do
  command -v "$dep" >/dev/null || { echo "ai-state-machine needs $dep (brew install $dep, or your package manager)" >&2; exit 1; }
done

backup() { [ -f "$1" ] && cp "$1" "$1.bak-asm-$(date +%Y%m%d-%H%M%S)" && echo "  backup: $1.bak-asm-…"; }
write_json() { local tmp; tmp=$(mktemp); jq "${@:2}" "$1" > "$tmp" && mv "$tmp" "$1"; }

# Hooks for one harness file: add asm to SessionStart, UserPromptSubmit and PostToolUse (idempotent),
# or remove it. $1 file, $2 PostToolUse matcher ("" for none).
wire_hooks() {
  local file=$1 matcher=$2
  [ -f "$file" ] || { mkdir -p "$(dirname "$file")"; echo '{}' > "$file"; }
  backup "$file"
  write_json "$file" --arg cmd "$ours_hook" --arg m "$matcher" --argjson rm "$uninstall" '
    def strip: map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0));
    def entry($ev): {hooks: [{type: "command", command: $cmd, timeout: 10}]}
      + (if $ev == "PostToolUse" and $m != "" then {matcher: $m} else {} end);
    .hooks //= {}
    | reduce ("SessionStart", "UserPromptSubmit", "PostToolUse") as $ev (.;
        .hooks[$ev] = (((.hooks[$ev] // []) | strip) + (if $rm == 1 then [] else [entry($ev)] end)))
    | .hooks |= with_entries(select(.value | length > 0))'
}

if [ "$uninstall" = 1 ]; then
  if [ "$claude" = 1 ] && [ -f "$settings" ]; then
    current=$(jq -r '.statusLine.command // empty' "$settings")
    if [ "$current" = "$ours_statusline" ]; then
      backup "$settings"
      if [ -s "$ASM_HOME/wrapped-statusline" ]; then
        write_json "$settings" --arg cmd "$(cat "$ASM_HOME/wrapped-statusline")" '.statusLine.command = $cmd'
        echo "Claude Code: restored the status line asm was wrapping."
      else
        write_json "$settings" 'del(.statusLine)'
        echo "Claude Code: removed the asm status line."
      fi
      rm -f "$ASM_HOME/wrapped-statusline"
    fi
    wire_hooks "$settings" "Bash|Skill" && echo "Claude Code: removed asm hooks from settings.json."
  fi
  if [ "$codex" = 1 ] && [ -f "$codex_hooks" ]; then
    wire_hooks "$codex_hooks" "" && echo "Codex: removed asm hooks from $codex_hooks."
  fi
  echo "Kept $ASM_HOME (machine.json and state.db history)."
  exit 0
fi

# Central home: the CLI, the default machine, your machine.json and the history database.
mkdir -p "$ASM_HOME/bin"
cp "$here/bin/asm" "$asm"; chmod +x "$asm"
cp "$here/machine.default.json" "$ASM_HOME/machine.default.json"
if [ ! -f "$ASM_HOME/machine.json" ]; then
  cp "$here/machine.default.json" "$ASM_HOME/machine.json"
  echo "Created $ASM_HOME/machine.json (edit it to customise states, transitions and triggers)."
fi
ASM_HOME="$ASM_HOME" bash "$asm" validate

if [ "$claude" = 1 ]; then
  [ -f "$settings" ] || { mkdir -p "$claude_dir"; echo '{}' > "$settings"; }
  current=$(jq -r '.statusLine.command // empty' "$settings")
  if [ "$current" = "$ours_statusline" ]; then
    echo "Claude Code: status line already runs asm."
  else
    backup "$settings"
    if [ -n "$current" ]; then
      printf '%s\n' "$current" > "$ASM_HOME/wrapped-statusline"
      write_json "$settings" --arg cmd "$ours_statusline" '.statusLine.command = $cmd'
      echo "Claude Code: wrapped your existing status line; asm adds its progress line under it."
      echo "  wrapped: $current"
    else
      write_json "$settings" --arg cmd "$ours_statusline" '.statusLine = {type: "command", command: $cmd, padding: 2}'
      echo "Claude Code: status line set to asm."
    fi
  fi
  if [ "$plugin" = 0 ]; then
    wire_hooks "$settings" "Bash|Skill"
    echo "Claude Code: hooks added to $settings."
  fi
fi

if [ "$codex" = 1 ]; then
  wire_hooks "$codex_hooks" ""
  echo "Codex: hooks added to $codex_hooks."
  cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if ! grep -qE '^\s*hooks\s*=\s*true' "$cfg" 2>/dev/null; then
    echo "  Codex hooks may be off: add 'hooks = true' under [features] in $cfg."
  fi
  echo "  Codex's status line only shows built-in items, so run 'asm get' or 'asm log' there."
fi

echo "Done. Restart running sessions to pick up the hooks."
