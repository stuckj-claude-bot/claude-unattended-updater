#!/bin/bash
# Install the updater and enable its hourly timer for the current user.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BIN_DIR" "$UNIT_DIR"
install -m 0755 "$here/bin/claude-unattended-update" "$BIN_DIR/"
install -m 0644 "$here/systemd/claude-unattended-update.service" "$UNIT_DIR/"
install -m 0644 "$here/systemd/claude-unattended-update.timer"   "$UNIT_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now claude-unattended-update.timer

# Without lingering, the timer dies with the login session.
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  echo "NOTE: enable-linger is off; the timer will not run while you are logged out."
  echo "      sudo loginctl enable-linger $USER"
fi

echo "installed. next run:"
systemctl --user list-timers claude-unattended-update --no-pager
