#!/usr/bin/env python3
"""Task files — the ONE coordination file per worker.

tasks/<name>.md = YAML-subset frontmatter (the old mission file + queue/LEDGER fields) + the charter as body
+ report lines appended under `## Reports`. Replaces charters/<name>.md + inbox/<name>.md + missions/<name>.yaml
+ the LEDGER row. Markdown, so a synced folder carries it between machines.

Frontmatter keys (references/orchestration.md → Task file):
  name, to (machine prefix that runs it), from, parent_goal, status (open|claimed|running|done|failed|parked|stopped),
  model, approved (false = one-way door awaiting the owner → the queue refuses it), needs ([vault, jira]), dir, agent,
  account, where, task_goal, done_means, created, started, closed, jira, heartbeat_min, depends_on_missions,
  story_list, continues, handoff, asks (block list), decisions, slices.

CLI (bash scripts call these):
  tasks.py get FILE KEY                 print one frontmatter value ('' when missing or empty)
  tasks.py set FILE KEY VALUE [K V]...  set top-level scalars in place (atomic rewrite)
  tasks.py report FILE LINE...          append lines under `## Reports`
  tasks.py json FILE                    frontmatter as JSON
  tasks.py list COSDIR                  name<TAB>status<TAB>to<TAB>path for every task file
  tasks.py new FILE --name N --to P [--from F] [--status S] [--model M] [--dir D] [--charter C] [K=V]...
"""
import json, os, re, sys

OPEN, CLOSED = ("open",), ("done", "failed", "parked", "stopped")
LIVE = ("claimed", "running")
REPORTS = "## Reports"


