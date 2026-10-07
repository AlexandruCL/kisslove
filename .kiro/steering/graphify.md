---
inclusion: always
---

graphify: A knowledge graph of this project lives in `graphify-out/`. For codebase, architecture, or dependency questions, when `graphify-out/graph.json` exists, first run `graphify query "<question>"` (or `graphify path "<A>" "<B>"` / `graphify explain "<concept>"`). These return a scoped subgraph, usually much smaller than `GRAPH_REPORT.md` or raw grep output. Read `GRAPH_REPORT.md` only for broad architecture review or when those commands do not surface enough context.

## Read scoped subtrees, not the whole graph

Never read the full `graphify-out/graph.json` into context — it can be large and wastes tokens. Always query a scoped slice:

- Point questions ("how does X work?", "what calls Y?"): `graphify query "<question>" --budget 1500` returns a token-capped subgraph. Lower `--budget` for tighter scopes.
- Relationships: `graphify path "<A>" "<B>"` (how two things connect) or `graphify affected "<X>"` (reverse impact of a change).
- Single concept: `graphify explain "<node>"` (one node + its neighbors).
- Architecture overview without the full dump: `graphify god-nodes --top 10` (the hubs) then drill in with `explain`/`query`.

If a graph is large (the build step warns past ~500 files / ~2M words), prefer building and querying **per subtree**: run `graphify . <subdir>` on the relevant subfolder, or scope reads to one community/subsystem via `query`/`explain` rather than loading the whole corpus. Treat `GRAPH_REPORT.md` as the only wholesale-readable artifact; `graph.json` is for the CLI to traverse, not for the agent to read directly.

## Keeping the graph current

A `PostFileSave` hook (`graphify-update-on-change`) runs `graphify update .` after source-file saves when a graph already exists, so the graph stays fresh on incremental changes with no LLM cost. On large structural changes you can also run `/graphify . --update` manually, or `/graphify .` for a full rebuild. The graph is complementary to `MEMORY.md`: the graph holds code *structure*, `MEMORY.md` holds *decisions and intent*.
