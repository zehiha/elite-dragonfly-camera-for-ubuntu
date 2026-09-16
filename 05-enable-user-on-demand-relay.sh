#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/redrix-camera-on-demand.service"

usage() {
  cat <<USAGE
Usage:
  $0           install, enable, and start the user on-demand relay
  $0 --status  show the user service and /dev/video0 state
  $0 --stop    stop the user on-demand relay

This mode keeps /dev/video0 visible, but opens the real HI556 camera only while
an application is reading it.
USAGE
}

status() {
  systemctl --user --no-pager --full status redrix-camera-on-demand.service || true
  echo
  systemctl --user --no-pager --full status redrix-camera-relay.service || true
  echo
  fuser -v /dev/video0 2>&1 || true
  echo
  v4l2-ctl -d /dev/video0 --all || true
}

case "${1:-install}" in
  --help|-h)
    usage
    exit 0
    ;;
  --status)
    status
    exit 0
    ;;
  --stop)
    systemctl --user stop redrix-camera-on-demand.service
    exit 0
    ;;
esac

chmod +x "$SCRIPT_DIR/redrix-camera-daemon.py" "$SCRIPT_DIR/redrix-camera-on-demand-user-run"
if [[ ! -x "$SCRIPT_DIR/redrix-video-watch" || "$SCRIPT_DIR/redrix-video-watch.c" -nt "$SCRIPT_DIR/redrix-video-watch" ]]; then
  gcc -O2 -Wall -Wextra -o "$SCRIPT_DIR/redrix-video-watch" "$SCRIPT_DIR/redrix-video-watch.c"
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Redrix HI556 user on-demand camera relay
Documentation=file://$SCRIPT_DIR/README.md
After=default.target
Conflicts=redrix-camera-relay.service
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
Environment=REDRIX_USER_POLL_SECONDS=0.5
Environment=REDRIX_VIDEO_DEVICE=/dev/video0
Environment=REDRIX_IDLE_WIDTH=640
Environment=REDRIX_IDLE_HEIGHT=480
Environment=REDRIX_OUTPUT_CAPS=video/x-raw,format=YUY2,width=640,height=480,framerate=30/1
Environment=REDRIX_SINK_CAPS=video/x-raw,format=YUY2,width=640,height=480,framerate=30/1
ExecStartPre=/usr/bin/test -e /dev/video0
ExecStartPre=/bin/sh -c 'grep -Fxq "Intel MIPI Camera" /sys/class/video4linux/video0/name'
ExecStart=$SCRIPT_DIR/redrix-camera-on-demand-user-run
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT_EOF

systemctl --user daemon-reload
systemctl --user disable --now redrix-camera-relay.service >/dev/null 2>&1 || true
systemctl --user enable redrix-camera-on-demand.service
systemctl --user reset-failed redrix-camera-on-demand.service >/dev/null 2>&1 || true
systemctl --user restart redrix-camera-on-demand.service
sleep 1
if ! systemctl --user is-active --quiet redrix-camera-on-demand.service; then
  systemctl --user --no-pager --full status redrix-camera-on-demand.service >&2 || true
  exit 1
fi
systemctl --user try-restart wireplumber.service xdg-desktop-portal.service >/dev/null 2>&1 || true

echo "User on-demand relay is active. The real camera opens only while a client reads /dev/video0."
