# hive/root — the control plane: node image + docker CLI.
FROM hive/node

ARG DOCKER_VERSION=27.5.1
RUN arch="$(uname -m)" \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VERSION}.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1 docker/docker

# Make `hive` available in root's PATH, pointing at the live copy under the
# /workspace directory mount (a single-file bind mount would pin a stale inode).
RUN ln -sf /workspace/bin/hive /usr/local/bin/hive
