# Agent instructions snippet

Paste the block below into your `AGENTS.md` or `CLAUDE.md` (global or per project) if you want your coding agents to use Background Worker Talk To Me. Opt-in only: the plugin never edits these files itself.

For Claude Code there is also a ready-made skill, see [skill/background-worker-talk-to-me/SKILL.md](skill/background-worker-talk-to-me/SKILL.md).

---

```markdown
## Desktop testing with human feedback (Background Worker Talk To Me)

A session (countdown + banner) is for work where the human's screen, keyboard or mouse and your test could disturb each other. Work that cannot touch them needs none: files and code, `--headless` runs, a nested compositor on a virtual `HEADLESS-n` monitor, commands aimed at another compositor (own `HYPRLAND_INSTANCE_SIGNATURE` / `WAYLAND_DISPLAY`). Do not start a session for those (prefix a command `TALK_TO_ME_ISOLATED=1` if the guard still blocks it and you are sure it is isolated). If a window opens on a monitor the human looks at, it is not isolated.

When a task makes you change what is visible on the desktop (moving or resizing windows,
switching workspaces, changing the bar, animations, window rules, layer-shell overlays),
use the `talk-to-me` command so the human can see and confirm the result instead of you
guessing from screenshots.

1. Before the first visible change run `talk-to-me start "short title" --estimate 3m` (always give your honest estimate: `90s`, `3m`, or minutes; the human decides from it whether to postpone, the banner counts it down and says "taking longer" when you overrun; revise it with `talk-to-me eta 2m`). It shows a 10 second
   countdown and a TESTING banner. The countdown is only a heads-up: a human who is there
   postpones or cancels it, otherwise it runs out and you continue alone (solo mode:
   `talk-to-me ask` prints `timeout` at once). If a human's eyes would be faster or more reliable than
   you testing alone, ask for help: `talk-to-me start "short title" --help "watch the screen and
   press Y/N after each window move"`. The card shows that text with a Y key; if they press Y
   you get `human` and `talk-to-me ask` works. Without `--help` there is no Y key and no one to ask. It can also print `cancelled` (Esc: not now; touch nothing, do other work, retry later) or `postpone:<min>` (P, exit code 5: do other non-visual work for `<min>` minutes, then run `talk-to-me start` again). Do not start a second session while one is open.
2. Ask right after each visible change, before the next one (do not run all the steps and ask at the end). Ask ONLY through `talk-to-me ask`, never in the terminal/chat or with a built-in question tool such as AskUserQuestion: the human is looking at the desktop, not at your terminal. One question that can be answered by looking:
   `talk-to-me ask "Did the window move from left to right?"`. It prints exactly one of
   `yes`, `no`, `unsure`, `text:<reply>`, `postpone:<min>`, `timeout` or `ended` and exits. Act on it:
   - `ended`: the human pressed Esc. Stop all visible changes, restore what you changed, and report.
   - `yes`: continue.
   - `text:<reply>`: the human typed a reply (they pressed T on a yes/no card). Read it as their answer or comment and act on it.
   - `postpone:<min>` (exit code 5, also from `talk-to-me start`): the human wants to test later. The session is already closed. Stop touching the desktop now, restore what you changed, do other non-visual work or wait `<min>` minutes, then run `talk-to-me start` again and continue with the same step.
   - `no`: fix and ask again (at most 3 attempts per question, then report what you tried).
   - `unsure` / `timeout`: do not treat as success. Try a screenshot check, or say in your report that the result was not confirmed.
   For an open question that cannot be answered yes/no use `talk-to-me ask "What do you see?" --text`: a textbox opens and it prints `text:<reply>`. Use it sparingly, typing is slower than a key press.
3. Use `talk-to-me say "text"` for a short status line that needs no answer.
4. ALWAYS finish with `talk-to-me end`, also when you fail or give up (use a shell `trap` or
   `talk-to-me end` in your cleanup). Never leave the TESTING banner up.

**Experimental: a question outside a testing session.** When you are blocked on a decision only the human can make (which of two options, "ok to continue?") and a wrong guess would be costly, `talk-to-me question "Which one: A or B?"` (add `--text` for a typed answer) shows a plain question card with no banner and prints `yes`, `no`, `unsure`, `text:<reply>`, `dismissed`, `timeout` or `busy`. It is OFF unless the human ran `talk-to-me settings set questions on`: if it prints `disabled` (exit code 6), do not retry, use your normal way of asking. Exit code 6 also means you asked too soon after the last one (`question-gap`). Do not use it for things you can decide or look up yourself, batch several decisions into one question, and never in a loop. `dismissed` (exit 4) = the human does not want to be asked now: decide yourself or carry on with another part of the task and say what you assumed.

Rules: one question per `talk-to-me ask`, yes/no phrasing unless you really need words (`--text`), under 100 characters. Do not ask
when nothing visible changed. Do not use `talk-to-me` for headless or non-visual work.
If `talk-to-me` is not installed (`command -v talk-to-me`), skip this section and say so in your report.
```
