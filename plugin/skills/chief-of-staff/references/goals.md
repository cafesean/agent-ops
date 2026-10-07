# Goals — daily ONE Thing and long-term

## GOALS.md — the one goal list (`$COS_DIR/GOALS.md`)
Every goal is one block, parsed by `spawn.sh`:
```
### <ID> · <outcome>
intent: <why, in the user's words — quoted>
done means: <measurable finish line + deadline>
status: confirmed | confirm? | parked | done
- tracked: <narrative item the chief curates under this goal — a P0, a collection, waiting-on-user>
```
- IDs: a letter per area (e.g. `G` general, `W` work, `P` personal) plus a number; never reuse a retired ID.
- **Never invent the user's words.** No quote → `intent: — (user to say; chief's reading: …)` and `status: confirm?`. Only the user moves a goal to `confirmed`.
- `parked` goals cannot receive workers (`spawn.sh` refuses).
- Anywhere a goal is shown (brief, sweep, Outstanding), an unconfirmed goal carries `?`: `G1?`.

## Task goals — one per task
GOALS.md holds broad goals. Each task file carries its own `task goal:` (the outcome THIS task delivers) + `done means:` (the check that proves it), with the broad ID as `parent goal:`. Status tables show the task goal; the parent ID rides along as a tag. Drift is judged against the task goal.

## Layers
| Layer | Source | Horizon |
|---|---|---|
| Long-term | the user's own goals notes, if any (point to them in `sources-of-truth.md`) | quarters–years |
| Program | GOALS.md goals and their tracked items | weeks |
| Daily | the ONE Thing in today's brief | today |

## Picking today's ONE Thing
Ask: "what ONE thing, done today, makes everything else easier or unnecessary?"
1. A FIRE wins the day.
2. Else the next step of the top goal that only moves with the user.
3. Else the next step of a long-term goal they are neglecting. This is where the chief protects them from being pulled into work a worker could do.
Write the WHY in their words from the goal. Never pick three.

## Alignment check (every brief and sweep)
For each running worker and each Needs-you item, show the task goal and tag the parent ID. Report:
- Work serving no goal → propose PARK.
- A long-term goal with no work for 7+ days → one line: "<goal> untouched since <date>".
- The user personally doing work a worker could do → say so once, plainly.

## Drift signals
- **Worker drift (every SWEEP):** a live worker's latest report is untagged, or tagged but not obviously serving its TASK goal → judge it with a cheap classifier call or a small-model subagent: "Does this update directly advance the task goal `<task goal>` (done means `<done means>`)? true only when it clearly moves it; false for side work, tooling or unrelated." `false` → 🟡 `drift?` row. Never stop or re-message a worker for drift; the user decides.
- Same ONE Thing unfinished 3 briefs in a row, or its parent goal `done` → ask: split it, unblock it, or re-decide.
- ONE Thing changed 3 days in a row → novelty churn; name it.
- Goal notes older than 90 days → ask the user once a week to confirm or update them.
