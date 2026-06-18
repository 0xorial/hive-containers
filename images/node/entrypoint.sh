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
  fi

  cat > /etc/claude-code/CLAUDE.md <<EOF
# hive — where you are

You are Claude Code running inside **${hive_name}**, one container in a *hive*: a tree of dev containers on a single host (a MacBook). The user reaches you through the Claude desktop app or \`hive claude ${hive_name}\`.

## This container
- Name: **${hive_name}**${hive_parent_line}
- Role: **${hive_role}**
- \`/workspace\` — your working directory
- \`/shared\` — a volume shared with every hive container (scratch space for handing files between containers)

## Network
${hive_net}

${hive_role_para}
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
    rm -f /var/run/docker.pid
    setsid dockerd >/var/log/dockerd.log 2>&1 < /dev/null &
  fi

  exec gosu dev "$@"
fi

exec "$@"
