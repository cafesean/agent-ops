# No hosts, no secrets: genericize on the way in

Plugin repos may be public, and git history is permanent. Everything written into an agent, skill, reference,
script or example is published to every reader. Genericize a lesson before it lands in a plugin file.

| Never write into a plugin file | Write instead | Where the real value belongs |
|---|---|---|
| IP addresses, hostnames, app or API domains | `<host>`, `<host-ip>`, `<app-domain>` | the user's own host inventory |
| SSH users, key file names | `<user>`, `<ssh-key>` | the user's SSH config / inventory |
| cloud account, project, org or resource ids | `<account-id>`, `<project-id>`, `<org-id>` | the user's inventory or env vars |
| tokens, API keys, passwords, including truncated prefixes | `<token>`, `<api-key>`, an env var name | the user's own secret store |
| personal emails, phone numbers, names | `<email>`, `<phone>`, `<owner>` | the user's own notes |
| local checkout paths | `<repo-root>`, `<plugin-root>`, `${CLAUDE_PLUGIN_ROOT}` | the user's config |

## Before and after editing
1. **Before inserting**: scan the text you are about to write (session excerpts, logs, command output) for the
   left column. Replace each hit with a placeholder plus a pointer to where the real value lives.
2. **After editing**: grep each edited file for IPv4 literals, `@` addresses and long high-entropy strings:
   ```bash
   grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}|[A-Za-z0-9_+/=-]{32,}' <file>
   ```
   Every hit is either a placeholder, a documented example, or removed.
3. **Already committed?** A secret that reached a commit is compromised. Tell the user to rotate it first,
   then scrub history. Never quietly delete it and move on.
