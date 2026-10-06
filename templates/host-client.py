#!/usr/bin/env python3
"""host — ask the Mac (hive-hostd) to run a command on your behalf.

Works only when this node has been turned on with `hive <node> host on`, which
injects the secret token at ~/.config/hive/hostd-token. The request goes
directly to the Mac daemon at host.docker.internal:8799.

Every command must be approved by a human at the Mac. If it is denied you'll see
the operator's message on stderr and this exits 77 — that is a person's
decision, not a transient error, so read the message instead of retrying.
"""
import json, os, pathlib, socket, sys, urllib.error, urllib.request

TOKEN_FILE = pathlib.Path.home() / ".config" / "hive" / "hostd-token"
URL = os.environ.get("HIVE_HOSTD_URL", "http://host.docker.internal:8799/run")
DENIED_EXIT = 77

if not TOKEN_FILE.exists():
    sys.exit("host: not enabled for this node — run `hive <node> host on` on the Mac")
if len(sys.argv) < 2:
    sys.exit("usage: host <command...>")

payload = json.dumps({
    "token": TOKEN_FILE.read_text().strip(),
    "cmd": " ".join(sys.argv[1:]),
    "node": os.environ.get("HIVE_NAME") or socket.gethostname(),
}).encode()
# talk directly to the Mac daemon (bypass any proxy env)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
req = urllib.request.Request(URL, data=payload, headers={"Content-Type": "application/json"})
try:
    # generous timeout: a human has to approve, then the command itself runs
    with opener.open(req, timeout=14400) as r:
        res = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"host: refused by hostd ({e.code}) — token wrong or host off")
except Exception as e:
    sys.exit(f"host: cannot reach hostd at {URL} ({e}); is `hive hostd start` running on the Mac?")

if res.get("denied"):
    reason = (res.get("reason") or "").strip()
    sys.stderr.write("host: ✗ DENIED by the human operator at the Mac (this is a person's decision, not a command error).\n")
    if reason:
        sys.stderr.write(f"host: operator's message: {reason}\n")
    sys.stderr.write("host: Do not just retry the same command — address the message above, or ask the user "
                     "and let them decide.\n")
    sys.exit(DENIED_EXIT)

sys.stdout.write(res.get("stdout", ""))
sys.stderr.write(res.get("stderr", ""))
sys.exit(int(res.get("exit", 0)))
