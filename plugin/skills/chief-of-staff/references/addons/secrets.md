# Add-on: secrets — use keys, never read them

The rule is core; the vault is optional. The chief and every worker can USE a key; none of them ever READS one. No secret value passes through a tool's output, a task file, a report line, a charter or a chat. Put this line in every subagent brief.

## How a session gets a key
| Need | Do | Never |
|---|---|---|
| An API key for a vendor | A local key proxy that adds auth (call `http://127.0.0.1:<port>/<route>/…`), or a wrapper that injects the value into one command's env and redacts it from output | Read the key, export it in the chat, paste it |
| Any other secret (DB URL, cloud creds) | The same injector: `<runner> NAME=<ref> -- <cmd>` | `cat`/`grep` on secrets files or `.env*`, keychain dump commands |
| Check a key exists | By name / length only | Print it "to check" |

## Add or rotate a key — the user only
The user enters secrets at a hidden prompt in their own terminal (the chief may open a pane or print the command). Several secrets → stage them as mode-600 files without printing values, then ONE command imports them all; verify each by name and length; only then delete the staging files. Never ask the user to paste values into chat.

## Tasks that need the vault
`needs: [vault]` in a task's frontmatter → `queue-run.sh` claims it only where the vault's health check (`http://127.0.0.1:$COS_VAULT_PORT/_health`) answers OK; otherwise the task stays `open` with a note and the next run retries.

## Guard hook
A PreToolUse guard that denies reads of secrets files, `.env*`, token files and env dumps (and names the safe alternative) backs this rule up. It arms only in sessions started after the hook is installed. A block is asked about once; never probe it with variations. A hook is a heuristic; the guarantee is a vault the agent's OS user cannot read.

## Claude account tokens
See `accounts.md`: extra logins live in the OS keychain; only the id is ever written anywhere.
