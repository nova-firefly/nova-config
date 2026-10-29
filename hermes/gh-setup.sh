#!/usr/bin/env bash
# Give Hermes a working, logged-in `gh` so its built-in `github` skill takes its
# normal path (`gh auth status` → gh commands) instead of failing preflight.
#
# Why this is needed:
#   - The image has no `gh`, and the agent can't apt-install (non-root).
#   - Hermes always strips GH_TOKEN/GITHUB_TOKEN from the agent's shells, so gh
#     must authenticate from its file store (hosts.yml), not the environment.
#
# What it does (idempotent; re-run after rotating HERMES_GITHUB_TOKEN):
#   1. Installs gh $GH_VERSION into /opt/data/.local/bin — on the image's PATH and
#      inside the hermes_data volume, so it survives restarts/updates. SHA-256 checked.
#   2. Writes /opt/data/home/.config/gh/hosts.yml (HOME of the agent's tool shells)
#      directly — `gh auth login --with-token` can hang on keyring-less containers.
#
# Usage (host, from the nova-config root):  ./hermes/gh-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

GH_VERSION="${GH_VERSION:-2.103.3}"
TOKEN=$(grep '^HERMES_GITHUB_TOKEN=' .env | head -1 | cut -d= -f2- | tr -d "\"' \r")
[ -n "$TOKEN" ] || { echo "HERMES_GITHUB_TOKEN is not set in .env" >&2; exit 1; }

# Token goes over stdin, never argv (keeps it out of `ps`).
# shellcheck disable=SC2016
printf '%s' "$TOKEN" | docker exec -i -u hermes \
  -e HOME=/opt/data/home -e GH_VERSION="$GH_VERSION" hermes bash -c '
set -euo pipefail
TOKEN=$(cat)
BIN=/opt/data/.local/bin
mkdir -p "$BIN"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

if "$BIN/gh" --version 2>/dev/null | grep -q "gh version $GH_VERSION "; then
  echo "gh $GH_VERSION already installed"
else
  tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT; cd "$tmp"
  f="gh_${GH_VERSION}_linux_${ARCH}.tar.gz"
  base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
  curl -fsSLO "$base/$f"
  curl -fsSLO "$base/gh_${GH_VERSION}_checksums.txt"
  grep " ${f}\$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c -
  tar -xzf "$f"
  install -m 0755 "gh_${GH_VERSION}_linux_${ARCH}/bin/gh" "$BIN/gh"
  echo "installed gh $GH_VERSION"
fi

LOGIN=$(curl -fsS -H "Authorization: token $TOKEN" https://api.github.com/user \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[\"login\"])")
umask 077
mkdir -p "$HOME/.config/gh"
printf "github.com:\n    users:\n        %s:\n            oauth_token: %s\n    git_protocol: https\n    oauth_token: %s\n    user: %s\n" \
  "$LOGIN" "$TOKEN" "$TOKEN" "$LOGIN" > "$HOME/.config/gh/hosts.yml"

"$BIN/gh" auth status
'
