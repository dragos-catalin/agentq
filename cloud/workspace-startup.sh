#!/usr/bin/env bash
# devcloud warm workspace bootstrap (DC-034/035). Idempotent: runs on every boot; installs once.
# Local SSD (if any) -> /work (node_modules, .turbo, target, pnpm store: fast scratch).
# Boot disk (Hyperdisk) keeps the toolchain; the git checkouts live on /work and are re-fetched by
# bundle when the SSD was discarded (resume after a discard-local-ssd suspend).
set -euo pipefail
exec > >(tee -a /var/log/devcloud-startup.log) 2>&1
# A rerun over ssh (workspace.ps1 -UpdateAgent) starts in the caller's home, which `dev` cannot
# read: pnpm then dies with ERR_PNPM_CLI_PREFIX_IO_ERROR and set -e skipped everything after it.
cd /
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
  # The baked image already carries pnpm from its own release tarball (/usr/local/bin/pnpm is a
  # symlink into /opt/pnpm), and `npm install -g` refuses to overwrite a file it does not own:
  # `npm error code EEXIST / npm error path /usr/local/bin/pnpm`, which `set -e` turns into a
  # failed boot - the runner agent never starts and every job queues forever. Measured 2026-11-25
  # on ws-brivio and ws-caelia-android, 37-58 s into the first boot. Keep the image's pnpm when it
  # is already usable (repos pin their own version through packageManager); only a workspace
  # without one installs it with npm.
  if pnpm --version >/dev/null 2>&1; then
    echo "startup: pnpm $(pnpm --version) already present (image), keeping it over $PNPM_VERSION"
  else
    npm install -g "pnpm@${PNPM_VERSION}"
  fi
  # Tailscale (joined by DC-055 with an OAuth client; installed now so the image has it)
  curl -fsSL https://tailscale.com/install.sh | sh || true
  mkdir -p /opt/devcloud && touch /opt/devcloud/.installed-$NODE_VERSION-$PNPM_VERSION
  # file watchers for dev servers / vitest
  echo 'fs.inotify.max_user_watches=1048576' > /etc/sysctl.d/90-devcloud.conf; sysctl --system >/dev/null
fi
sudo -u dev -H bash -lc "pnpm config set store-dir /work/.pnpm-store >/dev/null"

