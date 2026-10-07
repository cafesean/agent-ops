# Plugin structure, hooks and release path

Back to [SKILL.md](../SKILL.md).

## Layout
```
<plugin-root>/
  .claude-plugin/plugin.json
  agents/<name>.md
  skills/<name>/SKILL.md
  skills/<name>/references/*.md
  skills/<name>/scripts/*
  hooks/hooks.json
  hooks/*.sh
```
A marketplace repo adds `.claude-plugin/marketplace.json` at its root; each entry's `source` points at a plugin
root (for example `./plugin`).

Claude Code discovers `agents/`, `skills/`, `commands/` and `hooks/hooks.json` at the plugin root by convention.
`plugin.json` path fields (`agents`, `skills`, `commands`, `hooks`) are only needed for non-default locations.

## plugin.json
```json
{
  "name": "<plugin-name>",
  "description": "<one line>",
  "version": "1.0.0",
  "author": { "name": "<author>" },
  "keywords": ["<word1>", "<word2>"]
}
```
`name` equals the plugin directory (or the marketplace entry name). `author` should match the marketplace owner;
a stray author from a copied template is a smell.

## hooks.json
Top-level object keyed by event name. Never a bare array.
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/my-check.sh\"", "timeout": 10 }
        ]
      }
    ]
  }
}
```
Shapes that silently never fire (the loader ignores them, no error):
- a bare top-level array instead of `{ "hooks": { … } }`
- keys `event` / `toolNames`; the real keys are the event name and `matcher` (a regex string)
- an unsupported `type`; reimplement any LLM-judge intent as a command script that reads the hook JSON on
  stdin, inspects `tool_input`, and exits 2 to block (0 = allow; other non-zero = non-blocking error, reason on stderr)
- cwd-relative script paths; always `${CLAUDE_PLUGIN_ROOT}/hooks/<script>`

Copy a known-good hooks file from a working plugin rather than writing one from memory.

## Cross-platform scripts
Hooks and bundled scripts run under bash on macOS, Linux, WSL and Git Bash on Windows.
- LF line endings (add `*.sh text eol=lf` to `.gitattributes`); tolerate CRLF when reading config.
- Resolve Python once: `python3` → `python` → `py -3`, verifying it is Python 3 (the Windows Store `python3`
  alias exists but fails). Put the detection in one sourced helper and call it everywhere.
- Avoid mac-only commands (`sed -i ''`, `stat -f`, `date -j`, `pbcopy`) unless a fallback exists. Do the work in
  Python when a portable shell form is awkward.
- Convert `C:\…` paths with `cygpath` / `wslpath` when present.
- Hooks must stay silent and exit 0 when an optional dependency is missing.

## Release path
1. Edit in the source git repo only. Never in `~/.claude/plugins/marketplaces/<mkt>/` (installer clone) or
   `~/.claude/plugins/cache/<mkt>/<name>/<version>/` (runtime copy): both are overwritten on install.
2. Bump `version` in `plugin.json` and in the plugin's `marketplace.json` entry together: patch for fixes, minor
   for new skills/agents. Touch only that entry's lines. See the `version-bump` skill.
3. Commit in the user's repo. Push only when the user asks.
4. Users run `/plugin marketplace update <mkt>` (pulls the clone), then `/plugin` (installs the new version into
   the cache), then `/reload-plugins`.

Gotcha: `/reload-plugins` never fetches. It only re-reads the local cache, so a pushed bump stays invisible
until the marketplace clone advances. Verify on disk: `ls ~/.claude/plugins/cache/<mkt>/<name>/` shows the new
version directory.

## Cross-plugin references
- Reference another plugin's skill by its qualified name `<plugin>:<skill>`.
- Links into another plugin's files break silently on renames. Verify they resolve.
- Two installed plugins sharing a `name` across marketplaces: only one registers. Rename forks.
