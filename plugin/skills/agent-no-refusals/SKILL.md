---
name: agent-no-refusals
description: "HARD rule for every Cadra or Yobo agent change, read first: facts, not refusals; the single owner decides. Use when working on agents, roles, skills, tool rows, guardrails, reviews, checks or gates in Cadra, Yobo or the remix pipeline. Also use when the user mentions \"no refusals\", \"refuse\", \"refused\", \"reject\", \"block\", \"agent role\", \"tool row\", \"remix\" or \"storyboard\". Default action for a bare invocation: print the rule and list the agent-touching files that still license refusals."
---

# No refusals (HARD)

This is an underlying, this is a foundational concept in our agentic best practices. The agent will do what it does. There should not be mechanisms that block the agent from execution. The agent has the knowledge and the skills and it will know how to handle situations. (Sean, 2026-11-12)

The one shared copy of the rule. Agent-touching skills point here and carry the same paragraph.
The canonical text is p152 R12 (`_context/cadra/_specs/p152-agent-architecture/1-standard.md`, context 92206c3).

**Facts, not refusals; the single owner decides (Sean 2026-11-12).** A tool, AI function, skill or role never
refuses on the agent's behalf and never tells the agent to refuse. It returns facts — what happened, why, and
what is possible next (`{status, reason, options|next}`) — and does the best deliverable it can: deliver
something rather than nothing. The conversation's single owner decides what to do with those facts. No skill,
role or tool text says "refuse", "reject", "do not proceed" or "stop" as a policy. The only stops that stay are
facts too: an auth/tenant error (`access_unavailable`), and money is spent only on the merchant's own tap or yes
(the tool posts the buttons and returns that fact). A guard that protects the merchant (an invented offer, a
made-up product) changes the data and returns the fact; it does not refuse the call. Reviewers block any change
that adds a refusal (gate G4). Enforced at the harness (one principle line on every agent) and in these skills,
not in a knowledge base.

## How to apply

1. Before any agent edit, name the owner role for the step. No owner named → stop and ask the lead.
2. A check that finds a problem returns `{status, reason, options|next}`. It never stops the run.
3. A limit or cap on what an agent may do or see is a refusal in disguise: it needs the same owner review as a refusal. Allowed: sizing by a real outside ceiling (the model's context window, a provider's documented max) with a `_context/LIMITS.md` row, and excess that is stored and readable (p78 handles). Show what happens to the excess (G8).
4. Review the diff for refusal wording (`refused`, `rejected`, `blocked`, a reject status, a cap that stops a run). A match is a finding to fix, not a line to keep.

## Where it is enforced

- `hooks/agent-rule.sh` (UserPromptSubmit): on prompts that mention agents, roles, remix, storyboards, refusals or rejects, injects a two-line pointer to this skill (not the paragraph, to keep context small).
- `hooks/agent-refusal-warn.sh` (PreToolUse on Edit, Write, MultiEdit): warns, does not block, when an agent-touching file gets refusal wording.
