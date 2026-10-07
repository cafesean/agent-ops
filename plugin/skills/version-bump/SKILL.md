---
name: version-bump
description: Use when releasing a new version of a Claude Code plugin, so the version moves consistently across plugin.json, the marketplace.json entry and package.json, with a changelog entry, a commit and a tag. Also use when the user mentions "version bump", "bump the version", "release the plugin", "cut a release", "plugin release", "new plugin version" or "version drift".
---

# Plugin version bump

Moves a plugin to a new semantic version in every file that carries it, writes the changelog entry, commits and
tags in the user's repo. Default for a bare invocation: decide the bump level, show the dry run, then apply.
Never pushes unless the user asks.

## 1. Decide the level
- **patch**: fixes, wording, reference updates
- **minor**: new skills, agents, hooks or options (backward compatible)
- **major**: removed or renamed skills/agents, changed config keys, anything that breaks an existing setup

## 2. Dry run, then apply
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/version-bump/scripts/bump.sh" <repo-root> <patch|minor|major|X.Y.Z> [--plugin NAME]
bash "${CLAUDE_PLUGIN_ROOT}/skills/version-bump/scripts/bump.sh" <repo-root> <level> [--plugin NAME] --write
```
It edits only the version strings (other entries and formatting untouched) in:
- `<plugin-root>/.claude-plugin/plugin.json` (top-level `version`)
- `<repo-root>/.claude-plugin/marketplace.json`, the entry for this plugin only (`--plugin` picks it when the
  marketplace lists several)
- `package.json` at the repo root and the plugin root, when present with a `version`

Then it re-parses every file and checks the new value. It warns when plugin.json and marketplace.json had
already drifted, and sets both.

Check nothing else still carries the old version (other manifests, docs, badges):
```bash
git -C <repo-root> grep -n '"version": "<OLD>"'
```

## 3. Changelog
Add an entry at the top of `CHANGELOG.md` (create it when missing), newest first:
```markdown
## X.Y.Z — YYYY-MM-DD
- New: <skill/agent/option, one line each>
- Changed: <behaviour the user will notice>
- Fixed: <bug, one line>
```
Write for the plugin's users: what changed for them, not the internal steps. If the repo generates its
changelog from tags or releases, skip this step and say so.

## 4. Validate
- Run the repo's own tests or checks when they exist.
- Optional lint: `bash "${CLAUDE_PLUGIN_ROOT}/skills/plugin-authoring/scripts/check-plugin.sh" <plugin-root>`
- `claude plugin validate <plugin-root>` when the CLI offers it.

## 5. Commit and tag (the user's repo)
Stage only the release files, not unrelated work in the tree:
```bash
git -C <repo-root> add <plugin-root>/.claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md [package.json]
git -C <repo-root> commit -m "<plugin-name> X.Y.Z: <one-line summary>"
git -C <repo-root> tag -a vX.Y.Z -m "<plugin-name> X.Y.Z"
```
- Follow the repo's own commit-message convention when it has one (check `git log --oneline -10`).
- Do not add any trailer or attribution line yourself. The user's settings and the session's attribution rules
  decide that.
- Respect the repo's branch flow (for example: commit on a feature branch, merge per the repo's rules). Never
  commit to a protected branch the repo forbids committing to.

## 6. Push (only when asked)
Do not push the branch or the tag unless the user asks. When they do:
```bash
git -C <repo-root> push origin <branch>
git -C <repo-root> push origin vX.Y.Z
```
Then tell the user how installs pick it up: `/plugin marketplace update <marketplace>`, `/plugin`,
`/reload-plugins` (reload alone never fetches).

## Checklist
- [ ] plugin.json, marketplace entry and package.json (if any) all show X.Y.Z
- [ ] `git grep` for the old version finds nothing that should have moved
- [ ] CHANGELOG entry written (or skipped because it is generated)
- [ ] commit made in the user's repo, no self-added trailers; tag `vX.Y.Z` created
- [ ] nothing pushed unless the user asked
