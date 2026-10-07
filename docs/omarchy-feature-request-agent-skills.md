# Draft feature request: plugins can ship agent skills (DRAFT, not posted)

Target: Omarchy (basecamp/omarchy) issue/discussion. Written for Libor to review; nothing has been sent.

## Title
Let Omarchy plugins ship skills for coding agents

## Problem
Omarchy ships its own agent skills (`omarchy`, `diagnose-crash`) in `/usr/share/omarchy/default/agents/skills`, so any agent started on an Omarchy machine knows how the system works. A plugin cannot add to this. A plugin that changes how the desktop behaves, or that agents must use (for example a tool that warns the user before an agent moves windows), has no way to tell agents about itself. Authors can only write a README and hope the user copies a skill or an AGENTS.md block by hand. In practice agents then never use the plugin.

## Proposal
Add an optional manifest field:

```json
"agentSkills": "docs/agent"
```

`docs/agent/<skill-name>/SKILL.md` follows the same format as the built-in skills.

- `omarchy plugin enable <id>` links each skill folder next to the built-in ones (for example into the directory the `omarchy` agent skills are read from, or a per-user `~/.local/share/omarchy/agents/skills/` that is searched too).
- `omarchy plugin disable|remove <id>` removes the links.
- `omarchy plugin validate` checks that each skill has a `SKILL.md` with `name` and `description`.
- Marketplace bot: show the field in the listing so users see that the plugin brings agent guidance.

## Why this shape
- Same mechanism users already know (enable/disable), no extra step for them.
- Opt-in per plugin: a disabled plugin adds nothing to the agent's context.
- Skills stay plain markdown, no code execution at enable time.

## Optional follow-up
`agentHooks`: a list of command names the plugin wants to wrap while an agent runs (our use case: block `wtype` / `hyprctl dispatch` until the user has seen a TESTING banner). Probably out of scope for a first version.

## Reference implementation
Ask Me While Testing (`io.github.akton1.ask-me-while-testing`) does this by hand today with `bin/htm-install-agent`, which copies the skill, appends an instructions block and links a guard.
