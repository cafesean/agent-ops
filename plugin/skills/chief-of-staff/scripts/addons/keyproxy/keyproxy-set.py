#!/usr/bin/env python3
"""keyproxy-set — add or rotate ONE route's key in the keyproxy store. Run by the USER, never an agent.

    sudo <python3> -I <install dir>/keyproxy-set.py <route> [--clipboard] [--test /path]
    sudo <python3> -I <install dir>/keyproxy-set.py <route> --new --upstream https://api.example.com \
         --auth bearer|header|basic|query [--header NAME] [--param NAME] [--user NAME] [--test /path]

The value comes from a hidden prompt, from stdin when stdin is not a terminal, or with --clipboard from
the macOS clipboard (pbpaste, then cleared). Whitespace is stripped; empty, short (<8) or multi-part
values are refused. The previous value is kept under "_archive". Prints only "saved <route> (length N)"
and, with --test, the HTTP status of one GET through the proxy. Env: KEYPROXY_STORE, KEYPROXY_PORT.
"""
import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_STORE = "/var/lib/agent-ops-keyproxy/store.json"
AUTHS = ("bearer", "header", "basic", "query")


def die(msg):
    print(f"keyproxy-set: {msg}", file=sys.stderr)
    sys.exit(1)


def read_secret(clipboard):
    if clipboard:
        if sys.platform != "darwin":
            die("--clipboard is macOS only; pipe the value on stdin or use the prompt")
        who = os.environ.get("SUDO_USER")
        pre = ["sudo", "-u", who] if who and os.geteuid() == 0 else []
        val = subprocess.run(pre + ["pbpaste"], capture_output=True, text=True).stdout
        subprocess.run(pre + ["pbcopy"], input="", text=True)  # clear the clipboard
        return val
    if sys.stdin.isatty():
        return getpass.getpass("secret (hidden): ")
    return sys.stdin.read()


def check_secret(val):
    val = (val or "").strip()
    if not val:
        die("empty value, nothing saved")
    if len(val) < 8:
        die("value shorter than 8 characters, nothing saved")
    if re.search(r"\s", val):
        die("value has inner whitespace (two values pasted?), nothing saved")
    return val


def check_upstream(url):
    u = urllib.parse.urlsplit(url or "")
    if u.scheme != "https" or not u.hostname or u.username or u.password or u.query or u.fragment:
        die("--upstream must be a plain https://host[/base] URL")
    return url.rstrip("/")


def save(path, store):
    """Atomic write, mode 600, same owner as the existing file (or the store dir)."""
    d = os.path.dirname(path) or "."
    st = os.stat(path) if os.path.exists(path) else os.stat(d)
    tmp = os.path.join(d, f".store.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(store, f, indent=1)
            f.flush()
            os.fsync(f.fileno())
        if os.geteuid() == 0:
            os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def test_call(route, path, port):
    if not path.startswith("/"):
        path = "/" + path
    req = urllib.request.Request(f"http://127.0.0.1:{port}/{route}{path}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, OSError) as e:
        return f"proxy unreachable ({type(e).__name__})"


def main():
    ap = argparse.ArgumentParser(description="add or rotate one keyproxy route key")
    ap.add_argument("route")
    ap.add_argument("--new", action="store_true", help="create the route, or change its settings")
    ap.add_argument("--upstream")
    ap.add_argument("--auth", choices=AUTHS)
    ap.add_argument("--header")
    ap.add_argument("--param")
    ap.add_argument("--user")
    ap.add_argument("--clipboard", action="store_true")
    ap.add_argument("--test", metavar="PATH")
    a = ap.parse_args()
    if not re.match(r"^[a-z0-9][a-z0-9_-]{0,63}$", a.route):
        die("route name: lowercase letters, digits, - and _ only")
    path = os.environ.get("KEYPROXY_STORE", DEFAULT_STORE)
    try:
        with open(path) as f:
            store = json.load(f)
    except FileNotFoundError:
        store = {"routes": {}}
    except (OSError, ValueError) as e:
        die(f"cannot read the store ({type(e).__name__}); run with sudo")
    rts = store.setdefault("routes", {})
    cfg = rts.get(a.route)
    if cfg is None and not a.new:
        die(f"no route {a.route}; create it with --new --upstream URL --auth TYPE")
    if a.new:
        cfg = dict(cfg or {})
        if a.upstream or not cfg.get("upstream"):
            cfg["upstream"] = check_upstream(a.upstream)
        if a.auth or not cfg.get("auth"):
            if not a.auth:
                die("--new needs --auth bearer|header|basic|query")
            cfg["auth"] = a.auth
        for k in ("header", "param", "user"):
            if getattr(a, k):
                cfg[k] = getattr(a, k)
        if cfg["auth"] == "header":
            cfg.setdefault("header", "X-Api-Key")
        if cfg["auth"] == "query":
            cfg.setdefault("param", "api_key")
        if cfg["auth"] == "basic" and not cfg.get("user"):
            die("--auth basic needs --user")
    secret = check_secret(read_secret(a.clipboard))
    if cfg.get("secret") and cfg["secret"] != secret:
        store.setdefault("_archive", {})[f"{a.route}.{time.strftime('%Y%m%dT%H%M%S')}"] = cfg["secret"]
    cfg["secret"] = secret
    rts[a.route] = cfg
    save(path, store)
    print(f"saved {a.route} (length {len(secret)})")
    if a.test:
        time.sleep(0.2)  # the daemon reloads on the next request (mtime check)
        print(f"test GET {a.test}: {test_call(a.route, a.test, os.environ.get('KEYPROXY_PORT', '8787'))}")


if __name__ == "__main__":
    main()
