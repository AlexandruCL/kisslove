# kisslove — Portable Kiro Agent Configuration Bundle

`kisslove` is a portable export of a global [Kiro](https://kiro.dev) configuration. Kiro is an agentic AI coding assistant with a CLI (`kiro-cli`). This repository bundles a complete, curated set of **agents**, **skills**, **steering**, **hooks**, **powers**, and **portable settings** so the exact same setup can be reinstalled on a new machine with a single command. Everything lives under `.kiro/` (mirroring the `~/.kiro` layout Kiro reads from), alongside cross-platform installers that copy the bundle into your home directory, back up anything they would overwrite, and install the one external dependency the setup needs (the `graphify` CLI).

---

## Quick start

```bash
# Windows (PowerShell), from the repo root:
./install.ps1

# macOS / Linux, from the repo root:
chmod +x install.sh && ./install.sh

# Then: restart Kiro, and in any project you want a code graph for:
#   /graphify .
```

The installer is safe by default — it never deletes existing config, it backs up anything it touches to `~/.kiro-backup-<timestamp>`, and it leaves your existing `mcp.json` / `cli.json` untouched if you already have them.

---

## Table of contents

1. [What this bundle contains](#1-what-this-bundle-contains)
2. [Repository layout](#2-repository-layout)
3. [Core concepts (new to Kiro? start here)](#3-core-concepts-new-to-kiro-start-here)
4. [The agents](#4-the-agents)
5. [The skills](#5-the-skills)
6. [graphify — the code knowledge graph](#6-graphify--the-code-knowledge-graph)
7. [workspace-memory](#7-workspace-memory)
8. [Hooks](#8-hooks)
9. [Powers](#9-powers)
10. [Installation (full reference)](#10-installation-full-reference)
11. [Usage](#11-usage)
12. [Caveats and known limitations](#12-caveats-and-known-limitations)
13. [Settings reference](#13-settings-reference)

---

## 1. What this bundle contains

| Component | Count | Location | Summary |
|-----------|-------|----------|---------|
| Agents | 22 | `.kiro/agents/` | 2 orchestrators + 20 specialists, each a `.md` file with YAML frontmatter |
| Skills | 23 | `.kiro/skills/` | Each a folder with a `SKILL.md`; registered in `.skill-lock.json` |
| Steering | always-on + auto | `.kiro/steering/` | `graphify.md` (always-on) plus design/agent steering directories |
| Hooks | 2 | `.kiro/hooks/` | `graphify-update-on-change` + `workspace-memory-update` (JSON v1 schema) |
| Powers | 2 | `.kiro/powers/` | `cloudscape-design-frontend`, `kiro-protocols` |
| Settings | 2 | `.kiro/settings/` | `mcp.json` (ships empty), `cli.json` (portable CLI prefs) |

The one external runtime dependency is the **`graphify` code-graph CLI** (pip package `graphifyy`), which the installers set up for you.

---

## 2. Repository layout

```
kisslove/
├── README.md            (this file)
├── install.ps1          Windows / PowerShell installer
├── install.sh           macOS / Linux installer
├── .gitignore
└── .kiro/
    ├── agents/          22 agent definitions (.md with YAML frontmatter)
    ├── skills/          23 skills (each a folder with SKILL.md) + .skill-lock.json registry
    ├── steering/        always-on / auto guidance
    │   ├── graphify.md           always-on steering for the code graph
    │   ├── kiro-agents/          agent/alias/protocol steering
    │   ├── design/  design-system/  brand/  banner-design/
    │   ├── slides/  ui-styling/  ui-ux-pro-max/
    ├── hooks/           event hooks (JSON v1 schema)
    │   ├── graphify-update-on-change.json
    │   └── workspace-memory-update.json
    ├── powers/          installed Kiro "powers"
    │   ├── installed.json        registry of installed powers
    │   ├── cloudscape-design-frontend/ (under installed/)
    │   └── kiro-protocols/
    └── settings/        portable settings only
        ├── mcp.json     (empty — add your own MCP servers)
        └── cli.json
```

---

## 3. Core concepts (new to Kiro? start here)

If you have never worked with Kiro's configuration before, these are the five primitives this bundle is built from.

### Agent

An **agent** is a `.md` file with YAML frontmatter that defines a persona Kiro can run as. Key frontmatter fields:

- `name` — the identifier you invoke (e.g. `/agents architect`).
- `type` — one of `specialist`, `orchestrator`, or `generalist`.
- `description` — tells Kiro (and orchestrators) what the agent is for and when to route to it.
- `tools` — the capabilities the agent may use (`read`, `write`, `shell`, `web`, `subagent`, `todo_list`, …).
- `permissions` — allow/deny rules per capability (e.g. deny `rm -rf *`, `git push --force*`).
- `resources` — wires skills to the agent so they are available in that agent's context, using the form:

  ```
  skill://~/.kiro/skills/<name>/SKILL.md
  ```

### Skill

A **skill** is a `<name>/SKILL.md` folder (optionally with supporting references) that packages reusable methodology or domain knowledge. Its frontmatter declares `name`, `description`, and `triggers`. A skill is only recognized if it is **registered in `.kiro/skills/.skill-lock.json`** — the lockfile records each skill's source (GitHub repo, local, etc.), path, and install timestamps. Skills **auto-activate** when a task matches their triggers; the agent then loads the full `SKILL.md` into context before doing the work.

### Steering

**Steering** is markdown guidance applied outside of any single skill or agent. Its `inclusion` mode decides when it applies:

- `inclusion: always` — injected into **every** agent and session. (In this bundle, `graphify.md` is always-on.)
- `inclusion: auto` — activated only when a task matches its scope.

Steering outranks stored memories or learnings when they conflict.

### Hook

A **hook** is JSON automation triggered on an event — `PostFileSave`, `SessionStart`, `Stop`, `PreToolUse`, and so on. A hook's `action` can run a shell `command` or hand an `agent` a prompt. Hooks are what let the setup react to events (e.g. refresh the code graph after you save a source file).

### Power

A **power** is a bundled package of steering, tools, and/or MCP servers that can be installed as a unit. Installed powers are tracked in `.kiro/powers/installed.json`.

### Orchestrator vs specialist

An **orchestrator** is an agent with `type: orchestrator` that uses the `subagent` tool to route work to specialist agents. The agents it may route to are listed in its `toolsSettings.subagent.availableAgents` (and the subset it trusts to run with less friction in `trustedAgents`). An orchestrator **delegates** rather than doing specialist work itself. A **specialist** is a focused agent that does one kind of work well.

---

## 4. The agents

22 agents total: 2 orchestrators and 20 specialists.

### Orchestrators

| Agent | Routes | Behavior |
|-------|--------|----------|
| **website-mastermind** | WEB / frontend / website builds | Coordinates 18 specialists end-to-end: design → implement → test → review → secure → optimize → deploy. Reads each prompt, decides which specialist(s) to route to, sequences their work, and integrates output. |
| **dev-mastermind** | NON-WEB software work | CLIs, services, libraries, data pipelines, scripts, refactors — routes across a 15-agent dev roster. Hands web work off to `website-mastermind`. |

Both orchestrators share one important routing rule:

> They **always delegate** specialist work to specialists **by default** — the only exception is when the user's message **begins with the exact phrase `I am asking you`**, in which case the orchestrator answers directly instead of routing.

### Specialists

| Agent | Focus |
|-------|-------|
| **architect** | General system design and high-level architecture across any domain. |
| **backend-architect** | APIs, services, and the data layer — server-side architecture. |
| **planner** | Breaking a task into an ordered, actionable plan. |
| **ui-designer** | UI/UX, design systems, and visual assets. **Design, not code.** |
| **frontend-developer** | React / Next.js implementation — turns designs into working frontend code. |
| **code-reviewer** | Reviews changes for correctness, quality, and maintainability. |
| **test-automator** | Writes and automates tests; builds test coverage. |
| **debugger** | Fixes a **specific, known bug**. |
| **error-detective** | Hunts **error patterns** across logs and systems (not a single bug). |
| **performance-engineer** | Finds and fixes performance bottlenecks and optimizes hot paths. |
| **database-optimizer** | Query/schema/index optimization and database performance. |
| **legacy-modernizer** | Modernizes and refactors legacy code and systems. |
| **security** | Security review, threat modeling, and hardening. |
| **deployment** | Website deployment **advisor** — recommends strategy, does not implement. |
| **deployment-engineer** | CI/CD **implementer** — builds pipelines and deploy automation. |
| **devops-troubleshooter** | Production incidents and operational issues. |
| **docs-architect** | Comprehensive technical documentation. |
| **dx-optimizer** | Developer experience — tooling and workflow improvements. |
| **kiro-master** | Manages Kiro's **own** configuration: MCP, hooks, agents, steering. |
| **tdd-orchestrator** | Coordinates test-driven development flows. |

#### Deliberately distinct near-pairs

These pairs look similar but are kept separate on purpose — pick the right one:

- **deployment** (advisor: *what* to do) vs **deployment-engineer** (implementer: *does* the CI/CD).
- **debugger** (fix one specific bug) vs **error-detective** (hunt recurring error patterns across systems).
- **ui-designer** (design) vs **frontend-developer** (code).

---

## 5. The skills

23 skills, grouped by origin and purpose. All must be present in `.kiro/skills/.skill-lock.json` to be active.

### Methodology — from [`obra/superpowers`](https://github.com/obra/superpowers)

| Skill | Purpose |
|-------|---------|
| **test-driven-development** | Write tests before implementation. |
| **systematic-debugging** | Structured root-cause process for any bug or failure. |
| **writing-plans** | Produce an implementation plan from a spec. |
| **executing-plans** | Execute an implementation plan inline. |
| **verification-before-completion** | Require evidence (run commands, confirm output) before claiming success. |
| **requesting-code-review** | Verify work meets requirements before merge. |
| **receiving-code-review** | Handle review feedback with technical rigor, not blind agreement. |
| **using-git-worktrees** | Isolate feature work in a separate worktree. |
| **brainstorming** | Explore intent and design before implementation. |
| **subagent-driven-development** | Execute independent tasks via subagents. |

### Engineering practice — from [`mattpocock/skills`](https://github.com/mattpocock/skills)

| Skill | Purpose |
|-------|---------|
| **codebase-design** | Shared vocabulary for designing deep, testable modules. |
| **domain-modeling** | Build and sharpen a project's domain model / glossary. |
| **research** | Investigate a question against primary sources, capture findings as Markdown. |

### Reference — from [`wshobson/agents`](https://github.com/wshobson/agents)

| Skill | Purpose |
|-------|---------|
| **api-design-principles** | REST/GraphQL API design standards. |
| **architecture-decision-records** | Write and maintain ADRs. |
| **debugging-strategies** | Profiling and root-cause techniques across stacks. |
| **error-handling-patterns** | Exceptions, Result types, propagation, graceful degradation. |
| **code-review-excellence** | Constructive, effective code review practices. |
| **secrets-management** | Secure secrets handling for CI/CD (Vault, AWS SM, native). |

### Pre-existing / local

| Skill | Source | Purpose |
|-------|--------|---------|
| **agent-code-discipline** | `praveenc/skills` | Enforce think-first, simplicity, surgical changes, goal-driven execution. |
| **find-skills** | `vercel-labs/skills` | Discover and install additional skills on demand. |
| **workspace-memory** | local | Maintain a living `MEMORY.md` map of the project (see §7). |

### Special

| Skill | Purpose |
|-------|---------|
| **graphify** | Turn a codebase into a queryable knowledge graph (see §6). |

---

## 6. graphify — the code knowledge graph

**graphify** turns a codebase into a **queryable knowledge graph** rather than a pile of files to grep. In the graph:

- **Nodes** are functions, classes, and modules.
- **Edges** are relationships: calls, imports, inherits.
- Each node/edge is tagged **`EXTRACTED`** (found directly in the code) or **`INFERRED`** (deduced).

This is **not** embeddings or vector similarity search — it is a real graph you traverse with path-finding and impact analysis.

### How it builds (privacy)

Code is parsed **locally** using **tree-sitter** ASTs. This step is deterministic, uses **no LLM**, and **nothing leaves the machine**. Only an *optional* semantic pass over docs/images uses a model. The core structural graph is entirely local.

### CLI

- Installed as the pip package **`graphifyy`** (note the double `y`).
- The command is `graphify`, invoked portably as **`python -m graphify`**.
- Requires **Python 3.10+**.

### Lifecycle

| Phase | Command | Result |
|-------|---------|--------|
| **Build** (once per project) | `/graphify .` | Writes a per-project `graphify-out/` containing `graph.json`, `GRAPH_REPORT.md`, and `graph.html`. |
| **Query** (scoped) | `graphify query "<question>" --budget N` | Returns a token-capped subgraph for a point question. |
| | `graphify path "A" "B"` | How two things connect. |
| | `graphify explain "X"` | One node plus its neighbors. |
| | `graphify affected "X"` | Reverse impact of changing `X`. |
| | `graphify god-nodes` | The hub nodes (architecture overview). |
| **Update** | *(automatic — via hook)* | Incremental, LLM-free refresh on source saves (see §8). |

### Always-on steering

`.kiro/steering/graphify.md` has `inclusion: always`, so it is injected into **every** agent and session. It instructs all agents:

- For **codebase / architecture / dependency** questions, when `graphify-out/graph.json` exists, **query graphify first**.
- Use **scoped slices** (`query`, `path`, `explain`, `affected`, `god-nodes`) — **never read the whole `graph.json`** into context; query per subtree if the graph is large.
- If **no graph exists**, the guidance **no-ops** and the agent falls back to normal file reading.

### Routing to agents

graphify is wired as an explicit skill resource to **11 specialists plus both orchestrators**:

`architect`, `backend-architect`, `code-reviewer`, `database-optimizer`, `debugger`, `docs-architect`, `error-detective`, `legacy-modernizer`, `performance-engineer`, `planner`, `tdd-orchestrator` — plus `website-mastermind` and `dev-mastermind` via the always-on steering.

### Relationship to workspace-memory

graphify is **complementary** to `workspace-memory`, not a replacement:

- **graphify** = code **STRUCTURE** (refreshed automatically on save).
- **MEMORY.md** (from `workspace-memory`) = **DECISIONS & INTENT**.

Use both: the graph tells you *how the code is wired*; `MEMORY.md` tells you *why it is that way*.

---

## 7. workspace-memory

**workspace-memory** maintains a `MEMORY.md` file at a project root — a concise, living map of the project's structure, architecture, key decisions, data models, API contracts, build/run/test commands, and conventions. It is designed so any agent can read `MEMORY.md` and quickly understand the whole codebase.

On the origin machine it is wired to run on every agent turn (via the `workspace-memory-update` hook — see §8), updating `MEMORY.md` **in place** only when a turn actually changed the project. It is **not** an append-only changelog; it is a current-state map. As noted above, it is complementary to graphify: graphify captures structure, `MEMORY.md` captures intent.

---

## 8. Hooks

Two hooks ship in `.kiro/hooks/`, both using the JSON `v1` schema.

### `graphify-update-on-change.json`

- **Trigger:** `PostFileSave`.
- **Matcher:** source-code extensions — `.py .ts .tsx .js .jsx .go .rs .java .cpp .cc .cxx .hpp .h .c .rb .swift .kt .kts .cs .scala .php .lua`.
- **Action:** runs an incremental, LLM-free graph update, **but only if `graphify-out/graph.json` already exists** in the workspace:

  ```powershell
  if (Test-Path 'graphify-out/graph.json') { python -m graphify update . }
  else { "[graphify hook] no graph.json in workspace - skipping (run /graphify . to build first)" }
  ```

- **Guard:** it never builds from scratch unprompted — if there is no graph, it prints a hint and exits. The update is incremental and no-ops when nothing relevant changed. Timeout: 120s.

### `workspace-memory-update.json`

- **Trigger:** `Stop` (after each agent turn completes).
- **Action type:** `agent` — hands the agent a prompt to review what changed and, **only if** the turn modified structure/architecture/decisions/data models/contracts/commands/conventions, update `MEMORY.md` in place using the `workspace-memory` skill. It explicitly does nothing on pure Q&A, reads, or trivial edits, and keeps `MEMORY.md` under ~200 lines.

---

## 9. Powers

`.kiro/powers/installed.json` records two installed powers (both `registryId: user-added`):

| Power | Role |
|-------|------|
| **cloudscape-design-frontend** | Frontend design power (Cloudscape design system). |
| **kiro-protocols** | Provides the **steering / alias / protocol system** that some agents reference (e.g. the `/agents`, `/protocols`, `/modes` alias machinery). |

Powers are shipped as-is. `kiro-protocols` in particular underpins alias and protocol loading used by the agent system, so keep it installed.

---

## 10. Installation (full reference)

Both installers do the same five things, in order:

1. **Back up** any existing `~/.kiro/{agents,skills,steering,hooks,powers,settings}` to `~/.kiro-backup-<timestamp>` (nothing is ever deleted).
2. **Copy/merge** the bundle's `agents`, `skills`, `steering`, `hooks`, and `powers` into `~/.kiro` (copy, never delete other content).
3. **Copy `settings/mcp.json` and `settings/cli.json` only if they are absent** — an existing file is left untouched.
4. **Install the graphify CLI** via pip (`graphifyy`), unless skipped.
5. Print a reminder to **restart Kiro** and run `/graphify .` per project.

### Prerequisites

- **Kiro** installed on the target machine.
- **Python 3.10+** (required for graphify).
- **git** (recommended).

### Windows (PowerShell)

```powershell
./install.ps1
```

Flags:

| Flag | Effect |
|------|--------|
| `-SkipGraphify` | Do not attempt to install the graphify CLI. |
| `-Force` | Overwrite without creating a backup first. |

### macOS / Linux

```bash
chmod +x install.sh && ./install.sh
```

Environment variables:

| Variable | Effect |
|----------|--------|
| `SKIP_GRAPHIFY=1` | Skip the graphify CLI install. |

The shell installer prefers `uv tool install --upgrade graphifyy` when `uv` is available, otherwise falls back to `pip install --user` (with a `--break-system-packages` fallback for PEP 668 environments).

### Post-install

1. **Restart Kiro** so it picks up the new global agents, skills, and steering.
2. In **each project** where you want a code graph, run `/graphify .` once to build it.
3. Verify graphify: `python -m graphify --version`.

### Manual alternative

If you prefer not to run the installer:

```bash
# Copy the bundle into your global Kiro config:
cp -R .kiro/* ~/.kiro/        # (Windows: Copy-Item .kiro\* $HOME\.kiro -Recurse)

# Install the graphify CLI:
python -m pip install --user graphifyy
```

---

## 11. Usage

### How routing actually works

- By default, the **main session agent** handles your prompts.
- **Skills auto-activate** whenever a task matches their triggers.
- **Always-on steering** (graphify) applies **everywhere**, in every session.
- To get **specialist routing**, you must **invoke an orchestrator or a specific agent**:
  - `/agents website-mastermind` — for web / frontend work.
  - `/agents dev-mastermind` — for non-web software work.
  - `/agents <name>` — to run a specific specialist directly.
- Orchestrators **only route among their own roster** and **only once invoked** — there is **no fully-automatic global agent selection**. Nothing picks `website-mastermind` for you; you ask for it.

### Example flows

**A website build:**

```
/agents website-mastermind
Build a marketing site with a pricing page and a contact form.
```

The orchestrator plans, then routes: `architect`/`ui-designer` for design → `frontend-developer` + `backend-architect` to implement → `test-automator` → `code-reviewer` → `security` → `performance-engineer` → `deployment` / `deployment-engineer`. (Begin your message with `I am asking you` if you want the orchestrator to answer directly instead of delegating.)

**A CLI / library build:**

```
/agents dev-mastermind
Create a Python CLI that converts CSV to Parquet, with tests.
```

`dev-mastermind` routes across its dev roster (`planner`, `architect`, `backend-architect`, `test-automator`, `code-reviewer`, …) and hands any web work to `website-mastermind`.

**A codebase question using graphify:**

```
# First time in this project:
/graphify .

# Then just ask — the always-on steering makes agents query the graph first:
How does the auth flow connect the login handler to the session store?
```

The agent runs something like `graphify path "login handler" "session store"` or `graphify query "auth flow" --budget 1500` instead of grepping the whole tree. After you save source files, the `graphify-update-on-change` hook keeps the graph fresh automatically.

---

## 12. Caveats and known limitations

- **No `kirocrew-*` agents.** The `kirocrew-*` agents from the origin machine were **not** included — they depend on a locally-installed KiroCrew backend and machine-specific absolute paths, so they are not portable.
- **`mcp.json` ships empty.** No MCP servers were configured. Add your own servers to `~/.kiro/settings/mcp.json` after install. (The installer will not overwrite an existing `mcp.json`.)
- **Powers are shipped as-is.** `cloudscape-design-frontend` and `kiro-protocols` are included unchanged. Note that `kiro-protocols` provides the steering/alias/protocol system some agents reference — keep it installed.
- **graphify is per-workspace.** The graph must be built with `/graphify .` in each project before agents can query it. There is no global graph.
- **Restart required.** New global agents/skills/steering only appear after a Kiro restart/reload.

---

## 13. Settings reference

Only portable settings are included. Machine- or account-specific values are intentionally excluded.

### `.kiro/settings/mcp.json`

Ships empty — add your own MCP servers:

```json
{
  "mcpServers": {},
  "powers": {
    "mcpServers": {}
  }
}
```

### `.kiro/settings/cli.json`

Portable CLI preferences. Copied only if you do not already have one; your existing `cli.json` is left untouched by the installer.

### `.kiro/skills/.skill-lock.json`

The skill registry. Each entry records the skill's `source`, `sourceType`, `sourceUrl`/`skillPath`, and install/update timestamps. A skill present on disk but missing from this lockfile will **not** be recognized by Kiro.

---

*This bundle is a portable snapshot of a working Kiro configuration. The installers are re-run-safe and non-destructive; when in doubt, inspect `~/.kiro-backup-<timestamp>` after installing.*
