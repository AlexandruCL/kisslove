---
name: workspace-memory
description: Maintain a living MEMORY.md at the workspace root that captures the current structure, architecture, key decisions, data models, and conventions of a project so any agent can quickly understand the whole codebase. Use after implementation work that changes the project's structure, behavior, or important decisions. This is a living map of the project as it is now — not an append-only changelog.
---

# Workspace Memory

Maintain a single `MEMORY.md` file at the workspace root that acts as the project's living memory: a concise, always-current map that lets any agent understand the whole project without re-reading everything.

## Projects Directories (opt-in allowlist)

This skill and its companion `Stop` hook are **inactive by default**. They only run in a
project whose absolute path is listed below. If the current workspace root is **not** in
this list, the hook and skill must do nothing — no reading, no creating `MEMORY.md`, no
updates.

<!-- BEGIN PROJECTS -->
<!-- (none yet — register a project to enable memory updates here) -->
<!-- END PROJECTS -->

### Enabling a project (run this once per project)

When the user invokes this skill and asks to enable / register the current project:

1. Determine the **absolute path** of the current workspace root.
2. If that path is already listed between the `BEGIN PROJECTS` / `END PROJECTS` markers
   above, tell the user it's already enabled and stop.
3. Otherwise add it as a new bullet line inside the markers, exactly in the form:
   `- <absolute-path>`
   Preserve all existing entries; this is an append, not a rewrite.
4. Confirm to the user that memory updates are now active for that path.

### Disabling a project

When the user asks to disable / unregister a project, remove its matching
`- <absolute-path>` line from between the markers, leave the rest intact, and confirm.

### Gate check (performed on every automatic run)

Before doing any memory work — whether triggered by the hook or invoked directly for an
automatic update — first read the list between the `BEGIN PROJECTS` / `END PROJECTS`
markers and compare the current workspace root against it:

- **Not in the list** → do nothing and make no file changes. This is the correct outcome.
- **In the list** → proceed with the normal update workflow below.

(Explicit, user-initiated enable/disable requests are the only actions allowed when the
current directory is not yet in the list.)

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

1. **Gate check first.** Read the `Projects Directories` allowlist (between the
   `BEGIN PROJECTS` / `END PROJECTS` markers near the top of this skill). If the current
   workspace root is **not** listed, stop immediately and make no changes. Only continue
   if it is listed.
2. Determine whether this turn changed the project (see "When to Update"). If not, do nothing.
3. Read the existing `MEMORY.md` at the workspace root (create from the skeleton if missing).
4. Update the affected sections in place; append to Key Decisions only for significant new decisions.
5. Refresh the `Last updated` date.
6. Keep the total tight; prune if it's growing stale.
