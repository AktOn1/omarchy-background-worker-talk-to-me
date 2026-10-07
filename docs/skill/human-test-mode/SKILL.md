---
name: human-test-mode
description: >
  Use when a task changes anything visible on the Omarchy/Hyprland desktop: moving or
  resizing windows, workspaces, the bar, animations, window rules, overlays, themes.
  Wraps the work in `htm start` / `htm ask` / `htm end` so the human confirms the
  visual result with one key press. Triggers: htm, human test mode, "does it look right",
  window moves, workspace switch, bar change, Hyprland rule test.
---

# Human Test Mode

Human Test Mode (plugin `io.github.akton1.human-test-mode`) shows a TESTING banner on the
desktop and lets you ask the human a yes/no question that they answer with Y / N / ? .

## Check first
`command -v htm` . If missing, do the task without it and state in your report that the
visual result was not human-confirmed.

## Procedure
1. `htm start "short title"` before the first visible change (5 s countdown; Y = human is
   here, no key = solo mode and you continue alone).
2. Make one visible change, then `htm ask "<question answerable by looking>"`.
   Output is one of `yes` | `no` | `unsure` | `timeout` | `ended`.
   - `ended` (or `htm start` printing `cancelled`): the human pressed Esc. Stop changing the desktop, restore what you changed, and report.
   - `yes`: next step.
   - `no`: adjust and ask again, at most 3 tries, then stop and report.
   - `unsure` / `timeout`: not a success. Verify another way (screenshot, `hyprctl`) or report it as unconfirmed.
3. `htm say "text"` for status that needs no answer.
4. `htm end` at the very end, also on failure. Prefer
   `trap 'htm end' EXIT` in scripts so the banner never stays up.

## Good questions
- "Did the window move from left to right?" (yes/no, one thing)
- "Is the bar now on the left edge?"
- Bad: "How does it look?" (not yes/no), several questions in one, questions about hidden state.

## Do not
- Run `htm ask` when nothing visible changed, or in a loop to poll the human.
- Start a second session while one is open (`htm end` first).
- Treat `timeout` as yes.
- Use it for headless or purely code-level work.
