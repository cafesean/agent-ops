---
name: session-from-transcript
description: Use when a stale, cold or never-logged Claude Code session must become a session file (or a quick recap) by mining its raw .jsonl transcript — e.g. the 1-hour prompt cache expired, /resume is blocked or too expensive, or a session crashed. Target is a title, session uuid or .jsonl path. Triggers include "session from transcript", "pick up session X", "the cache expired", "reconstruct the session called X", "continue that session fresh", "recap that session into a file".
model: sonnet
---

# Session From Transcript (raw .jsonl → session file or quick recap)

Mine a past session's raw transcript with `jq` (via the bundled `scripts/mine.sh`), then:

- **Mode B — session file (DEFAULT)**: write a file in the `/agent-ops:session-update` format, provenance-stamped *"Reconstructed from transcript `<id>`"*. A bare `/agent-ops:session-from-transcript <title>` means *write the file*.
- **Mode A — quick recap (opt-in)**: print a tight summary, write nothing. Only when the user says "summarize", "recap", "just tell me", "don't write a file".

Siblings: `session-start` → `session-update` → `session-end` log live; this skill reconstructs
one after the fact into the same directory and tracker, so the result is indistinguishable
from a live-logged file. For a printed recap of any transcript use `/agent-ops:recap-session`;
to mine curated `.md` session files for plugin updates use `/agent-ops:session-analysis`.

## Step 0: Resolve locations

```bash
eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh")"
echo "$SESSIONS_DIR | $SPECS_DIR | $LOC_SOURCE"
```

Order: `.agent-ops.json` → `COS_SESSIONS_DIR`/`COS_SPECS_DIR` in the agent-ops config →
`./sessions`, `./specs`. Details: [locations](../session-start/references/locations.md).
Re-run with the transcript's repo (`.cwd`) as the argument when it differs from `$PWD`.

Requires `jq` (macOS: `brew install jq`; Debian/WSL: `apt install jq`; Git Bash: `winget install jqlang.jq`).

## Fastest path: the bundled extractor

`scripts/mine.sh` does Steps 1–6 in one pass — header, titles, record counts, timespan, compaction status, branch/cwd, typed prompts, assistant narrative (→ `$T/mine_assist_<session-id>.txt`, path printed in the output), commit ledger, files touched, specs, tool histogram, the **tail** (last events, open background launches, unanswered tool calls — Step 7), and a **subagent-transcript inventory** (Step 6 — the sibling per-agent `.jsonl`s the main file does NOT contain, tiered HIGH/low):

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/session-from-transcript/scripts/mine.sh"; T="${TMPDIR:-/tmp}"
bash "$S" --list                                  # recent transcripts (id + title) for $PWD's repo
bash "$S" --title "billing retry fix" > $T/mine.txt  # resolve by TITLE (case/space/hyphen-insensitive)
bash "$S" 00000000-0000-0000-0000-000000000000 > $T/mine.txt # by session-uuid
bash "$S" /abs/path/to/<uuid>.jsonl > $T/mine.txt # by path
bash "$S" --latest > $T/mine.txt                # newest session
bash "$S" --subagent <.../subagents/agent-<id>.jsonl> > $T/mine_sub_<id>.txt  # Tier-2 deep-read of ONE subagent (stdout)
```

A bare argument that is neither a path nor a uuid is treated as a **title query** automatically. Then `Read $T/mine.txt` and the narrative file its `## ASSISTANT NARRATIVE` line names. If `$CLAUDE_PLUGIN_ROOT` is unset, use the inline recipes in [procedure](references/procedure.md).

The main mine's **`## SUBAGENT TRANSCRIPTS`** section lists each subagent with its tool-histogram, mission line, and a `[HIGH]`/`[low]` tier. For an implementation/debug/incident session, `--subagent` the `[HIGH]` ones (see **Step 6**) — their internal process (exact edits, discarded hypotheses, real test output) is NOT in the main transcript, only their returned summary is.

## Why this is run: usually a cold handoff, sometimes just a capture

**Read this first — it sets how every step below is judged.**

The usual case: the user left a session and could not get back to it **within one hour**. The prompt cache has a 1-hour TTL, so the old session's context is no longer cached. Resuming it (`/resume`, or just typing into it) re-reads the entire context at full, uncached input price on the next turn — and that context is often hundreds of thousands of tokens. `/compact` does not help: it too reads the whole stale context to write its summary, and the summary is lossy and lives only inside that one session.

So this skill is usually **the handoff path and the replacement for `/compact`**. Sometimes the work finished and the user only wants the session **captured** — no handoff. Which one it is decides the output, so **decide it from the tail (Step 7) before writing anything**:

| | `/resume` on a cold session | `/compact` | this skill |
|---|---|---|---|
| Cost to continue | full uncached re-read of the whole context | full re-read to summarise, then keep a big session | `jq` extracts only; new session reads one small file |
| Output | none durable | in-session summary, lossy, not on disk | session file on disk, grounded in extracts, RAG-ingestable |
| Where work continues | old session | old session | **a fresh session** |

