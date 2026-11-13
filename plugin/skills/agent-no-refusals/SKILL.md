---
name: agent-no-refusals
description: "HARD rule for every agent change, read first: facts, not refusals; the single owner decides. Use when working on agents, roles, skills, tool rows, guardrails, reviews, checks or gates in any agent platform. Also use when the user mentions \"no refusals\", \"refuse\", \"refused\", \"reject\", \"block\", \"agent role\" or \"tool row\". Default action for a bare invocation: print the rule and list the agent-touching files that still license refusals."
---

# No refusals (HARD)

The agent does what it does. No mechanism blocks its execution. The agent has the knowledge and the skills, and it handles situations itself. Checks report facts; they never stop the agent.

The shared rule text is below. Agent-touching skills point here and carry the same paragraph.

**Facts, not refusals; the single owner decides.** A tool, AI function, skill or role never
refuses on the agent's behalf and never tells the agent to refuse. It returns facts — what happened, why, and
what is possible next (`{status, reason, options|next}`) — and does the best deliverable it can: deliver
something rather than nothing. The conversation's single owner decides what to do with those facts. No skill,
role or tool text says "refuse", "reject", "do not proceed" or "stop" as a policy. The only stops that stay are
facts too: an auth or tenant error (`access_unavailable`), and money is spent only on the end user's own explicit
confirmation (the tool posts the confirmation buttons and returns that fact). A guard that protects the end user
(an invented offer, a made-up product) changes the data and returns the fact; it does not refuse the call.
Reviewers block any change that adds a refusal (a review gate). Enforced at the harness (one principle line on
every agent) and in these skills, not in a knowledge base.

## How to apply

1. Before any agent edit, name the owner role for the step. No owner named → stop and ask the lead.
2. A check that finds a problem returns `{status, reason, options|next}`. It never stops the run.
3. A limit or cap on what an agent may do or see is a refusal in disguise: it needs the same owner review as a refusal. Allowed: sizing by a real outside ceiling (the model's context window, a provider's documented max) recorded in a limits register, and excess that is stored and readable. Show what happens to the excess.
4. Review the diff for refusal wording (`refused`, `rejected`, `blocked`, a reject status, a cap that stops a run). A match is a finding to fix, not a line to keep.
5. **No hard-coded decisions (gate G7).** Code stores state, returns facts (`{status, reason, options|next}`) and runs the owner's tool calls. Code enforces only auth or tenant, and money on the end user's own confirmation. Code does NOT: post an end-user line in reaction to a situation; choose the next question from a situation; decide meaning by threshold or regex; hold, skip, drop or refuse; route an inbound by a fixed rule away from the owner; cap what the agent may see or do. Those decisions belong to the agent, using its skills. An agent-touching diff that does any of these is a finding, same as a refusal (G4).

## Where it is enforced

- `hooks/agent-rule.sh` (UserPromptSubmit): on prompts that mention agents, roles, refusals or rejects, injects a two-line pointer to this skill (not the paragraph, to keep context small).
- `hooks/agent-refusal-warn.sh` (PreToolUse on Edit, Write, MultiEdit): warns, does not block, when an agent-touching file gets refusal wording (G4) or a new numeric threshold in an agent-touching edit (G7).
