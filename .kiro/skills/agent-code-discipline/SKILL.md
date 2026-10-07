---
name: agent-code-discipline
description: "Enforce four coding-agent principles: think before coding, simplicity first, surgical changes, goal-driven execution. Apply when generating or editing code to reduce overcomplication, silent assumptions, and scope creep."
metadata:
  version: "1.0"
  author: praveenc
triggers:
  - coding discipline
  - simplicity
  - overengineering
  - scope creep
  - surgical changes
  - code review
  - think before coding
  - keep it simple
  - too complex
  - reduce complexity
---

# Karpathy Coding Discipline

Behavioral guidelines for LLM coding agents, distilled from Andrej Karpathy's observations on agent-assisted coding. These principles reduce the most common failure modes: silent assumptions, premature abstraction, scope creep, and unfocused execution.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial one-liner tasks, use judgment.

> **References (load conditionally):**
> - `references/examples-generic.md` - General coding examples (Python). Load for any code generation or editing task.
> - `references/examples-aws-cdk.md` - CDK examples (Lambda, DynamoDB, S3, Step Functions). Load for CDK tasks.
> - `references/examples-aws-bedrock.md` - Bedrock/AgentCore examples (invoke, agents, guardrails, agent loop). Load for Bedrock tasks.
> - `references/examples-aws-compositions.md` - Multi-service architecture patterns (RAG pipelines, orchestration, event-driven, streaming). Load when the task involves 5+ AWS services wired together.
>
> Load the relevant reference file when the agent needs concrete before/after contrast examples.

---

## Core Observations (What Goes Wrong)

### IDE/Agent Swarms and Fallibility
- Models still make subtle conceptual errors, not just syntax errors
- They make wrong assumptions and run with them without checking
- They don't manage their own confusion or surface inconsistencies
- They don't push back or present tradeoffs when they should
- They overcomplicate code, bloat abstractions, and don't clean up dead code
- They implement brittle, bloated construction over 1000 lines when 100 would do
- They change/remove comments and code that are orthogonal to the task

### Leverage
- LLMs are exceptionally good at looping until they meet specific goals
- The "feel the AGI" magic: write tests first, then pass them, then watch it iterate
- Write the naive algorithm that is very likely correct first, then ask it to optimize while preserving correctness
- Change your approach from imperative to declarative to gain leverage

### Tenacity and Stamina
- Agents never get tired, never get demoralized, keep trying things
- Stamina used to be a core bottleneck - with LLMs it has dramatically increased
- Use this: set clear success criteria and let the agent loop

### Atrophy Warning
- Generation (writing code) and discrimination (reading/reviewing code) are different capabilities
- You can review code just fine even if you struggle to write it from scratch
- LLMs are better at fill-in-the-blanks (micro) than grand strategy (macro)

---

## The Four Principles

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

**Anti-pattern:** User says "Add a feature to export user data." Agent silently assumes: export ALL users, to a file, in JSON, to a hardcoded path. None of these were specified.

**Correct behavior:** Surface the hidden assumptions:
- Scope: all users or filtered? (privacy implications)
- Delivery mechanism: file download, background job, API endpoint?
- Fields: which ones? Some may be sensitive.
- Volume: affects whether you need pagination or streaming.

State the simplest interpretation and ask for confirmation.

**Anti-pattern:** User says "Make the search faster." Agent picks one interpretation and writes 200 lines of caching + async + connection pooling.

**Correct behavior:** Present the interpretations:
- Faster response time (indexing, caching)
- Higher throughput (async, pooling)
- Perceived speed (progressive loading)

Ask which matters for their use case.

---

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

**Anti-pattern:** User asks for "a function to calculate discount." Agent produces a DiscountStrategy ABC, PercentageDiscount, FixedDiscount, DiscountConfig dataclass, DiscountCalculator class - 50+ lines of abstractions for what is a single multiplication.

**Correct behavior:**
```python
def calculate_discount(amount: float, percent: float) -> float:
    """Calculate discount amount. percent should be 0-100."""
    return amount * (percent / 100)
```

Add complexity only when you actually need multiple discount types. If that requirement comes later, refactor then.

**Key insight:** The overcomplicated versions aren't obviously wrong - they follow design patterns. The problem is timing: they add complexity before it's needed, which makes code harder to understand, introduces more bugs, takes longer, and is harder to test.

**At composition scale (5+ services):** Simplicity does NOT mean fewer services. When the architecture requires API Gateway + Cognito + Lambda + Guardrails + Bedrock KB + OpenSearch, the agent's job is to implement each service minimally for its role and wire them correctly - not to collapse the architecture into fewer pieces. See `references/examples-aws-compositions.md` for patterns on disciplined multi-service implementations.

---

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

**The test:** Every changed line should trace directly to the user's request.

**Anti-pattern:** User says "Fix the bug where empty emails crash the validator." Agent also: adds a docstring, improves email regex validation beyond the fix, adds username length checks, changes comment wording.

**Correct behavior:** Only change the specific lines that handle the empty email case. Keep existing style, quotes, spacing. Don't touch anything else.

---

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" -> "Write tests for invalid inputs, then make them pass"
- "Fix the bug" -> "Write a test that reproduces it, then make it pass"
- "Refactor X" -> "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
3. [Step] -> verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**Stop when:** All verify checks pass, or after 3 failed attempts escalate to the user with what you've tried and what's failing.

**Anti-pattern:** User says "Fix the authentication system." Agent says "I'll review the code, identify issues, make improvements, and test." Then proceeds without clear success criteria.

**Correct behavior:** Ask what specific issue needs solving. Then define verifiable steps:
1. Write test that reproduces the bug -> verify: test fails
2. Implement fix -> verify: test passes
3. Check edge cases -> verify: additional tests pass
4. Verify no regression -> verify: full test suite green

---

## Gotchas

- **Don't over-apply "ask first" to trivial tasks.** Typo fixes, single-line additions with obvious intent, and mechanical refactors (rename variable) should just be done. These principles target ambiguous, multi-line code generation - not every keystroke.
- **These principles apply to code generation, not prose or documentation.** Writing docs, READMEs, or comments doesn't require the same "minimal diff" discipline.
- **The examples in `references/examples-aws.md` are illustrations, not templates.** Adapt the principle to the situation. Don't copy example code verbatim into unrelated projects.
- **"Simplicity first" does not mean "no error handling."** If the user explicitly asks for production-ready code, include appropriate error handling. The principle targets *speculative* additions, not *requested* ones.
- **Asking too many questions is also a failure mode.** If the request is clear enough to produce a reasonable minimal implementation, do it and note your assumptions - don't block on 5 clarifying questions for a straightforward task.

---

## Summary Table

| Principle | Anti-Pattern | Fix |
|-----------|-------------|-----|
| Think Before Coding | Silently assumes file format, fields, scope | List assumptions explicitly, ask for clarification |
| Simplicity First | Strategy pattern for single discount calculation | One function until complexity is actually needed |
| Surgical Changes | Reformats quotes, adds type hints while fixing bug | Only change lines that fix the reported issue |
| Goal-Driven | "I'll review and improve the code" | "Write test for bug X -> make it pass -> verify no regressions" |

---

## When These Guidelines Are Working

- Fewer unnecessary changes in diffs
- Fewer rewrites due to overcomplication
- Clarifying questions come before implementation, not after mistakes
- Code solves today's problem simply, not tomorrow's problem prematurely
