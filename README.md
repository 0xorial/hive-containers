# hive

Hierarchical Claude Code containers with one curated bridge to your Mac.

```
 MacBook ────────────────────────────────────────────────────────────────
 │  hive CLI · VS Code attach · config/ (the two curated files)
 │
 │   docker         ┌────────────────────────────────────────────┐
 │   socket ──────► │ root        control plane (docker CLI +    │
 │                  │             hive CLI + Claude Code)        │
 │                  │   ├─ node a      ├─ node b                 │
 │                  │   │   └─ node a2 │                         │  hive-net
 │                  │   (any depth, tracked via labels)          │  (internal —
 │                  └───────────────────┬────────────────────────┘   no way out)
 │                                      │ only crossing point
 │                            ┌─────────┴─────────┐
 │   host.docker.internal ◄── │ bridge            │ ──► internet
 │   (only what's listed in   │  squid 3128       │     (allowlisted domains for
 │    config/forwards.conf)   │  socat forwards   │      sealed nodes; everything
 │                            └───────────────────┘      for nodes you `net on`)
```

Three guarantees, all enforced by Docker networking rather than convention:

1. **Nodes are sealed.** Every node sits on `hive-net`, an `internal: true`
   network. No internet, no Mac, not even with root inside the container.
2. **The bridge is the only door, and you curate both sides of it.**
   Outbound HTTP(S) goes through a domain allowlist
   ([config/egress-allowlist.txt](config/egress-allowlist.txt)); access to your
   Mac exists only as the explicit TCP forwards in
   ([config/forwards.conf](config/forwards.conf)).
3. **Only `root` holds the Docker socket.** It is the one container that can
   spawn or destroy others — a Claude instance in `root` can orchestrate the
   whole tree, while Claude instances in nodes can't touch the hierarchy.

## Quickstart

```sh
alias hive="$PWD/bin/hive"     # or add bin/ to PATH

hive up                        # build + start root and bridge
hive claude root               # log in once; credentials are shared hive-wide
hive ssh setup                 # once: lets the Claude desktop app open sessions in nodes
hive doctor                    # verify the isolation actually holds

hive new api                   # spawn a node (fresh volume workspace)
hive new web --bind ~/code/web # ...or mount a Mac directory as /workspace
hive sh api                    # zsh inside
hive claude api                # interactive claude inside
hive claude api -p "run the tests and summarize failures"   # headless
hive tree                      # see the hierarchy
hive rm api --purge            # remove node + its workspace volume
```

## Every container knows where it is

