---
name: workspace-memory
description: Maintain a living MEMORY.md at the workspace root that captures the current structure, architecture, key decisions, data models, and conventions of a project so any agent can quickly understand the whole codebase. Use after implementation work that changes the project's structure, behavior, or important decisions. This is a living map of the project as it is now — not an append-only changelog.
---

# Workspace Memory

Maintain a single `MEMORY.md` file at the workspace root that acts as the project's living memory: a concise, always-current map that lets any agent understand the whole project without re-reading everything.

## Core Principle

`MEMORY.md` answers one question: **"If a new agent opened this project cold, what would it need to know?"**

It is a **living map of the current state**, not a diary. Update sections **in place** as reality changes. Do not append an entry for every edit — that turns memory into an unreadable changelog. Git history already records chronology; this file records the *current truth*.

## When to Update

Update `MEMORY.md` after work that changes any of:
- Project structure (files/modules added, moved, or removed)
- Architecture or component boundaries
- A significant technical decision
- Data models, schemas, or API contracts
- Build/run/test commands or conventions
- What is implemented vs. in progress

**Skip the update** when the turn did not change the project — pure questions, explanations, reads, or trivial one-line tweaks with no structural impact. A no-op is the correct outcome for those turns.

## What to Track (and What Not To)

Track the stable, high-value facts below. Keep it tight — aim for under ~200 lines total. If it grows past that, prune stale detail; it's drifting into changelog territory.

Do **not** track: per-edit history, verbose command output, transient TODOs already tracked elsewhere, or anything git already captures well.

## File Structure

Use exactly these sections. Create the file with this skeleton if it does not exist, then keep it updated.

```markdown
# Project Memory

> Living map of this project for AI agents. Update in place — do not append per-edit.
> Last updated: <YYYY-MM-DD>

## Overview
<One paragraph: what this project is, the stack, and how to run / build / test it.>

## Architecture & Structure
<Folder/module map with a one-line responsibility per area. The core "remember the structure" section.>

- `path/` — responsibility
- `path/` — responsibility

## Data Models & Contracts
<Key entities, schemas, and API surfaces at a glance. Omit if none yet.>

## Key Decisions
<Append-only. Short ADR-style entries: the decision and why. Newest last.>

- **<decision>** — <why> (<YYYY-MM-DD>)

## Current State
<What's implemented, what's in progress, and the best entry points to start from.>

## Conventions & Gotchas
<Patterns to follow, traps to avoid, non-obvious constraints.>
```

## Update Rules

1. **Update in place.** When a module's responsibility or the structure changes, rewrite the affected lines — do not add a duplicate dated entry.
2. **Key Decisions is the only append-only section.** Preserve the trail of *why*; never rewrite past decisions (add a new one that supersedes if needed).
3. **Refresh `Last updated`** to today's date on every change.
4. **Keep it concise.** One line per module. No prose walls. Prune stale content as you go.
5. **Don't invent.** Only record what you actually know from the work done or the code read. If unsure, leave it out rather than guess.
6. **Preserve existing content** you're not changing — this is a merge/update, not a rewrite from scratch.

## Workflow

1. Determine whether this turn changed the project (see "When to Update"). If not, do nothing.
2. Read the existing `MEMORY.md` at the workspace root (create from the skeleton if missing).
3. Update the affected sections in place; append to Key Decisions only for significant new decisions.
4. Refresh the `Last updated` date.
5. Keep the total tight; prune if it's growing stale.
