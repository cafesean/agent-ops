---
name: {{PREFIX}}-<topic>
to: {{PREFIX}}
from: chief
parent_goal: G1
status: open
model: opus
approved: true
needs: []
dir: <one of COS_LAUNCH_DIRS>
agent:
account: auto
where:
task_goal: "<one sentence — the outcome THIS task delivers>"
done_means: "<the concrete check that proves it>"
created: {{DATE}}
started:
closed:
heartbeat_min: 60
depends_on_missions: []
light: false
asks: []
decisions: []
slices: []
---
# Charter: {{PREFIX}}-<topic>
task goal: <one sentence>
done means: <the concrete check>
parent goal: G1
intent: <copied verbatim from the parent goal>
off-goal rule: if the next step doesn't serve the TASK goal, report BLOCKED off-goal instead of doing it.

Task: <one paragraph, outcome not steps>
Read first: <paths>
Stop and report BLOCKED if: <conditions>
Never (one-way doors): prod deploys, main pushes, writes to prod/shared DBs, messages to anyone but the owner, spending money, deleting branches/data.

## Reports
