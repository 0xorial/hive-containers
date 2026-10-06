#!/bin/bash
# Runs as root, prepares the container, then drops to the 'dev' user.
set -e

if [ "$(id -u)" -eq 0 ]; then
  # Named volumes mount root-owned on first use; hand the top level to dev.
  # (chown is a no-op / may fail on Mac bind mounts — that's fine.)
  for d in /home/dev/.claude /shared /workspace; do
    if [ -d "$d" ] && [ "$(stat -c %u "$d")" != "$(id -u dev)" ]; then
      chown dev:dev "$d" 2>/dev/null || true
    fi
  done

  # On-demand sshd (desktop app sessions): per-container host keys + the
  # runtime env, which ssh logins don't inherit from docker.
  if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A >/dev/null 2>&1 || true
  fi
  mkdir -p /run/sshd
  {
    printf 'export CLAUDE_CONFIG_DIR=%q\n' "${CLAUDE_CONFIG_DIR:-/home/dev/.claude}"
    printf 'export DISABLE_AUTOUPDATER=1\n'
  } > /etc/hive-env.sh

  # Permissions: every session in a hive container runs with everything
  # allowed (= --dangerously-skip-permissions); the container is the sandbox.
  # Seeded into this container's own ~/.claude volume, and only where unset,
  # so editing a node's settings.json makes that node ask again.
  #  - settings.json: permissions.defaultMode = bypassPermissions (documented;
  #    honored by the CLI, ssh/desktop sessions and the VS Code extension).
  #  - .claude.json: bypassPermissionsModeAccepted = true pre-accepts the
  #    one-time bypass disclaimer. Undocumented key, but it is exactly what the
  #    installed CLI checks; if it ever changes, the cost is one extra dialog.
  cfg="${CLAUDE_CONFIG_DIR:-/home/dev/.claude}"
  mkdir -p "$cfg"
  seed_json() {  # file  jq-filter-to-test  jq-filter-to-apply
    local f=$1 test=$2 apply=$3
    [ -s "$f" ] || echo '{}' > "$f"
    if [ "$(jq -r "$test" "$f" 2>/dev/null)" != true ]; then
      if jq "$apply" "$f" > "$f.tmp" 2>/dev/null; then mv "$f.tmp" "$f"
      else rm -f "$f.tmp"; echo "node: warning: could not seed $f (not valid JSON?)" >&2; fi
    fi
    chown dev:dev "$f" 2>/dev/null || true
  }
  seed_json "$cfg/settings.json" '.permissions.defaultMode != null' \
            '.permissions.defaultMode = "bypassPermissions"'
  seed_json "$cfg/.claude.json" '.bypassPermissionsModeAccepted == true' \
            '.bypassPermissionsModeAccepted = true'
  chmod 600 "$cfg/.claude.json" 2>/dev/null || true

  # Tell this container's Claude where it is. /etc/claude-code/CLAUDE.md is the
  # Linux "managed policy" memory path: loaded first in every session, on the
  # container's own fs (so it neither collides via the shared ~/.claude volume
  # nor pollutes the bind-mounted /workspace). Rendered every start, so it stays
  # correct across restarts and recreation.
  hive_name="${HIVE_NAME:-$(hostname)}"
  # root == this container can actually drive Docker: the socket must be present
  # AND a usable docker client installed (the hive/root image adds the client).
  # A bare socket on a plain node image is not a working control plane.
  if [ -S /var/run/docker.sock ] && command -v docker >/dev/null 2>&1; then
    hive_role=root
  else
    hive_role=node
  fi
  mkdir -p /etc/claude-code

  hive_net="This container has normal, direct internet access (no egress proxy or allowlist) and can reach the user's Mac at \`host.docker.internal\`."
  hive_host_para=""
  hive_auth_para=""

  if [ "$hive_role" = root ]; then
    hive_parent_line=""
    hive_role_para=$(cat <<'EOR'
## You are the hive control plane (root)
You hold the Docker socket and the `hive` CLI, and `/workspace` is the hive repo itself, so you manage the whole tree:
- `hive new <name> [--parent <p>] [--bind <macdir>]` — spawn a node
- `hive claude <node> -p "..."` — run a task inside a node headlessly and read back its output
- `hive tree` / `hive ls` — inspect the hierarchy
- `hive rm <node> --purge` — destroy a node and its workspace

Do messy or untrusted work in a node you spawn — keep this control plane clean. Pass files to and from nodes through `/shared`.
EOR
)
  else
    hive_parent_line="
