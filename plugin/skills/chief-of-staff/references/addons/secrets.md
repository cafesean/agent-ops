# Add-on: secrets — use keys, never read them

The rule is core; the vault is optional. The chief and every worker can USE a key; none of them ever READS one. No secret value passes through a tool's output, a task file, a report line, a charter or a chat. Put this line in every subagent brief.

## How a session gets a key
Use the bundled key proxy, `scripts/addons/keyproxy/`. Full detail: [keyproxy.md](keyproxy.md). It listens on `127.0.0.1` and adds the key to each call. Its store belongs to a separate service user, so agents can use a key but can never read it.

| Step | Who | Command |
|---|---|---|
| Install (once) | the user, sudo | `sudo bash <plugin>/skills/chief-of-staff/scripts/addons/keyproxy/install.sh` |
| Add a route + key | the user, sudo | `sudo <python3> -I "<code dir>/keyproxy-set.py" <route> --new --upstream https://<api host>[/base] --auth bearer\|header\|basic\|query --test /<path>` |
| Rotate | the user, sudo | same command without `--new` |
| Use | any agent | `curl -s http://127.0.0.1:8787/<route>/<path>`, or point an SDK at it: `OPENAI_BASE_URL=http://127.0.0.1:8787/<route>` |
| Check | anyone | `keyproxy-health` (route names + ok; exit 2 when down) |

`install.sh` prints the exact python path and code dir. The value comes from a hidden prompt, from stdin, or with `--clipboard` (macOS). The command prints only `saved <route> (length N)`.

| Need | Do | Never |
|---|---|---|
| An API key for a vendor | A proxy route, as above | Read the key, export it in the chat, paste it |
| Any other secret (DB URL, cloud creds) | A wrapper that puts the value into one command's env and redacts it from output | `cat`/`grep` on secrets files or `.env*`, keychain dump commands |
| Check a key exists | By route name in `/_health`, or by length | Print it "to check" |

Honest limits: loopback only, same machine. A user with sudo/root can still read the store. Any local process can spend a configured key. The bundled proxy is macOS only. On Linux and Windows leave `COS_VAULT_PORT` unset and rely on the rule above: inject a value into one command's env, never read or print it.

## Add or rotate a key — the user only
The user types secrets at a hidden prompt in their own terminal. The chief may open a pane or print the command, but never runs `sudo`. Never ask the user to paste values into chat.

## Tasks that need the vault
Set `COS_VAULT_PORT=8787` (the proxy's port) in `config.env`. `needs: [vault]` in a task's frontmatter → `queue-run.sh` claims it only where `http://127.0.0.1:$COS_VAULT_PORT/_health` answers `"ok": true`. Otherwise the task stays `open` with a note and the next run retries. Any proxy with that health shape works in place of the bundled one.

## Guard hook
A PreToolUse guard that denies reads of secrets files, `.env*`, token files and env dumps (and names the safe alternative) backs this rule up. It arms only in sessions started after the hook is installed. A block is asked about once; never probe it with variations. A hook is a heuristic; the guarantee is a vault the agent's OS user cannot read.

## Claude account tokens
See `accounts.md`: extra logins live in the OS keychain; only the id is ever written anywhere.
