# Agents and skills: templates and rules

Back to [SKILL.md](../SKILL.md).

## Agent frontmatter
```yaml
---
name: agent-name           # kebab-case, equals agents/<file>.md
description: ...           # see below
model: opus                # optional: opus for complex domain agents, sonnet for simpler ones; never "default"
color: cyan                # optional; unique per plugin
---
```

## Agent description
Structure: `Use this agent for [domain]. This agent specializes in [areas].\n\nExamples:\n- <example>...</example>`

- First sentence: broad domain trigger.
- Second sentence: specialisations as a comma-separated list.
- 3-7 examples, each with a context line, a user quote, an assistant quote and a commentary saying why this agent.
- Cover diverse task types: new feature, bug fix, performance, a specific technology, UI change.

```
<example>
  Context: [brief situation]
  user: "[realistic request]"
  assistant: "I'll use the {agent-name} agent to [action]"
  <commentary>
  [why this agent fits; name the knowledge it needs]
  </commentary>
</example>
```

## Agent system prompt skeleton
```markdown
You are a [role] specializing in [domain]. You have deep expertise in [technologies].

## Communication style
Be concise. Code over words. No greetings or filler.

## Skills available
- `<plugin>:<skill>` — [what it gives]

## Architecture
[directory tree of key paths]

## Key patterns
[3-5 patterns with code]

## Context loading
1. Always: [files read on every task]
2. Architecture: [authoritative docs]
3. Task-based: [pattern files by task type]
4. Feature-specific: [feature docs as needed]

## Reference documentation
[table: area → doc path]
```

## Agent checklist
- [ ] Description has 3+ diverse examples
- [ ] System prompt lists every skill it should invoke
- [ ] Architecture section matches the current tree; reference paths exist
- [ ] Context loading has phases (always → architecture → task → feature)
- [ ] Rule zero: placeholders and pointers only
- [ ] Plugin version bumped after the change

## Skill frontmatter
```yaml
---
name: skill-name           # equals the directory name
description: Use when working on [area]. Also use when the user mentions "[t1]", "[t2]" or "[t3]".
---
```
Two sentences joined by "Also use when". Include technical terms, casual phrasings, the feature name and common
abbreviations. 4-8 trigger phrases. Disambiguate against sibling skills that overlap.

## Skill body template
```markdown
# [Feature area]

[one line: what this skill covers; the default action for a bare invocation]

## Architecture
[tree or diagram]

## Key files
[table of paths]

## [Section]
[patterns, code, paths]

## Critical rules
[must-follow rules, pitfalls, anti-patterns]

## Reference documentation
[pointers to references/*.md and project docs]
```

Rules: imperative voice; code over prose; full paths from the repo root; most important first; 1,500-2,500 words
before splitting into `references/`; no duplication (point to the other skill instead).

## Skill checklist
- [ ] Description has a context trigger and explicit trigger phrases; ≤ 1,536 chars; quoted if it contains `": "`
- [ ] SKILL.md under 500 lines; detail in `references/*.md` with a 1-3 line pointer
- [ ] Code is copy-pasteable; bundled scripts use `${CLAUDE_PLUGIN_ROOT}`
- [ ] Critical rules section exists
- [ ] No stale paths (spot-check the key ones)
- [ ] Rule zero swept
- [ ] Plugin version bumped; verification step run (see [verification.md](verification.md))

## Naming
| Component | Convention | Example |
|---|---|---|
| Plugin dir | kebab-case | `dev-workflow` |
| Agent file | `<name>.md`, `name:` equal | `agents/code-reviewer.md` |
| Skill dir | kebab-case, `name:` equal | `skills/billing-subscriptions/` |
| Skill file | always `SKILL.md` | |

If a name and its file disagree: rename the agent file to match `name` (the name may be referenced already);
change a skill's `name` to match its directory (directories are referenced by path).

Name skills by action, not by tool or actor:
| Good | Bad | Why |
|---|---|---|
| `review-specs` | `spec-feedback-reviewer` | says what happens |
| `address-feedback` | `feedback-bot-v2` | says what happens, not who acts |
| `create-specs` | `spec-writer` | action, not role |

Pipelines should read as a sequence: `/create-specs → /review-specs → /address-feedback → /develop-specs`.

## Grouping and duplication
- Group skills by feature area (`billing-subscriptions`, `i18n`), not by file type (`database-skills`).
- New skill when the area has 3+ distinct patterns and is independently triggerable; otherwise extend an existing one.
- Before creating one, search existing descriptions:
  `grep -rh "^description:" <plugins-root>/*/skills/*/SKILL.md`. Merge overlaps into the clearer name.

## Agent vs skill split
| Agent holds | Skill holds |
|---|---|
| WHAT and WHEN: workflow, orchestration, inventory | HOW: templates, patterns, checklists |
| decision logic (gap analysis, update plans) | writing standards, naming |
| context-loading order | quality checklists |

If an agent says "create a skill", it invokes the skill for the HOW. Keep one primary agent per plugin unless
the domains are truly distinct.
