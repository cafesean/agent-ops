#!/usr/bin/env python3
"""keyproxy — a loopback HTTP proxy that holds API keys agents may USE but never READ.

Runs as a dedicated service user (install.sh), so its store is unreadable by the agent's OS user.
Callers send:
    http://127.0.0.1:<port>/<route>/<upstream path>   ->  <route upstream>/<upstream path>
and the proxy adds the credential server-side. GET /_health -> {"ok": true, "routes": [names]}.

Store (JSON, mode 600, owned by the service user):
    {"routes": {"<name>": {"upstream": "https://api.example.com/v1", "auth": "bearer|header|basic|query",
                           "header": "X-Api-Key", "param": "api_key", "user": "<user>", "secret": "<secret>"}}}

Stdlib only. Env: KEYPROXY_STORE, KEYPROXY_PORT (8787), KEYPROXY_LOG_DIR, KEYPROXY_TIMEOUT (120 s),
KEYPROXY_TEST_UPSTREAMS (tests only: JSON map "https://host" -> "http://127.0.0.1:port").
Never logs headers, query strings, bodies or secrets.
"""
import base64
import http.server
import json
import os
import re
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

STORE = os.environ.get("KEYPROXY_STORE", "/var/lib/agent-ops-keyproxy/store.json")
PORT = int(os.environ.get("KEYPROXY_PORT", "8787"))
LOG_DIR = os.environ.get("KEYPROXY_LOG_DIR", "/var/log/agent-ops-keyproxy")
TIMEOUT = float(os.environ.get("KEYPROXY_TIMEOUT", "120"))
TEST_UPSTREAMS = json.loads(os.environ.get("KEYPROXY_TEST_UPSTREAMS", "{}") or "{}")
MAX_BODY = 32 * 1024 * 1024
REDACTED = b"[redacted]"
AUTHS = ("bearer", "header", "basic", "query")
ROUTE_RE = re.compile(r"^/([a-z0-9][a-z0-9_-]{0,63})(/[^?]*)?(\?.*)?$")
HOP = {"host", "connection", "keep-alive", "proxy-connection", "te", "trailer", "trailers", "transfer-encoding",
       "upgrade", "content-length", "accept-encoding", "origin", "referer", "forwarded"}
CRED_HDR = re.compile(r"auth|api-?key|token|secret|cookie|passw|session", re.I)
BAD_ENC = ("%2e", "%2f", "%5c", "%00", "%25", "%0d", "%0a")

_lock = threading.Lock()
_store = {"routes": {}}
_mtime = None


def load_store():
    """Reload the store when its mtime changes; keep the previous copy if the new one is broken."""
    global _store, _mtime
    try:
        m = os.stat(STORE).st_mtime_ns
    except OSError:
        return _store
    if m != _mtime:
        with _lock:
            try:
                with open(STORE) as f:
                    data = json.load(f)
                if not isinstance(data.get("routes"), dict):
                    raise ValueError("no routes object")
                _store, _mtime = data, m
            except (OSError, ValueError) as e:
                sys.stderr.write(f"keyproxy: store not reloaded ({type(e).__name__}); keeping the previous one\n")
    return _store


def routes():
    return {k: v for k, v in (load_store().get("routes") or {}).items() if isinstance(v, dict)}


def secrets_of(cfg):
    """Every form of the route's secret that could appear in a response."""
    s = cfg.get("secret") or ""
    out = {s, urllib.parse.quote(s, safe=""), urllib.parse.quote_plus(s)}
    if cfg.get("auth") == "basic":
        out.add(base64.b64encode(f"{cfg.get('user', '')}:{s}".encode()).decode())
    return sorted((x.encode() for x in out if x and len(x) >= 8), key=len, reverse=True)


def scrub(b, secrets):
    for s in secrets:
        b = b.replace(s, REDACTED)
    return b


def audit(route, method, path, status, nbytes, ms):
    line = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "route": route, "method": method,
                       "path": path.split("?", 1)[0][:300], "status": status, "bytes": nbytes, "ms": ms})
    try:
        with open(os.path.join(LOG_DIR, "audit.log"), "a") as f:
            f.write(line + "\n")
    except OSError:
        sys.stderr.write(line + "\n")


def safe_target(raw):
    """True when the request target is a plain origin-form path with no traversal or encoding tricks."""
    if not raw.startswith("/") or raw.startswith("//"):
        return False
    if any(c < "!" or c > "~" for c in raw) or "\\" in raw or "#" in raw:
        return False
    path = raw.split("?", 1)[0]
    if any(e in path.lower() for e in BAD_ENC):
        return False
    return not any(seg in (".", "..") for seg in path.split("/"))


