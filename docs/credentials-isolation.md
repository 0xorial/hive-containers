# Per-node credentials — the shared `~/.claude` volume and the session-drop bug

Status: **fixed / current design.** Each container has its own
`hive-claude-<name>` volume (root's is `hive-claude-root`). Credentials,
history and sessions are **not** shared across the hive. This file records the
bug that forced the change and the decision behind it.

## The symptom

Connecting to a node from the Claude desktop app (Code tab → SSH connection)
*looked* fine — the app reported the connection as OK — but the session dropped
the instant you ran anything. Reconnect, same thing: a tight connect → drop
loop.

## What it was not

The hive SSH transport. SSH rides `ProxyCommand docker exec -i <node> sshd -i`
(see "Claude desktop app" in the README). From the `ssh` CLI, everything was
healthy: non-interactive commands, interactive PTYs, and 75s-idle sessions all
survived, and the keepalives in the managed `~/.ssh/config` block held idle
sessions up. The transport was never the problem.

## What it actually was

One layer up — the Claude **remote-dev server** the desktop app runs inside the
node (`~/.claude/remote/srv/<hash>/server --serve` + `--bridge`, the same model
as VS Code's remote server). Its log showed the real failure:

```
[Server] New connection from: @
[Server] Unauthorized request: method=server.ping, id=0
[Server] Connection closed: @
```

The bridge's `server.ping` was rejected as unauthorized, so the server closed
the connection — over and over, with the per-session token changing on every
cycle (a respawn loop).

## Root cause: the shared volume

Every node mounted the **single** `hive-claude` volume over the **whole**
`~/.claude` (`bin/hive` for `hive new` nodes, `compose.yaml` for root). That was
deliberate — it gave "log in once, every node is authenticated."

But it also meant every node shared `~/.claude/remote/run/` — the remote
server's **live socket and per-session auth tokens**. With the app connected to
two nodes at once, their servers used the *same* socket path and *same* token
files and continuously clobbered each other's tokens. So a `server.ping`
carrying one node's token hit a server that had since rewritten the file with a
different token → `Unauthorized` → drop. Two containers cannot meaningfully
share one Unix socket / token dir; that state is inherently per-node.

A marker written into one node's `~/.claude/remote/run` appeared in another
node's — direct confirmation the dir was shared.

## The discussion / decision

The first instinct was a minimal patch: keep the shared volume (and shared
login) but carve just `~/.claude/remote/run` out to node-local storage via a
symlink created in the node entrypoint. That fixes the drops while preserving
"log in once."

That was rejected. We did **not** want credentials shared between containers at
all — the shared volume also exposed `.claude.json`, `projects/`, `sessions/`
and conversation history across every node, which is a cross-node isolation
problem in its own right, drop bug or not.

So we chose **full per-node isolation** instead of the carve-out:

- Each container gets its own `hive-claude-<name>` volume (`hive-claude-root`
  for root) mounted at `~/.claude`.
- Credentials, history and sessions are isolated per node. Each node
  authenticates on its own — the "log in once for the whole hive" convenience
  is intentionally gone.
- `~/.claude/remote/run` is now naturally node-local, so the original drop bug
  disappears as a side effect and the entrypoint symlink workaround is not
  needed (it was reverted).
- `hive rm <node> --purge` now also deletes the node's `hive-claude-<name>`
  volume, so a node's credentials can be revoked by purging just that node.
- The pre-existing shared `hive-claude` volume was left untouched (not deleted),
  so nothing was lost; it is simply no longer mounted.

## Activation note

The volume name is set at container creation, so the change only takes effect
when a node is **(re)created**. Existing nodes keep using the old shared
`hive-claude` volume until recreated, at which point they come up with a fresh,
empty, per-node `~/.claude` and must be logged in individually.
