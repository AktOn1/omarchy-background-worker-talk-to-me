# Ask Me While Testing

<a href='https://ko-fi.com/akton1' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi3.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

Omarchy shell plugin that lets a script or AI agent that changes your desktop (moving windows, workspaces, the bar, animations) ask you quick yes/no questions, instead of slow screenshot loops. Origin: AKT-460 / AKT-463.

## The flow
1. **Countdown.** `htm start "Desktop testing"` shows a card "Desktop testing is about to start 5 4 3 2 1". It is a heads-up, not a question: if you are at the desk and not ready, press **P** or **Esc**; if you are away, it runs out and the agent continues alone. **Y** exists only when the agent asks for help with `htm start "title" --help "watch the screen and press Y/N after each window move"`: the card then says "Faster with your help: …" and Y = "I'll help" (human mode, `htm ask` works). **P** = postpone: type the minutes, Enter sends; the countdown waits while you type, the banner turns into a blue "Testing paused, resumes in M:SS" pill and `htm start` prints `postpone:<minutes>` (exit code 5). **Esc** = cancel (`cancelled`, exit 4: not now, the agent stops). No key = the agent goes on alone (solo mode; `htm ask` then prints `timeout` at once, so an agent that wants answers must pass `--help`).
**Every screen, more time to read.** The countdown and question cards show on every monitor (the keyboard goes to the card on the screen you are working on; the buttons are clickable on any of them). Tap **Ctrl alone** to freeze the countdown or question timer while you read; tap Ctrl again to continue (it resumes by itself after 120 s). Ctrl+P and other Ctrl combinations do not count. `htm` waits long enough for a hold.

2. **TESTING banner.** For the whole session a small always-on-top banner shows "TESTING in progress", the title, the mode and the time left. It never takes the keyboard. Click it to end the session.
3. **Questions.** `htm ask "Did the window move from left to right?"` shows the question. Press **Y** / **N**, or **?** for "can't tell", or **T** to type a reply in a textbox (Enter sends, Esc goes back), or **P** to postpone the test: type the minutes, the banner turns into a "Testing paused, resumes in M:SS" pill and the agent gets `postpone:<minutes>` (exit code 5), stops, and restarts the test after that time. In a `--text` box postponing is **Ctrl+P**. For an open question use `htm ask "What do you see?" --text`: the textbox opens at once. The command prints `yes`, `no`, `unsure`, `text:<what you typed>` or `timeout` and exits.
4. **Experimental: a question without a test.** `htm question "Which one, A or B?"` shows a plain question card (Y / N / ? / T, Esc dismisses) with no TESTING banner and no countdown, so an agent that is stuck on a decision can ask you while you work in another app. It is **off** until you run `htm settings set questions on`. Agents are told to use it only when blocked and a wrong guess is costly; `question-gap` (default 60 s) refuses a second question too soon. Esc prints `dismissed`; P (postpone) does not exist here.
5. **Stop.** `htm end` removes the banner. Safety nets: Esc on a question ends the session (Esc in the textbox opened with T only goes back; with `--text` it ends the session) (`ask` prints `ended`), the session has a hard time limit (default 20 min), a killed `htm ask` withdraws its question.

The keyboard is grabbed only while the countdown card or a question (including its textbox) is on screen (the countdown needs it to hear P and Esc, and Y when help was asked for). The rest of the time you type into your own windows as usual.

## Commands
```
htm start [TITLE] [--help TEXT] [--countdown SEC] [--max MIN]   -> human | solo | cancelled | postpone:<min>   (default 5 s, 20 min)
htm ask "QUESTION" [--text] [--timeout SEC]       -> yes | no | unsure | text:<typed> | postpone:<min> | timeout | ended  (default 60 s, 120 s with --text)
htm question "QUESTION" [--text] [--timeout SEC]   EXPERIMENTAL, off by default -> yes | no | unsure | text:<typed> | dismissed | timeout | busy | disabled | toosoon  (default 120 s)
htm settings [get KEY | set KEY VALUE | reset [KEY]]   list or change settings
htm say "TEXT"                                     status line on the banner for 8 s, no answer
htm end                                            end the session
htm status                                         JSON: phase, mode, title, question, seconds left
```
Exit codes: 0 ok, 1 error (shell not running, plugin not loaded), 3 no session, 4 you pressed Esc (`cancelled` / `ended` / `dismissed`), 5 you pressed P (`postpone:<min>`), 6 `htm question` not allowed (`disabled`, `toosoon` or `busy`).
In solo mode `htm ask` prints `timeout` at once (nobody is there to answer). Only one question at a time; a new one replaces the old.

## Settings (command line)
Stored in `~/.config/ask-me-while-testing/settings.conf` (plain `key=value`). `htm settings` lists them, `htm settings set KEY VALUE` changes one, `htm settings reset [KEY]` goes back to the defaults. Options on the command line (`--countdown`, `--max`, `--timeout`) always win.

