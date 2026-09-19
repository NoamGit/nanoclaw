#!/usr/bin/env python3
"""
ops/mcp-health.py — end-to-end health probe for the Gmail / Calendar / Drive MCPs.

Runs each server the way production does (agent image, real user, OneCLI proxy,
same mounts) and makes ONE read-only call, so it catches: image/tooling breakage,
OneCLI down, expired/revoked Google connections, disabled APIs.

Used by the crash-recovery flow (bin/recover-after-shutdown.sh) — non-fatal there.
Exit: 0 = all healthy, 1 = at least one failed, 2 = could not run (OneCLI/docker down).

  python3 ops/mcp-health.py [--only gmail,calendar,drive]
"""
import json, os, sqlite3, subprocess, sys, tempfile, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ONECLI = os.environ.get("ONECLI_URL", "http://172.17.0.1:10254")
PROXY_HOST = os.environ.get("ONECLI_PROXY_HOST", "host.docker.internal")
TIMEOUT = 60

# server -> (tool, arguments, predicate on result text)
PROBES = {
    "gmail": ("list_email_labels", {}, lambda t: t.startswith("Found ")),
    "calendar": ("list_calendars", {}, lambda t: t.lstrip().startswith("[")),
    "drive": ("search_files", {"page_size": 1}, lambda t: '"files"' in t),
}


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def http(path, binary=False):
    with urllib.request.urlopen(ONECLI + path, timeout=10) as r:
        data = r.read()
    return data if binary else json.loads(data)


def image_name():
    slug = sh(["bash", "-c", f'PROJECT_ROOT="{ROOT}"; source "{ROOT}/setup/lib/install-slug.sh"; container_image_base']).stdout.strip()
    return f"{slug}:latest"


def main_group_token():
    db = sqlite3.connect(f"file:{ROOT}/data/v2.db?mode=ro", uri=True)
    gid = db.execute("select id from agent_groups where folder='main'").fetchone()[0]
    for a in http("/api/agents"):
        if a.get("identifier") == gid:
            return a["accessToken"]
    raise RuntimeError("no OneCLI agent for the main group")


def probe(server, cfg, image, token, ca_path):
    tool, targs, ok = PROBES[server]
    command = [cfg["command"], *cfg.get("args", [])]
    env = {
        "HOME": "/home/node",
        "HTTPS_PROXY": f"http://x:{token}@{PROXY_HOST}:10255",
        "HTTP_PROXY": f"http://x:{token}@{PROXY_HOST}:10255",
        "NODE_EXTRA_CA_CERTS": "/tmp/ca.pem",
        "SSL_CERT_FILE": "/tmp/ca.pem",
        "NODE_USE_ENV_PROXY": "1",
        **cfg.get("env", {}),
    }
    docker = ["docker", "run", "--rm", "-i", "--user", f"{os.getuid()}:{os.getgid()}", "-w", "/app",
              "--network", "onecli_onecli", "--add-host", f"{PROXY_HOST}:{gateway_ip()}",
              "-v", f"{ca_path}:/tmp/ca.pem:ro",
              "-v", f"{ROOT}/container/agent-runner/src:/app/src:ro"]
    if server == "gmail":
        docker += ["-v", os.path.expanduser("~/.gmail-mcp") + ":/workspace/extra/gmail-mcp"]
    for k, v in env.items():
        docker += ["-e", f"{k}={v}"]
    docker += ["--entrypoint", command[0], image, *command[1:]]

    p = subprocess.Popen(docker, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "health", "version": "1"}}})
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": targs}})
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            line = p.stdout.readline()
            if not line:
                return False, "server exited before answering"
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 2:
                res = msg.get("result", {})
                text = (res.get("content") or [{}])[0].get("text", "")
                if res.get("isError"):
                    return False, text[:400]
                return (True, "ok") if ok(text) else (False, f"unexpected response: {text[:200]}")
        return False, f"timed out after {TIMEOUT}s"
    finally:
        try: p.stdin.close()
        except Exception: pass
        p.terminate()


_gw = None
def gateway_ip():
    global _gw
    if _gw is None:
        _gw = sh(["docker", "inspect", "onecli", "--format", "{{(index .NetworkSettings.Networks \"onecli_onecli\").IPAddress}}"]).stdout.strip()
    return _gw


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1].split(",")
    manifest = json.load(open(f"{ROOT}/ops/mcp-wiring.json"))
    wired = {s for names in manifest["groups"].values() for s in names}
    servers = [s for s in PROBES if s in wired and (only is None or s in only)]

    try:
        token = main_group_token()
        with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
            f.write(http("/api/gateway/ca", binary=True)); ca_path = f.name
        os.chmod(ca_path, 0o644)
        image = image_name()
        if sh(["docker", "image", "inspect", image]).returncode != 0:
            raise RuntimeError(f"agent image {image} not found")
        gateway_ip()
    except Exception as e:
        print(f"[mcp-health] cannot run probes: {e}")
        return 2

    failed = 0
    for s in servers:
        good, detail = probe(s, manifest["servers"][s]["config"], image, token, ca_path)
        print(f"[mcp-health] {s:9s} {'OK' if good else 'FAIL'}" + ("" if good else f" — {detail}"))
        failed += 0 if good else 1
    os.unlink(ca_path)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
