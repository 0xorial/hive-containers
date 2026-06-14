# hive/node — base image for every hive container: Claude Code + dev tools.
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash zsh git curl wget jq ripgrep less procps sudo openssh-client \
      openssh-server ca-certificates gnupg gosu nano vim tmux unzip \
      python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (also configures git's credential helper for HTTPS auth).
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Rich toolset for the agents working inside nodes.
# Network suite:
RUN apt-get update && apt-get install -y --no-install-recommends \
      nmap tcpdump dnsutils iproute2 iputils-ping iputils-tracepath traceroute \
      mtr-tiny netcat-openbsd socat whois net-tools telnet rsync iperf3 \
      ldnsutils ngrep ethtool nftables iptables arp-scan openssl \
 && rm -rf /var/lib/apt/lists/*
# Datastore clients, build toolchain, and CLI utilities:
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client default-mysql-client redis-tools sqlite3 \
      build-essential pkg-config make \
      htop tree file lsof strace bat fd-find httpie zip zstd gettext-base \
      shellcheck moreutils \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

# sshd runs only on demand: the Mac-side ssh config spawns `sshd -i` over
# `docker exec` (stdio), so nodes never listen on any port.
RUN printf '%s\n' \
      'PermitRootLogin no' \
      'AllowUsers dev' \
      'PubkeyAuthentication yes' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'UsePAM no' \
      'PrintMotd no' \
      'LogLevel QUIET' \
      'AuthorizedKeysFile .ssh/authorized_keys' \
      'Subsystem sftp internal-sftp' \
      > /etc/ssh/sshd_config.hive

# SSH logins don't see `docker run -e` vars; the entrypoint persists them to
# /etc/hive-env.sh and these hooks load it for zsh and bash alike.
RUN echo '[ -f /etc/hive-env.sh ] && . /etc/hive-env.sh' >> /etc/zsh/zshenv \
 && echo '[ -f /etc/hive-env.sh ] && . /etc/hive-env.sh' > /etc/profile.d/hive-env.sh

# Rename the stock 'node' user (uid/gid 1000) to 'dev' and give it sudo —
# root inside a node container still can't cross the network boundary.
RUN usermod -l dev node \
 && groupmod -n dev node \
 && usermod -d /home/dev -m dev \
 && usermod -s /bin/zsh dev \
 && usermod -p '*' dev \
 && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

RUN npm install -g @anthropic-ai/claude-code

ENV SHELL=/bin/zsh \
    EDITOR=nano \
    CLAUDE_CONFIG_DIR=/home/dev/.claude \
    DISABLE_AUTOUPDATER=1

RUN mkdir -p /workspace /shared /home/dev/.claude \
 && chown -R dev:dev /workspace /shared /home/dev \
 && printf 'PROMPT="%%F{yellow}%%n@%%m%%f %%F{blue}%%~%%f %%# "\n' > /home/dev/.zshrc \
 && chown dev:dev /home/dev/.zshrc

COPY images/node/entrypoint.sh /usr/local/bin/hive-entrypoint
COPY templates/host-client.py /usr/local/bin/host
RUN chmod +x /usr/local/bin/hive-entrypoint /usr/local/bin/host

WORKDIR /workspace
USER root
ENTRYPOINT ["/usr/local/bin/hive-entrypoint"]
CMD ["sleep", "infinity"]