On each start, a container renders its own identity into
`/etc/claude-code/CLAUDE.md` (Claude Code's Linux managed-policy memory path),
so the Claude inside it loads — before anything else, every session — who it
is, that it's sealed behind the bridge, how egress and host forwards work, and
its role. `root` additionally learns it's the control plane and how to drive
the tree; a node learns it's a leaf and to ask you for network changes rather
than fight the allowlist. The text is derived from the container's role and
environment (name, parent, whether it has the proxy or `--uplink`), so it's
always accurate after any restart or rebuild — nothing to maintain by hand.
This lives on the container's own filesystem, so it never collides via the
shared `~/.claude` volume nor clutters your bind-mounted `/workspace`. Confirm
it's loaded inside a session with `/memory`.

## The hierarchy

`--parent` builds arbitrary trees; the hierarchy is *logical* (Docker labels),
while spawn *privilege* stays physical (only `root` has the socket):

```sh
hive new backend
hive new backend-tests --parent backend
hive tree
```

Orchestration pattern: run `hive claude root` and let that Claude drive the
fleet. **`hive` is the same control plane whether you run it on your Mac or
inside `root`** — `root` holds the Docker socket and has `hive` on its PATH
(symlinked to the live `/workspace/bin/hive`), so from a shell in `root` you
can `hive new`, `hive <node> net on`, `hive tree`, and `hive claude <node> -p
"..."` its children, then collect results through the `/shared` volume. The
one split: lifecycle commands (`build` / `up` / `down`) stay on the Mac,
because they manage the container set that includes `root` itself. Every
container also shares the `hive-claude` volume, so you authenticate once.

## The bridge — your curation surface

The bridge runs **Squid**, which applies two layers of "allow": the curated
domain allowlist (every node) and a per-node open set of source IPs (the nodes
you `net on`). Both files below live in [config/](config/) on your Mac, mounted
read-only into the bridge. Edit, then `hive bridge reload`.

- **[egress-allowlist.txt](config/egress-allowlist.txt)** — which domains the
  hive may reach. Ships with Anthropic, npm, PyPI, GitHub, and Debian.
  `hive bridge logs` shows what's being refused when something fails.
- **[forwards.conf](config/forwards.conf)** — which Mac services the hive may
  reach. One line per opening, e.g. `postgres 15432 host.docker.internal:5432`;
  nodes then connect to `bridge:15432`. Nothing is forwarded by default.

`hive bridge conf` prints the generated proxy config and active listeners.

## Per-node switches: internet & GitHub

Each node has two live switches. They are applied **at the bridge**, not inside
the node — so they take effect on the node's very next request, instantly, even
in a shell that was already open (the node's environment never changes). Flip
them from the Mac or from inside `root`:

```sh
hive <node> net on        # full, unfiltered internet for this node
hive <node> net off       # back to sealed (allowlist only)
hive <node> github on     # give this node your GitHub token
hive <node> github off    # remove it
hive <node> status        # show both
```

**`net on`** adds the node's source IP to the bridge's "open" set in Squid and
reconfigures it live (`squid -k reconfigure`), so that node bypasses the
allowlist while every other node stays sealed. **`net off`** removes it. Because
the node still reaches the world only through the bridge, nothing about the node
changes — there is no proxy to go stale, no reconnect, no recreate. The open
set is remembered in `config/open-nodes` so it survives a bridge restart.

If instead you want to open *one domain for the whole hive while keeping every
node sealed*, add it to [egress-allowlist.txt](config/egress-allowlist.txt) and
`hive bridge reload`. `hive bridge logs` shows each request as `TCP_DENIED` or
`TCP_TUNNEL/200`, so you can see exactly what was refused.

**`github on` does the login for you — no token to paste.** The first time you
run it, hive starts GitHub's device login (using `gh` inside `root`, which
reaches GitHub through the bridge), prints a URL and a one-time code, and waits
while you approve in your browser. It then caches the resulting token at
`~/.config/hive/github-token` (chmod 600, outside the repo) and installs it in
the node — git's credential helper for `git clone https://github.com/...` and
the `gh` CLI for `gh pr` / `gh repo clone`. Every later `hive <node> github on`
is silent (the cached token is reused). `hive <node> github off` deletes the
token from that node; `hive github --forget` drops the cached copy. No allowlist
change is needed (`github.com` is already permitted), and the token never enters
an image layer.

GitHub won't mint a token without you authenticating once — that single browser
approval is unavoidable. After it, hive handles everything. (For scripts, a
token piped in — `echo "$T" | hive <node> github on` — skips the login. You can
also pre-seed one with `hive github <token>`.)

Prefer SSH keys? Plain `git@github.com` needs port 22, which the bridge doesn't
tunnel. Use GitHub's SSH-over-443 endpoint: add `ssh.github.com` to the
allowlist (CONNECT on 443 is already permitted), put your key in the node, and
use remotes like `ssh://git@ssh.github.com:443/owner/repo.git`.

> Full internet + published ports from creation: `hive new web --uplink -- -p 3000:3000`.

## Claude desktop app

The desktop app's SSH sessions run entirely inside a node while the app is
your interface — file pane, terminal-free permission modes, the lot.

```sh
hive ssh setup     # once: dedicated key + ~/.ssh/config block + key install
```

Then in the app: **Code tab → environment dropdown → + Add SSH connection**,
host `hive-<node>` (e.g. `hive-root`), port and identity file empty. Every
node you `hive new` afterwards is immediately connectable the same way.

How it stays sealed: there is no sshd listening anywhere. The `~/.ssh/config`
block uses `ProxyCommand docker exec` to spawn `sshd -i` on the connection's
stdio, so SSH rides the Docker socket — nodes gain no open port, nothing on
the hive network changes, and only this Mac can connect. The Docker context
is baked into the config at setup time, so it keeps working when another
engine (e.g. colima) holds the default context.

## Two Docker engines (Docker Desktop + colima)

Hive lives on one engine — its seal is a Docker network, which can't span
VMs. Which engine is pinned in [config/docker-context](config/docker-context)
(currently `desktop-linux`); every `hive` command targets it no matter which
context your shell has active, so `colima start` stealing the default context
never breaks or relocates the hive. Plain `docker` keeps following your
active context for other projects.

To let hive nodes reach a service from a colima project: publish its port to
the Mac as usual (`-p 5432:5432`), then curate it like any Mac service —
`colima-pg 15432 host.docker.internal:5432` in forwards.conf. To migrate hive
itself to another engine: change `config/docker-context`, then
`hive build && hive up && hive ssh setup`.

## Devcontainers / IDEs

- `hive devcontainer ~/code/myproject` drops a `.devcontainer/` that joins the
  project to the hive as a labeled node — then "Reopen in Container".
- Or attach VS Code to any existing node: "Dev Containers: Attach to Running
  Container" → `hive-<name>`.
- `hive join <container>` connects a container you created some other way to
  `hive-net` (it appears under *guests* in `hive ls`).

## What's in a node

Every node (and `root`) is built from `hive/node`, which ships Claude Code, the
GitHub CLI, Node and Python, and a broad toolset so the agent rarely has to
install anything:

- **network suite** — `nmap`, `tcpdump`, `dig`/`nslookup`, `mtr`, `traceroute`,
  `nc`/`ncat`, `socat`, `whois`, `iperf3`, `ngrep`, `arp-scan`, `iproute2`,
  `nftables`/`iptables`, `ethtool`, `openssl`
- **datastore clients** — `psql`, `mysql`, `redis-cli`, `sqlite3`
- **build & dev** — `build-essential`/`gcc`/`make`, `pkg-config`, `git`, `tmux`,
  `jq`, `ripgrep`, `fd`, `bat`, `httpie`, `htop`, `strace`, `shellcheck`, `rsync`

Add more in [images/node/Dockerfile](images/node/Dockerfile) and `hive build`.

## Escape hatches

| Need | Do |
|---|---|
| Full internet for one node, instantly | `hive <node> net on` |
| Direct internet at creation + working `-p` published ports | `hive new x --uplink -- -p 3000:3000` |
| Extra docker flags (env, ports, gpus…) | everything after `--` goes to `docker run` |
| A different base image | `hive new x --image myimage` (any image works; Claude tooling comes from `hive/node`) |
| Open egress entirely | put a single `*` line in the allowlist (deliberate act, on purpose) |
| New tools in the base image | edit [images/node/Dockerfile](images/node/Dockerfile), `hive build` |

## Prior art & how hive differs

Sandboxing AI coding agents is a well-trodden, active area — the building
blocks here are not new:

- Anthropic ships a reference **devcontainer firewall**: `iptables` default-DROP
  plus an `ipset` domain allowlist, per container, which is what makes
  `--dangerously-skip-permissions` safe.
- **`@anthropic-ai/sandbox-runtime`** wraps the Claude Code process in
  Seatbelt/bubblewrap with filesystem + network allowlists (host process, not a
  container).
- **Docker AI Sandboxes** route all egress through a host proxy that enforces a
  network policy (and inject credentials).
- **agent-sandbox** (mattolson) forces traffic through a sidecar proxy with
  per-hostname/path egress rules.
- Conceptually the closest is **Qubes OS**, where AppVMs reach the network only
  through a shared `sys-net`/`sys-firewall` VM.

So the egress-allowlist idea is mainstream. What hive assembles — and what I
haven't found packaged together — is:

1. a **hierarchy** of agent containers: a `root` control plane that holds the
   Docker socket and orchestrates an arbitrary-depth tree of nodes;
2. a **single shared curated bridge** that does *both* egress filtering and
   host-port forwarding — one auditable crossing point for the whole fleet,
   rather than a firewall baked into each container;
3. a **per-node, live egress toggle** (`hive <node> net on/off`) via Squid
   source ACLs — instant, with no change to the node or its environment;
4. **desktop-app / IDE access over socket-tunnelled SSH**, with no open ports;
5. one CLI tying it together, each container told *where it is* via a managed
   `CLAUDE.md`.

In one line: the allowlist is mainstream; hive's contribution is the *shared
bridge + hierarchy + per-node instant toggle + host forwards + desktop SSH* as
one small, auditable system — roughly "Anthropic's firewall devcontainer meets
a Qubes-style network VM."

## Security model, honestly

- The seal on nodes is the internal network — in-container root/sudo doesn't
  break it, which is why nodes get passwordless sudo for convenience.
- The egress allowlist is domain-level filtering, not DPI; an allowlisted
  domain (e.g. github.com) is still a data channel.
- `hive <node> net on` opens *that one node* to the whole internet (Squid keys
  off its source IP); other nodes stay sealed. It's per-node, instant, and
  reversible, but while on, that node has no egress restriction at all.
- `root` + the Docker socket = control of the Docker VM and every container.
  Treat `root` as trusted infrastructure: it's your orchestrator, not a
  sandbox for untrusted work — untrusted work belongs in nodes.
- Claude credentials are shared via the `hive-claude` volume: log in once,
  every node is authenticated. Delete the volume to revoke.

## Layout

```
bin/hive                    the CLI (symlinked into root via /workspace)
compose.yaml                root + bridge + networks + volumes
config/                     ← the two files you curate
images/{node,root,bridge}/  Dockerfiles + entrypoints
templates/devcontainer/     what `hive devcontainer` installs
```
