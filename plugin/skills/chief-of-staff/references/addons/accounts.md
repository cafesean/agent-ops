# Add-on: multiple Claude logins

Optional. Load-balance workers across more than one Claude login so one account's usage limit does not stop every session. Off when `COS_ACCOUNTS` is empty: the scripts print `addon accounts not configured, skipping`.

Scripts: `${CLAUDE_PLUGIN_ROOT}/skills/chief-of-staff/scripts/addons/account-add.sh`, `account-limit.sh`.

## How it works
- **Default login** (`COS_DEFAULT_ACCOUNT`, e.g. `a`) = the normal Claude Code login, never read by the chief.
- **Extra logins** (`b`, `c`…) = long-lived tokens (`claude setup-token`) the user stores with `account-add.sh <id>` (stdin only; prints length + hash prefix, never the value) in the OS keychain. `--list`, `--remove <id>`.
- spawn.sh's launch script strips inherited `CLAUDE*` env vars and, for a non-default id, reads the keychain item at pane start and exports `CLAUDE_CODE_OAUTH_TOKEN` for that worker only. The token is never in the launch script, task file, `--dry-run` output or a log; only the id is.
- **`--account auto`** (default): `account-limit.sh --pick` over `$COS_DIR/accounts.md` (`| id | status | limited_until | note |`) picks the ok account with the fewest live sessions. All limited → exit 4 with the soonest reset; leave the task open.

## Rules
- **Worker hits the usage limit** → `account-limit.sh <its account> <reset HH:MM>` (`--clear <id>` early), then a successor with `--account auto` and `--continues`. A live session cannot move accounts.
- **Account nears its limit** → tell live sessions on it to stop at a good stopping point and write their handoff. Never kill them. New sessions go to another account. After the reset, resume every session left waiting, each via a successor `--continues`.
- **Never swap the shared default login while workers run**; it changes the login under every default-account pane.
- Changing account on resume is a cache miss; tell the user first.
- Non-default workers may not appear in the Claude app (no remote control); they run in their pane only.
