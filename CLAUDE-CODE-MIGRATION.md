# Migrating the kisslove bundle to Claude Code

This guide explains how to install the **agents** and **skills** from this `kisslove`
Kiro bundle into [Claude Code](https://docs.anthropic.com/en/docs/claude-code), and how
to recreate the Kiro **orchestrator → specialist delegation** workflow using Claude
Code's architecture.

It is written for the specific setup in this repo. Read it start to finish before
copying anything — a few pieces convert cleanly, a few need edits, and a few must be
dropped.

---

## 1. What's in this bundle (and what ports)

| Component | Count | Ports to Claude Code? |
|-----------|-------|-----------------------|
| Skills (`.kiro/skills/*/SKILL.md`) | 23 | ✅ Yes — same `SKILL.md` format, near copy-paste |
| Agents (`.kiro/agents/*.md`) | 22 | ⚠️ Partly — see breakdown below |
| Steering (`.kiro/steering/`) | always-on + auto | ⚠️ `graphify.md` → `CLAUDE.md`; design dirs → skills; drop `kiro-agents/` |
| Hooks (`.kiro/hooks/`) | 2 | ⚠️ Rebuild in `settings.json`; the memory hook needs a redesign |
| Powers (`.kiro/powers/`) | 2 | ❌ No Claude equivalent — drop |
| Settings (`.kiro/settings/`) | 2 | ❌ Kiro-specific — don't port |

### The 22 agents, broken down

- **2 orchestrators** — `dev-mastermind`, `website-mastermind`
  → These do **not** become subagents. They become **routing modes** (see §3).
- **19 portable specialists** —
  `architect`, `backend-architect`, `planner`, `ui-designer`, `frontend-developer`,
  `code-reviewer`, `test-automator`, `debugger`, `error-detective`,
  `performance-engineer`, `database-optimizer`, `legacy-modernizer`, `security`,
  `deployment`, `deployment-engineer`, `devops-troubleshooter`, `docs-architect`,
  `dx-optimizer`, `tdd-orchestrator`
  → These become Claude Code **subagents** in `~/.claude/agents/`.
- **1 to drop** — `kiro-master` (manages Kiro's own config; meaningless in Claude Code).

So: **22 agent files = 2 orchestrators + 19 specialists + 1 (kiro-master) dropped.**

---

## 2. Why orchestrators can't be subagents in Claude Code

In Kiro, an orchestrator is an agent with `type: orchestrator` that lists
`availableAgents` and dispatches to them. You invoke it (`/agents dev-mastermind`) and it
drives the specialists.

Claude Code's architecture is different in three ways that matter here:

1. **There is no `type: orchestrator`.** Any agent can delegate; orchestration is a
   *behavior you prompt*, not a declared type.
2. **Only the main thread reliably holds the delegation (Task) tool.** The main agent —
   the one configured by `CLAUDE.md` — can dispatch to subagents.
3. **A subagent generally cannot spawn other subagents.** It runs in an isolated child
   context. So a chain of "orchestrator subagent → specialist subagents" does **not**
   work reliably — if you invoked an orchestrator *as a subagent*, it would end up doing
   the work itself instead of delegating.

**Consequence:** the orchestrators must live where the delegation tool lives — in the
**main thread**, configured via `CLAUDE.md`. They become *routing modes the main agent
adopts*, not things you invoke as subagents.

---

## 3. The chosen approach — Option C: prefix-triggered routing modes

Instead of invoking `/dev-mastermind`, you prefix your message to pick which roster the
main agent routes among. The main thread stays the orchestrator (so delegation to your
specialists actually works), and the prefix is your explicit "which brain is driving"
switch — mirroring the Kiro `I am asking you` prefix convention you already use.

| You type | Main agent behaves as | Routes among |
|----------|----------------------|--------------|
| `dev: <request>` | **dev-mastermind** | the non-web specialist roster |
| `web: <request>` | **website-mastermind** | the web/frontend/design roster |
| *(no prefix)* | infers from the prompt | whichever roster fits |
| `I am asking you <request>` | answers directly, no delegation | — |

You keep all 19 specialists as **subagents**, so you can also still call one directly by
name when you want to bypass the router.

### What you gain vs. Kiro

- Real delegation to your specialists (main thread owns the Task tool).
- Prompt-based auto-routing when you omit the prefix — Kiro had **no** automatic global
  routing; this is an improvement.
- An explicit dev-vs-web switch via `dev:` / `web:`.

### What you give up vs. Kiro

- No literal `/dev-mastermind` invocation (you said you don't need it).
- Routing is prompt-driven guidance, not a hard state machine. The strict pipeline
  (design → plan → implement → test → review → security) lives as instructions in
  `CLAUDE.md`; the main agent follows it, but it is not rigidly enforced the way a
  hand-written orchestrator loop would be.

---

## 4. Target layout in Claude Code

```
~/.claude/
├── CLAUDE.md              ← both routing modes + delegate-by-default rules + graphify note
├── agents/
│   ├── architect.md       ← 19 specialists, converted frontmatter
│   ├── backend-architect.md
│   ├── ...
│   └── tdd-orchestrator.md
├── skills/
│   ├── test-driven-development/SKILL.md   ← 23 skills, copied as-is
│   ├── graphify/SKILL.md
│   └── ...
└── settings.json          ← permission denies + rebuilt graphify hook
```

(Use `~/.claude/` for a global install, or a project-level `.claude/` to scope it to one
repo.)

---

## 5. Step-by-step install

### 5.1 Skills (easiest — do this first)

Copy every skill folder as-is:

```powershell
# Windows
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null
Copy-Item "D:\kisslove\.kiro\skills\*" "$HOME\.claude\skills\" -Recurse
Remove-Item "$HOME\.claude\skills\.skill-lock.json" -ErrorAction SilentlyContinue
```

```bash
# macOS / Linux
mkdir -p ~/.claude/skills
cp -R .kiro/skills/* ~/.claude/skills/
rm -f ~/.claude/skills/.skill-lock.json
```

- Claude Code uses the same progressive-disclosure skill model (only `name` +
  `description` sit in context until a skill triggers), so these are efficient as-is.
- Claude does **not** use `.skill-lock.json` — delete it (harmless if left, but noise).
- The design "skills" that live under `.kiro/steering/` (`design`, `brand`,
  `design-system`, `slides`, `ui-styling`, `banner-design`, `ui-ux-pro-max`) are already
  `SKILL.md`-formatted — copy them into `~/.claude/skills/` too, not into `CLAUDE.md`.

### 5.2 Specialist agents (light edit each)

Copy the **19 specialists** into `~/.claude/agents/`, then fix the frontmatter.
Do **not** copy `dev-mastermind.md`, `website-mastermind.md`, or `kiro-master.md`.

For each specialist `.md`, convert the frontmatter:

**Keep / map:**
- `name` → keep
- `description` → keep (Claude uses this for auto-routing; the "Use PROACTIVELY" phrasing
  already present helps)
- `tools:` (Kiro's `read`/`write`/`shell`/`web`) → map to Claude's tool names, or omit
  the field to inherit all tools. Claude tool names include `Read`, `Write`, `Edit`,
  `Bash`, `Grep`, `Glob`, `WebFetch`, `WebSearch`.
- Add `model:` if you want to pin one (e.g. `model: sonnet`), otherwise omit.

**Delete (no Claude equivalent):**
- `type:` (specialist/orchestrator)
- `version:`
- `permissions:` block → moves to `settings.json` (see §5.4)
- `resources: skill://…` → delete; Claude auto-loads matching skills by description
- `toolsSettings:` / `availableAgents` / `trustedAgents` → delete

The body (everything below the frontmatter) can stay as-is.

Example — converted `code-reviewer.md` frontmatter:

```yaml
---
name: code-reviewer
description: Elite code review expert for security, performance, and production reliability. Use PROACTIVELY after writing or changing code.
tools: Read, Grep, Glob, WebSearch, WebFetch
---
```

### 5.3 CLAUDE.md (the orchestrator)

Create `~/.claude/CLAUDE.md`. This is where both orchestrators now live, as routing
modes. Paste the routing tables from `dev-mastermind.md` and `website-mastermind.md`
bodies into the two sections below, then keep the delegate-by-default rule.

```markdown
# Orchestration rules

You are the orchestrator. Read each request and delegate to the right specialist
subagent via the Task tool. Delegate specialist work by default — do not do it yourself —
**unless** the message begins with the exact phrase "I am asking you", in which case
answer or act directly without delegating.

## Routing modes (chosen by message prefix)

- If the message starts with `dev:` → act as **dev-mastermind**. Route only among the
  non-web roster below. Hand any web/frontend/UI parts to the web roster.
- If the message starts with `web:` → act as **website-mastermind**. Route among the
  web/frontend/design roster below.
- If there is no prefix → infer dev vs web from the request and route accordingly.

### Non-web roster (dev:)
architect, backend-architect, planner, code-reviewer, test-automator, debugger,
error-detective, performance-engineer, database-optimizer, legacy-modernizer, security,
deployment-engineer, devops-troubleshooter, docs-architect, dx-optimizer, tdd-orchestrator

<!-- paste dev-mastermind's "Routing Logic" table + pipeline here -->

### Web roster (web:)
architect, ui-designer, frontend-developer, backend-architect, planner, test-automator,
code-reviewer, security, performance-engineer, database-optimizer, debugger,
error-detective, legacy-modernizer, devops-troubleshooter, docs-architect, dx-optimizer,
deployment, deployment-engineer

<!-- paste website-mastermind's routing table + pipeline here -->

## Pipeline (non-trivial builds)
design → plan → implement → test → review → security → optimize → deploy.
Use the fewest specialists that satisfy the request; no ceremony for simple prompts.

## graphify (always-on)
For codebase / architecture / dependency questions, if `graphify-out/graph.json` exists,
query graphify first (`graphify query`, `path`, `explain`, `affected`, `god-nodes`) with a
scoped budget instead of reading the whole graph. If no graph exists, fall back to normal
file reading.
```

### 5.4 settings.json (permissions + hook)

Create `~/.claude/settings.json`. Port the Kiro permission *denies* and rebuild the
graphify hook as a `PostToolUse` command on file writes.

```json
{
  "permissions": {
    "deny": [
      "Bash(rm -rf *)",
      "Bash(git push --force*)",
      "Bash(git reset --hard*)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -Command \"if (Test-Path 'graphify-out/graph.json') { python -m graphify update . }\""
          }
        ]
      }
    ]
  }
}
```

> The second Kiro hook — `workspace-memory-update` — used an `action.type: agent`
> (hand a prompt to an agent on the `Stop` event). **Claude Code hooks run shell
> commands, not agent prompts**, so there is no direct port. Options: (a) drop it and
> update `MEMORY.md` manually; (b) keep the `workspace-memory` *skill* and trigger it by
> asking; (c) write a `Stop` command hook that calls an external script. There is no
> faithful one-to-one conversion.

### 5.5 Install the graphify CLI (unchanged)

graphify is a normal Python CLI and works regardless of the agent host:

```bash
python -m pip install --user graphifyy   # note the double y
python -m graphify --version
# then, per project:  python -m graphify .   (Kiro's /graphify . becomes this)
```

---

## 6. What to drop entirely

- `.kiro/agents/kiro-master.md` — manages Kiro's own config.
- `.kiro/agents/dev-mastermind.md`, `website-mastermind.md` — folded into `CLAUDE.md`.
- `.kiro/steering/kiro-agents/` — Kiro slash-command / alias / protocol plumbing
  (`/agents`, `/protocols`, `/modes`). No Claude equivalent.
- `.kiro/powers/` — Kiro-only concept.
- `.kiro/settings/` — Kiro settings format.
- `.kiro/skills/.skill-lock.json` — Kiro registry.

---

## 7. Effort summary

| Task | Effort |
|------|--------|
| Copy 23 skills | Trivial (copy-paste) |
| Copy design steering as skills | Trivial (copy-paste) |
| Convert 19 specialist agents | Light — trim frontmatter per §5.2 |
| Write CLAUDE.md router | Moderate — paste both routing tables, add rules |
| settings.json permissions + graphify hook | Light |
| workspace-memory hook | Redesign or drop (no faithful port) |
| Drop kirocrew / powers / kiro-master / aliases | None (just don't copy) |

Net: the bulk (skills + specialists) moves almost mechanically. The real design work is
the single `CLAUDE.md` router that replaces the two orchestrators — and because the main
thread owns delegation, that router actually delegates to your subagents the way you
want, selected by the `dev:` / `web:` prefix.
