#!/bin/sh
# Regenerate squid's per-node "open" source-IP ACL from the curated
# /etc/hive/open-nodes list, then tell squid to reconfigure (instant, keeps
# live connections). Called at startup (--no-reload) and by `hive <node> net`.
OPEN=/run/hive/open

{
  echo "127.0.0.2"   # never-matching sentinel so the acl file is never empty
  if [ -f /etc/hive/open-nodes ]; then
    grep -E '^[0-9]' /etc/hive/open-nodes 2>/dev/null
  fi
} > "$OPEN.tmp" && mv "$OPEN.tmp" "$OPEN"
chown squid:squid "$OPEN" 2>/dev/null || true

if [ "${1:-}" = "--no-reload" ]; then
  exit 0
fi

squid -k reconfigure -f /run/hive/squid.conf 2>/dev/null \
  || pkill -HUP squid 2>/dev/null \
  || kill -HUP 1 2>/dev/null \
  || true
