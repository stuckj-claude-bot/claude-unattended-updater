#!/bin/bash
# Install the updater from a git checkout and enable its hourly timer.
#
# Prefer the .deb where one exists; it installs the same files system-wide. This
# script exists for machines that install from source.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BIN_DIR" "$UNIT_DIR"
install -m 0755 "$here/bin/claude-unattended-update" "$BIN_DIR/"

# The unit in the repo is the packaged one and points at /usr/bin, which is
# where the .deb puts the binary. A source install lives under $HOME instead.
sed 's|^ExecStart=/usr/bin/claude-unattended-update$|ExecStart=%h/.local/bin/claude-unattended-update|' \
  "$here/systemd/claude-unattended-update.service" > "$UNIT_DIR/claude-unattended-update.service"
chmod 0644 "$UNIT_DIR/claude-unattended-update.service"
install -m 0644 "$here/systemd/claude-unattended-update.timer" "$UNIT_DIR/"

grep -q "ExecStart=%h/.local/bin/claude-unattended-update" \
  "$UNIT_DIR/claude-unattended-update.service" \
  || { echo "FATAL: unit ExecStart was not rewritten; refusing to enable it" >&2; exit 1; }

systemctl --user daemon-reload
systemctl --user enable --now claude-unattended-update.timer

# Without lingering, the timer only runs while you are logged in.
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  echo "NOTE: enable-linger is off; the timer will not run while you are logged out."
  echo "      sudo loginctl enable-linger $USER"
fi

echo "installed. next run:"
systemctl --user list-timers claude-unattended-update --no-pager
