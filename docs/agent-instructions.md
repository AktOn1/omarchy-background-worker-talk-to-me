# Agent instructions snippet

Paste the block below into your `AGENTS.md` or `CLAUDE.md` (global or per project) if you want your coding agents to use Human Test Mode. Opt-in only: the plugin never edits these files itself.

For Claude Code there is also a ready-made skill, see [skill/human-test-mode/SKILL.md](skill/human-test-mode/SKILL.md).

---

```markdown
## Desktop testing with human feedback (Human Test Mode)

When a task makes you change what is visible on the desktop (moving or resizing windows,
switching workspaces, changing the bar, animations, window rules, layer-shell overlays),
use the `htm` command so the human can see and confirm the result instead of you
guessing from screenshots.

1. Before the first visible change run `htm start "short title"`. It shows a 5 second
   countdown; the human presses Y to join. No key means solo mode (you continue alone,
   the TESTING banner is still shown). Do not start a second session while one is open.
2. After each visible change ask one question that can be answered by looking:
   `htm ask "Did the window move from left to right?"`. It prints exactly one of
   `yes`, `no`, `unsure`, `timeout` or `ended` and exits. Act on it:
   - `ended` (or `htm start` printing `cancelled`): the human pressed Esc. Stop all visible changes, restore what you changed, and report.
   - `yes`: continue.
   - `no`: fix and ask again (at most 3 attempts per question, then report what you tried).
   - `unsure` / `timeout`: do not treat as success. Try a screenshot check, or say in your report that the result was not confirmed.
3. Use `htm say "text"` for a short status line that needs no answer.
4. ALWAYS finish with `htm end`, also when you fail or give up (use a shell `trap` or
   `htm end` in your cleanup). Never leave the TESTING banner up.

Rules: one question per `htm ask`, yes/no phrasing, under 100 characters. Do not ask
when nothing visible changed. Do not use `htm` for headless or non-visual work.
If `htm` is not installed (`command -v htm`), skip this section and say so in your report.
```
