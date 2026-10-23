---
description: Install ai-state-machine (status line progress row, Codex hooks, ~/.ai-state-machine home)
argument-hint: "[--codex] [--uninstall]"
allowed-tools: Bash
---

Install ai-state-machine by running:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" --plugin $ARGUMENTS
```

The plugin already ships the Claude Code hooks, so `--plugin` skips adding them to settings.json.

- On success, summarise what it changed. That covers the status line, whether it wrapped an existing one (and which), and where backups went. Say the progress line appears once the session has a state.
- If Codex is installed and `--codex` wasn't passed, ask whether to wire Codex too, then re-run with `--codex` if they agree.
- If it fails because `jq` or `sqlite3` is missing, tell the user how to install it.
- Mention `~/.ai-state-machine/machine.json` is where they customise states, transitions and triggers.