# --- Rust + Tauri 2 Linux libraries (vitals: Linux clippy/test from verify.ps1, QA2-4). Separate
# marker so existing workspaces pick it up on the next boot or -UpdateAgent without a node reinstall.
# rustup default stays `stable`; repos pin their own toolchain (rust-toolchain.toml / CI 1.99.0) and
# rustup installs that on first use. CARGO_TARGET_DIR is left alone: each repo's target/ is on /work.
RUST_TOOLCHAIN="$(md rust-toolchain)"; RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.99.0}"
if [ ! -f /opt/devcloud/.rust-$RUST_TOOLCHAIN ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf libxdo-dev
  sudo -u dev -H bash -c 'command -v rustup >/dev/null 2>&1 || ~/.cargo/bin/rustup --version >/dev/null 2>&1 || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable -c clippy,rustfmt'
  sudo -u dev -H bash -c "~/.cargo/bin/rustup toolchain install $RUST_TOOLCHAIN --profile minimal -c clippy,rustfmt"
  touch /opt/devcloud/.rust-$RUST_TOOLCHAIN
fi

# --- optional toolchains (metadata devcloud-toolchains, comma list). android-jdk21 = Temurin 21 +
# Android SDK + PowerShell 7 (watch-faces Gradle gates, ws-watch-faces). Job env goes to
# /etc/devcloud/env (systemd EnvironmentFile of the agent) and /etc/profile.d (bash -lc).
# Same picks as vmui infra/devcloud/images/image-setup.sh (jdk/android layers). The SDK is owned by
# dev so AGP can auto-install a platform/build-tools a repo asks for later.
TOOLCHAINS="$(md devcloud-toolchains)"
mkdir -p /etc/devcloud
: > /etc/devcloud/env.new
case ",$TOOLCHAINS," in *,android-jdk21,*)
  A=/opt/android-sdk; J=/usr/lib/jvm/temurin-21-jdk-amd64
  if [ ! -f /opt/devcloud/.android-jdk21-v1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /usr/share/keyrings/adoptium.gpg
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main" > /etc/apt/sources.list.d/adoptium.list
    curl -fsSL -o /tmp/msprod.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb && dpkg -i /tmp/msprod.deb >/dev/null
    apt-get update
    apt-get install -y --no-install-recommends temurin-21-jdk powershell
    mkdir -p "$A/cmdline-tools"
    if [ ! -x "$A/cmdline-tools/latest/bin/sdkmanager" ]; then
      curl -fsSL -o /tmp/clt.zip "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
      rm -rf "$A/cmdline-tools/cmdline-tools" && unzip -q /tmp/clt.zip -d "$A/cmdline-tools" && rm -rf "$A/cmdline-tools/latest" && mv "$A/cmdline-tools/cmdline-tools" "$A/cmdline-tools/latest" && rm /tmp/clt.zip
    fi
    SDKM="$A/cmdline-tools/latest/bin/sdkmanager"
    export JAVA_HOME=$J
    yes | "$SDKM" --sdk_root="$A" --licenses >/dev/null 2>&1 || true
    LIST="$("$SDKM" --sdk_root="$A" --list 2>/dev/null)"
    # Full package ids (platforms;android-37.0 since API 36.1); stable only.
    PLAT="$(echo "$LIST" | grep -oE 'platforms;android-[0-9]+(\.[0-9]+)?( |$)' | tr -d ' ' | sort -V | uniq | tail -1)"
    BT="$(echo "$LIST" | grep -oE 'build-tools;[0-9]+\.[0-9]+\.[0-9]+( |$)' | tr -d ' ' | sort -V | uniq | tail -1)"
    echo "::android-pick plat=$PLAT bt=$BT"
    [ -n "$PLAT" ] && [ -n "$BT" ]
    "$SDKM" --sdk_root="$A" --install platform-tools "platforms;android-36" "$PLAT" "$BT" >/dev/null
    chown -R dev:dev "$A"
    touch /opt/devcloud/.android-jdk21-v1
  fi
  printf 'JAVA_HOME=%s\nANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$J" "$A" "$A" >> /etc/devcloud/env.new
  ;;
esac
# jdk21 = Temurin 21 and nothing else. Added 2026-11-26 for ws-brivio, whose land gate runs
# `@brivio/tax-ro:test`: that suite shells out to scripts/validate-declaration.mjs, which builds
# tools/duk/shim/BrivioDuk.java with javac and EXITS 2 when there is no JVM on PATH - on purpose
# ("a gate that quietly does nothing is indistinguishable from a gate that passed"). So a workspace
# with no JDK cannot go green on any branch. Measured on ws-brivio 2026-11-26 with an empty
# devcloud-toolchains: `land-gate: 116/117 green in 136 s`, the only red member
# `@brivio/tax-ro:test: + harness fault: no JVM on PATH`, and nothing to fix in the branch itself.
# `android-jdk21` would also satisfy javac but drags the Android SDK (~1.5 GB) onto a runner that
# builds no APK; keep this one for JDK-only gates (brivio's own CI android job has its own image).
case ",$TOOLCHAINS," in *,jdk21,*)
  J=/usr/lib/jvm/temurin-21-jdk-amd64
  if [ ! -f /opt/devcloud/.jdk21-v1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /usr/share/keyrings/adoptium.gpg
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main" > /etc/apt/sources.list.d/adoptium.list
    apt-get update
    apt-get install -y --no-install-recommends temurin-21-jdk
    # javac, not just java: the DUK shim compiles. Ubuntu's alternatives put it on /usr/bin, which
    # is already on the job user's PATH; JAVA_HOME is for Gradle/AGP-style consumers.
    "$J/bin/javac" -version
    touch /opt/devcloud/.jdk21-v1
  fi
  printf 'JAVA_HOME=%s\n' "$J" >> /etc/devcloud/env.new
  ;;
esac
# python-uv = uv (Astral) in /usr/local/bin + a managed CPython, for every Python repo on the VM. Added
# 2026-11-25: the image had no uv, so each frontier gate bootstrapped it into $HOME/.local/bin on every
# fresh job (~20 s + a network dependency on astral.sh inside a run that should be measuring math).
# uv installs to /usr/local/bin (`sudo`-free for jobs) and its cache lives on the boot disk.
case ",$TOOLCHAINS," in *,python-uv,*)
  if [ ! -f /opt/devcloud/.python-uv-v1 ]; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
    mkdir -p /work/.uv-cache && chown dev:dev /work/.uv-cache
    sudo -u dev -H env UV_CACHE_DIR=/work/.uv-cache bash -lc '/usr/local/bin/uv python install 3.12 3.13' || true
    /usr/local/bin/uv --version
    touch /opt/devcloud/.python-uv-v1
  fi
  # UV_CACHE_DIR only: the VM keeps one cache across jobs, and repos still choose their own interpreter.
  printf 'UV_CACHE_DIR=%s\n' /work/.uv-cache >> /etc/devcloud/env.new
  ;;
