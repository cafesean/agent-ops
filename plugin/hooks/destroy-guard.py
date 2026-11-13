#!/usr/bin/env python3
"""destroy-guard — PreToolUse(Bash) hook: no inferred deletes.

Rule (chief-of-staff SKILL.md § Critical rules, worker-rules.md § Autonomy): a delete, terminate or destroy of a
server, volume, database, bucket or account runs only after the user's named go — the user's own words, naming that
exact resource, in reply to the question. A statement of intent, a scope clarification or a relayed message is not
the go; a question about a resource gets facts only.

Denies a Bash command that
  (1) sends an HTTP DELETE (`-X DELETE`, `--request DELETE`) to a URL containing one of COS_DESTROY_HTTP_ROUTES
      (space or comma separated, case-insensitive substrings; unset or empty = the public cloud API hosts in
      DEFAULT_ROUTES; `none` = no HTTP check), or
  (2) runs a CLI destroy verb: aws ec2 terminate-instances|delete-volume, aws rds delete-db-instance|cluster,
      aws s3 rb, aws s3api delete-bucket, hcloud server|volume|database|storage-box|network|firewall|ssh-key delete,
      terraform destroy, coolify … delete.
Escape: a line `# user-named-go: <resource id> <the user's exact words>` in the command. The quoted words must name
the resource id and contain a go verb (go, yes, confirm, approve, delete, terminate, destroy); anything else is denied.
The guard catches inference by accident; the rule itself is the control.

Runs through hooks/cos-py.sh (inactive without the agent-ops config). Fails OPEN on any error.
Kill switch COS_DESTROY_GUARD=0.
"""
import json
import os
import re
import sys

DEFAULT_ROUTES = ("api.hetzner.cloud", "api.digitalocean.com", "api.vercel.com", "api.cloudflare.com",
                  "console.neon.tech", "amazonaws.com", "api.linode.com", "management.azure.com",
                  "googleapis.com")
DELETE_HTTP = re.compile(r"(-X\s*DELETE\b|--request[= ]\s*['\"]?DELETE\b)", re.I)
CLI_DESTROY = re.compile(
    r"\baws\s+ec2\s+(terminate-instances|delete-volume)\b|"
    r"\baws\s+rds\s+delete-db-(instance|cluster)\b|"
    r"\baws\s+s3\s+rb\b|\baws\s+s3api\s+delete-bucket\b|"
    r"\bhcloud\s+(server|volume|database|storage-box|network|firewall|ssh-key)\s+delete\b|"
    r"\bterraform\s+destroy\b|"
    r"\bcoolify\b[^\n;&|]*\bdelete\b",
    re.I)
ESCAPE = re.compile(r"#\s*user-named-go:\s*(\S+)\s+(.+)", re.I)
GO_VERB = re.compile(r"\b(go|yes|confirm|approve|delete|terminate|destroy)\b", re.I)


def routes():
    raw = os.environ.get("COS_DESTROY_HTTP_ROUTES", "").strip()
    if not raw:
        return DEFAULT_ROUTES
    if raw.lower() == "none":
        return ()
    return tuple(r for r in re.split(r"[\s,]+", raw) if r)


def kind_of(cmd):
    if DELETE_HTTP.search(cmd):
        low = cmd.lower()
        hit = next((r for r in routes() if r.lower() in low), None)
        if hit:
            return f"HTTP DELETE to a guarded route ({hit})"
    m = CLI_DESTROY.search(cmd)
    if m:
        return f"CLI destroy ({m.group(0).strip()})"
    return None


def named_go(cmd):
    """True when the escape line names a resource id and quotes the user with a go verb."""
    m = ESCAPE.search(cmd)
    if not m:
        return False
    rid, words = m.group(1), m.group(2)
    return rid in words and bool(GO_VERB.search(words))


def main():
    if os.environ.get("COS_DESTROY_GUARD") == "0":
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    kind = kind_of(cmd)
    if not kind or named_go(cmd):
        return
    reason = (f"destroy-guard: {kind} needs the user's named go. Report the facts and ask. "
              "Escape only with the user's exact words: `# user-named-go: <resource id> <their words naming it, "
              "with a go verb>` (chief-of-staff SKILL.md § Critical rules).")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:   # fails open: a broken guard must never block work
        pass
    sys.exit(0)
