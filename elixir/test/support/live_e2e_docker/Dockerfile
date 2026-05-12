FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    git \
    openssh-server \
    python3 \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN install -d -m 700 /root/.ssh /root/.codex /run/symphony/ssh /var/run/sshd

RUN set -eux; \
  npm config set registry https://registry.npmmirror.com; \
  codex_version="$(npm view @openai/codex version)"; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    arm64) codex_platform="linux-arm64" ;; \
    amd64) codex_platform="linux-x64" ;; \
    *) echo "unsupported Codex worker architecture: $arch" >&2; exit 1 ;; \
  esac; \
  npm install --global \
    "@openai/codex@${codex_version}" \
    "@openai/codex-${codex_platform}@npm:@openai/codex@${codex_version}-${codex_platform}"; \
  codex --version

COPY symphony-live-worker.conf /etc/ssh/sshd_config.d/symphony-live-worker.conf
COPY live_worker_entrypoint.sh /usr/local/bin/symphony-live-worker
RUN chmod 755 /usr/local/bin/symphony-live-worker

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/symphony-live-worker"]
