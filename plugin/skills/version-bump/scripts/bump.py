"""Bump a Claude Code plugin's version consistently. Called by bump.sh; stdlib only.

Usage: python bump.py <repo-root> <patch|minor|major|X.Y.Z> [--plugin NAME] [--write]
Without --write it is a dry run: prints old -> new per file, changes nothing.
Edits only the version string in place (formatting and other entries untouched), then re-parses
each file as JSON and checks the new value. Exit 0 ok, 1 error, 2 usage.
"""
import glob
import json
import os
import re
import sys

SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def next_version(old, how):
    if SEMVER.match(how):
        return how
    m = SEMVER.match(old or "")
    if not m:
        raise ValueError(f"current version '{old}' is not X.Y.Z; pass an explicit version")
    a, b, c = map(int, m.groups())
    return {"major": f"{a + 1}.0.0", "minor": f"{a}.{b + 1}.0", "patch": f"{a}.{b}.{c + 1}"}[how]


def load(path):
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8")
    return raw, json.loads(raw)


def replace_top_level(text, old, new):
    # the first "version" key at nesting depth 1 of the top-level object
    depth, i, in_str, esc = 0, 0, False, False
    pat = re.compile(r'"version"\s*:\s*"' + re.escape(old) + '"')
    while i < len(text):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            if depth == 1:
                m = pat.match(text, i)
                if m:
                    return text[:i] + m.group(0).replace(old, new) + text[m.end():]
            in_str = True
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        i += 1
    return None


def replace_in_entry(text, name, old, new):
    # inside the plugins[] object whose "name" is NAME: replace its "version"
    for m in re.finditer(r'\{[^{}]*"name"\s*:\s*"' + re.escape(name) + r'"[^{}]*\}', text):
        block = m.group(0)
        nb, n = re.subn(r'("version"\s*:\s*")' + re.escape(old) + '"', r"\g<1>" + new + '"', block, count=1)
        if n:
            return text[:m.start()] + nb + text[m.end():]
    return None


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    write = "--write" in argv
    name = None
    if "--plugin" in argv:
        k = argv.index("--plugin")
        name = argv[k + 1] if k + 1 < len(argv) else None
        args = [a for a in args if a != name]
    if len(args) != 2 or (args[1] not in ("patch", "minor", "major") and not SEMVER.match(args[1])):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    root, how = os.path.abspath(args[0]), args[1]

    mp_path = os.path.join(root, ".claude-plugin", "marketplace.json")
    mp_text, mp = (load(mp_path) if os.path.isfile(mp_path) else (None, None))

    # locate the plugin root
    plugin_dir = None
    if mp:
        entries = mp.get("plugins", [])
        entry = next((p for p in entries if p.get("name") == name), None) if name else (entries[0] if len(entries) == 1 else None)
        if entry is None:
            print("marketplace has several plugins (or none matched); pass --plugin NAME", file=sys.stderr)
            return 1
        name = entry["name"]
        src = entry.get("source")
        if isinstance(src, str) and src.startswith("."):
            plugin_dir = os.path.normpath(os.path.join(root, src))
    if plugin_dir is None:
        plugin_dir = root
    pj_path = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
    if not os.path.isfile(pj_path):
        print(f"no plugin.json at {pj_path}", file=sys.stderr)
        return 1
    pj_text, pj = load(pj_path)
    old = pj.get("version")
    try:
        new = next_version(old, how)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1

    edits = []  # (path, new_text)
    t = replace_top_level(pj_text, old, new)
    if t is None:
        print(f"could not find version {old} in {pj_path}", file=sys.stderr)
        return 1
    edits.append((pj_path, t))
    if mp_text is not None:
        e = next(p for p in mp["plugins"] if p.get("name") == name)
        if e.get("version") not in (None, old):
            print(f"WARN marketplace.json had drifted ({e.get('version')} vs plugin.json {old}); setting both to {new}")
        if e.get("version") is not None:
            t = replace_in_entry(mp_text, name, e["version"], new)
            if t is None:
                print(f"could not edit the '{name}' entry in {mp_path}", file=sys.stderr)
                return 1
            edits.append((mp_path, t))
    for pkg in sorted(set(glob.glob(os.path.join(root, "package.json")) + glob.glob(os.path.join(plugin_dir, "package.json")))):
        ptext, p = load(pkg)
        if p.get("version"):
            t = replace_top_level(ptext, p["version"], new)
            if t is not None:
                edits.append((pkg, t))

    for path, text in edits:
        json.loads(text)  # must still parse
        print(f"{'write' if write else 'dry-run'}: {os.path.relpath(path, root)}  {old} -> {new}")
        if write:
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
    if write:
        for path, _ in edits:
            _, d = load(path)
            got = d.get("version") if "plugins" not in d else next(p for p in d["plugins"] if p.get("name") == name).get("version")
            if got != new:
                print(f"verify failed: {path} has {got}", file=sys.stderr)
                return 1
        print(f"ok: {name or pj.get('name')} {new}")
    else:
        print("dry run only; re-run with --write to apply")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