# ---- minimal YAML subset (stdlib only): top-level scalars, flow lists, block lists of flat maps or scalars ----
def scalar(v, where):
    v = v.strip()
    if v in ("", "~", "null"): return None
    if v.startswith("["):
        if not v.endswith("]"): raise ValueError(f"{where}: unclosed [")
        inner = v[1:-1].strip()
        return [scalar(x, where) for x in re.findall(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[^,]+', inner) if x.strip()] if inner else []
    if v.startswith('"'):
        try: return json.loads(v)
        except Exception: raise ValueError(f"{where}: bad double-quoted string")
    if v.startswith("'"):
        if not v.endswith("'") or len(v) < 2: raise ValueError(f"{where}: bad single-quoted string")
        return v[1:-1].replace("''", "'")
    if v in ("true", "false"): return v == "true"
    if re.fullmatch(r"-?\d+", v): return int(v)
    return v


def strip_comment(line):
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q: q = None
        elif c in "\"'": q = c
        elif c == "#" and (i == 0 or line[i-1] in " \t"): return line[:i]
    return line


def load_yaml_lines(lines, name):
    doc, cur_list, cur_item = {}, None, None
    for n, raw in enumerate(lines, 1):
        line = strip_comment(raw.rstrip("\n")).rstrip()
        if not line.strip(): continue
        where = f"{name}:{n}"
        if "\t" in raw[:len(raw) - len(raw.lstrip())]: raise ValueError(f"{where}: tab indent")
        ind = len(line) - len(line.lstrip())
        body = line.strip()
        if ind == 0:
            m = re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", body)
            if not m: raise ValueError(f"{where}: expected 'key: value'")
            k, v = m.group(1), m.group(2)
            if v is None or v == "":
                doc[k] = []; cur_list, cur_item = doc[k], None
            else:
                doc[k] = scalar(v, where); cur_list = cur_item = None
            continue
        if cur_list is None: raise ValueError(f"{where}: indented line outside a list")
        if body.startswith("- "):
            rest = body[2:].strip()
            if rest[:1] in "\"'" or not re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", rest):
                cur_list.append(scalar(rest, where)); cur_item = None; continue
            cur_item = {}; cur_list.append(cur_item); body = rest
        elif cur_item is None: raise ValueError(f"{where}: list item must start with '- '")
        m = re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", body)
        if not m: raise ValueError(f"{where}: expected 'key: value' in list item")
        cur_item[m.group(1)] = scalar(m.group(2) or "", where)
    return doc


def load_yaml(path):
    return load_yaml_lines(open(path, encoding="utf-8").read().split("\n"), os.path.basename(path))


# ---- task files ----
def split(text):
    """-> (frontmatter lines, body text). No frontmatter → ([], text)."""
    L = text.split("\n")
    if L and L[0].strip() == "---":
        for i in range(1, len(L)):
            if L[i].strip() == "---": return L[1:i], "\n".join(L[i+1:])
    return [], text


def read(path):
    """-> (frontmatter dict, body). Raises ValueError on a broken frontmatter."""
    fm, body = split(open(path, encoding="utf-8", errors="replace").read())
    d = load_yaml_lines(fm, os.path.basename(path)) if fm else {}
    d.setdefault("name", os.path.basename(path)[:-3])
    return d, body


def reports(body):
    """The report section (after `## Reports`), else the whole body."""
    i = body.find("\n" + REPORTS)
    return body[i + 1:] if i >= 0 else body


def qv(v):
    v = "" if v is None else str(v)
    if v in ("true", "false") or re.fullmatch(r"-?\d+|\[.*\]", v): return v
    return json.dumps(v, ensure_ascii=False) if (v == "" or re.search(r"[\s/#:\"'\[\]{},]", v)) else v


def write_atomic(path, text):
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + f".{os.getpid()}.tmp")
    open(tmp, "w", encoding="utf-8").write(text); os.replace(tmp, path)


def set_fields(path, kv):
    text = open(path, encoding="utf-8").read()
    fm, body = split(text)
    for k, v in kv:
        line = f"{k}: {qv(v)}"
        i = next((n for n, l in enumerate(fm) if re.match(rf"{re.escape(k)}:(\s|$)", l)), None)
        if i is not None:
            # drop an old block value (indented lines) under a scalar we now set
            j = i + 1
            while j < len(fm) and (fm[j].startswith(" ") or fm[j].startswith("\t")): j += 1
            fm[i:j] = [line]
        else:
            fm.append(line)
    write_atomic(path, "---\n" + "\n".join(fm) + "\n---\n" + body)


def append_report(path, lines):
    text = open(path, encoding="utf-8").read()
    if "\n" + REPORTS not in text: text = text.rstrip("\n") + f"\n\n{REPORTS}\n"
    write_atomic(path, text.rstrip("\n") + "\n" + "\n".join(lines) + "\n")


def list_tasks(cosdir):
    out = []
    d = os.path.join(cosdir, "tasks")
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.endswith(".md") and not f.startswith("."):
            p = os.path.join(d, f)
            try: fm, _ = read(p)
            except Exception as e: fm = {"name": f[:-3], "status": f"broken: {e}"}
            out.append((p, fm))
    return out


def new(path, name, to, frm="chief", status="open", extra=(), charter_text=""):
    import datetime as dt
    fm = [("name", name), ("to", to), ("from", frm), ("status", status), *extra]
    have = {k for k, _ in fm}
    for key, pat in (("parent_goal", r"[Pp]arent [Gg]oal"), ("task_goal", r"[Tt]ask [Gg]oal"), ("done_means", r"[Dd]one [Mm]eans")):
        m = re.search(rf"(?m)^[-*\s]*\**{pat}\**:\**\s*(.+?)\s*$", charter_text)
        if m and key not in have:   # lift the charter header so the queue/next.sh read it without parsing the body
            fm.append((key, re.match(r"[A-Za-z0-9]+", m.group(1)).group(0) if key == "parent_goal" and re.match(r"[A-Za-z0-9]+", m.group(1)) else m.group(1)))
    if not any(k == "created" for k, _ in fm): fm.append(("created", dt.datetime.now().strftime("%Y-%m-%d %H:%M")))
    head = "\n".join(f"{k}: {qv(v)}" for k, v in fm)
    body = charter_text.rstrip("\n") + f"\n\n{REPORTS}\n"
    write_atomic(path, f"---\n{head}\n---\n{body}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: print(__doc__); sys.exit(2)
    cmd = a[0]
    if cmd == "get":
        fm, _ = read(a[1]); v = fm.get(a[2])
        print("" if v is None or v == [] else (json.dumps(v) if isinstance(v, (list, dict)) else str(v).lower() if isinstance(v, bool) else v))
    elif cmd == "set":
        set_fields(a[1], list(zip(a[2::2], a[3::2])))
    elif cmd == "report":
        append_report(a[1], a[2:])
    elif cmd == "json":
        print(json.dumps(read(a[1])[0], ensure_ascii=False))
    elif cmd == "list":
        for p, fm in list_tasks(a[1]): print(f"{fm.get('name')}\t{fm.get('status')}\t{fm.get('to') or ''}\t{p}")
    elif cmd == "new":
        o = {"--name": None, "--to": None, "--from": "chief", "--status": "open", "--charter": None}
        extra, i = [], 2
        while i < len(a):
            if a[i] in o: o[a[i]] = a[i+1]; i += 2
            elif "=" in a[i]: k, v = a[i].split("=", 1); extra.append((k, v)); i += 1
            else: print(f"bad arg {a[i]}", file=sys.stderr); sys.exit(2)
        ct = open(o["--charter"], encoding="utf-8").read() if o["--charter"] else ""
        new(a[1], o["--name"], o["--to"], o["--from"], o["--status"], extra, ct)
    else:
        print(__doc__); sys.exit(2)
