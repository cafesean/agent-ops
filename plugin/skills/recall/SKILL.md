---
name: recall
description: "Use when the user asks what was done, decided or learned in past work and the answer lives in the project's durable artifacts: session files, specs, CLAUDE.md and memory notes. Triggers include \"how did we do X\", \"what did we decide about Y\", \"where's the spec for Z\", \"have we hit this before\", \"what changed last time\", \"recall\", \"find the session where\". Acts as a librarian: it points to the source artifact and exact section, it is not a memory store and it does not write."
---

# Recall — librarian over project artifacts

The artifacts hold the knowledge, not this skill. Find the right artifact and the right
section inside it, then read only that section.

## Step 0: Resolve where artifacts live

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$REPO_ROOT | $SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR` / `COS_SPECS_DIR` in the agent-ops config →
an existing `_ai/sessions` / `_context` → `./sessions`, `./specs`. Details:
[locations](../session-start/references/locations.md). If `$SESSIONS_DIR` does not exist,
say so and search the conventional places as a best effort. The memory folder is not
resolved by agent-ops: use the one the user names, or look for a `MEMORY.md` index.

## First: a domain question goes to the domain skill

"Is X built", "how far did it get", "why is X still happening" in an area that has its own
skill is that skill's question. Invoke it with the Skill tool and read the `references/*.md`
it points at. A skill that names a reference is saying the reference is required.

This skill is for cross-cutting recall: "when did we decide X", "have we hit this
before", "what changed last time".

## Where knowledge lives (search in authority order)

1. **CLAUDE.md** (per repo): standing rules and architecture. Highest trust.
2. **Memory notes**: durable facts, gotchas, feedback.
3. **Specs** in `$SPECS_DIR`: designs and decisions. Demote anything marked `SUPERSEDED` or `PARKED`.
4. **Session files** in `$SESSIONS_DIR/*.md`: richest detail. Sections: `## Architecture Issues`,
   `## Lessons Learned`, `## User Steering & Corrections`, `## Next Steps`, `## Commit Log`.

A session file answers "what did this sitting do", never "what does the domain still
lack". It is the wrong artifact for an is-it-built question: a sitting that fixed the same
symptom by another route reads as "done". Confirm in code and the ticket before asserting.

Do not search source code or git for "what we decided or learned": the artifacts are for that.
Use code search only to confirm a pointer an artifact gave you.

## Procedure

1. **Identify intent and topic.** Turn the question into keywords and, if known, a topic tag.
2. **Scan, ranked by authority then recency.**
   `rg -l "<keywords>" "$SESSIONS_DIR" "$SPECS_DIR" "$REPO_ROOT/CLAUDE.md"` (plus the memory folder).
   Session files are date-prefixed (`YYYY-MM-DD-[tag]-desc.md`); prefer recent ones.
   Frontmatter `topics:` and `tags:` are a strong signal.
3. **Open the matching section, not the whole file.** Jump to the `##` heading that fits:
   a past bug → `## Architecture Issues` or `## Lessons Learned`; a decision →
   `## User Steering & Corrections`.
4. **Check freshness.** A `resolved` Architecture Issue beats an older `investigating` note.
   The newer session wins on conflict.
5. **Report pointers, not a dump.** Give the answer, a `file:section` citation and a short
   snippet. Never paste whole files.

## What this is not

- Not semantic search. It is deterministic text search over files: no index, never stale.
- Not a writer. Capture stays manual (`/agent-ops:session-update`, specs).
