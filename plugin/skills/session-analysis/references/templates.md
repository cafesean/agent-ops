# Session analysis — extraction templates and checks

Loaded from [SKILL.md](../SKILL.md).

## Knowledge Extraction Templates

### For a New Feature Session
```markdown
Feature: [name]
Skill: [existing skill to update OR new skill needed]
Key Files:
- [path1] — [purpose]
- [path2] — [purpose]
Patterns:
- [pattern description with code if applicable]
Lessons:
- [lesson with context]
```

### For a Bug Fix Session
```markdown
Bug: [description]
Root Cause: [what went wrong]
Fix Pattern: [the correct approach]
Affected Skill: [which skill should document this]
Critical Rule: [one-line rule to add to skill]
```

### For a Refactoring Session
```markdown
Refactor: [what changed]
Before: [old pattern]
After: [new pattern]
Files Moved/Renamed:
- [old path] → [new path]
Skills to Update: [list of skills with stale references]
```

## Quality Checks

After extracting knowledge, verify:
- No duplicate information (check if skill already documents it)
- Correct file paths (files may have moved since session was written)
- Patterns are actionable (include code, not just descriptions)
- Lessons include the "why" (not just "do X" but "do X because Y")

## Cross-Session Patterns

When multiple sessions touch the same area, look for:
- **Evolving patterns**: Later sessions may supersede earlier ones
- **Repeated lessons**: If the same lesson appears twice, it's critical — flag prominently
- **Contradiction**: If sessions disagree, the later one wins (check git history if unsure)
