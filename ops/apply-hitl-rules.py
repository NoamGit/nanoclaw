#!/usr/bin/env python3
"""
ops/apply-hitl-rules.py — idempotently apply ops/hitl-rules.json to OneCLI.

Matches rules by NAME: creates missing ones, PATCHes ones that drifted, never deletes.
  python3 ops/apply-hitl-rules.py            apply
  python3 ops/apply-hitl-rules.py --check    read-only: report drift, change nothing
Exit: 0 = in sync (or applied), 1 = drift found in --check mode / API error.
"""
import json, os, sys, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ONECLI = os.environ.get("ONECLI_URL", "http://172.17.0.1:10254")
FIELDS = ("hostPattern", "pathPattern", "method", "action", "enabled")


def call(method, path, body=None):
    req = urllib.request.Request(ONECLI + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def main():
    check = "--check" in sys.argv
    desired = json.load(open(f"{ROOT}/ops/hitl-rules.json"))["rules"]
    try:
        existing = {r["name"]: r for r in call("GET", "/api/rules")}
    except Exception as e:
        print(f"[hitl-rules] ERROR: cannot reach OneCLI at {ONECLI}: {e}")
        return 1
    drift = 0
    for d in desired:
        cur = existing.get(d["name"])
        if cur is None:
            drift += 1
            print(f"[hitl-rules] {d['name']}: MISSING" + ("" if check else " -> creating"))
            if not check: call("POST", "/api/rules", d)
        else:
            diff = {k: d[k] for k in FIELDS if cur.get(k) != d[k]}
            if diff:
                drift += 1
                print(f"[hitl-rules] {d['name']}: DIFFERS {sorted(diff)}" + ("" if check else " -> updating"))
                if not check: call("PATCH", f"/api/rules/{cur['id']}", diff)
            else:
                print(f"[hitl-rules] {d['name']}: ok")
    print(f"[hitl-rules] {len(desired)} rule(s), {drift} out of sync" + (" (check only)" if check else ""))
    return 1 if (check and drift) else 0


if __name__ == "__main__":
    sys.exit(main())