- Parent: **${HIVE_PARENT:-root}**"
    hive_role_para=$(cat <<'EOR'
## You are a leaf node
You cannot see or control other hive containers — the hive's own config lives in the control plane, not here. You have normal, direct internet access; ask the user if you need anything from the control plane.
EOR
)
    hive_auth_para=$(cat <<EOR

## Git auth (when \`hive ${hive_name} github on\` was run on the Mac)
This container holds two complementary credentials for \`origin\`:

- **HTTPS**: a token in \`~/.git-credentials\` (personal token from the user's \`gh\` login + a short-lived read-all token).
- **SSH**: a per-repo deploy key at **\`~/.ssh/hive_deploy\`** with **write** access. The matching pubkey is registered on the GitHub repo as **\`hive-${hive_name}\`**, and \`~/.ssh/config\` already routes \`github.com\` through it.

Use the existing files — **do not** \`ssh-keygen\` a new key, and **do not** commit either key file. \`hive_deploy\` only works for THIS container's \`origin\` (GitHub deploy keys are unique per repo); it can't push to any other repo. If \`~/.ssh/hive_deploy\` doesn't exist, \`github on\` hasn't been run yet — ask the user to run it on the Mac.
EOR
)
    hive_host_para=$(cat <<'EOR'

## Running commands on the user's Mac (`host`)
If this node has been blessed (the user ran `hive <node> host on`), a `host` command is available:

    host "<command…>"

It runs the command **on the user's Mac, as them** — but only after they approve it interactively at their Mac terminal. Reach for it only when the task genuinely needs the Mac (their toolchain, building or installing artefacts there, driving their setup); otherwise do the work here in the container.

- **Paths are Mac paths**, not container paths — `/workspace` here is a different location on the Mac. `cd` to the real Mac path inside the command.
- The user may **deny** a command and send back a short message. A denial shows as `DENIED by the human operator` (exit 77) — that is a deliberate decision, not a transient error. Read their message and adapt, or ask; do **not** blindly retry the same command.
- State plainly what you intend to run before using `host` for anything consequential, and don't try to route around a denial.
EOR
)
  fi

  # A node whose project hive also mounted at its own path (HIVE_PROJECT_DIR; terra's dev VM,
  # terra-config #52/#53) starts its sessions there, and they are stored by that folder.
  if [ -n "${HIVE_PROJECT_DIR:-}" ] && [ "$HIVE_PROJECT_DIR" != /workspace ]; then
    workdir_line="- \`${HIVE_PROJECT_DIR}\` — your project folder and working directory (the same files are also mounted at \`/workspace\`)"
  else
    workdir_line="- \`/workspace\` — your working directory"
  fi

  cat > /etc/claude-code/CLAUDE.md <<EOF
# hive — where you are

You are Claude Code running inside **${hive_name}**, one container in a *hive*: a tree of dev containers on a single host (the user's Mac, or the dev VM on their home server terra). The user reaches you through the Claude desktop app, \`hive claude ${hive_name}\`, or the Claude Code VS Code extension attached to this container.

## This container
- Name: **${hive_name}**${hive_parent_line}
- Role: **${hive_role}**
${workdir_line}
- \`/shared\` — a volume shared with every hive container (scratch space for handing files between containers)

## Permissions
Every session here runs in bypass-permissions mode (no approval prompts) — this container is the sandbox. That makes *you* the only check on destructive actions: say what you are about to do before anything irreversible, and stay inside \`/workspace\` unless asked.

## Network
${hive_net}

${hive_role_para}
${hive_auth_para}
${hive_host_para}
EOF
  chmod 0644 /etc/claude-code/CLAUDE.md

  # Root container only: let dev use the mounted docker socket.
  if [ -S /var/run/docker.sock ]; then
    gid=$(stat -c %g /var/run/docker.sock)
    grp=$(getent group "$gid" | cut -d: -f1 || true)
    if [ -z "$grp" ]; then
      groupadd -g "$gid" hostdocker
      grp=hostdocker
    fi
    usermod -aG "$grp" dev
  fi

  # --dind: start a nested docker engine (the dev image has dockerd; needs
  # --privileged). dev is already in the docker group via the image.
  if [ "${HIVE_DIND:-}" = 1 ] && command -v dockerd >/dev/null 2>&1; then
    echo "node: starting nested dockerd (dind)…"
    # A restarted node keeps its container fs, so both pid files survive; a stale
    # containerd.pid names some other process and dockerd then times out waiting for
    # "containerd is still running" (seen on terra's dev VM, 2026-09-28).
    rm -f /var/run/docker.pid /var/run/docker/containerd/containerd.pid
    setsid dockerd >/var/log/dockerd.log 2>&1 < /dev/null &
  fi

  exec gosu dev "$@"
fi

exec "$@"
