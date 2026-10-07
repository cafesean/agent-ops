# Verification and config audit

Back to [SKILL.md](../SKILL.md).

## Reference verification (after writing any skill or reference doc)
1. Re-read the source: session file, git log, error messages.
2. Run the checklist below and mark each item.
3. Add a new subsection for each gap rather than bloating an existing one.
4. Trace one code example as if an agent sent it verbatim.

### Completeness
- [ ] Every confirmed lesson in the source is captured
- [ ] Every error hit has a "Common errors" entry: exact message, root cause, fix
- [ ] Id formats are documented (type, shape, placeholder example)
- [ ] Endpoint paths match real responses, not only docs

### Critical patterns
- [ ] Each write endpoint shows the full required body
- [ ] "Read before update" sequences are numbered steps
- [ ] Fields that are ignored or rejected are listed
- [ ] Non-obvious defaults (headers, prefixes, versions) are written down

### Gaps to look for
- [ ] A verification or activation step after setup?
- [ ] Per-environment differences (local, dev, prod)?
- [ ] Platform behaviours that change the outcome (caches, TTLs, injected defaults)?
- [ ] Known model failure modes (fields often omitted, wrong shape copied from a similar endpoint)?

### Quality
- [ ] Examples have the right shape, with named placeholders for every host, credential and id
- [ ] Workflows are numbered steps; alternatives are labelled Path A / Path B
- [ ] Rule zero swept: no IPv4 literals, `@` addresses, phone numbers, 25+ char high-entropy strings
- [ ] If a real credential was found, the user was told to rotate it

## Config correctness audit (before shipping)
`scripts/check-plugin.sh` automates the items marked (auto).

Manifests
- [ ] (auto) `plugin.json` is valid JSON with non-empty `name`, `description`, `version`
- [ ] (auto) `plugin.json` version equals the plugin's `marketplace.json` entry version; never let them drift
- [ ] (auto) every marketplace `source` resolves
- [ ] `author` matches the marketplace owner

Agents and skills
- [ ] (auto) agent `name` equals the file name; skill `name` equals the directory
- [ ] (auto) `model:`, when present, is `opus`, `sonnet`, `haiku` or `inherit`
- [ ] (auto) `description` present, ≤ 1,536 chars, quoted when it contains `": "`
- [ ] every description states trigger conditions and disambiguates siblings

References and scripts
- [ ] (auto) bundled-script examples use `${CLAUDE_PLUGIN_ROOT}`, not cwd-relative `skills/…/scripts/…`
- [ ] (auto) `hooks.json` is an object keyed by event name with `type: command` entries
- [ ] (auto) no CRLF in `.sh` / `.py` files
- [ ] cross-plugin links resolve on disk
- [ ] no two installed plugins share a `name`
