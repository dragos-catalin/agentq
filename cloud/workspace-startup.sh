#!/usr/bin/env bash
# devcloud warm workspace bootstrap (DC-034/035). Idempotent: runs on every boot; installs once.
# Local SSD (if any) -> /work (node_modules, .turbo, target, pnpm store: fast scratch).
# Boot disk (Hyperdisk) keeps the toolchain; the git checkouts live on /work and are re-fetched by
# bundle when the SSD was discarded (resume after a discard-local-ssd suspend).
set -euo pipefail
exec > >(tee -a /var/log/devcloud-startup.log) 2>&1
md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }
NODE_VERSION="$(md node-version)"; NODE_VERSION="${NODE_VERSION:-24.21.0}"
PNPM_VERSION="$(md pnpm-version)"; PNPM_VERSION="${PNPM_VERSION:-12.9.1}"

# --- /work on local SSD (NVMe) when present, else a dir on the boot disk
if ! mountpoint -q /work; then
  mkdir -p /work
  dev=$(ls /dev/disk/by-id/google-local-nvme-ssd-0 2>/dev/null || ls /dev/nvme0n2 2>/dev/null || true)
  if [ -n "$dev" ]; then
    if ! blkid "$dev" >/dev/null 2>&1; then mkfs.ext4 -F -E lazy_itable_init=1,lazy_journal_init=1 -m 0 "$dev"; fi
    mount -o discard,defaults,noatime "$dev" /work
  fi
fi
id dev >/dev/null 2>&1 || useradd -m -s /bin/bash dev
chown dev:dev /work

if [ ! -f /opt/devcloud/.installed-$NODE_VERSION-$PNPM_VERSION ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends git curl ca-certificates jq unzip zstd xz-utils build-essential python3 ripgrep pkg-config libssl-dev
  timedatectl set-timezone Europe/Bucharest || true
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" | tar -xJ -C /usr/local --strip-components=1
  npm install -g "pnpm@${PNPM_VERSION}"
  # Tailscale (joined by DC-055 with an OAuth client; installed now so the image has it)
  curl -fsSL https://tailscale.com/install.sh | sh || true
  mkdir -p /opt/devcloud && touch /opt/devcloud/.installed-$NODE_VERSION-$PNPM_VERSION
  # file watchers for dev servers / vitest
  echo 'fs.inotify.max_user_watches=1048576' > /etc/sysctl.d/90-devcloud.conf; sysctl --system >/dev/null
fi
sudo -u dev -H bash -lc "pnpm config set store-dir /work/.pnpm-store >/dev/null"

# --- runner-agent from metadata (always the latest pushed by the provisioner)
mkdir -p /opt/devcloud
md runner-agent > /opt/devcloud/runner-agent.mjs.new && [ -s /opt/devcloud/runner-agent.mjs.new ] && mv /opt/devcloud/runner-agent.mjs.new /opt/devcloud/runner-agent.mjs
cat > /etc/systemd/system/devcloud-agent.service <<'EOF'
[Unit]
Description=devcloud runner-agent
After=network-online.target
Wants=network-online.target
[Service]
User=dev
WorkingDirectory=/work
Environment=HOME=/home/dev
ExecStart=/usr/local/bin/node /opt/devcloud/runner-agent.mjs
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable devcloud-agent
systemctl restart devcloud-agent
echo DEVCLOUD_STARTUP_OK
