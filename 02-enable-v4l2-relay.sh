#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$PREFIX/lib/x86_64-linux-gnu}"
UNIT="/etc/systemd/system/redrix-camera-relay.service"
RUNNER="/usr/local/bin/redrix-camera-relay-run"
DEFAULTS="/etc/default/redrix-camera-relay"

usage() {
  cat <<USAGE
Usage:
  $0                 install, enable, and start the libcamera relay
  $0 --status        show service and stream status
  $0 --stop          stop only the libcamera relay
  $0 --revert        disable this relay and re-enable v4l2-relayd@default

The relay feeds the existing v4l2loopback camera, normally /dev/video0.
USAGE
}

require_install() {
  if [[ ! -x "$PREFIX/bin/cam" ]]; then
    echo "Missing $PREFIX/bin/cam. Run 01-build-libcamera.sh first." >&2
    exit 1
  fi
  if [[ ! -d "$LIBDIR/gstreamer-1.0" ]]; then
    echo "Missing $LIBDIR/gstreamer-1.0. The libcamera GStreamer plugin was not installed." >&2
    exit 1
  fi
}

status() {
  echo "=== redrix-camera-relay ==="
  systemctl --no-pager --full status redrix-camera-relay.service || true
  echo
  echo "=== old Intel relay ==="
  systemctl --no-pager --full status v4l2-relayd@default.service || true
  echo
  echo "=== /dev/video0 formats ==="
  v4l2-ctl --list-formats-ext -d /dev/video0 || true
  echo
  echo "=== /dev/video0 30-frame read test ==="
  set +e
  timeout 8s v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=30 --stream-to=/dev/null
  rc=$?
  set -e
  echo "exit=$rc"
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
    sudo systemctl stop redrix-camera-relay.service
    exit 0
    ;;
  --revert)
    sudo systemctl disable --now redrix-camera-relay.service || true
    sudo systemctl enable --now v4l2-relayd.service || true
    sudo systemctl enable --now v4l2-relayd@default.service || true
    echo "Reverted to v4l2-relayd@default.service."
    exit 0
    ;;
esac

require_install

sudo install -D -m 0755 /dev/stdin "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/default/redrix-camera-relay ]]; then
  # shellcheck disable=SC1091
  source /etc/default/redrix-camera-relay
fi

PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$PREFIX/lib/x86_64-linux-gnu}"
DEVICE="${REDRIX_VIDEO_DEVICE:-/dev/video0}"
SOURCE_CAPS="${REDRIX_SOURCE_CAPS:-video/x-raw,width=1280,height=720,framerate=30/1}"
SINK_CAPS="${REDRIX_SINK_CAPS:-video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1}"

export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GST_PLUGIN_PATH="$LIBDIR/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
export LIBCAMERA_DATA_DIR="$PREFIX/share/libcamera"
export LIBCAMERA_IPA_MODULE_PATH="$LIBDIR/libcamera/ipa"
export LIBCAMERA_IPA_CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa"
export LIBCAMERA_IPA_PROXY_PATH="$PREFIX/libexec/libcamera"

if [[ ! -e "$DEVICE" ]]; then
  echo "$DEVICE does not exist. v4l2loopback is not loaded." >&2
  exit 1
fi

pipeline=(/usr/bin/gst-launch-1.0 -e libcamerasrc)
if [[ -n "$SOURCE_CAPS" ]]; then
  pipeline+=(! "$SOURCE_CAPS")
fi
pipeline+=(
  ! queue max-size-buffers=4 leaky=downstream
  ! videoconvert
  ! videoscale
  ! "$SINK_CAPS"
  ! v4l2sink device="$DEVICE" sync=false
)

exec "${pipeline[@]}"
RUNNER_EOF

sudo install -D -m 0644 /dev/stdin "$DEFAULTS" <<DEFAULTS_EOF
# Redrix libcamera relay settings.
REDRIX_LIBCAMERA_PREFIX=$PREFIX
REDRIX_LIBCAMERA_LIBDIR=$LIBDIR
REDRIX_VIDEO_DEVICE=/dev/video0

# The Redrix HI556 simple pipeline currently outputs RGBA. Do not force NV12
# here; videoconvert below produces the browser-friendly YUY2 stream.
#
# If negotiation fails, try an empty source caps line:
# REDRIX_SOURCE_CAPS=
REDRIX_SOURCE_CAPS=video/x-raw,width=1280,height=720,framerate=30/1
REDRIX_SINK_CAPS=video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1
DEFAULTS_EOF

sudo install -D -m 0644 /dev/stdin "$UNIT" <<UNIT_EOF
[Unit]
Description=Redrix HI556 libcamera relay to v4l2loopback
Documentation=file://$SCRIPT_DIR/README.md
Wants=modprobe@v4l2loopback.service systemd-udev-settle.service
After=modprobe@v4l2loopback.service systemd-udev-settle.service systemd-logind.service
Conflicts=v4l2-relayd.service v4l2-relayd@default.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/redrix-camera-relay
ExecStartPre=/bin/sh -c 'test -e "\${REDRIX_VIDEO_DEVICE:-/dev/video0}"'
ExecStart=$RUNNER
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "==> Stopping the old Intel icamerasrc relay"
sudo systemctl disable --now v4l2-relayd@default.service || true
sudo systemctl disable --now v4l2-relayd.service || true

echo "==> Starting Redrix libcamera relay"
sudo systemctl daemon-reload
sudo systemctl enable --now redrix-camera-relay.service

echo
echo "Relay started. Check it with:"
echo "  $0 --status"
