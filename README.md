# Ask Me While Testing

Omarchy shell plugin that lets a script or AI agent that changes your desktop (moving windows, workspaces, the bar, animations) ask you quick yes/no questions, instead of slow screenshot loops. Origin: AKT-460 / AKT-463.

## The flow
1. **Countdown.** `htm start "Desktop testing"` shows a card "Desktop testing is about to start 5 4 3 2 1". **Y** = "I'm here, I'll help" (human mode). **P** = postpone: type the minutes, Enter sends; the countdown waits while you type, the banner turns into a blue "Testing paused, resumes in M:SS" pill and `htm start` prints `postpone:<minutes>` (exit code 5). **Esc** = cancel (`cancelled`, exit 4: not now, the agent stops). No key = the agent goes on alone (solo mode).
2. **TESTING banner.** For the whole session a small always-on-top banner shows "TESTING in progress", the title, the mode and the time left. It never takes the keyboard. Click it to end the session.
3. **Questions.** `htm ask "Did the window move from left to right?"` shows the question. Press **Y** / **N**, or **?** for "can't tell", or **T** to type a reply in a textbox (Enter sends, Esc goes back), or **P** to postpone the test: type the minutes, the banner turns into a "Testing paused, resumes in M:SS" pill and the agent gets `postpone:<minutes>` (exit code 5), stops, and restarts the test after that time. In a `--text` box postponing is **Ctrl+P**. For an open question use `htm ask "What do you see?" --text`: the textbox opens at once. The command prints `yes`, `no`, `unsure`, `text:<what you typed>` or `timeout` and exits.
4. **Stop.** `htm end` removes the banner. Safety nets: Esc on a question ends the session (Esc in the textbox opened with T only goes back; with `--text` it ends the session) (`ask` prints `ended`), the session has a hard time limit (default 20 min), a killed `htm ask` withdraws its question.

The keyboard is grabbed only while the countdown card or a question (including its textbox) is on screen (the countdown needs it to hear Y). The rest of the time you type into your own windows as usual.

## Commands
```
htm start [TITLE] [--countdown SEC] [--max MIN]   -> human | solo | cancelled | postpone:<min>   (default 5 s, 20 min)
htm ask "QUESTION" [--text] [--timeout SEC]       -> yes | no | unsure | text:<typed> | postpone:<min> | timeout | ended  (default 60 s, 120 s with --text)
htm say "TEXT"                                     status line on the banner for 8 s, no answer
htm end                                            end the session
htm status                                         JSON: phase, mode, title, question, seconds left
```
Exit codes: 0 ok, 1 error (shell not running, plugin not loaded), 3 no session, 4 you pressed Esc (`cancelled` / `ended`), 5 you pressed P (`postpone:<min>`).
In solo mode `htm ask` prints `timeout` at once (nobody is there to answer). Only one question at a time; a new one replaces the old.

## Install
```
omarchy plugin add <repo url> --enable        # or copy this folder to ~/.config/omarchy/plugins/io.github.akton1.ask-me-while-testing/
ln -s ~/.config/omarchy/plugins/io.github.akton1.ask-me-while-testing/bin/htm ~/.local/bin/htm
```
Requires `omarchy-shell` running. No network, no sudo, no changes to your config. State: short-lived result files in `$XDG_RUNTIME_DIR/htm/` (removed by `htm`, gone at logout).

## Remove
```
omarchy plugin disable io.github.akton1.ask-me-while-testing && omarchy plugin remove io.github.akton1.ask-me-while-testing
rm -f ~/.local/bin/htm; rm -rf "$XDG_RUNTIME_DIR/htm"
```

## For agents
Opt-in only. One command sets it up: `bin/htm-install-agent all ~/.claude/CLAUDE.md` (skill + instructions block + guard), or pick parts: `skill`, `block FILE`, `guard`; undo the guard with `guard-remove`; `status` shows what is on. Manual route: [docs/agent-instructions.md](docs/agent-instructions.md) is a block to paste into AGENTS.md / CLAUDE.md, and [docs/skill/ask-me-while-testing/SKILL.md](docs/skill/ask-me-while-testing/SKILL.md) is a Claude Code skill (copy to `~/.claude/skills/ask-me-while-testing/`). No root AGENTS.md/CLAUDE.md on purpose (the marketplace rejects them).

## Develop and test
- Logic: `node tests/model.test.js`.
- Scratch shell (does not touch your running shell): make a folder with symlinks to `/usr/share/omarchy/shell/Commons`, `Service.qml`, `HtmModel.js` and a `shell.qml` containing `ShellRoot { Service {} }`; run `quickshell -n -p <folder>`; talk to it with `HTM_QS_PATH=<folder> bin/htm ...`.
- `omarchy plugin validate .`

## Guard for agents

`bin/htm-guard` is symlinked as `wtype`, `omarchy-restart-shell` and `hyprctl` in `~/.local/bin` (`htm-install-agent guard`). Inside an agent run these refuse to run (exit 99) unless an `htm start` session is active; everywhere else they pass straight through to the real command. An agent run is detected by `CLAUDECODE` (Claude Code), `PAPERCLIP_RUN_ID` (Paperclip) or `HTM_GUARD=1` (set it yourself for any other agent). `HTM_GUARD_OFF=1` bypasses the guard. Only these three commands are covered; `~/.local/bin` must come first in `PATH`.

Proposal for Omarchy itself (plugins shipping agent skills): [docs/omarchy-feature-request-agent-skills.md](docs/omarchy-feature-request-agent-skills.md).
