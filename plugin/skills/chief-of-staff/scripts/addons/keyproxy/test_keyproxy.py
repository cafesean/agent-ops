#!/usr/bin/env python3
"""Tests for keyproxy.py + keyproxy-set.py: a fake local upstream, dummy keys only. Run: python3 test_keyproxy.py"""
import base64
import http.client
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "sk-test-0000-bearer"
HDR_KEY = "sk-test-0000-header"
BASIC_KEY = "sk-test-0000-basic"
Q_KEY = "sk-test-0000-query"
ALL_KEYS = (KEY, HDR_KEY, BASIC_KEY, Q_KEY)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Upstream(http.server.BaseHTTPRequestHandler):
    """Echoes what it received; a few paths misbehave on purpose."""
    def log_message(self, *a):
        pass

    def do_GET(self):
        if "/redirect" in self.path:
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.other}/steal")
            self.end_headers()
            return
        if "/leak" in self.path:
            body = f"oops your key is {KEY} and again {KEY}".encode()
            self.send_response(500)
        else:
            Upstream.last = {"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}}
            body = json.dumps(Upstream.last).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET


class Thief(http.server.BaseHTTPRequestHandler):
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        Thief.hits.append(dict(self.headers))
        self.send_response(200)
        self.end_headers()


class KeyproxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.thief = http.server.HTTPServer(("127.0.0.1", 0), Thief)
        cls.up = http.server.HTTPServer(("127.0.0.1", 0), Upstream)
        cls.up.other = cls.thief.server_port
        for s in (cls.up, cls.thief):
            threading.Thread(target=s.serve_forever, daemon=True).start()
        up = f"http://127.0.0.1:{cls.up.server_port}"
        cls.store = os.path.join(cls.tmp, "store.json")
        routes = {
            "bear": {"upstream": "https://api.test.invalid/v1", "auth": "bearer", "secret": KEY},
            "hdr": {"upstream": "https://hdr.test.invalid", "auth": "header", "header": "X-Api-Key", "secret": HDR_KEY},
            "bas": {"upstream": "https://bas.test.invalid", "auth": "basic", "user": "demo", "secret": BASIC_KEY},
            "qry": {"upstream": "https://qry.test.invalid", "auth": "query", "param": "key", "secret": Q_KEY},
        }
        with open(cls.store, "w") as f:
            json.dump({"routes": routes}, f)
        os.chmod(cls.store, 0o600)
        cls.port = free_port()
        env = dict(os.environ, KEYPROXY_STORE=cls.store, KEYPROXY_PORT=str(cls.port), KEYPROXY_LOG_DIR=cls.tmp,
                   KEYPROXY_TIMEOUT="10", KEYPROXY_TEST_UPSTREAMS=json.dumps(
                       {f"https://{h}.test.invalid": up for h in ("api", "hdr", "bas", "qry")}))
        cls.proc = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "keyproxy.py")], env=env,
                                    stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                if cls.get("/_health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait()
        cls.up.shutdown()
        cls.thief.shutdown()

    @classmethod
    def get(cls, path, headers=None, method="GET"):
        c = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=10)
        c.request(method, path, headers=headers or {})
        r = c.getresponse()
        return r.status, r.read().decode(), dict(r.getheaders())

    def raw(self, request_bytes):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        s.sendall(request_bytes)
        out = b""
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
        s.close()
        return out.decode("latin-1")

    def echo(self, path, headers=None):
        st, body, _ = self.get(path, headers)
        self.assertEqual(st, 200, body)
        return Upstream.last  # what the upstream got (the reply to the caller is redacted)

    # ---- auth styles ----
    def test_bearer(self):
        j = self.echo("/bear/models?limit=2")
        self.assertEqual(j["headers"]["authorization"], "Bearer " + KEY)
        self.assertEqual(j["path"], "/v1/models?limit=2")

    def test_header(self):
        self.assertEqual(self.echo("/hdr/x")["headers"]["x-api-key"], HDR_KEY)

    def test_basic(self):
        want = "Basic " + base64.b64encode(f"demo:{BASIC_KEY}".encode()).decode()
        self.assertEqual(self.echo("/bas/x")["headers"]["authorization"], want)

    def test_query(self):
        j = self.echo("/qry/search?q=1&key=client-supplied")
        self.assertIn(f"key={Q_KEY}", j["path"])
        self.assertNotIn("client-supplied", j["path"])
        self.assertIn("q=1", j["path"])

    def test_client_auth_stripped(self):
        j = self.echo("/hdr/x", {"Authorization": "Bearer stolen-xyz", "Cookie": "a=b", "X-Auth-Token": "t"})
        for h in ("authorization", "cookie", "x-auth-token"):
            self.assertNotIn(h, j["headers"])
        j = self.echo("/bear/x", {"Authorization": "Bearer client-value"})
        self.assertEqual(j["headers"]["authorization"], "Bearer " + KEY)

    # ---- request guards ----
    def test_path_tricks_rejected(self):
        for p in ("/bear/../etc", "/bear/a/%2e%2e/b", "/bear/a%2fb", "/bear/%252e", "/bear/a\\b", "//evil.test/x",
                  "/bear/./x", "/bear/a%00", "/bear/a%0d%0a"):
            st, body, _ = self.get(p)
            self.assertIn(st, (400, 404), p)
        out = self.raw(b"GET http://evil.test/x HTTP/1.0\r\nHost: 127.0.0.1:%d\r\n\r\n" % self.port)
        self.assertIn(" 400 ", out.split("\r\n")[0])
        out = self.raw(b"GET /bear/a\tb HTTP/1.0\r\nHost: 127.0.0.1:%d\r\n\r\n" % self.port)
        self.assertIn(" 400 ", out.split("\r\n")[0])

    def test_unknown_route(self):
        self.assertEqual(self.get("/nope/x")[0], 404)

    def test_browser_and_host_rejected(self):
        self.assertEqual(self.get("/bear/x", {"Origin": "https://evil.test"})[0], 403)
        self.assertEqual(self.get("/bear/x", {"Sec-Fetch-Site": "cross-site"})[0], 403)
        self.assertEqual(self.get("/bear/x", {"Sec-Fetch-Site": "none"})[0], 200)
        self.assertEqual(self.get("/bear/x", {"Host": "evil.test"})[0], 403)
        self.assertEqual(self.get("/_health", {"Host": f"rebind.test:{self.port}"})[0], 403)

    # ---- responses ----
    def test_health_shape(self):
        st, body, _ = self.get("/_health")
        self.assertEqual(st, 200)
        self.assertIn('"ok": true', body)
        self.assertEqual(json.loads(body)["routes"], ["bas", "bear", "hdr", "qry"])
        for k in ALL_KEYS:
            self.assertNotIn(k, body)

    def test_redirect_not_followed(self):
        Thief.hits.clear()
        st, body, hdrs = self.get("/bear/redirect")
        self.assertEqual(st, 302)
        self.assertEqual(Thief.hits, [])

    def test_response_redacted(self):
        st, body, _ = self.get("/bear/leak")
        self.assertEqual(st, 500)
        self.assertNotIn(KEY, body)
        self.assertIn("[redacted]", body)

    def test_echoed_key_redacted(self):
        st, body, _ = self.get("/hdr/x")
        self.assertNotIn(HDR_KEY, body)

    def test_audit_log_has_no_secrets(self):
        self.get("/qry/search?q=secret-query-value")
        self.get("/bear/x", {"Authorization": "Bearer client-value"})
        time.sleep(0.2)
        with open(os.path.join(self.tmp, "audit.log")) as f:
            log = f.read()
        self.assertIn('"route": "qry"', log)
        for s in ALL_KEYS + ("secret-query-value", "client-value", "Bearer"):
            self.assertNotIn(s, log)

    def test_store_reload(self):
        with open(self.store) as f:
            st = json.load(f)
        st["routes"]["late"] = {"upstream": "https://api.test.invalid", "auth": "bearer", "secret": "sk-test-0000-late"}
        time.sleep(0.05)
        with open(self.store, "w") as f:
            json.dump(st, f)
        self.assertIn("late", json.loads(self.get("/_health")[1])["routes"])


