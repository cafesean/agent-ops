# Self-improvement

The chief gets better from evidence it already writes: task reports, stop/queue refusals, STATE.md decisions, and the user's corrections.

## Loop
1. **Spot**: at the end of every sweep, note what happened: `correction` (the user said so), `failure` (worker FAILED / wrong model / killed / refused), `win` (an approach that worked), `measure` (a number: spend, duration, load).
2. **Decide**: a user correction, or the same lesson seen twice, gets promoted now. Anything else is dropped; there is no lessons file to park it in.
3. **Promote** straight to exactly one home:
   | Lesson type | Home |
   |---|---|
   | Standing preference or trap across projects | a memory file in `$COS_MEMORY_DIR` (if configured), one line in its index |
   | How the chief itself should work | this skill's `SKILL.md` or a `references/` file, in the plugin's source repo |
   | Domain knowledge for one project | that project's own docs or skill |
   | A decision that must not be re-litigated | STATE.md → *Decisions* (one line) |

## Rules
- One skill edit per sweep, max. Improving the system must not replace doing the work.
- Never rewrite a memory index; append single lines.
- Skill edits happen in the plugin's source repo on a branch; bump the version. Pushing is the user's call.
- Weekly: read the last 7 days of closed tasks in `tasks/` + `_archive/`, report in one line what changed in how the chief works, plus one metric: workers DONE vs FAILED, verified vs unverified.
