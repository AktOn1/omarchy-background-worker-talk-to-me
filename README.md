# Human Test Mode

Omarchy shell plugin that lets a script or AI agent that changes your desktop (moving windows, workspaces, the bar, animations) ask you quick yes/no questions, instead of slow screenshot loops. Origin: AKT-460 / AKT-463.

## The flow
1. **Countdown.** `htm start "Desktop testing"` shows a card "Desktop testing is about to start 5 4 3 2 1". **Y** = "I'm here, I'll help" (human mode). **Esc** = cancel (the agent is told to stop). No key = the agent goes on alone (solo mode).
2. **TESTING banner.** For the whole session a small always-on-top banner shows "TESTING in progress", the title, the mode and the time left. It never takes the keyboard. Click it to end the session.
3. **Questions.** `htm ask "Did the window move from left to right?"` shows the question. Press **Y** / **N**, or **?** for "can't tell". The command prints `yes`, `no`, `unsure` or `timeout` and exits.
4. **Stop.** `htm end` removes the banner. Safety nets: Esc on a question ends the session (`ask` prints `ended`), the session has a hard time limit (default 20 min), a killed `htm ask` withdraws its question.

The keyboard is grabbed only while the countdown card or a question is on screen (the countdown needs it to hear Y). The rest of the time you type into your own windows as usual.

## Commands
```
htm start [TITLE] [--countdown SEC] [--max MIN]   -> human | solo | cancelled   (default 5 s, 20 min)
htm ask "QUESTION" [--timeout SEC]                -> yes | no | unsure | timeout | ended  (default 60 s)
htm say "TEXT"                                     status line on the banner for 8 s, no answer
htm end                                            end the session
htm status                                         JSON: phase, mode, title, question, seconds left
```
Exit codes: 0 ok, 1 error (shell not running, plugin not loaded), 3 no session, 4 you pressed Esc (`cancelled` / `ended`).
In solo mode `htm ask` prints `timeout` at once (nobody is there to answer). Only one question at a time; a new one replaces the old.

## Install
```
omarchy plugin add <repo url> --enable        # or copy this folder to ~/.config/omarchy/plugins/io.github.akton1.human-test-mode/
ln -s ~/.config/omarchy/plugins/io.github.akton1.human-test-mode/bin/htm ~/.local/bin/htm
```
Requires `omarchy-shell` running. No network, no sudo, no changes to your config. State: short-lived result files in `$XDG_RUNTIME_DIR/htm/` (removed by `htm`, gone at logout).

## Remove
```
omarchy plugin disable io.github.akton1.human-test-mode && omarchy plugin remove io.github.akton1.human-test-mode
rm -f ~/.local/bin/htm; rm -rf "$XDG_RUNTIME_DIR/htm"
```

## For agents
Opt-in only. [docs/agent-instructions.md](docs/agent-instructions.md) is a block to paste into AGENTS.md / CLAUDE.md, and [docs/skill/human-test-mode/SKILL.md](docs/skill/human-test-mode/SKILL.md) is a Claude Code skill (copy to `~/.claude/skills/human-test-mode/`). No root AGENTS.md/CLAUDE.md on purpose (the marketplace rejects them).

## Develop and test
- Logic: `node tests/model.test.js`.
- Scratch shell (does not touch your running shell): make a folder with symlinks to `/usr/share/omarchy/shell/Commons`, `Service.qml`, `HtmModel.js` and a `shell.qml` containing `ShellRoot { Service {} }`; run `quickshell -n -p <folder>`; talk to it with `HTM_QS_PATH=<folder> bin/htm ...`.
- `omarchy plugin validate .`
