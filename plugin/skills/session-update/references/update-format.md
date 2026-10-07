# Session update formats

Referenced by `session-update` (and `session-from-transcript` Mode B). Frontmatter and
skeleton: [file format](../../session-start/references/file-format.md).

## Update block

Append one per update cycle. **Do not summarize — capture granular detail.** Someone reading
it months later (or a retriever pulling it alone) must understand what happened and why.

```markdown
---

### Update — 2026-06-03 14:30

#### What Changed

Describe the specific changes made in this update cycle. Include:
- What code was written or modified and WHY (not just "modified auth.ts")
- What problem was being solved — the specific symptoms, not just "fixed a bug"
- What approach was taken and what alternatives were considered
- What the before/after behavior is

#### Detailed Problem Analysis

(Include when debugging or investigating issues)

- **Symptoms observed**: Exact error messages, unexpected behavior, reproduction steps
- **Investigation path**: What was checked, in what order, and what each check revealed
- **Root cause**: The actual underlying issue with technical explanation
- **Why it wasn't obvious**: What made this hard to find

#### Implementation Details

- Specific code patterns used and why they were chosen
- Edge cases handled or intentionally deferred
- Performance implications of the changes
- Security considerations (especially for auth, permissions, data isolation)

#### Commit Log

| Hash | Message | Files |
|------|---------|-------|
| `abc1234` | fix(auth): refresh token before retrying the request | `src/server/auth.ts` |

#### Files Changed (This Update)

```
M src/server/auth.ts    — Refresh the access token before retry instead of failing
A src/lib/new-helper.ts  — New utility for X because Y
D src/lib/old-helper.ts  — Removed: replaced by new-helper.ts
```

#### Git Status

- Branch: `feature/my-feature`
- Last commit: `def5678 fix(cache): default scope to user`
- Working tree: clean / N uncommitted changes

#### Commands Run

(Include when non-trivial commands were run — test suites, builds, migrations, scripts.
The exact command and its result are high-value search keywords.)

| Command | Purpose | Result |
|---------|---------|--------|
| `pnpm test src/api/auth` | Verify auth tests pass after refactor | 18/18 passing |
```

## Standing sections

Review and refresh these after each update block. Write each as if it will be read alone.
### SDK / Library Notes Section

Maintain a `## SDK Notes` section for anything specific to the libraries or internal
SDKs the project depends on. Focus on:
- **How APIs were used** — correct patterns discovered, incorrect assumptions corrected
- **Gaps or limitations** encountered — missing features, workarounds needed
- **Cross-app inconsistencies** — where different apps use the same dependency differently
- **Bugs found** — unexpected behavior in dependency code

### Architecture Issues Section

Maintain a `## Architecture Issues` section. Document inconsistencies, confusion,
misunderstandings, or incorrectly implemented patterns. High-value for the knowledge base.

```markdown
## Architecture Issues

### Issue Title
- **Status**: resolved | workaround-applied | known-limitation | unresolved | investigating
- **Topics**: topic1, topic2
- **Issue**: (description)
- **Impact**: (what breaks or is at risk)
- **Applies to**: (which apps/SDKs)
- **Correct pattern**: (what should be done instead)
```

### Context Documents Section

Update `## Context Documents` with files referenced during this session. Include enough
description that a RAG system can match queries to the right documents.

| Document | Path | Why It Matters |
|----------|------|----------------|

### Lessons Learned Section

Maintain `## Lessons Learned`. Each lesson is a candidate for extraction into learning
docs. Write each as a self-contained knowledge unit. Every lesson MUST include:

- **The lesson** — specific and actionable, not generic advice
- **Topics** — which taxonomy topics this maps to (for cross-session grouping)
- **Applies to** — which apps/SDKs this lesson is relevant to
- **Confidence** — `confirmed` (verified by testing/deployment) or `hypothesis`
- **Evidence** — which commit, update block, or investigation step proved this

```markdown
## Lessons Learned

### Architecture

- **Lesson**: When one module works but another doesn't with identical code, check
  infrastructure-level differences (HTTP cache headers, middleware order) before code logic.
  - Topics: `caching`, `cdn`, `debugging`
  - Applies to: all apps using cached routes
  - Confidence: confirmed
  - Evidence: commit `abc1234`
```

### User Steering & Corrections Section

Maintain a `## User Steering & Corrections` section. This captures every instance where
the user had to redirect, correct, clarify, or mentor the agent. **This is training
data** — it reveals where agents need improvement. Record the user's **exact words** (or
close paraphrase), what the agent did wrong or would have done, the root cause of the
misunderstanding, and the lesson.

```markdown
## User Steering & Corrections

### Corrections (agent was wrong or heading wrong direction)
- **User said**: "(exact words)"
  - What agent did wrong, root cause, lesson

### Clarifications (agent needed more context)
- **User said**: "(exact words)"
  - What was unclear, resolution

### Steering (user redirected approach or priorities)
- **User said**: "(exact words)"
  - What agent was doing, better approach

### Requirements additions (user added scope mid-session)
- **User said**: "(exact words)"
  - Impact on design/implementation
```

### Decisions Section

Maintain a `## Decisions` section capturing decisions made during the session, with the
reasoning and the roads not taken. Each entry is independently retrievable, so write the
context into it.

```markdown
## Decisions

- **Decision:** Use Postgres LISTEN/NOTIFY instead of Redis pubsub for real-time updates
  **Why:** Reduces infra surface, transactional consistency with the data writes
  **Alternatives considered:** Redis pubsub (rejected: extra service), polling (rejected: latency)
```

### Next Steps

Specific, actionable items with enough context that another developer or agent can pick up
where this session stopped.

## Writing Guidelines for RAG Optimization

1. **Be specific, not generic** — "token refresh races the retry on cold start" not "auth bug"
2. **Include technical terms** — exact function names, file paths, error messages
3. **Self-contained sections** — each `##` section should make sense if retrieved alone
4. **Explain WHY, not just WHAT**
5. **Include the investigation path** — what was checked and eliminated matters
6. **Name specific files and functions**
7. **Capture cross-app patterns** explicitly
8. **Record what DIDN'T work** — failed approaches are valuable
9. **Use exact error messages** — high-value search targets

## Knowledge Pipeline Context

Session files are the **first stage** of a knowledge pipeline:

1. **Sessions** (this output) — raw, detailed records of development work
2. **Learnings** — distilled, cross-session knowledge grouped by topic
3. **Golden Docs** — authoritative guidelines (live under `$SPECS_DIR`)

To support the pipeline, every session uses standardized **topics**, tags lessons with
**applies to**, includes **confidence**, provides **evidence**, captures **architecture
issues** with status, records **SDK notes**, and captures **user steering & corrections**.

When the project has a `CLAUDE.md`, update it with durable learnings and standards
discovered during the session.
