---
description: Show or set this session's workflow state, or show its history
argument-hint: "[STATE | log | states | reset]"
allowed-tools: Bash
---

Run the matching command. `asm` is `bash "$HOME/.ai-state-machine/bin/asm"`.

- No argument: `asm get`, then `asm log --limit 10`.
- `log`, `states` or `reset`: `asm $ARGUMENTS`.
- Anything else is a state name: `asm set $ARGUMENTS`. If it's refused as a disallowed transition, show the allowed next states and ask before retrying with `--force`.

Report the result in one or two lines.
