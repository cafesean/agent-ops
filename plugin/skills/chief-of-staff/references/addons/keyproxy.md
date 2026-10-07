# Add-on: keyproxy — the bundled key proxy

A loopback HTTP proxy (stdlib Python 3, no dependencies) that holds API keys. Agents call it and it adds the key; the key store belongs to a separate service user, so the agent's OS user cannot read it. Code: `scripts/addons/keyproxy/`.

## Install (the user, once, with sudo)
```
sudo bash <plugin>/skills/chief-of-staff/scripts/addons/keyproxy/install.sh [--port 8787]
```
**macOS only.** On Linux and Windows `install.sh` refuses and the add-on stays off; use another secret store there (see `secrets.md`).

| | macOS |
|---|---|
| Service user | `_agentops_keyproxy` (hidden, no shell) |
| Service | LaunchDaemon `com.agent-ops.keyproxy` |
| Code (root-owned) | `/Library/Application Support/agent-ops-keyproxy` |
| Store | `/var/lib/agent-ops-keyproxy/store.json` (dir 700, file 600, service user) |
| Audit log | `/var/log/agent-ops-keyproxy/audit.log` (readable; no secrets) |

Safe to re-run: it updates the code and restarts the service; the store's keys stay. `--uninstall` removes service and code and keeps the store; `--uninstall --purge` also deletes store, logs and service user.

Then set `COS_VAULT_PORT=8787` (or your `--port`) in `config.env`.

## Add or rotate a key (the user)
```
sudo <python3> -I "<code dir>/keyproxy-set.py" llm --new --upstream https://api.example.com/v1 --auth bearer --test /models
sudo <python3> -I "<code dir>/keyproxy-set.py" llm               # rotate: same route, new value
```
`install.sh` prints the exact python path and code dir. The value comes from a hidden prompt; or stdin when piped; or `--clipboard` (macOS: reads, then clears the clipboard). Empty, short (<8) and multi-part values are refused. The old value moves to `_archive` in the store. Output is only `saved <route> (length N)` plus the test call's HTTP status.

| `--auth` | Sends | Extra flag |
|---|---|---|
| `bearer` | `Authorization: Bearer <secret>` | — |
| `header` | `<NAME>: <secret>` | `--header NAME` (default `X-Api-Key`) |
| `basic` | `Authorization: Basic base64(user:secret)` | `--user NAME` |
| `query` | `?<param>=<secret>` | `--param NAME` (default `api_key`) |

## Use it (agents)
```
curl -s http://127.0.0.1:8787/llm/models
OPENAI_BASE_URL=http://127.0.0.1:8787/llm OPENAI_API_KEY=unused <cmd>
```
Any SDK with a base-URL setting works the same way. Give it a dummy key if it insists on one; the proxy drops the caller's auth headers and adds its own.

## Health
`keyproxy-health [port]` prints `ok` + route names, exit 0; exit 2 when it is down. `GET /_health` returns `{"ok": true, "routes": [...]}` (names only). `queue-run.sh` uses it for `needs: [vault]`; `doctor.sh` reports it when `COS_VAULT_PORT` is set.

## What it enforces
- Binds `127.0.0.1` only. Rejects a wrong `Host` header (DNS rebinding) and browser requests (`Origin`, or `Sec-Fetch-Site` other than `none`/`same-origin`).
- Path is `/<route>/<path>`. Absolute URLs, `..`, `.`, backslashes, control characters and encoded tricks (`%2e %2f %5c %00 %25 %0d %0a`) get 400. The built URL must keep the route's own https host, or it is refused.
- Drops the caller's credential headers (`Authorization`, cookies, anything named like key/token/secret/auth), hop-by-hop headers and `Sec-*`/`X-Forwarded-*`.
- Never follows redirects: the 3xx goes back to the caller, so the key never goes to another host.
- Replaces the route's secret (raw, URL-encoded, and Basic-encoded) in response bodies and headers with `[redacted]`, also across stream chunks. Error replies carry only an exception type.
- Audit log line per call: route, method, path without query, status, bytes, ms. No headers, queries or bodies.
- Reloads the store when its mtime changes. Upstream timeout 120 s (`KEYPROXY_TIMEOUT`). Request bodies need `Content-Length` (max 32 MB).

## Honest limits
- Same machine, loopback only. A remote worker needs its own proxy.
- A user with sudo/root can still read the store. This stops agents and their scripts, not an administrator.
- Any local process can USE a configured route. Only add keys you are happy for local tools to spend.
- Gzip responses (an upstream ignoring `Accept-Encoding: identity`) pass through unscrubbed.
- macOS only. The install path has not been CI-tested under sudo; the daemon and `keyproxy-set.py` are covered by `test_keyproxy.py`.