esac
# flutter = the image bakes the SDK at /home/runner/flutter (image-setup.sh `step flutter`) and
# publishes its bin only into a GitHub-runner `.path` file, while devcloud jobs run as `dev`. Added
# 2026-11-25 for ws-caelia-android: with no `flutter` branch the case fell through, so the workspace had
# no flutter/dart on PATH, no JAVA_HOME/ANDROID_HOME, and an EMPTY /etc/devcloud/env - the APK job died
# with `no flutter SDK on this workspace`.
# The SDK is COPIED to /opt/flutter and owned by dev, once (stamp): the job user must be able to WRITE
# bin/cache (flutter rewrites its lockfile and stamps on each run), and chowning the image's own tree
# would break the GitHub runner still using it.
case ",$TOOLCHAINS," in *,flutter,*)
  # The image bakes exactly ONE Flutter - whatever `stable` was at image build time - while a repo pins
  # its own. caelia pins 3.47.3 and the image has 3.50.1, whose android plugin now demands AGP >= 9.1.1
  # and refuses the 9.1.0 the repo pins (`Your project's Android Gradle Plugin version 9.1.0 is lower
  # than Flutter's minimum supported version 9.1.1`). Installing the exact tag keeps the pool build equal
  # to the workstation build instead of quietly upgrading the toolchain under the repo.
  FV="$(md devcloud-flutter-version)"
  if [ -n "$FV" ]; then
    F="/opt/flutter-$FV"
    if [ ! -f "/opt/devcloud/.flutter-$FV-v1" ]; then
      echo "::flutter-install version=$FV into $F"
      rm -rf "$F"
      # `/opt` is root-owned and `git clone` creates its target directory itself - as `dev` that is an
      # instant EACCES. Measured: the whole install died 1.4 s in and fell back to the image's Flutter.
      install -d -o dev -g dev "$F"
      if sudo -u dev -H git clone -q --depth 1 -b "$FV" https://github.com/flutter/flutter.git "$F" \
          >/var/log/devcloud-flutter-clone.log 2>&1 && [ -x "$F/bin/flutter" ]; then
        sudo -u dev -H "$F/bin/flutter" precache --android --linux >>/var/log/devcloud-flutter-clone.log 2>&1 || true
        touch "/opt/devcloud/.flutter-$FV-v1"
      else
        echo "::flutter-install FAILED for $FV"
        tail -6 /var/log/devcloud-flutter-clone.log 2>/dev/null | sed -e 's/^/::flutter-clone: /' || true
      fi
    fi
  fi
  if [ -z "$FV" ] || [ ! -x "$F/bin/flutter" ]; then
    F=/opt/flutter
    if [ ! -f /opt/devcloud/.flutter-v1 ]; then
      SRC="$(find /home /opt /usr/local /srv -maxdepth 4 -type f -path '*/bin/flutter' -printf '%h\n' 2>/dev/null | head -1 || true)"
      SRC="${SRC%/bin}"
      if [ -n "$SRC" ] && [ "$SRC" != "$F" ] && [ -x "$SRC/bin/flutter" ]; then
        echo "::flutter-copy src=$SRC"
        rm -rf "$F"
        cp -a "$SRC" "$F"
        chown -R dev:dev "$F"
        if [ -d /opt/android-sdk ]; then chown -R dev:dev /opt/android-sdk; fi
        touch /opt/devcloud/.flutter-v1
      elif [ -x "$F/bin/flutter" ]; then
        touch /opt/devcloud/.flutter-v1
      else
        echo "::flutter-no-sdk (nothing under /home /opt /usr/local /srv at depth 4)"
      fi
    fi
  fi
  if [ -x "$F/bin/flutter" ]; then
    chown -R dev:dev "$F"
    ln -sfn "$F/bin/flutter" /usr/local/bin/flutter
    ln -sfn "$F/bin/dart" /usr/local/bin/dart
    git config --system --add safe.directory "$F" || true
    A=/opt/android-sdk; J=/usr/lib/jvm/temurin-21-jdk-amd64
    if [ -d "$A" ]; then printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$A" "$A" >> /etc/devcloud/env.new; fi
    if [ -d "$J" ]; then printf 'JAVA_HOME=%s\n' "$J" >> /etc/devcloud/env.new; fi
    VERS="$("$F/bin/flutter" --version 2>/dev/null | head -1 || true)"
    echo "::flutter-ready root=$F version=$VERS java=$J android=$A"
  fi
  ;;
