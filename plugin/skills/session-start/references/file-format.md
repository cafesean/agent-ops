# Session file format

Shared by `session-start` (creates it), `session-update` (appends and maintains it),
`session-end` (closes it) and `session-from-transcript` (reconstructs it). Session files are
written for humans first and RAG / vector search second: every `##` section must make
sense when retrieved on its own.

## Frontmatter

```yaml
---
title: "Descriptive title of what this session accomplishes"
date: YYYY-MM-DD
projects: [project-name]
branch: branch-name
status: in-progress  # in-progress | completed | blocked | paused
type: feature        # feature | bugfix | refactor | investigation | qa | migration | infrastructure | research | planning | review | docs
topics: []           # from the taxonomy below
tags: []             # extra semantic tags for retrieval
last_updated: ISO-8601-timestamp
sdk_touched: []      # libraries / internal SDKs involved
apps_touched: [project-name]
commits: []          # every commit hash from the session
related_sessions: [] # filenames
specs: []            # paths to related spec documents
---
```

## Skeleton body

```markdown
# Session: Title

## Objective
(What this session will accomplish and why. Specific — the primary retrieval target.)

---

## Context
(State at the start, what preceded it, constraints.)

## SDK Notes
## Architecture Issues
## Context Documents

| Document | Path | Why It Matters |
|----------|------|----------------|

## Decisions
## Lessons Learned
## User Steering & Corrections
## Next Steps
```

Section formats (update block, issues, lessons, decisions, steering) live in
[update format](../../session-update/references/update-format.md).

## Topic taxonomy

Starting points — add project-specific topics when none fit.

- **Architecture & patterns**: `permissions`, `rbac`, `multi-tenancy`, `row-level-security`, `extension-pattern`, `router-pattern`, `repository-pattern`, `schema-design`, `migration`
- **SDK / libraries**: `sdk-api-design`, `sdk-exports`, `sdk-build`
- **Infrastructure**: `caching`, `cdn`, `serverless`, `docker`, `redis`, `database`, `object-storage`, `deployment`
- **Frontend**: `data-table`, `inline-editing`, `forms`, `modals`, `streaming`, `sse`
- **Auth & security**: `auth`, `jwt`, `session-management`, `api-keys`, `oauth`, `cors`
- **Integration**: `trpc`, `rest-api`, `webhooks`, `messaging-channels`
- **Testing**: `e2e-testing`, `integration-testing`, `smoke-testing`, `regression-testing`
- **Plugins & agents**: `plugins`, `skills`, `agents`, `hooks`
