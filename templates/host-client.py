#!/usr/bin/env python3
"""host — ask the Mac (hive-hostd) to run a command and print its output.

Works only when this node has been turned on with `hive <node> host on`, which
injects the secret token at ~/.config/hive/hostd-token. The request goes
directly to the Mac daemon at host.docker.internal:8799.
"""
import json, os, pathlib, sys, urllib.request

TOKEN_FILE = pathlib.Path.home() / ".config" / "hive" / "hostd-token"
URL = os.environ.get("HIVE_HOSTD_URL", "http://host.docker.internal:8799/run")

if not TOKEN_FILE.exists():
    sys.exit("host: not enabled for this node — run `hive <node> host on` on the Mac")
if len(sys.argv) < 2:
    sys.exit("usage: host <command...>")

payload = json.dumps({"token": TOKEN_FILE.read_text().strip(), "cmd": " ".join(sys.argv[1:])}).encode()
# talk directly to the Mac daemon (bypass any proxy env)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
req = urllib.request.Request(URL, data=payload, headers={"Content-Type": "application/json"})
try:
    with opener.open(req, timeout=1830) as r:
        res = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"host: refused by hostd ({e.code}) — token wrong or host off")
except Exception as e:
    sys.exit(f"host: cannot reach hostd at {URL} ({e}); is `hive hostd start` running on the Mac?")

sys.stdout.write(res.get("stdout", ""))
sys.stderr.write(res.get("stderr", ""))
sys.exit(int(res.get("exit", 0)))