esac
# --- docker for job containers. brivio's land gate starts its own pgvector Postgres container, and the
# brivio workspace (ws-brivio, image devcloud-ci-node24) has the docker binary but neither a running
# daemon nor the job user in the `docker` group. Added 2026-11-25 after
# `[gate] docker is not usable on this workspace; the gate's database would not start`.
# Safe everywhere: it does nothing on an image without /usr/bin/docker.
if [ -x /usr/bin/docker ]; then
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker dev >/dev/null 2>&1 || true
  systemctl enable --now docker >/dev/null 2>&1 || true
  echo "::docker service=$(systemctl is-active docker 2>&1 | head -1) group=$(id -nG dev 2>&1)"
fi

mv /etc/devcloud/env.new /etc/devcloud/env
sed -e 's/^\([A-Z_]*\)=\(.*\)$/export \1="\2"/' /etc/devcloud/env > /etc/profile.d/devcloud-env.sh

# --- gh, the GitHub CLI (unconditional, like rust: the CI image's base layer has it since DC-040, and a
# workspace without it cannot read a PR, an issue or a private sibling). Added 2026-11-25.
if [ ! -f /opt/devcloud/.gh-v1 ]; then
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  # jq is needed by the credential block below and only the (skippable) node block installs it.
  apt-get install -y --no-install-recommends gh jq ca-certificates >/dev/null
  gh --version | head -1
  touch /opt/devcloud/.gh-v1
fi

# --- optional GitHub credential (secret devcloud-github-token in the control project). The provisioner
# grants it with -SecretAccess 'dragos-devcloud:devcloud-github-token'; with no grant (or no secret) this
# is a no-op and jobs simply run unauthenticated - never a failed boot. Read straight from the Secret
# Manager REST API with the VM's own metadata token, so no gcloud CLI is needed on the image. The token
# goes to /home/dev/.config/gh/hosts.yml (0600, dev-owned) - the one place `gh` and `git` read it - and
# is never echoed. Rotating the secret: `rm /opt/devcloud/.gh-token-v1` then re-run -UpdateAgent.
if [ ! -f /opt/devcloud/.gh-token-v1 ]; then
  GH_SECRET="$(md devcloud-github-token-secret)"; GH_SECRET="${GH_SECRET:-devcloud-github-token}"
  GH_SP="$(md devcloud-secret-project)"
  GH_VAL=''
  if [ -n "$GH_SP" ] && command -v gh >/dev/null 2>&1; then
    MT="$(curl -fsS -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' 2>/dev/null | jq -r '.access_token // empty' || true)"
    if [ -n "$MT" ]; then
      GH_VAL="$(curl -fsS -H "Authorization: Bearer $MT" "https://secretmanager.googleapis.com/v1/projects/$GH_SP/secrets/$GH_SECRET/versions/latest:access" 2>/dev/null | jq -r '.payload.data // empty' | base64 -d 2>/dev/null || true)"
      case "$GH_VAL" in ''|null|*'<'*'Error'*) GH_VAL='' ;; esac
    fi
  fi
  if [ -n "$GH_VAL" ]; then
    install -d -o dev -g dev -m 700 /home/dev/.config/gh
    printf 'github.com:\n    oauth_token: %s\n    git_protocol: https\n    user: devcloud\n' "$GH_VAL" > /home/dev/.config/gh/hosts.yml
    chown dev:dev /home/dev/.config/gh/hosts.yml; chmod 600 /home/dev/.config/gh/hosts.yml
    sudo -u dev -H bash -lc 'gh auth setup-git' >/dev/null 2>&1 || true
    echo "github credential: installed for dev ($GH_SP/$GH_SECRET)"
    touch /opt/devcloud/.gh-token-v1
  else
    echo "github credential: not available ($GH_SP/$GH_SECRET unreadable or absent) - jobs run without gh auth"
  fi
  unset GH_VAL MT
fi

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
EnvironmentFile=-/etc/devcloud/env
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
