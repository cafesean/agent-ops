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
  tasks.py set-if FILE --if K V [--if K V]... KEY VALUE [K V]...
                                        compare-and-set: write only while every --if K still equals V, else exit 3
                                        (queue-run.sh: never reopen a task another process set running meanwhile)
  tasks.py report FILE LINE...          append lines under `## Reports`
  tasks.py set-ask FILE ID KEY VALUE... set keys on one ask item in place (asks.py uses it)
  tasks.py json FILE                    frontmatter as JSON
  tasks.py list COSDIR                  name<TAB>status<TAB>to<TAB>path for every task file
  tasks.py new FILE --name N --to P [--from F] [--status S] [--model M] [--dir D] [--charter C] [K=V]...
"""
import json, os, re, sys

OPEN, CLOSED = ("open",), ("done", "failed", "parked", "stopped")
LIVE = ("claimed", "running")
REPORTS = "## Reports"
JOINED = ("steps", "options")   # ask keys whose value is ONE " | " string; a worker's ["a", "b"] is joined


# ---- minimal YAML subset (stdlib only): top-level scalars, flow lists, block lists of flat maps or scalars ----
def scalar(v, where):
    v = v.strip()
    if v in ("", "~", "null"): return None
    if v.startswith("["):
        if not v.endswith("]"): raise ValueError(f"{where}: unclosed [")
        inner = v[1:-1].strip()
        # \s* first: a quoted item after ", " must match whole, not as `[^,]+` up to its first inner comma
        return [scalar(x, where) for x in re.findall(r'\s*(?:"(?:[^"\\]|\\.)*"|\'[^\']*\'|[^,]+)', inner) if x.strip()] if inner else []
    if v.startswith('"'):
        try: return json.loads(v)
        except Exception: return dquoted(v, where)
    if v.startswith("'"):
        if not v.endswith("'") or len(v) < 2: raise ValueError(f"{where}: bad single-quoted string")
        return v[1:-1].replace("''", "'")
    if v in ("true", "false"): return v == "true"
    if re.fullmatch(r"-?\d+", v): return int(v)
    return v


YESC = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
        "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\u2028", "P": "\u2029"}


def dquoted(v, where):
    """YAML double-quoted string that json.loads refused: YAML escapes (\\x41, \\e, \\_ …), and a stray `\\'` or other
    unknown escape kept as its character — workers' shell/JS writers emit those."""
    bad = ValueError(f"{where}: bad double-quoted string")
    out, i, end = [], 1, len(v) - 1
    if end < 1 or v[end] != '"': raise bad
    while i < end:
        c = v[i]
        if c == '"': raise bad
        if c == "\\":
            i += 1
            if i >= end: raise bad   # the closing quote is escaped
            e = v[i]
            if e in "xuU":
                k = {"x": 2, "u": 4, "U": 8}[e]
                try: out.append(chr(int(v[i + 1:i + 1 + k], 16)))
                except ValueError: raise bad
                i += k
            else: out.append(YESC.get(e, e))
        else: out.append(c)
        i += 1
    return "".join(out)


def strip_comment(line):
    q, esc = None, False
    for i, c in enumerate(line):
        if esc: esc = False
        elif q:
            if c == "\\" and q == '"': esc = True   # `\"` inside "…" does not close it
            elif c == q: q = None
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
        v = scalar(m.group(2) or "", where)
        if m.group(1) in JOINED and isinstance(v, list): v = " | ".join(str(x) for x in v)   # ask flow list → house " | " string
        cur_item[m.group(1)] = v
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


def ask_spans(fm):
    """-> [(start, end, item_indent, id)] for each item of the top-level `asks:` block list (frontmatter line indexes)."""
    i = next((n for n, l in enumerate(fm) if re.match(r"asks:\s*$", l)), None)
    if i is None: return []
    out, j = [], i + 1
    while j < len(fm) and (not fm[j].strip() or fm[j][:1] in " \t"):
        m = re.match(r"(\s+)- ", fm[j])
        if m:
            k = j + 1
            while k < len(fm) and (not fm[k].strip() or (fm[k][:1] in " \t" and not re.match(re.escape(m.group(1)) + r"- ", fm[k]))): k += 1
            iid = next((re.sub(r"^\s*(- )?id:\s*", "", fm[n]).strip().strip("\"'") for n in range(j, k)
                        if re.match(r"\s*(- )?id:\s", fm[n])), None)
            out.append((j, k, len(m.group(1)) + 2, iid)); j = k
        else: j += 1
    return out


def set_ask(path, ask_id, kv):
    """Set keys on ONE ask item in place (the rest of the file untouched). Returns False when the id is not found."""
    text = open(path, encoding="utf-8").read()
    fm, body = split(text)
    span = next((s for s in ask_spans(fm) if s[3] == str(ask_id)), None)
    if not span: return False
    a, b, ind, _ = span
    while b > a + 1 and not fm[b - 1].strip(): b -= 1   # keep blank lines after the item outside it
    for k, v in kv:
        line = " " * ind + f"{k}: {qv(v)}"
        n = next((n for n in range(a, b) if re.match(rf"\s*(- )?{re.escape(k)}:(\s|$)", fm[n])), None)
        if n is None: fm.insert(b, line); b += 1
        elif fm[n].lstrip().startswith("- "): fm[n] = " " * (ind - 2) + "- " + line.lstrip()
        else: fm[n] = line
    write_atomic(path, "---\n" + "\n".join(fm) + "\n---\n" + body)
    return True


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
            except Exception as e: fm = {"status": f"broken: {e}"}
            # identity = the file name, as every script opens tasks/<name>.md. A successor file copied from its
            # predecessor can keep the old `name:` and would pass as the parked worker.
            fm["name"] = f[:-3]
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
    elif cmd == "set-if":
        conds, i = [], 2
        while i < len(a) and a[i] == "--if": conds.append((a[i+1], a[i+2])); i += 3
        fm, _ = read(a[1])
        cur = lambda k: "" if fm.get(k) is None else str(fm.get(k)).lower() if isinstance(fm.get(k), bool) else str(fm.get(k))
        bad = [f"{k}={cur(k)!r} (want {v!r})" for k, v in conds if cur(k) != v]
        if bad: print("set-if: unchanged, " + "; ".join(bad), file=sys.stderr); sys.exit(3)
        set_fields(a[1], list(zip(a[i::2], a[i+1::2])))
    elif cmd == "report":
        append_report(a[1], a[2:])
    elif cmd == "set-ask":
        if not set_ask(a[1], a[2], list(zip(a[3::2], a[4::2]))): print(f"no ask {a[2]} in {a[1]}", file=sys.stderr); sys.exit(1)
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
