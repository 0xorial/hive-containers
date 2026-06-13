#!/bin/bash
# hive bridge: Squid egress proxy with two layers of allow —
#   1. a curated domain allowlist that applies to every node, and
#   2. a per-node "open" set (source IPs) that bypasses the allowlist.
# Plus socat TCP forwards to the host. Config is mounted read-only at /etc/hive.
set -u

CFG=/etc/hive
RUN=/run/hive
ALLOW="$CFG/egress-allowlist.txt"
FWD="$CFG/forwards.conf"
CONF="$RUN/squid.conf"
ALLOWED="$RUN/allowed"
ALLOWED_RE="$RUN/allowed_regex"
OPEN="$RUN/open"

mkdir -p "$RUN"
: > "$ALLOWED"
: > "$ALLOWED_RE"

open_all=0
connect_ports="443"
has_regex=0

# ---- parse the egress allowlist into squid acl files ----
if [ -f "$ALLOW" ]; then
  while IFS= read -r raw || [ -n "$raw" ]; do
    line=$(printf '%s' "$raw" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$line" ] && continue
    case "$line" in
      '*')               open_all=1 ;;
      '@connect-port '*) connect_ports="$connect_ports ${line#@connect-port }" ;;
      '~'*)              printf '%s\n' "${line#\~}" >> "$ALLOWED_RE"; has_regex=1 ;;
      *)                 printf '.%s\n' "$line" >> "$ALLOWED" ;;   # .dom matches dom + subdomains
    esac
  done < "$ALLOW"
else
  echo "bridge: WARNING: $ALLOW missing — egress is OPEN"
  open_all=1
fi
# drop entries already covered by a broader one (.api.foo.com under .foo.com)
if [ -s "$ALLOWED" ]; then
  sort -u "$ALLOWED" -o "$ALLOWED"
  cp "$ALLOWED" "$ALLOWED.all"; : > "$ALLOWED"
  while read -r d; do
    redundant=0
    while read -r p; do
      [ "$d" = "$p" ] && continue
      case "$d" in *"$p") redundant=1; break ;; esac
    done < "$ALLOWED.all"
    [ "$redundant" = 0 ] && printf '%s\n' "$d" >> "$ALLOWED"
  done < "$ALLOWED.all"
  rm -f "$ALLOWED.all"
fi
[ -s "$ALLOWED" ] || echo ".invalid.hive.local" > "$ALLOWED"  # avoid empty-acl warning

# ---- per-node open set (regenerated from the curated open-nodes list) ----
/usr/local/bin/reopen --no-reload

# ---- generate squid.conf ----
{
  echo "http_port 3128"
  echo "pid_filename $RUN/squid.pid"
  echo "cache deny all"
  echo "cache_mem 16 MB"
  echo "access_log stdio:$RUN/access.log squid"
  echo "cache_log stdio:$RUN/cache.log"
  echo "logfile_rotate 0"
  echo "shutdown_lifetime 1 seconds"
  echo "httpd_suppress_version_string on"
  echo "forwarded_for delete"
  echo "acl CONNECT method CONNECT"
  echo "acl Safe_ports port 80"
  for p in $connect_ports; do
    echo "acl Safe_ports port $p"
    echo "acl SSL_ports port $p"
  done
  echo "acl open_src src \"$OPEN\""
  echo "http_access deny !Safe_ports"
  echo "http_access deny CONNECT !SSL_ports"
  echo "http_access allow open_src"
  if [ "$open_all" = 1 ]; then
    echo "http_access allow all"
  else
    echo "acl allowed_domains dstdomain \"$ALLOWED\""
    echo "http_access allow allowed_domains"
    if [ "$has_regex" = 1 ]; then
      echo "acl allowed_regex dstdom_regex \"$ALLOWED_RE\""
      echo "http_access allow allowed_regex"
    fi
  fi
  echo "http_access deny all"
  echo "cache_effective_user squid"
} > "$CONF"

chown -R squid:squid "$RUN" 2>/dev/null || true

if [ "$open_all" = 1 ]; then
  echo "bridge: egress OPEN (no domain filtering)"
else
  echo "bridge: allowlist active ($(grep -c . "$ALLOWED") domains), CONNECT ports: $connect_ports"
fi
echo "bridge: $(grep -cE '^[0-9]' "$OPEN" 2>/dev/null || echo 0) open node(s)"

# ---- curated TCP forwards to the host ----
if [ -f "$FWD" ]; then
  while read -r name listen target _rest; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ -z "${listen:-}" ] || [ -z "${target:-}" ]; then
      echo "bridge: skipping malformed forward line: $name"
      continue
    fi
    echo "bridge: forward bridge:$listen -> $target  ($name)"
    socat "TCP-LISTEN:$listen,fork,reuseaddr" "TCP:$target" &
  done < "$FWD"
fi

# squid becomes the main process; `hive <node> net on/off` reconfigures it live.
# -d1 mirrors squid's log to stderr so `docker logs hive-bridge` shows it.
exec squid -N -d1 -f "$CONF"
