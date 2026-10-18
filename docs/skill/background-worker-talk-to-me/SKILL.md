---
name: background-worker-talk-to-me
description: >
  Use when a task changes anything visible on the Omarchy/Hyprland desktop: moving or
  resizing windows, workspaces, the bar, animations, window rules, overlays, themes,
  and before using heavy hardware (a big CPU/RAM job, a VM with lots of resources, the GPU).
  Wraps the work in `talk-to-me start` / `talk-to-me ask` / `talk-to-me end` so the human confirms the
  visual result with one key press. Triggers: talk-to-me, human test mode, "does it look right",
  window moves, workspace switch, bar change, Hyprland rule test, talk-to-me need, announce hardware, GPU, VM.
---

# Background Worker Talk To Me

Background Worker Talk To Me (plugin `io.github.akton1.background-worker-talk-to-me`) shows a TESTING banner on the
desktop and lets you ask the human a yes/no question that they answer with Ctrl+Y / Ctrl+N / Ctrl+/ , or a free-text question they answer in a textbox.

## Check first
Before anything else, check whether the test can run in a virtual machine (or a nested compositor) instead of on the human's real desktop. If it does not need their real logins, GPU or monitors, run it there: no session, no banner, no risk. Only start a session for what truly needs the real desktop.

`command -v talk-to-me` . If missing, do the task without it and state in your report that the
visual result was not human-confirmed.

## Announce heavy hardware
Before you use something the human can feel, announce it: `talk-to-me need cpu|vm|gpu "<who, what exactly, why>" --estimate 10m`.
- `cpu`: more than 8 GB RAM, or 8+ threads busy for 2+ minutes (big builds, encodes, test suites).
- `vm`: a VM with more than 4 GB RAM, or any VM test run (`vm-test`, qemu).
- `gpu`: more than 2 GB VRAM, or load for 2+ minutes (image, voice or LLM models, GPU video encodes).
- The screen, keyboard or mouse is `talk-to-me start` (below).
`need` prints `granted` when you may go ahead; with the queue on it waits for a free slot first (`timeout`, exit 7, or `cancelled`, exit 4: do other work, retry later). Run the heavy command after `granted`, then `talk-to-me release cpu|vm|gpu`. An announcement expires by itself after the longest hold (60 min by default). `talk-to-me hardware` lists who holds what and the thresholds. If the human turned enforcement on, the guard hook blocks known heavy commands (`ollama run`, `vm-test`, `stress-ng`, big encodes) until you have announced.

## Procedure
1. `talk-to-me start "<full title>" --estimate 3m` (the title is the only thing the human reads and is shown in full, max 240 characters: one sentence with who you are, exactly what you test or do, and for which project or reason; "Desktop testing"/"demo" are refused with exit 2) before the first visible change (always give an honest `--estimate`: `90s`, `3m` or minutes; the card shows it, the banner counts it down and says "taking longer" when you overrun; revise with `talk-to-me eta 2m`) (10 s countdown, a heads-up only: the
   human postpones or cancels it if they are at the desk, otherwise it runs out and you continue
   alone in solo mode, where `talk-to-me ask` prints `timeout` at once). To get answers, ask for help:
   `talk-to-me start "<full title>" --help "watch the screen and answer Ctrl+Y / Ctrl+N after each window move"`; the card
   shows it with a Ctrl+Y key and Ctrl+Y gives `human`. Use `--help` when a human's eyes are faster or more
   reliable than you testing alone. Without it there is no Ctrl+Y key. It prints `human`, `solo`, `cancelled` (Ctrl+Q: not now, touch nothing, do other work and retry later) or `postpone:<min>` (Ctrl+P, exit code 5: wait that many minutes doing non-visual work, then `talk-to-me start` again).
   **Not testing?** Restarting the shell, reloading Hyprland, installing a plugin or other desktop work that is not a test: add `--work` (`talk-to-me start "<full title>" --work --estimate 1m`). The screens then say WORKING instead of TESTING; nothing else changes and you usually have nothing to `ask`.
2. Make one visible change, then ask at once (never run all the steps and ask at the end): `talk-to-me ask "<question answerable by looking>"`. Ask ONLY through `talk-to-me ask`, never in the terminal/chat or with a built-in question tool such as AskUserQuestion: the human is looking at the desktop, not at your terminal.
   Output is one of `yes` | `no` | `unsure` | `text:<reply>` | `postpone:<min>` | `timeout` | `ended`.
   - `ended`: the human pressed Ctrl+Q. Stop changing the desktop, restore what you changed, and report.
   - `yes`: next step.
   - `text:<reply>`: the human pressed Ctrl+T and typed a reply. Treat it as their comment or answer and act on it.
   - `postpone:<min>` (exit code 5, also from `talk-to-me start`): the human pressed P and wants to test later. The session is already closed. Stop touching the desktop, restore what you changed, do other non-visual work or wait `<min>` minutes, then `talk-to-me start` again and resume at the same step.
   - `no`: adjust and ask again, at most 3 tries, then stop and report.
   - `unsure` / `timeout`: not a success. Verify another way (screenshot, `hyprctl`) or report it as unconfirmed.
   Open question? `talk-to-me ask "What do you see?" --text` opens a textbox at once and prints `text:<reply>`. Use sparingly; a key press is faster.
3. `talk-to-me say "text"` for status that needs no answer.
4. `talk-to-me end` at the very end when the work succeeded: it shows a green checkmark "DONE" card for 3 s.
   On failure or cleanup use `talk-to-me end --quiet` (no checkmark). Prefer
   `trap 'talk-to-me end --quiet' EXIT` in scripts so the banner never stays up (a no-op once ended).

## Experimental: ask outside a testing session
`talk-to-me question "Which one: A or B?" [--text]` pops up a plain question card (no TESTING banner, no `talk-to-me start`
needed) for a decision you are blocked on while the human works in another app. Prints `yes` | `no` |
`unsure` | `text:<reply>` | `dismissed` (exit 4) | `timeout` | `busy` (exit 6). It is OFF by default
(the human enables it with `talk-to-me settings set questions on`). On `disabled` (exit 6) do not retry: use your
normal way of asking. Exit 6 also means "too soon after the last question" (`question-gap`). Use it only when
blocked and a wrong guess is costly; batch decisions, never loop. On `dismissed`/`timeout` decide yourself and
say what you assumed. Settings: `talk-to-me settings`.

## Good questions
- "Did the window move from left to right?" (yes/no, one thing)
- "Is the bar now on the left edge?"
- Bad: "How does it look?" (not yes/no), several questions in one, questions about hidden state.

## Do not
- Run `talk-to-me ask` when nothing visible changed, or in a loop to poll the human.
- Start a second session while one is open (`talk-to-me end` first).
- Treat `timeout` as yes.
- Use it for headless or purely code-level work, a nested compositor on a virtual `HEADLESS-n` monitor, or commands aimed at another compositor: the human's keyboard and mouse cannot disturb those and they cannot disturb the human. Use it only when your test and the human's screen, keyboard or mouse could get in each other's way. If the guard still blocks an isolated command, prefix `TALK_TO_ME_ISOLATED=1`.