def build_url(cfg, rest, query):
    """Upstream URL; raises ValueError unless it stays on the route's own scheme + host."""
    base = cfg.get("upstream") or ""
    b = urllib.parse.urlsplit(base)
    if b.scheme != "https" or not b.hostname or b.username or b.password or b.query or b.fragment:
        raise ValueError("route upstream must be a plain https://host[/base] URL")
    base = TEST_UPSTREAMS.get(f"{b.scheme}://{b.netloc}", f"{b.scheme}://{b.netloc}") + b.path.rstrip("/")
    q = urllib.parse.parse_qsl(query.lstrip("?"), keep_blank_values=True) if query else []
    if cfg.get("auth") == "query":
        p = cfg.get("param") or "api_key"
        q = [(k, v) for k, v in q if k != p] + [(p, cfg.get("secret", ""))]
    url = base + rest + ("?" + urllib.parse.urlencode(q) if q else "")
    u, want = urllib.parse.urlsplit(url), urllib.parse.urlsplit(base)
    if (u.scheme, u.netloc) != (want.scheme, want.netloc) or not u.path.startswith(want.path):
        raise ValueError("target left the route's upstream")
    return url


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the 3xx goes back to the caller, the credential never goes anywhere else."""
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "keyproxy/1"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):  # the audit log replaces the access log
        pass

    def send_json(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)
        return status, len(b)

    def do_GET(self): self.handle_any()
    def do_HEAD(self): self.handle_any()
    def do_POST(self): self.handle_any()
    def do_PUT(self): self.handle_any()
    def do_PATCH(self): self.handle_any()
    def do_DELETE(self): self.handle_any()

    def refuse(self):
        """403 reason for anything that is not a local, non-browser client; None when fine."""
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return "local only"
        host = (self.headers.get("Host") or "").lower()
        if host not in (f"127.0.0.1:{PORT}", f"localhost:{PORT}", "127.0.0.1", "localhost"):
            return "bad Host header"
        site = (self.headers.get("Sec-Fetch-Site") or "none").lower()
        if self.headers.get("Origin") is not None or site not in ("none", "same-origin"):
            return "keyproxy serves local tools, not browsers"
        return None

    def handle_any(self):
        t0, route, status, nbytes = time.time(), "-", 500, 0
        secrets = []
        try:
            why = self.refuse()
            if why:
                status, nbytes = self.send_json(403, {"error": why})
                return
            if not safe_target(self.path):
                status, nbytes = self.send_json(400, {"error": "bad path"})
                return
            if self.path == "/_health":
                status, nbytes = self.send_json(200, {"ok": True, "routes": sorted(routes())})
                return
            m = ROUTE_RE.match(self.path)
            if not m:
                status, nbytes = self.send_json(404, {"error": "use /<route>/<path>; GET /_health lists routes"})
                return
            route, rest, query = m.group(1), m.group(2) or "/", m.group(3) or ""
            cfg = routes().get(route)
            if not cfg:
                status, nbytes = self.send_json(404, {"error": "unknown route"})
                return
            if cfg.get("auth") not in AUTHS or not cfg.get("secret"):
                status, nbytes = self.send_json(500, {"error": "route misconfigured (auth or secret)"})
                return
            secrets = secrets_of(cfg)
            try:
                url = build_url(cfg, rest, query)
            except ValueError as e:
                status, nbytes = self.send_json(400, {"error": str(e)})
                return
            status, nbytes = self.forward(cfg, url, secrets)
        except Exception as e:  # never echo request data; scrub the reason anyway
            msg = scrub(f"keyproxy: {type(e).__name__}".encode(), secrets).decode("utf-8", "replace")
            try:
                status, nbytes = self.send_json(502, {"error": msg})
            except Exception:
                status = 502
        finally:
            audit(route, self.command, self.path, status, nbytes, int((time.time() - t0) * 1000))

    def read_body(self):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("chunked request bodies are not supported; send Content-Length")
        n = int(self.headers.get("Content-Length") or 0)
        if n < 0 or n > MAX_BODY:
            raise ValueError("body too large")
        return self.rfile.read(n) if n else None

    def forward(self, cfg, url, secrets):
        body = self.read_body()
        req = urllib.request.Request(url, data=body, method=self.command)
        drop = {h.strip().lower() for h in (self.headers.get("Connection") or "").split(",")}
        own = (cfg.get("header") or "").lower()
        for k, v in self.headers.items():
            kl = k.lower()
            if kl in HOP or kl in drop or kl == own or kl.startswith(("sec-", "x-forwarded", "proxy-")) \
                    or CRED_HDR.search(kl):
                continue
            req.add_header(k, v)
        req.add_header("Accept-Encoding", "identity")  # scrubbing needs plain bytes
        if not req.has_header("User-agent"):
            req.add_header("User-Agent", "keyproxy/1")
        auth, secret = cfg["auth"], cfg["secret"]
        if auth == "bearer":
            req.add_unredirected_header("Authorization", "Bearer " + secret)
        elif auth == "basic":
            token = base64.b64encode(f"{cfg.get('user', '')}:{secret}".encode()).decode()
            req.add_unredirected_header("Authorization", "Basic " + token)
        elif auth == "header":
            req.add_unredirected_header(cfg.get("header") or "X-Api-Key", secret)
        try:
            resp = OPENER.open(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            resp = e  # 4xx/5xx and unfollowed 3xx: pass through, scrubbed
        code = getattr(resp, "status", None) or resp.code
        self.send_response(code)
        for k, v in resp.headers.items():
            if k.lower() not in HOP | {"set-cookie", "server", "date"}:
                self.send_header(k, scrub(v.encode("latin-1", "replace"), secrets).decode("latin-1"))
        self.end_headers()
        if self.command == "HEAD":
            return code, 0
        keep = max((len(s) for s in secrets), default=1) - 1  # hold back so a split secret is still caught
        buf, total = b"", 0
        while True:
            chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
            buf = scrub(buf + chunk, secrets)
            if not chunk:
                self.wfile.write(buf)
                return code, total + len(buf)
            cut = len(buf) - keep
            if cut > 0:
                self.wfile.write(buf[:cut])
                self.wfile.flush()
                total += cut
                buf = buf[cut:]


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.umask(0o077)
    load_store()
    srv = Server(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"keyproxy listening on 127.0.0.1:{PORT}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
