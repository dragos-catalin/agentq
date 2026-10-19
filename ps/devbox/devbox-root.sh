#!/usr/bin/env bash
# devbox system bootstrap (root, idempotent; agentq ADR 0007). Installs:
#   * gh, age, sops, pwsh, acl (setfacl) system tools
#   * agentq system-wide in /opt/agentq (from the agentq checkout passed as $1, default /work/agentq) with
#     /usr/local/bin/agentq (per-user CLI: user store ~/.codai/coord + system store /var/lib/agentq)
#   * /usr/local/sbin/devbox-teams (users / repo groups / /work/<repo> 2770 / system store)
#   * agentq-sweep.timer: root sweep of stale leases every 10 min (system agentq)
# Usage: sudo bash devbox-root.sh [/path/to/agentq-checkout]
set -euo pipefail
SRC="${1:-/work/agentq}"
[ -d "$SRC/ps/bin" ] || SRC=/work/gh/agentq
T=$(mktemp -d)
if ! command -v gh >/dev/null; then
  curl -fsSLo "$T/gh.gpg" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  install -m 0644 "$T/gh.gpg" /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y -qq gh
fi
for p in age acl python3; do dpkg -s "$p" >/dev/null 2>&1 || apt-get install -y -qq "$p"; done
if ! command -v sops >/dev/null; then
  v=3.13.3; curl -fsSLo "$T/sops" "https://github.com/getsops/sops/releases/download/v$v/sops-v$v.linux.amd64"; install -m 0755 "$T/sops" /usr/local/bin/sops
fi
if ! command -v pwsh >/dev/null; then
  . /etc/os-release
  curl -fsSLo "$T/ms.deb" "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  dpkg -i "$T/ms.deb" >/dev/null && apt-get update -qq && apt-get install -y -qq powershell
fi
rm -rf "$T"
# /work root-owned: team repos inside are 2770 per group; nobody but root can rename/replace one
mkdir -p /work && chown root:root /work && chmod 0755 /work
getent group devbox-users >/dev/null || groupadd devbox-users
id dev >/dev/null 2>&1 && usermod -aG devbox-users dev

# --- agentq system install (root-owned code: users run it, nobody but root changes it)
install -d -m 0755 /opt/agentq/bin
cp -f "$SRC"/ps/bin/*.ps1 "$SRC"/ps/bin/*.mjs "$SRC"/ps/bin/agentq-config.json /opt/agentq/bin/ 2>/dev/null || true
install -m 0755 "$SRC/ps/bin/devbox-teams.py" /usr/local/sbin/devbox-teams
chown -R root:root /opt/agentq && chmod -R a+rX,go-w /opt/agentq
cat > /usr/local/bin/agentq <<'EOF'
#!/usr/bin/env bash
# agentq on the devbox: per-user store ~/.codai/coord + system store /var/lib/agentq (ADR 0007)
exec pwsh -NoProfile -File /opt/agentq/bin/agentq.ps1 "$@"
EOF
chmod 0755 /usr/local/bin/agentq
cat > /etc/profile.d/agentq.sh <<'EOF'
# per-user files stay private (u=rwx); repo trees get group rw from their setgid dir + default ACL
umask 0007
export CODAI_WT_ROOT=/work/.wt
EOF

# --- system sweep: stale leases of every user (root reads every user's job registry)
cat > /etc/systemd/system/agentq-sweep.service <<'EOF'
[Unit]
Description=agentq system sweep (stale workspace leases, all users)
[Service]
Type=oneshot
Environment=HOME=/root
Environment=CODAI_WT_ROOT=/work/.wt
ExecStart=/usr/bin/pwsh -NoProfile -File /opt/agentq/bin/agentq.ps1 sweep
Nice=10
EOF
cat > /etc/systemd/system/agentq-sweep.timer <<'EOF'
[Unit]
Description=agentq system sweep every 10 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now agentq-sweep.timer >/dev/null 2>&1 || true
echo ROOT_TOOLS_OK "$(gh --version | head -1)" "$(sops --version 2>/dev/null | head -1)" "pwsh $(pwsh -v 2>/dev/null)" "agentq $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null)"
