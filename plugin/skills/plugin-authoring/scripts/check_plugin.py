"""Read-only lint of a Claude Code plugin. Called by check-plugin.sh; stdlib only.

Usage: python check_plugin.py <plugin-dir> [<marketplace-root>]
Exit 0 = no FAIL, 1 = at least one FAIL, 2 = usage error.
"""
import json
import os
import re
import sys

VALID_MODELS = {"opus", "sonnet", "haiku", "inherit"}
DESC_MAX = 1536
results = []


def out(level, msg):
    results.append(level)
    print(f"{level:4} {msg}")


def read_text(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    return raw.decode("utf-8", errors="replace"), b"\r\n" in raw


def frontmatter(text):
    """Return (dict of top-level scalar keys -> raw value string, ok)."""
    text = text.lstrip("﻿")
    if not text.startswith("---"):
        return {}, False
    end = text.find("\n---", 3)
    if end < 0:
        return {}, False
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z_][\w-]*):\s?(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm, True


def check_desc(where, raw):
    if not raw:
        out("FAIL", f"{where}: description missing")
        return
    quoted = raw[:1] in ("'", '"') or raw[:1] in ("|", ">")
    val = raw.strip("'\"")
    if len(val) > DESC_MAX:
        out("FAIL", f"{where}: description {len(val)} chars > {DESC_MAX}")
    if not quoted and ": " in val:
        out("WARN", f"{where}: unquoted description contains ': ' (invalid YAML for strict parsers)")


def find_marketplace(start):
    d = os.path.abspath(start)
    for _ in range(6):
        if os.path.isfile(os.path.join(d, ".claude-plugin", "marketplace.json")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def main(argv):
    if len(argv) < 2:
        print("usage: check_plugin.py <plugin-dir> [<marketplace-root>]", file=sys.stderr)
        return 2
    plugin = os.path.abspath(argv[1])
    mkt_root = os.path.abspath(argv[2]) if len(argv) > 2 else find_marketplace(plugin)

    # --- plugin.json
    pj_path = os.path.join(plugin, ".claude-plugin", "plugin.json")
    pj = {}
    if not os.path.isfile(pj_path):
        out("FAIL", f"missing {pj_path}")
    else:
        try:
            with open(pj_path, encoding="utf-8") as fh:
                pj = json.load(fh)
            missing = [k for k in ("name", "description", "version") if not pj.get(k)]
            if missing:
                out("FAIL", f"plugin.json missing {', '.join(missing)}")
            else:
                out("PASS", f"plugin.json {pj['name']} {pj['version']}")
        except ValueError as e:
            out("FAIL", f"plugin.json invalid JSON: {e}")

    # --- marketplace.json
    if mkt_root:
        mp_path = os.path.join(mkt_root, ".claude-plugin", "marketplace.json")
        try:
            with open(mp_path, encoding="utf-8") as fh:
                mp = json.load(fh)
            by_name, by_src = None, None
            for p in mp.get("plugins", []):
                src = p.get("source")
                if isinstance(src, str) and src.startswith("."):
                    if not os.path.isdir(os.path.normpath(os.path.join(mkt_root, src))):
                        out("FAIL", f"marketplace source does not resolve: {src}")
                    elif by_src is None and os.path.normpath(os.path.join(mkt_root, src)) == plugin:
                        by_src = p
                if by_name is None and p.get("name") == pj.get("name"):
                    by_name = p
            entry = by_name or by_src
            if entry is None:
                out("WARN", f"plugin not listed in {mp_path}")
            elif entry.get("version") and pj.get("version") and entry["version"] != pj["version"]:
                out("FAIL", f"version drift: plugin.json {pj['version']} vs marketplace.json {entry['version']}")
            else:
                out("PASS", "marketplace.json entry matches plugin.json")
        except (OSError, ValueError) as e:
            out("FAIL", f"marketplace.json unreadable: {e}")
    else:
        out("WARN", "no marketplace.json found (skipped version-drift check)")

    # --- agents
    adir = os.path.join(plugin, "agents")
    if os.path.isdir(adir):
        for fn in sorted(os.listdir(adir)):
            if not fn.endswith(".md"):
                continue
            text, _ = read_text(os.path.join(adir, fn))
            fm, ok = frontmatter(text)
            where = f"agents/{fn}"
            if not ok:
                out("FAIL", f"{where}: no frontmatter")
                continue
            name = fm.get("name", "").strip("'\"")
            if name != fn[:-3]:
                out("FAIL", f"{where}: name '{name}' != file name")
            model = fm.get("model", "").strip("'\"")
            if model and model not in VALID_MODELS:
                out("FAIL", f"{where}: model '{model}' is not a real id")
            check_desc(where, fm.get("description", ""))
            out("PASS", f"{where} checked")

    # --- skills
    sdir = os.path.join(plugin, "skills")
    if os.path.isdir(sdir):
        for d in sorted(os.listdir(sdir)):
            sk = os.path.join(sdir, d, "SKILL.md")
            if not os.path.isdir(os.path.join(sdir, d)):
                continue
            where = f"skills/{d}/SKILL.md"
            if not os.path.isfile(sk):
                out("FAIL", f"{where}: missing")
                continue
            text, _ = read_text(sk)
            fm, ok = frontmatter(text)
            if not ok:
                out("FAIL", f"{where}: no frontmatter")
                continue
            name = fm.get("name", "").strip("'\"")
            if name != d:
                out("FAIL", f"{where}: name '{name}' != directory")
            model = fm.get("model", "").strip("'\"")
            if model and model not in VALID_MODELS:
                out("FAIL", f"{where}: model '{model}' is not a real id")
            check_desc(where, fm.get("description", ""))
            lines = text.count("\n")
            if lines > 500:
                out("WARN", f"{where}: {lines} lines (> 500); move detail to references/")
            if re.search(r"(?<![\w/{}$])skills/[\w-]+/scripts/", text.replace("${CLAUDE_PLUGIN_ROOT}/skills/", "")):
                out("WARN", f"{where}: cwd-relative skills/<x>/scripts/ path; use ${{CLAUDE_PLUGIN_ROOT}}")
            out("PASS", f"{where} checked")

    # --- hooks
    hj = os.path.join(plugin, "hooks", "hooks.json")
    if os.path.isfile(hj):
        try:
            with open(hj, encoding="utf-8") as fh:
                h = json.load(fh)
            if not isinstance(h, dict) or not isinstance(h.get("hooks"), dict):
                out("FAIL", "hooks.json must be an object with a 'hooks' object keyed by event name")
            else:
                bad = []
                for ev, groups in h["hooks"].items():
                    for g in groups if isinstance(groups, list) else [None]:
                        if not isinstance(g, dict) or not isinstance(g.get("hooks"), list):
                            bad.append(f"{ev}: group needs a 'hooks' list")
                            continue
                        for hk in g["hooks"]:
                            if not isinstance(hk, dict) or hk.get("type") != "command":
                                bad.append(f"{ev}: hook type must be 'command'")
                for b in bad:
                    out("FAIL", f"hooks.json {b}")
                if not bad:
                    out("PASS", "hooks.json shape")
        except ValueError as e:
            out("FAIL", f"hooks.json invalid JSON: {e}")

    # --- line endings
    crlf = []
    for root, dirs, files in os.walk(plugin):
        dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
        for fn in files:
            if fn.endswith((".sh", ".py")):
                _, has = read_text(os.path.join(root, fn))
                if has:
                    crlf.append(os.path.relpath(os.path.join(root, fn), plugin))
    for c in crlf:
        out("FAIL", f"CRLF line ends: {c}")
    if not crlf:
        out("PASS", "scripts use LF line ends")

    fails = results.count("FAIL")
    print(f"---- {fails} FAIL, {results.count('WARN')} WARN, {results.count('PASS')} PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