| Key | Values | Default | What |
|---|---|---|---|
| `questions` | `on` / `off` | `off` | allow `htm question` (experimental) |
| `question-timeout` | 3-600 s | 120 | how long a question card stays |
| `question-gap` | 0-3600 s | 60 | minimum time between two questions |
| `countdown` | 1-30 s | 5 | start countdown |
| `max` | 1-240 min | 20 | session time limit |
| `ask-timeout` | 3-600 s | 60 | `htm ask` |
| `text-timeout` | 3-600 s | 120 | `htm ask --text` |

## Install
```
omarchy plugin add <repo url> --enable        # or copy this folder to ~/.config/omarchy/plugins/io.github.akton1.ask-me-while-testing/
ln -s ~/.config/omarchy/plugins/io.github.akton1.ask-me-while-testing/bin/htm ~/.local/bin/htm
```
Requires `omarchy-shell` running. No network, no sudo, no changes to your config. State: short-lived result files in `$XDG_RUNTIME_DIR/htm/` (removed by `htm`, gone at logout).

## Try it with an agent
Open an agent (`omarchy agent`, Claude Code, ...) with the instructions installed (see "For agents") and paste one of these. Each one exercises a different feature.

### One block for everything
No mention of the plugin or `htm`. The task itself makes the agent touch the desktop (guard, countdown, banner), need a human eye (yes/no/unsure), ask for an opinion (typed reply) and choose between options (standalone question, if enabled):

```
Do a small desktop demo for me. Move this terminal to workspace 3, make it float, then put it back. Then try three window opacity values (0.8, 0.9, 1.0) on this terminal and tell me which looks best. Don't judge from screenshots: my eyes are faster, so after each change ask me what I see, and ask me in my own words what I think of each opacity. If I offer to help, use it step by step instead of doing everything first and asking at the end. If you are torn between two layouts for the result, ask me which I want instead of guessing.
```

While it runs: at the first countdown the card shows "Faster with your help: ..." (the agent's offer). Press **Y** to help (questions follow after each change), **P** to postpone, **Esc** to cancel, or do nothing and it runs alone (questions then return `timeout`). Later: **Ctrl** (freeze the timer), **T** (type a reply), **Esc** (stop). For the last step to use a popup, run `htm settings set questions on` first.

### One feature at a time
| Feature | Paste this |
|---|---|
| Whole flow | `Test the Ask Me While Testing plugin: htm start "plugin demo" --help "watch and answer my questions", then move this terminal to workspace 3 and ask me with htm ask whether I saw it, then ask me an open question with --text what I see, then htm end.` |
| Hands-off guard (no mention of htm) | `Move this terminal to workspace 3, make it float, then put it back.` Expect: a block message, then the countdown and the TESTING banner. |
| Open question | `Run htm start "demo", then htm ask "What do you see on screen?" --text, repeat my answer back to me, then htm end.` |
| Postpone | `Run htm start "demo". If I postpone, wait that long and start again. Then ask me one yes/no question with htm ask and htm end.` Press **P** and a number of minutes. |
| Ask for help | `Run htm start "demo" --help "tell me whether the terminal moved", move this terminal to workspace 3 and back, ask me after each move, then htm end.` Press **Y** on the countdown: the card shows the help request and the questions follow. |
| Cancel | `Run htm start "demo" and tell me what it printed.` Press **Esc**; the agent should say `cancelled` and touch nothing. |
| Question without a test (experimental) | First `htm settings set questions on` and restart the shell once. Then: `Use htm question to ask me whether to continue, A or B, and do what I answer. Do not run htm start.` |

Tips while testing: tap **Ctrl alone** to freeze a timer, **T** types a reply, **Esc** stops. `htm status` shows the current state.

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

Two layers, both set up by `htm-install-agent guard`:

1. **Claude Code hook (main layer).** `bin/htm-guard-hook` is added to `~/.claude/settings.json` as a `PreToolUse` hook on Bash. It looks at the command text and blocks (the agent sees the message) `wtype`, `ydotool`, `dotool`, `omarchy-restart-shell` and `hyprctl dispatch|reload|keyword` unless an `htm start` session is active. It does not depend on `PATH` order, so absolute paths are caught too. A backup is kept as `settings.json.htm-backup`; `guard-remove` takes the hook out again.
2. **PATH shims.** `bin/htm-guard` is symlinked as `wtype`, `omarchy-restart-shell` and `hyprctl` in `~/.local/bin`; inside an agent run (`CLAUDECODE`, `PAPERCLIP_RUN_ID`, or `HTM_GUARD=1` for any other agent) they exit 99 until a session is active. **Caveat:** Omarchy appends `~/.local/bin` *after* `/usr/bin` in the desktop session `PATH`, so these shims only fire where `~/.local/bin` comes first (e.g. Paperclip runs). In a normal `omarchy agent` terminal layer 1 does the work.

`HTM_GUARD_OFF=1` bypasses both layers. The hook only covers Claude Code; other agents rely on the shims plus the instruction block.

Proposal for Omarchy itself (plugins shipping agent skills): [docs/omarchy-feature-request-agent-skills.md](docs/omarchy-feature-request-agent-skills.md).
