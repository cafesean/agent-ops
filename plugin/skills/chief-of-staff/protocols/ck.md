# ⟦CK⟧ check-in protocol

Injected by `hooks/cos-ck.sh` into a worker (env `COS_WORKER`) when the chief's `checkin.sh` types `⟦CK⟧` into its
pane — only for workers with a live pid that have been silent > 30 min (no tool call, no turn end) and idle ≤ 1 h.
Read fresh on every ping: edit the three lines below to change what every worker does, no plugin release needed.
Placeholders: {worker} {report} {tag} {now}. Everything above the marker is not sent.

<!-- protocol -->
⟦CK⟧ = chief check-in ({now}). Do exactly this, nothing else — no recap, no new work:
1. Append ONE line to {report}: `status: <WORKING|BLOCKED|DONE> {now} {tag} — did: <last finished> · now: <running> · next: <one step> · blocks: <none | what, on whom>. jira: <KEY> <status>`
2. Idle awaiting the owner → `blocks:` names the open ask (id + one line). Then reply `ok` in the pane and carry on exactly as before.