What that means for how you run it:

1. **In a handoff, the deliverable is a file a fresh session can resume from cold.** Treat it as `/handoff` output, not a history write-up. The `## Resume Here` block (B3) is mandatory. In a capture, the file is the record and there is no Resume Here.
2. **Never tell the user to `/resume` or `/compact` the target session.** That is the cost this skill exists to avoid.
3. **The transcript's last message is not the current state.** Time has passed. Check live repo state (B3a) before writing *Build state* or *Resume Here*.
4. **The target is a different session from the one running this skill.** The current session's transcript is the newest file on disk — never mine it by accident (`--latest` skips it; see Step T).
5. **If the old session already had a session file, update it** instead of writing a duplicate (B1).
6. **End with the one line the user needs**: the verdict (handoff or capture), the file path, and — for a handoff — what the fresh session picks up first.

### Secondary case: the 1M-context billing gate

The error **"Usage credits required for 1M context · run /usage-credits to turn them on, or /model to switch to standard context"** is a **billing-tier gate, not a token-count problem**. It fires even on a small (<200k) conversation. `/model` → standard context clears it; `/usage-credits` enables the 1M tier. When it blocks a `/resume` or `/recall`, fall back to this skill — same handoff output.


## Procedure

Full step-by-step (target resolution, inspection, prompt / narrative / signal extraction,
subagent transcripts, the tail verdict, Mode A and Mode B B1–B4 with Resume Here):
[procedure](references/procedure.md). Per-section field formats:
[update format](../session-update/references/update-format.md).

## Critical rules

- **Handoff or capture — decide from the tail first (Step 7).** Usually a cold handoff: the old session passed the 1-hour cache window, and this replaces `/resume` and `/compact`. Then the file must let a fresh session continue: `## Resume Here` with what Claude was waiting for, what was mid-flight, and live repo state. Sometimes the user only wants the session captured: then no Resume Here. Never recommend resuming or compacting the target.
- **Default output is a written session file (Mode B).** A bare `/session-from-transcript <title>` means *create the `$SESSIONS_DIR/*.md` file* — do NOT stop at a printed recap. Only do Mode A when the user explicitly asks to summarize/recap.
- **A title/name is NOT a filename.** "the session titled X" → search `customTitle` (user-set, wins) then `aiTitle` *inside* the transcripts, normalized for case/space/hyphen. Never glob the projects dir for a file named after the title, and don't trust a raw `grep` of the whole file (the title string also appears where the user typed it, in other sessions).
- **Never read the raw `.jsonl` into context.** Multi-MB / thousands of lines. `jq`-extract to `$T` (`T="${TMPDIR:-/tmp}"`) (or use `mine.sh`), then Read the small extract.
- **Use the robust prompt filter** (Step 3) — `promptSource` alone misses real prompts when the field is absent; `none`/expansions drag in 5 KB+ slash-command bodies.
- **Handle string-or-array `content`** in every recipe.
- **`grep -v 'system-reminder'`** / the `<command…>` filter on prompt extracts — the harness wraps prompts in reminders and expands slash commands inline.
- **A compaction marker is not data loss** — the continuation summary (in `user` records) is itself a dense recap; read it: `jq -r 'select(.type=="user")|.message.content|select(type=="string")' "$f" | grep -A40 'continued from a previous conversation' | head -50`. In Mode B note "compacted N×".
- **Subagent process is NOT in the main file — it's in `<sessionId>/subagents/`.** The main transcript has only each subagent's returned summary. For an **implementation/debug/incident** session, deep-read the `[HIGH]` subagents (Step 6, `mine.sh --subagent`) — else you lose the exact diff locus, discarded hypotheses, and real verification output, and you're trusting a return that may over-claim. For a review/spec/research session the returns suffice. State the coverage (`folded M of K`) in the provenance line; don't silently skip them, and don't blanket-read all of them either.
- **Fanning subagent mining out in parallel is safe only with one outfile per agent** (`> $T/mine_sub_<id>.txt`). Before using a report, check its `SUBAGENT:` line names the agent you asked for. `## WRITES REFUSED` lists writes a hook or permission check refused: they never landed, so they are not changes, but they often mark a discarded approach worth a Lessons line.
- **Ground every claim in an extract** — cite the commit hash; don't infer outcomes the transcript doesn't state. Mode B is reconstruction, not fiction.
- **Mode B writes to `$SESSIONS_DIR` with literal `[scope]` brackets** in the filename and appends to `.current-session`.
- **Keep the filename SIMPLE — 2–4 plain words, ONE topic, no `and`, no p-numbers/story codes/status words** (B1). Mining a transcript surfaces everything that happened; do not let that leak into the name. Name it after the session's *main deliverable* and put the rest in `title:`/`tags:`/the body. `title:` is a short phrase too, not a semicolon-joined list of outcomes.
- **Use absolute paths.** the Claude config dir may be non-default and `~` may not expand as expected (Git Bash, custom `CLAUDE_CONFIG_DIR`) — set `PROJ` first.

