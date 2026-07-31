#!/usr/bin/env bash
# Transparent installer for the LocalNode systemd service (Linux).
# It only runs the same steps documented in localnode.service — read it first.
#
# Usage:
#   sudo ./install-localnode.sh /path/to/localnode-cli
#
# Re-running is safe: existing user/dirs/config are left as-is.
set -euo pipefail

BIN_SRC="${1:-}"
if [[ -z "$BIN_SRC" || ! -x "$BIN_SRC" ]]; then
  echo "usage: sudo $0 /path/to/localnode-cli" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=localnode

run() { echo "+ $*"; "$@"; }

echo "== 1. install binary =="
run install -m 0755 "$BIN_SRC" /usr/local/bin/localnode-cli

echo "== 2. create service user (if missing) =="
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  run useradd --system --home /var/lib/localnode --shell /usr/sbin/nologin "$USER_NAME"
else
  echo "  user '$USER_NAME' already exists, skipping"
fi

echo "== 3. create directories =="
run mkdir -p /etc/localnode /var/lib/localnode /var/cache/localnode /srv/share /run/localnode
run chown -R "$USER_NAME:$USER_NAME" /var/lib/localnode /var/cache/localnode /run/localnode

echo "== 4. config =="
if [[ ! -f /etc/localnode/config.yaml ]]; then
  if [[ -f "$SVC_DIR/../config.example.yaml" ]]; then
    run install -m 0640 "$SVC_DIR/../config.example.yaml" /etc/localnode/config.yaml
    echo "  >> edit /etc/localnode/config.yaml before starting the service"
  else
    echo "  !! config.example.yaml not found; create /etc/localnode/config.yaml yourself"
  fi
else
  echo "  /etc/localnode/config.yaml already exists, leaving it"
fi

echo "== 5. install unit =="
run install -m 0644 "$SVC_DIR/localnode.service" /etc/systemd/system/localnode.service
run systemctl daemon-reload

echo
echo "Done. Review /etc/localnode/config.yaml, then:"
echo "  sudo systemctl enable --now localnode"
echo "  journalctl -u localnode -f"
