#!/usr/bin/env bash
# devbox per-user bootstrap (runs AS the person, e.g. `dev`; agentq ADR 0007). Git-first: repos come from
# GitHub, secrets from sops+age, .git is never file-synced. Clones into /work/<repo> only when the repo does
# not exist yet (a repo already shared by the team is used as-is: access = membership of r-<repo>).
#   REPOS="owner/repo=folder ..." [AGE_KEY_B64=...] [GH_TOKEN=...] bash devbox-user.sh
set -euo pipefail
REPOS="${REPOS:-codai axiom agentq}"
WORK="${WORK:-/work}"
umask 0007
mkdir -p ~/.config/sops/age ~/.codai/coord
chmod 700 ~/.config ~/.codai

for t in gh sops age git; do command -v "$t" >/dev/null || { echo "missing $t (run devbox-root.sh as root)"; exit 2; }; done

# secrets key (passed once, base64, never echoed) - private to this user
if [ -n "${AGE_KEY_B64:-}" ]; then (umask 077; echo "$AGE_KEY_B64" | base64 -d > ~/.config/sops/age/keys.txt); fi
grep -q 'SOPS_AGE_KEY_FILE' ~/.profile 2>/dev/null || echo 'export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt' >> ~/.profile
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt

# GitHub auth (token from the caller's gh, never written to a repo; gh refuses login while GH_TOKEN is exported)
if [ -n "${GH_TOKEN:-}" ]; then _t="$GH_TOKEN"; unset GH_TOKEN; echo "$_t" | gh auth login --with-token; unset _t; gh auth setup-git; fi
git config --global pull.ff only
git config --global fetch.prune true
git config --global core.autocrlf input

for r in $REPOS; do
  folder=""; case "$r" in *=*) folder="${r#*=}"; r="${r%%=*}";; esac
  case "$r" in */*) full="$r";; codai) full=codai-ro/codai-cc;; axiom) full=dragoscv/axiom;; agentq) full=dragos-catalin/agentq;; *) full="dragos-catalin/$r";; esac
  name="${folder:-$(basename "$r")}"
  d="$WORK/$name"
  [ -d "$d/.git" ] || { [ -d "$WORK/gh/$name/.git" ] && d="$WORK/gh/$name"; }
  if [ ! -d "$d/.git" ]; then gh repo clone "$full" "$d" -- --filter=blob:none -q
  elif [ -r "$d/.git/HEAD" ]; then git -C "$d" fetch -q --all || true
  else echo "repo $name: no access (not in group r-$name)"; continue; fi
  # restore encrypted secrets next to their originals (secrets/<rel>.enc -> <rel>), only when the key exists
  if [ -d "$d/secrets" ] && [ -s ~/.config/sops/age/keys.txt ]; then
    (cd "$d" && find secrets -name '*.enc' -type f | while read -r f; do rel="${f#secrets/}"; rel="${rel%.enc}"; [ -e "$rel" ] || { mkdir -p "$(dirname "$rel")"; sops --decrypt --input-type json --output-type binary --output "$rel" "$f" && chmod 660 "$rel"; }; done)
  fi
  echo "repo $full -> $d ($(git -C "$d" rev-parse --short HEAD))"
done
echo DEVBOX_BOOTSTRAP_OK
