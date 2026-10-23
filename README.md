**To install, paste this into any AI coding agent (Claude Code, Codex or anything else):**

```text
Install ai-state-machine from https://github.com/fraser-langton/ai-state-machine into the AI coding tool you are running in.

1. Clone the repo into a temporary directory. Read README.md, bin/asm, machine.default.json and scripts/install.sh.
2. If you are Claude Code or Codex: run `bash <clone>/scripts/install.sh --claude` or `--codex`. It needs jq and sqlite3; if either is missing, tell me how to install it.
3. If you are any other tool: copy bin/asm to ~/.ai-state-machine/bin/asm and machine.default.json to ~/.ai-state-machine/machine.json. Then find out how the tool runs hooks and configures its status line. Wire `bash ~/.ai-state-machine/bin/asm hook` to its session-start, prompt-submit and after-tool events, passing the event JSON on stdin. If its status line can run a command, make it run `asm statusline` and keep the existing one by saving its command to ~/.ai-state-machine/wrapped-statusline. Back up any config file before changing it.
4. If Claude Code or Codex is also installed on this machine, ask me whether to set that one up too.
5. Tell me what you changed, where the backups are, and whether I need to restart anything.
```

# ai-state-machine

Know where every AI coding session is in your workflow. You define the states and the allowed moves between them. Hooks move the session automatically when something observable happens, the agent moves it the rest of the way, and a progress line under your status line shows the result:

```
Model: Opus 5.5 | Effort: high | 5h: 42% (1h30m) | 7d: 81% (2d7h) | Cost: $1.23
✓ PLAN › ✓ DEV › ✗ READY FOR REVIEW › ✗ IN REVIEW › ✓ REVIEW DONE › ▌PR READY▐ › MERGING › MERGED › DEPLOYED
```

| Mark | Meaning |
| --- | --- |
| highlighted block | the current state |
| `✓` in the state's colour | visited this session |
| red `✗` | skipped: never visited, but a later state was reached |
| dim grey | not reached yet |

Every transition is stored permanently, so you can see how work actually flows.

## How it works

- **`~/.ai-state-machine/`** is the one central home for every harness:
  - `machine.json` is your state machine
  - `state.db` is the transition history
  - `bin/asm` is the CLI
- **History is append-only SQLite.** Each row records time, session, harness, cwd, repo and branch, from-state, to-state, what caused it and whether the move was allowed. `asm reset` appends a reset row; nothing is ever deleted.
- **Hooks** (session start, prompt submit, after a tool runs) apply your triggers. At session start they also tell the agent the current state, what each state means and how to move it.
- **The agent** runs `asm set "<STATE>"` for the moves no hook can see, such as "the review came back clean".
- **The status line** runs your existing status line command and adds the progress line underneath, so it works alongside [better-ai-status-line](https://github.com/fraser-langton/better-ai-status-line) or anything else.

| Harness | Hooks | Progress line |
| --- | --- | --- |
| Claude Code | plugin `hooks/hooks.json`, or `install.sh --claude` | yes, under your status line |
| Codex | `~/.codex/hooks.json` via `install.sh --codex` (needs `hooks = true` under `[features]`) | no: Codex's status line only shows built-in items, so use `asm get` / `asm log` |
| Others | any tool that can run a command on events with JSON on stdin | if its status line can run a command |

## Install (Claude Code)

Requires `bash`, `jq` and `sqlite3`.

```
/plugin install ai-state-machine --marketplace fraser-langton/ai-state-machine
/ai-state-machine:setup
```

Setup copies `asm` to `~/.ai-state-machine/bin`, creates `machine.json` from the default if you don't have one, and wraps your status line, backing up `settings.json` first. Add `--codex` to wire Codex too.

### Manual install

```sh
git clone https://github.com/fraser-langton/ai-state-machine
bash ai-state-machine/scripts/install.sh            # sets up Claude Code and Codex if present
bash ai-state-machine/scripts/install.sh --uninstall  # undo; your machine.json and history are kept
```

## Customise the state machine

Edit `~/.ai-state-machine/machine.json`, then run `asm validate`. The default is a plan → build → local review → PR → merge → deploy workflow:

```jsonc
{
  "name": "dev-workflow",
  "states": [
    { "name": "PLAN", "color": 141, "description": "Designing or planning, no code yet." },
    { "name": "DEV", "color": 39, "description": "Building, including UAT checks, hands-on review and writing tests." }
    // … in display order; color is a 256-colour ANSI code
  ],
  "transitions": {
    "PLAN": ["DEV"],
    "DEV": ["PLAN", "READY FOR REVIEW"]
    // omit "transitions" entirely to allow any move
  },
  "triggers": [
    { "on": "prompt",  "match": "^\\s*[/$]([a-z0-9-]+:)?(code-review|codex-review|my-review|review)\\b", "to": "IN REVIEW" },
    { "on": "skill",   "match": "^([a-z0-9-]+:)?merge-when-ready$", "to": "MERGING" },
    { "on": "command", "match": "(^|[;&|(\\s])gh pr merge\\b", "unless": "--(auto|disable-auto)\\b", "to": "MERGED" },
    { "on": "command", "match": "(^|[;&|(\\s])git commit\\b", "from": ["REVIEW DONE"], "to": "READY FOR REVIEW" }
  ]
}
```

- **States** are listed in display order. `description` is what the agent is told each state means.
- **Transitions** map each state to the states it may move to.
  - `asm set` refuses any other move unless you pass `--force`, which records the move with `allowed = 0`.
  - Triggers always record what happened, even when the move isn't listed, and flag it the same way.
- **Triggers** fire on:
  - `prompt`: what the user typed
  - `skill`: a skill the agent invoked
  - `command`: a shell command the agent ran

  `match` and `unless` are regexes, and `from` limits a trigger to certain current states. The first matching trigger wins.

## CLI

```
asm set <STATE> [--force] [--reason TEXT]   move this session (names are case-insensitive: asm set "in review")
asm get                                     current state
asm states                                  states, allowed next states and descriptions
asm log [--all] [--limit N]                 history for this session, or every session
asm reset [--reason TEXT]                   start this session's progress over
asm validate                                check machine.json
```

The session comes from `--session`, else `$ASM_SESSION_ID`, `$CLAUDE_CODE_SESSION_ID` or `$CODEX_THREAD_ID`. In Claude Code, `/ai-state-machine:state [STATE|log|states|reset]` does the same.

### Analyse the history

```sh
sqlite3 ~/.ai-state-machine/state.db "
  SELECT to_state, COUNT(*) FROM transitions WHERE to_state <> '' GROUP BY 1 ORDER BY 2 DESC;"
sqlite3 ~/.ai-state-machine/state.db "
  SELECT repo, from_state, to_state, source FROM transitions WHERE allowed = 0;"   -- skipped or forced moves
```

## Options

| Variable | Effect |
| --- | --- |
| `ASM_HOME` | Central home. Default `~/.ai-state-machine`. |
| `ASM_MACHINE` | Use a different machine file, for example per project. |
| `ASM_SESSION_ID` | Override the session ID. |

## Tests

```sh
bash tests/run.sh
```

## License

MIT
