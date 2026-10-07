# Session from transcript — full procedure

Loaded from [SKILL.md](../SKILL.md). `$T` is a scratch dir: `T="${TMPDIR:-/tmp}"`.

## Step T: Resolve the target (title vs uuid vs path)

The user names the session in one of three ways. **A title/name is NOT a filename — it lives *inside* the transcripts** (`custom-title.customTitle`, which the user sets and which **wins**; else `ai-title.aiTitle`, auto). Never `ls`/glob for a file named after the title.

| Input looks like | How to resolve |
|---|---|
| `.../<uuid>.jsonl` path | use it directly |
| a bare UUID (`00000000-0000-0000-0000-000000000000`) | `$PROJ/<uuid>.jsonl` |
| anything else — a **title/name** ("billing retry fix", "the session titled X") | search `customTitle`/`aiTitle` across `$PROJ/*.jsonl`, normalized (case/space/hyphen-insensitive) |

`mine.sh` does this automatically — pass the title, uuid, or path and it dispatches. Or resolve inline:

```bash
PROJ="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/-home-dev-code-my-repo
q="billing-retry-fix"; qn=$(printf '%s' "$q" | tr 'A-Z' 'a-z' | sed 's/[-_ ][-_ ]*/ /g; s/^ //; s/ $//')
for f in "$PROJ"/*.jsonl; do
  t=$(jq -r 'select(.type=="custom-title")|.customTitle//empty' "$f" 2>/dev/null | tail -1)
  [ -z "$t" ] && t=$(jq -r 'select(.type=="ai-title")|.aiTitle//empty' "$f" 2>/dev/null | tail -1)
  tn=$(printf '%s' "$t" | tr 'A-Z' 'a-z' | sed 's/[-_ ][-_ ]*/ /g; s/^ //; s/ $//')
  case "$tn" in *"$qn"*) echo "$(basename "$f")  ->  $t" ;; esac
done
```

**No target given** → the user means the session they just walked away from: the newest transcript that is *not* this one (`mine.sh --latest` skips `$CLAUDE_CODE_SESSION_ID`). Confirm its title in your first line, then proceed. If 0 match → `--list` the titles and ask. If >1 → show ids+titles and ask which. The user's typed title may differ in spacing/hyphens from the stored `customTitle` (e.g. they type `billing-retry-fix`, it's stored `billing retry fix`) — the normalized match handles that. **The literal title string may also appear in conversation content** (the user typed it) in *other* transcripts — match on the title records only, not a raw `grep` of the whole file.

## Step 1: Locate the transcript file