class SetTest(unittest.TestCase):
    def run_set(self, store, args, value):
        env = dict(os.environ, KEYPROXY_STORE=store)
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "keyproxy-set.py")] + args, input=value,
                              capture_output=True, text=True, env=env)

    def test_add_rotate_refuse(self):
        d = tempfile.mkdtemp()
        store = os.path.join(d, "store.json")
        r = self.run_set(store, ["demo", "--new", "--upstream", "https://api.test.invalid", "--auth", "bearer"],
                         "  sk-test-0000-one \n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "saved demo (length 16)")
        self.assertEqual(os.stat(store).st_mode & 0o777, 0o600)
        r = self.run_set(store, ["demo"], "sk-test-0000-two\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("sk-test", r.stdout + r.stderr)
        with open(store) as f:
            st = json.load(f)
        self.assertEqual(st["routes"]["demo"]["secret"], "sk-test-0000-two")
        self.assertIn("sk-test-0000-one", st["_archive"].values())
        for bad in ("", "abc12", "sk-test-0000 sk-test-0001"):
            r = self.run_set(store, ["demo"], bad)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertNotIn(bad or "x-none", r.stdout + r.stderr)
        r = self.run_set(store, ["other"], "sk-test-0000-xyz")
        self.assertNotEqual(r.returncode, 0)
        r = self.run_set(store, ["evil", "--new", "--upstream", "http://plain.test", "--auth", "bearer"], "sk-test-0000")
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
