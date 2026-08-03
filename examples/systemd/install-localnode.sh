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

echo "== 3. create config directory =="
# /var/lib, /var/cache, /run/localnode are created and owned automatically by
# the unit's StateDirectory=/CacheDirectory=/RuntimeDirectory= at start, so we
# only need the config dir here.
run mkdir -p /etc/localnode

echo "== 4. config =="
# Write a MINIMAL working default whose writable paths all live under the
# systemd-managed dirs, so it starts with the shipped unit as-is (no
# ReadWritePaths / manual chown needed). config.example.yaml is the full
# annotated reference — do NOT install it verbatim (it enables HTTPS /
# federation pointing at paths/hosts that won't exist and would fail to start).
if [[ ! -f /etc/localnode/config.yaml ]]; then
  cat > /etc/localnode/config.yaml <<'YAML'
# LocalNode service config — minimal defaults for the systemd unit.
# All writable paths are under the systemd-managed dirs, so this works with the
# shipped unit as-is. See /opt/localnode or the repo examples/config.example.yaml
# for every available option (HTTPS, passkey accounts, federation, etc.).
server:
  port: 8080
  dir: /var/lib/localnode/share          # shared folder (inside StateDirectory)
  cache-dir: /var/cache/localnode
  state-file: /var/lib/localnode/state.json
  # pin: omitted -> a random PIN is generated and printed to the journal at start
  #   (find it with: journalctl -u localnode | grep -i pin)
YAML
  # Readable by the service user (group), not world-readable (may hold secrets).
  run chown "root:$USER_NAME" /etc/localnode/config.yaml
  run chmod 0640 /etc/localnode/config.yaml
  echo "  wrote a minimal /etc/localnode/config.yaml (edit to taste)"
else
  echo "  /etc/localnode/config.yaml already exists, leaving it"
fi

echo "== 5. install unit =="
run install -m 0644 "$SVC_DIR/localnode.service" /etc/systemd/system/localnode.service
run systemctl daemon-reload

echo
echo "Done. The default config works out of the box. Start it with:"
echo "  sudo systemctl enable --now localnode"
echo "  journalctl -u localnode -f      # note the PIN printed on start"
echo
echo "To serve files from a path OUTSIDE the managed dirs (e.g. /srv/share or an"
echo "external disk), set server.dir to it in /etc/localnode/config.yaml AND add"
echo "  ReadWritePaths=<that path>   to the unit (systemctl edit --full localnode),"
echo "then: sudo mkdir -p <path> && sudo chown -R $USER_NAME:$USER_NAME <path>"
