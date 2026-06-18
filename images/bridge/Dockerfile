FROM alpine:3.20

# squid: per-source egress ACLs (curated allowlist + per-node "open" set).
# socat: curated TCP forwards to the host.
RUN apk add --no-cache squid socat bash curl \
 && mkdir -p /run/hive /var/log/squid /var/cache/squid \
 && chown -R squid:squid /run/hive /var/log/squid /var/cache/squid

COPY images/bridge/entrypoint.sh /usr/local/bin/bridge-entrypoint
COPY images/bridge/reopen.sh /usr/local/bin/reopen
RUN chmod +x /usr/local/bin/bridge-entrypoint /usr/local/bin/reopen

EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/bridge-entrypoint"]
