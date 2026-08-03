#!/usr/bin/env bash
# Transparent installer for the LocalNode systemd service (Linux).
# It only runs the same steps documented in localnode.service — read it first.
#
# `localnode-cli` needs its web assets (data/flutter_assets/…) next to it, so
# this installs the WHOLE extracted release directory to /opt/localnode, not
# just the binary.
#
# Usage:
#   tar xzf localnode-linux-x64-v*.tar.gz -C /tmp/localnode-dist
#   sudo ./install-localnode.sh /tmp/localnode-dist
#
# Re-running is safe: existing user/dirs/config are left as-is; /opt/localnode
# is refreshed from the given directory.
set -euo pipefail

DIST_SRC="${1:-}"
if [[ -z "$DIST_SRC" || ! -d "$DIST_SRC" || ! -x "$DIST_SRC/localnode-cli" ]]; then
  echo "usage: sudo $0 /path/to/extracted-release-dir  (must contain localnode-cli + data/)" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=localnode
INSTALL_DIR=/opt/localnode

run() { echo "+ $*"; "$@"; }

echo "== 1. install the release bundle to $INSTALL_DIR =="
run mkdir -p "$INSTALL_DIR"
# Copy the whole directory (binary + data/flutter_assets + libs). root-owned,
# read-only for the service user is fine — the CLI only reads its assets.
run cp -a "$DIST_SRC/." "$INSTALL_DIR/"
run chmod 0755 "$INSTALL_DIR/localnode-cli"

echo "== 2. create service user (if missing) =="
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  run useradd --system --home /var/lib/localnode --shell /usr/sbin/nologin "$USER_NAME"
else
  echo "  user '$USER_NAME' already exists, skipping"
fi

echo "== 3. create directories =="
run mkdir -p /etc/localnode /var/lib/localnode /var/cache/localnode /srv/share /run/localnode
# The service runs as $USER_NAME and must be able to write the shared dir and
# its runtime/state/cache dirs.
run chown -R "$USER_NAME:$USER_NAME" /var/lib/localnode /var/cache/localnode /run/localnode /srv/share

echo "== 4. config =="
if [[ ! -f /etc/localnode/config.yaml ]]; then
  if [[ -f "$SVC_DIR/../config.example.yaml" ]]; then
    run install -m 0640 "$SVC_DIR/../config.example.yaml" /etc/localnode/config.yaml
    # Readable by the service user (group), not world-readable (may hold secrets).
    run chown "root:$USER_NAME" /etc/localnode/config.yaml
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
