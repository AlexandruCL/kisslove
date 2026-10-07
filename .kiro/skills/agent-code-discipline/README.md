# :shield: agent-code-discipline

[![skills.sh](https://skills.sh/b/praveenc/skills)](https://skills.sh/praveenc/skills)

Behavioral guidelines for LLM coding agents that reduce overcomplication, silent assumptions, scope creep, and unfocused execution. Distilled from Andrej Karpathy's observations on agent-assisted coding workflows.

## Why this skill?

The popular [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) repo (152k+ stars) ships a single flat `CLAUDE.md` with the four principles in ~60 lines. It's a great starting point. This skill goes further:

| | multica-ai | agent-code-discipline |
|---|---|---|
| **Format** | Single `CLAUDE.md` file | SKILL.md (cross-agent standard) |
| **Agent support** | Claude Code only | pi, Claude Code, Kiro CLI, Cursor |
| **Examples** | Principles only, no code | Detailed anti-pattern vs correct-behavior code blocks inline |
| **Domain references** | None | 4 conditional reference files (generic Python, AWS CDK, Bedrock, multi-service compositions) |
| **Context strategy** | Always-loaded flat file | Base principles always loaded; heavy examples loaded on-demand per task domain |
| **Eval harness** | None | 8 structured test cases (`evals/evals.json`) to verify agent behavior |
| **Gotchas / meta-guidance** | None | When NOT to apply the principles (trivial tasks, prose, asking too many questions) |
| **Composition scale** | Not addressed | Explicit guidance for 5+ service architectures |
| **Karpathy taxonomy** | Quotes only | Full breakdown: leverage, tenacity/stamina, atrophy warning |

In short: same source inspiration, but this skill is **deeper** (anti-patterns with code), **broader** (multi-agent, multi-domain), and **leaner in context** (conditional loading keeps your token budget tight).

## Install

```bash
npx skills add https://github.com/praveenc/skills --skill agent-code-discipline
```

## Usage

Drop `SKILL.md` into your agent's system prompt, CLAUDE.md, .cursorrules, or skill loader. The file is self-contained (~190 lines, ~2300 tokens).

Reference files in [`references/`](./references/) provide concrete before/after examples. Load conditionally to keep base context lean:

- [`examples-generic.md`](./references/examples-generic.md) - General coding examples (Python) for any code task
- [`examples-aws-cdk.md`](./references/examples-aws-cdk.md) - CDK infrastructure examples (Lambda, DynamoDB, S3, Step Functions)
- [`examples-aws-bedrock.md`](./references/examples-aws-bedrock.md) - Bedrock/AgentCore examples (invoke, agents, guardrails, agent loop)
- [`examples-aws-compositions.md`](./references/examples-aws-compositions.md) - Multi-service architecture patterns (RAG, orchestration, event-driven, streaming)

## Structure

```
agent-code-discipline/
├── SKILL.md                      # Core principles (always loaded)
├── README.md                     # This file
├── references/
│   ├── examples-generic.md       # Generic coding contrast examples
│   ├── examples-aws-cdk.md       # 4 CDK contrast examples
│   ├── examples-aws-compositions.md  # 5 multi-service architecture patterns
│   └── examples-aws-bedrock.md   # 4 Bedrock/AgentCore contrast examples
├── evals/
│   └── evals.json                # 8 test cases to verify agent behavior
└── audit-report.md               # Best-practices audit
```

## Principles

1. **Think Before Coding** - Surface assumptions, ask before implementing ambiguous requests
2. **Simplicity First** - Minimum code that solves the problem, nothing speculative
3. **Surgical Changes** - Touch only what you must, match existing style
4. **Goal-Driven Execution** - Define success criteria, loop until verified

## Triggers

This skill activates on: coding discipline, simplicity, overengineering, scope creep, surgical changes, code review, think before coding, keep it simple, too complex, reduce complexity.

## Origin

Based on [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on Claude Code (Jan 2026) and the [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) repo.