Transcripts live at `<config-dir>/projects/<slugified-cwd>/<sessionId>.jsonl`. The config dir may be non-default — always resolve it via `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, never assume `~/.claude`.

**Slug rule:** the cwd path with every `/` replaced by `-`. `/home/dev/code/my-repo` → `-home-dev-code-my-repo`; on Windows `C:\code\my-repo` → `C--code-my-repo` (every non-alphanumeric character becomes `-`).

```bash
PROJ="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/-home-dev-code-my-repo
ls -lt "$PROJ"/*.jsonl | head -10          # most-recently-modified sessions
f="$PROJ/<sessionId>.jsonl"; ls -lh "$f"; wc -l "$f"
```

> A pasted **PowerShell** `Get-Content … -Tail` recipe does not run on macOS/zsh — translate it to the `jq` recipes here. Same intent, native tooling.
> **The path in the prompt is the target** — a session often asks you to recap a *different* session (users reuse the same prompt and only swap the path). Don't assume it's the current one.

## Step 2: Inspect structure before extracting

```bash
jq -r '.type // .role // "unknown"' "$f" 2>/dev/null | sort | uniq -c | sort -rn
```

Record types — **only `user` and `assistant` carry the conversation**; the rest are metadata, skip them:

| Type | What it is |
|---|---|
| `assistant` | model turns (text blocks + tool calls) |
| `user` | human prompts AND tool results AND slash-command expansions |
| `custom-title` | **user-set** session title in `.customTitle` — this is what "the session titled X" refers to; **wins over `ai-title`**; take the last |
| `ai-title` | auto-generated title in `.aiTitle` (many — dedupe, take last); fallback when no `custom-title` |
| `attachment` / `mode` / `system` / `last-prompt` / `queue-operation` / `file-history-snapshot` | session metadata (skip) |

`*.message.content` is **either a string or an array of blocks** — every recipe handles both. Blocks have `.type` of `text`, `tool_use`, `tool_result`.

> **Sub-agent (Task/Agent-tool) turns are NOT in this file.** Newer harness versions persist each dispatched subagent's full transcript to a **sibling directory** `<projdir>/<sessionId>/subagents/agent-<id>.jsonl` (not as `isSidechain` records inside the main `.jsonl`). The main transcript keeps only each subagent's **returned summary** (as a `tool_result`). So a bare mine sees the *conclusions* but not the subagent's *process*. **Step 6** covers when and how to fold those in. (Older sessions predate this — no `subagents/` dir → nothing to fold, and the returns in the main file are all there is.)

## Step 3: Extract the genuine human prompts (the intent spine)

**Discriminator caveat:** `.promptSource` (`typed`/`queued`) is the cleanest signal *when present*, but it is **version-dependent and often absent** (many transcripts have it on only a handful of records). Don't filter on it alone or you'll silently drop real prompts. Use this robust filter — keep `typed`/`queued` **or** records lacking the field, drop meta, tool-results, command/reminder bodies, and compaction summaries:

```bash
jq -r '
  select(.type=="user")
  | select((.promptSource==null) or .promptSource=="typed" or .promptSource=="queued")
  | select((.isMeta // false)|not)
  | (.message.content) as $c
  | (if ($c|type)=="string" then $c
     elif ($c|type)=="array" then ($c[]|select(.type=="text")|.text)
     else empty end)
  | select(test("^\\s*<(command|local-command|system-reminder)")|not)
  | select(test("continued from a previous conversation")|not)
  | select(length>0)' "$f" 2>/dev/null
```

This yields the ordered list of what the user actually asked for — the backbone of both modes.

## Step 4: Extract the assistant narrative (what was done)

The assistant's **text blocks** (excluding tool calls) are the running "here's what I did" narrative. Dump to a temp file — never read the multi-MB `.jsonl` into context:

```bash
jq -r 'select(.type=="assistant") | (.message.content) as $c |
  if ($c|type)=="array" then ($c[] | select(.type=="text") | .text) else empty end' \
  "$f" 2>/dev/null | grep -v '^[[:space:]]*$' > /tmp/assist_text.txt
wc -l /tmp/assist_text.txt
```

Then **Read** `/tmp/assist_text.txt` (it paginates large files cleanly).

## Step 5: Pull structured signals

```bash
# Commit hashes reported (ledger of what shipped):
grep -oE '`[0-9a-f]{7,8}`' /tmp/assist_text.txt | sort -u | tr -d '`' | tr '\n' ' '; echo
# Session span:
jq -r 'select(.type=="assistant" or .type=="user") | .timestamp // empty' "$f" | sed -n '1p;$p'
# Compacted? (continuation summary lives in USER records, not assistant text):
jq -r 'select(.type=="user")|.message.content|select(type=="string")' "$f" 2>/dev/null \
  | grep -c 'continued from a previous conversation'        # >0 ⇒ compacted
# Branch + cwd (frontmatter):
jq -r 'select(.gitBranch)|.gitBranch' "$f" | awk 'NF&&!s[$0]++'
jq -r 'select(.cwd)|.cwd' "$f" | awk '!s[$0]++'
# Files touched (apps_touched / sdk_touched derive from these paths):
jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and (.name|test("Edit|Write|NotebookEdit")))|.input.file_path // empty' "$f" | sort -u
# Specs referenced (paths under your <specs-dir>; adjust the pattern to your layout):
grep -oE '[A-Za-z0-9_./-]*specs/[A-Za-z0-9_./-]+' "$f" | sort -u
```

## Step 6: Subagent transcripts (the process the returns drop)

The main transcript keeps each dispatched subagent's **returned summary** but not its **process** — the exact edits, the discarded hypotheses, the real test/command output, incident ground truth. Those live only in the sibling `subagents/` dir. `mine.sh` inventories them (Tier-1) and deep-reads one (Tier-2).

```bash
# Tier-1 — already in the main mine output, "## SUBAGENT TRANSCRIPTS":
#   lists each agent-<id>.jsonl with lines · tool-histogram · mission line · [HIGH]/[low] tier.
# Tier-2 — deep-read ONE (path from Tier-1). Prints to stdout: mission, files changed (count/path),
#   refused writes, verification/key bash, full internal narrative, final return. One file PER agent:
bash "$S" --subagent "$PROJ/<sessionId>/subagents/agent-<id>.jsonl" > $T/mine_sub_<id>.txt   # then Read it
```
Inline (no mine.sh): `sdir="${f%.jsonl}/subagents"; ls "$sdir"/agent-*.jsonl` → per file, the same jq recipes from Steps 4–5 apply (it's just another transcript).

**Tier heuristic** — `[HIGH]` = an implementer (Edit/Write ≥ 10) OR a debug/regression/rollback/incident mission; `[low]` = review/spec (its deliverable is a doc already on disk), recon, deploy, git-consolidation, peer-evidence relay.

**Decide by session shape — don't blanket-read all of them (a busy session has 15–20, ~10 MB):**
- **Implementation / debugging / incident session** → **deep-read the `[HIGH]` ones.** Fold: FILES CHANGED → *Build state* (precise diff locus + commits per repo); discarded hypotheses / failed attempts → *Lessons Learned*; VERIFICATION (real test/tsc/deploy output) → *Build state* confidence (evidence, not the return's claim); incident bash (reset/revert/reflog) → the data-loss or rollback note. Also a **provenance check**: if a subagent's return over-claimed vs what its transcript shows it did, prefer the transcript.
- **Review / spec / planning / research session** → the returns usually suffice (the deliverable is a doc or a decision already captured in the main narrative). Skim Tier-1; deep-read only if a `[HIGH]` mission surprises you.
- **No `subagents/` dir** (older harness, or no subagents) → nothing to fold; the main-file returns are complete.

Keep it bounded: `log`-style, note in the provenance line how many subagents existed and how many you deep-read, so a reader knows the coverage (e.g. *"folded 4 of 17 [HIGH] subagents"*).

---

> **Pick the mode: default to B (write the file).** Only do Mode A if the user explicitly asked to summarize/recap.

## Step 7: Read the tail — handoff or capture?

The end of the transcript is the most important part for a handoff. Read the mine's three tail sections **first**, before the narrative:

- `## TAIL` — the last 20 events: typed prompts, Claude's text, tool calls, results.
- `## WAITING ON AT HAND-OFF` — background launches (`run_in_background`, `Agent`, `Monitor`, `ScheduleWakeup`, `Workflow`…) against their `<task-notification>` completion notices. **A launch with no later NOTIFY was still open.**
- `## TOOL CALLS WITH NO RESULT` — the session died or was stopped mid-call.

From those, answer two questions and write both into the file:

1. **What was Claude waiting for?** A background build/deploy/test, a subagent, a monitor, a scheduled wakeup — or **the user's answer** to a question or a proposed next step in Claude's last message.
2. **What was mid-flight?** A multi-step task half done: the last `TOOL` with no result, an edit series that stopped before the commit, a plan with steps left.

Then classify:

| Signal in the tail | Verdict |
|---|---|
| Claude's last message asks the user something, or proposes a step and waits for "yes" | **handoff** |
| An open launch in WAITING, or a tool call with no result | **handoff** |
| Last message says "next", "now doing", "in progress"; uncommitted or unpushed work (B3a) | **handoff** |
| Ends on `API Error`, "Continue from where you left off", or `No response requested.` | **handoff** (died mid-flight) |
| Last message reports done, every launch has a NOTIFY, repos clean and pushed | **capture** |
| The user says "just capture / log / write up this session" | **capture** — their words win over the signals |

Mixed signals → **handoff**. A needless Resume Here costs a few lines; a missing one costs the user an hour reconstructing state. Say the verdict and the deciding signal in your first line to the user.

**Background work does not survive the session.** A build, agent or monitor that was open at hand-off is no longer being watched. In the Resume Here block, list it with how to check its result now (the build URL, the deploy status command, the subagent's `subagents/agent-<id>.jsonl`).

**Capture** → `status: completed`, no `## Resume Here`, no "start a fresh session" line. Still run B3a if the transcript shows uncommitted work — then it is not a capture.

## Mode B — Full session file (THE DEFAULT) — reconstruct a `/session-update` file

See the "Mode B" steps below (B1–B4). This is the default output for any bare invocation. After writing, you may *also* print a 2–3 line confirmation of what's in it, but the deliverable is the file.

## Mode A — Quick recap (opt-in only)

Do this **only** when the user explicitly said "summarize" / "recap" / "just tell me" / "don't write a file". Write a tight summary grounded in the extracts (never invent). Shape: **Header** (short id, date, span, compacted?) · **Goal** (opening typed prompt) · **What got done** (narrative + commit ledger; a table works well) · **Where it stopped** (final assistant message + last timestamp; flag in-flight agents, blocked items, uncommitted/unpushed state) · **User steering** (corrections/decisions from typed prompts). Report as a recap, not a file dump. Offer to resume.

A session that ends on `API Error`, repeated "Continue from where you left off", or `No response requested.` **died mid-flight** — say so and name what was unfinished.

## Mode B steps (B1–B4) — write the `/session-update` file

Produce a session `.md` in the project's format and **write it to disk**. This is the default, durable, RAG-ingestable output.

### B1. Resolve the sessions directory & filename

- **Sessions dir**: run the [locations](../../session-start/references/locations.md) resolver from the transcript's repo (`.cwd`, Step 5): `eval "$(bash "${CLAUDE_PLUGIN_ROOT}/skills/session-start/scripts/locations.sh" <repo>)"`. An explicit path in `$ARGUMENTS` wins. `mkdir -p "$SESSIONS_DIR"` before writing.
- **Filename** — `YYYY-MM-DD-[app]-plain-description.md`. The **square brackets are literal characters** (grep affordance). `[app]` holds **only major-app / repo short-names**, comma-joined — e.g. `web`, `api`, `mobile`, `plugins`, `infra`. **Never** a feature, topic, skill, or descriptor (not `[gtm]`, not `[tooling]`, not `[session-from-transcript]`) — those belong in the description, not the bracket. Date = the transcript's first-message date.

- **Existing session file first.** A handed-off session often already ran `/session-start` or `/session-update`. Check the mine's files-touched list (and `grep -l '<short-id>' <sessions-dir>/*.md`) for an `$SESSIONS_DIR/*.md` it wrote. If one exists, **update that file**: bump `last_updated`/`status`, append what the transcript adds, and add the `## Resume Here` block. Do not create a second file for the same work.

#### The description must be SIMPLE — 2–4 plain words, ONE topic

A transcript mine sees everything that happened, so the pull toward a long name that "covers the session" is strong. **Resist it.** The filename is an **index entry for a dev scanning `$SESSIONS_DIR`**, not a status line or a changelog.

**Hard rules:**
- **2–4 plain words** after the bracket. Plain-language topic, not internal jargon.
- **ONE topic** — the session's *main deliverable*. Everything else lives in the body.
- **No `and`, no clause-joining, no `—`.** A name that needs a conjunction is naming two things; pick one.
- **No p-numbers, story/wave codes, ticket keys, or status words** (`p12`, `W1-W3`, `DEMO-7`, `ABC-123`, `two-of-five`, `complete`, `landed`, `blocked`). Those go in `title:`, `tags:`, `jira:`, and the body.

| ❌ Bad | ✅ Good |
|---|---|
| `p12-export-complete-w1-w3-build` | `export-build` |
| `export-feature-spec-session-and-csv-format-review` | `export-feature-spec-session` |
| `p12-deployed-retry-fix-and-docs-pass` | `retry-fix-live` |

**Same discipline applies to `title:`** — a short phrase, not a run-on that lists every outcome with semicolons. The body sections carry the detail.

Litmus test: **could a person skim 30 filenames and know which one to open?** If the name needs parsing, shorten it. When torn between two, pick the shorter.

### B2. Frontmatter (match the project's existing files exactly)

```yaml
---
title: "Specific outcome-oriented title — primary RAG search target"
date: YYYY-MM-DD
projects: [web, api, worker]        # or a single repo
branch: <gitBranch from Step 5>
status: completed                      # completed | in-progress | blocked | paused
type: feature                          # feature | debugging | refactor | research | planning | meta
topics: [..]                           # free-form semantic tags
tags: [..]                             # technology/area tags
last_updated: <ISO-8601 of last message>
sdk_touched: []                        # from files-touched under shared SDK packages
apps_touched: [..]                     # from files-touched repo roots
commits: ["<hash>", ...]               # the Step 5 commit ledger
related_sessions: []                   # other session .md filenames if relevant
specs:                                 # the Step 5 specs list
  - <specs-dir>/<feature>/
---
```

### B3. Body sections

Open with a one-line **provenance** sentence, then the standard sections:

```markdown
# <Title>

Reconstructed from transcript `<short-id>` (<first→last UTC>, compacted N×; folded M of K subagent transcripts).

## What this session accomplished
(numbered, concrete outcomes — files, commits, decisions)

## <Durable knowledge / architecture decisions>
(load-bearing decisions worth keeping; include the question that drove each and the resolution)

## Build state at session end
(ledger: DONE / IN-PROGRESS / BLOCKED / NOT-STARTED, grounded in commits — note uncommitted/unpushed)

## Lessons Learned
## User Steering & Corrections
## Next Steps

## Resume Here
(handoff only — mandatory then; omit for a capture. See Step 7 and B3a)
```

#### B3a. Resume Here — verify live state, then write it

The transcript ends when the user walked away; the repos may have moved since (another session, a merge, a worktree cleanup). Before writing *Build state* and *Resume Here*, read the live state of each repo in `apps_touched` — read-only:

```bash
cd <repo> && command git branch --show-current && command git status -s | head -20 \
  && command git log --oneline -5 && command git log --oneline @{u}..HEAD 2>/dev/null | head   # unpushed
```

Use `command git` (bypasses any shell wrapper or proxy that rewrites git output). Then write `## Resume Here`, following the standard handoff block:

- **State now** — branch, uncommitted files, unpushed commits, per repo. Flag anything that differs from the transcript's end.
- **Open decision / next action** — the exact next step, and the question the user still owes an answer to, quoted if they asked it.
- **Run commands** — the commands to get back to a working state (dev server, tests).
- **Constraints** — steering from Step 3 that the next session must not re-violate.
- **Waiting on / in-flight at hand-off** — from Step 7: what Claude was waiting for (including an unanswered question to the user, quoted) and what was mid-step. Background agents, builds, monitors and loops are no longer running or watched — give the command or URL to check each result now.

For the **per-section field formats** (Issues with Status/Impact/Applies-to; Lessons with Topics/Confidence/Evidence; Steering with exact-words), follow `agent-ops:session-update` — do not reinvent them. Populate from: *What this session accomplished* ← Step 4 narrative; *User Steering* ← Step 3 typed prompts (quote the user's exact redirects); *Build state*/*commits* ← Step 5 ledger; and for an implementation/debug/incident session, enrich *Build state* (diff locus, real verification) and *Lessons Learned* (discarded hypotheses) from the Step 6 `[HIGH]` subagent deep-reads.

### B4. After writing

1. **Append** the new filename as a line to `<sessions-dir>/.current-session` (append — never overwrite; multiple sessions may be active).
2. Tell the user, in one or two lines: the verdict (handoff or capture) and its deciding signal, and the path written (or updated). For a handoff, add what the fresh session picks up first — e.g. start a new session and run `/session-start` on that file. Never suggest resuming the old session.

