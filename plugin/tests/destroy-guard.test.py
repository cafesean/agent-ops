#!/usr/bin/env python3
"""Tests for hooks/destroy-guard.py (direct, and through hooks/cos-py.sh with and without the agent-ops config).
Run: python3 plugin/tests/destroy-guard.test.py"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.join(HERE, "..", "hooks")
GUARD = os.path.join(HOOKS, "destroy-guard.py")
RID = "169312439"
API = "https://api.hetzner.cloud/v1/servers"


def run(cmd, tool="Bash", env=None, via=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("COS_")}
    e.update(env or {})
    payload = json.dumps({"tool_name": tool, "tool_input": {"command": cmd}})
    argv = via or [sys.executable, GUARD]
    return subprocess.run(argv, input=payload, capture_output=True, text=True, env=e).stdout.strip()


CASES = [
    # (name, command, tool, env, expect_deny)
    ("GET to a cloud API is allowed", f"curl -s {API}/{RID}", "Bash", None, False),
    ("HTTP DELETE to a cloud API is denied", f"curl -X DELETE {API}/{RID}", "Bash", None, True),
    ("--request DELETE to an AWS endpoint is denied",
     "curl --request DELETE https://ec2.us-east-1.amazonaws.com/vol-1", "Bash", None, True),
    ("DELETE word without -X or --request is allowed", f"echo DELETE {API}/{RID}", "Bash", None, False),
    ("DELETE to an unguarded route is allowed", "curl -X DELETE https://example.com/item/1", "Bash", None, False),
    ("COS_DESTROY_HTTP_ROUTES adds a route", "curl -X DELETE https://proxy.internal/cloud-servers/1", "Bash",
     {"COS_DESTROY_HTTP_ROUTES": "proxy.internal/cloud-, other.example"}, True),
    ("COS_DESTROY_HTTP_ROUTES replaces the defaults", f"curl -X DELETE {API}/{RID}", "Bash",
     {"COS_DESTROY_HTTP_ROUTES": "proxy.internal/cloud-"}, False),
    ("COS_DESTROY_HTTP_ROUTES=none turns the HTTP check off", f"curl -X DELETE {API}/{RID}", "Bash",
     {"COS_DESTROY_HTTP_ROUTES": "none"}, False),
    ("aws terminate-instances is denied", "aws ec2 terminate-instances --instance-ids i-0abc", "Bash", None, True),
    ("aws s3 rb is denied", "aws s3 rb s3://bucket-x --force", "Bash", None, True),
    ("hcloud server delete is denied", f"hcloud server delete {RID}", "Bash", None, True),
    ("hcloud server list is allowed", "hcloud server list", "Bash", None, False),
    ("terraform destroy is denied", "terraform destroy -auto-approve", "Bash", None, True),
    ("coolify delete is denied", "coolify app delete abc123", "Bash", None, True),
    ("named go with id and go verb is allowed",
     f"curl -X DELETE {API}/{RID}  # user-named-go: {RID} yes, delete server {RID}", "Bash", None, False),
    ("escape without the id in the quoted words is denied",
     f"hcloud server delete {RID}  # user-named-go: {RID} yes do it", "Bash", None, True),
    ("escape without a go verb is denied (a question is not a go)",
     f"hcloud server delete {RID}  # user-named-go: {RID} what is on {RID}?", "Bash", None, True),
    ("kill switch COS_DESTROY_GUARD=0 allows", f"hcloud server delete {RID}", "Bash", {"COS_DESTROY_GUARD": "0"}, False),
    ("non-Bash tool is ignored", f"hcloud server delete {RID}", "Write", None, False),
]


def main():
    fails = 0
    total = 0

    def check(name, out, expect_deny):
        nonlocal fails, total
        total += 1
        denied = '"permissionDecision": "deny"' in out
        if denied == expect_deny:
            print(f"ok   {name}")
        else:
            fails += 1
            print(f"FAIL {name}\n     got: {out or '(allow)'}")

    for name, cmd, tool, env, expect_deny in CASES:
        check(name, run(cmd, tool, env), expect_deny)

    # through cos-py.sh: inactive without the config, active with it (config keys reach the hook)
    via = ["bash", os.path.join(HOOKS, "cos-py.sh"), "destroy-guard.py"]
    with tempfile.TemporaryDirectory() as d:
        missing = os.path.join(d, "none.env")
        cfg = os.path.join(d, "config.env")
        with open(cfg, "w") as f:
            f.write(f"COS_DIR={d}\nCOS_DESTROY_HTTP_ROUTES=proxy.internal/cloud-\n")
        check("cos-py.sh without config: inactive",
              run(f"hcloud server delete {RID}", env={"AGENT_OPS_CONFIG": missing, "HOME": d}, via=via), False)
        check("cos-py.sh with config: denies",
              run(f"hcloud server delete {RID}", env={"AGENT_OPS_CONFIG": cfg, "HOME": d}, via=via), True)
        check("cos-py.sh passes config keys to the hook",
              run("curl -X DELETE https://proxy.internal/cloud-servers/1", env={"AGENT_OPS_CONFIG": cfg, "HOME": d},
                  via=via), True)
    print(f"{total - fails} passed, {fails} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
