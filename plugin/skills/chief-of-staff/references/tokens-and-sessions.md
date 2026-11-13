# Tokens and sessions

## Cost model
Cost ≈ API calls × context size. Count cost as cache writes x1.25 + input + output x5; warm cache reads are not counted. On that measure the levers are
output length (reports, subagent returns), cold starts (new sessions and subagents, resumes after the cache expired) and
model choice. Context size is not a lever: a lower handover point saves about nothing, because a handover writes a fresh cache.
- **A cold resume costs about 1.25 x the old context in cache writes; a fresh successor costs about 115k.** A session idle past the cache lifetime with context above ~100k is never resumed: start a successor (`--continues`). Below ~100k a resume is equal or cheaper.
- **Resume within the cache lifetime (about 1 h) is warm.** The cache is server-side, keyed on the prompt prefix, so it survives a killed process. Past that the whole context is rewritten.
- **A mid-session MCP/tool load rewrites the whole cache.** Load heavy tools at session start or inside a subagent.
- **Build subagents tend to dominate spend**, not cache misses. Cap subagent context: a fresh subagent per story, handoff via files.

Levers, strongest first:
1. Fewer calls: batch shell commands; parallel independent tool calls in one message.
2. Smaller context: fresh subagent per step with a "read these paths" brief; don't grow the chief's own context with file dumps.
3. Right model: the routing guidance in SKILL.md.
4. Stop idle workers; a stopped worker costs nothing, an idle one re-reads its context on every nudge.

## Limits
| Limit | Value |
|---|---|
| Subagents at once per session | 3-4 |
| Live sessions on this machine | `COS_MAX_LOCAL_SESSIONS` |
| Re-message a subagent | only if idle < 5 min |
| Re-message a session | only if idle < 1 h |

## Tools
| Need | Command |
|---|---|
| Spend by day/session | a usage tool such as `ccusage` |
| Live sessions + idle | `scripts/sessions.sh` |
| Background agents | `claude agents --json --all` |
| Context used by a session | its status line; the transcript's last `message.usage` |
| Transcripts | `~/.claude/projects/<cwd-dashed>/<sessionId>.jsonl` |

## Session hygiene
- A parent restart kills its subagents. After a restart, check the agent list and relaunch from git state.
- A subagent that waits on its own background watcher never wakes. Run long commands in the foreground, give every subagent a wall-clock budget, and have it return partial results rather than wait on deploys, CI or locks.
- Before a session maxes out: write a handoff, then spawn a successor that reads it.
- In the sweep, report spend only when a day is > 2× the 7-day median.
- **Measure before any handover** (`ctx.py`): a live session below its handover point is corrected in place, not replaced. At the point, the context-handoff Stop hook blocks the stop until Resume Here exists, then the chief spawns the successor.
- **Cold cache**: a prompt cache lives minutes to an hour. A session idle past that (or on a machine that slept) gets no cron, ping or SendMessage: every wake re-reads the whole context at full price. The send-cold-guard hook denies such a SendMessage; continue the work with `--continues`.
- Subagent count per session follows `load-check.sh` and the agent-budget-guard cap, not a fixed number.
