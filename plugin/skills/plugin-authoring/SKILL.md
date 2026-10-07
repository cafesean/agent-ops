---
name: plugin-authoring
description: Use when creating or improving Claude Code plugin agents, skills, hooks or plugin structure, or auditing a plugin before release. Also use when the user mentions "write agent", "write skill", "agent description", "skill description", "trigger phrases", "plugin structure", "agent examples", "SKILL.md" or "check my plugin".
---

# Plugin Authoring

How to write Claude Code agents, skills and plugin layouts that trigger reliably, load lean and ship cleanly.
Default action for a bare invocation: run the checker on the plugin in the current repo, then fix what it reports.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/plugin-authoring/scripts/check-plugin.sh" <plugin-dir> [<marketplace-root>]
```
Read-only. Prints `PASS` / `WARN` / `FAIL` lines, exits 1 on any FAIL. Checks manifests, version drift with
`marketplace.json`, frontmatter `name` vs file/dir, `model:` values, description length and quoting,
`hooks.json` shape, cwd-relative script paths and CRLF line ends.

## Rule zero: no hosts, no secrets in a plugin
Plugin repos are shared git repos. Anything in an agent, skill or reference file is published to every reader,
permanently, through git history. Never write IPs, hostnames, app domains, SSH users, key file names, account or
resource ids, tokens (not even a prefix), emails, phone numbers or personal checkout paths. Write a named
placeholder (`<host-ip>`, `<user>`, `<repo-root>`, `<token>`) plus a pointer to where the real value lives
(an inventory file, a secrets vault, an env var name). A secret that reached a commit is compromised: tell the
user to rotate it, then scrub. Never silently delete. Before committing, grep touched files for IPv4 literals,
`@` addresses and long high-entropy strings. Placeholder table and grep: read `references/no-secrets.md`.

## Agents (`agents/<name>.md`)
- Frontmatter: `name` (kebab-case, equals the file name), `description`, optional `model` (`opus` / `sonnet` /
  `haiku`, never `default`), optional `color`.
- The description decides when the agent fires: one broad domain sentence, one sentence of specialisations,
  then 3-7 `<example>` blocks with diverse task types.
- The agent holds WHAT and WHEN (workflow, decisions, context-loading order). The HOW (templates, checklists)
  lives in skills the agent invokes.

Templates, the system-prompt skeleton and the agent checklist: read `references/agents-and-skills.md`.

## Skills (`skills/<name>/SKILL.md`)
- Frontmatter `name` equals the directory name. Description = "Use when <work context>. Also use when the user
  mentions "<t1>", "<t2>" …" with 4-8 trigger phrases, technical and casual.
- State the default action for a bare invocation in both the description and the body.
- Imperative voice, code over prose, copy-pasteable examples, full paths from the repo root.
- Bundled scripts are always invoked as `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/scripts/<file>`, never cwd-relative.
- Name by action (`verb-noun`): `create-specs`, `address-feedback`. Name for the actor that runs the skill.

### Keep SKILL.md lean
SKILL.md loads whole on every trigger. Keep it under 500 lines (ideally under ~18,000 chars). Move detail,
trap catalogues and long procedures to `references/*.md` and leave a 1-3 line pointer saying what the file
covers and when to read it. `description` must stay at or under 1,536 chars; quote it when it contains `": "`.

Skill template, naming and grouping rules, duplication checks: read `references/agents-and-skills.md`.

## Plugin structure
```
<plugin-root>/
  .claude-plugin/plugin.json   # name, description, version, author, keywords
  agents/<name>.md             # auto-discovered, no manifest field needed
  skills/<name>/SKILL.md       # auto-discovered
  skills/<name>/references/    # on-demand detail
  skills/<name>/scripts/       # bundled scripts
  hooks/hooks.json             # optional; object keyed by event name
```
`agents/`, `skills/`, `commands/` and `hooks/hooks.json` at the plugin root are found by convention. Add a
manifest path field only for a non-default location.

Hook schema, the anti-patterns that silently never fire, and cross-platform script rules: read
`references/structure-and-hooks.md`.

## Where to edit, and how a change reaches users
Edit only the plugin's source git repo. Never edit `~/.claude/plugins/marketplaces/…` or
`~/.claude/plugins/cache/…`: the installer overwrites both, and edits there are lost. After a content change:
bump the version in `plugin.json` and the plugin's `marketplace.json` entry together (use the `version-bump`
skill), commit, and let the user push. Users then run `/plugin marketplace update <marketplace>`,
`/plugin` to install, `/reload-plugins` to activate. Reload alone never fetches.

Full release path and the stale-cache gotcha: read `references/structure-and-hooks.md` § Release path.

## Verify after writing (mandatory)
Re-read the source material (session file, code, error logs) and check the new text against it. First drafts
miss edge cases. Run the checker. Then run the audit and verification checklists in
`references/verification.md`.

## Subagents inside a skill
A skill that spawns subagents must use the native Agent tool (explicit `subagent_type`), never shell-out
(`claude -p`, background `claude` sessions). Shell spawning is only for a deliberate standalone session that a
human picks up.
