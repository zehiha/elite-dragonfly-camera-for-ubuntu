#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$PREFIX/lib/x86_64-linux-gnu}"
UNIT="/etc/systemd/system/redrix-camera-on-demand.service"
RUNNER="/usr/local/bin/redrix-camera-on-demand-run"
DEFAULTS="/etc/default/redrix-camera-relay"

usage() {
  cat <<USAGE
Usage:
  $0                 install, enable, and start the on-demand relay
  $0 --status        show service and camera status
  $0 --stop          stop only the on-demand relay
  $0 --revert        disable on-demand mode and re-enable the continuous relay

On-demand mode keeps /dev/video0 configured, but opens the real HI556 camera
only while an application is reading /dev/video0.
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
  echo "=== on-demand relay ==="
  systemctl --no-pager --full status redrix-camera-on-demand.service || true
  echo
  echo "=== continuous relay ==="
  systemctl --no-pager --full status redrix-camera-relay.service || true
  echo
  echo "=== /dev/video0 users ==="
  sudo -n fuser -v /dev/video0 2>&1 || fuser -v /dev/video0 2>&1 || true
  echo
  echo "=== /dev/video0 ==="
  v4l2-ctl --all -d /dev/video0 || true
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
    sudo systemctl stop redrix-camera-on-demand.service
    exit 0
    ;;
  --revert)
    sudo systemctl disable --now redrix-camera-on-demand.service || true
    sudo systemctl enable --now redrix-camera-relay.service || true
    echo "Reverted to the continuous redrix-camera-relay.service."
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
IDLE_WIDTH="${REDRIX_IDLE_WIDTH:-1280}"
IDLE_HEIGHT="${REDRIX_IDLE_HEIGHT:-720}"
IDLE_PIXEL_FORMAT="${REDRIX_IDLE_PIXEL_FORMAT:-YUYV}"
IDLE_FPS="${REDRIX_IDLE_FPS:-30}"
IDLE_SECONDS="${REDRIX_IDLE_SECONDS:-4}"
POLL_SECONDS="${REDRIX_POLL_SECONDS:-0.15}"

export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GST_PLUGIN_PATH="$LIBDIR/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
export LIBCAMERA_DATA_DIR="$PREFIX/share/libcamera"
export LIBCAMERA_IPA_MODULE_PATH="$LIBDIR/libcamera/ipa"
export LIBCAMERA_IPA_CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa"
export LIBCAMERA_IPA_PROXY_PATH="$PREFIX/libexec/libcamera"

child_pid=""
mode=""
idle_since=0

log() {
  echo "$(date --iso-8601=seconds) $*" >&2
}

client_pids() {
  local pid
  { /usr/bin/lsof -t -- "$DEVICE" 2>/dev/null || true; } | while read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$$" ]] && continue
    [[ -n "$child_pid" && "$pid" == "$child_pid" ]] && continue
    echo "$pid"
  done
  return 0
}

configure_idle_device() {
  /usr/bin/v4l2-ctl -d "$DEVICE" \
    --set-fmt-video="width=${IDLE_WIDTH},height=${IDLE_HEIGHT},pixelformat=${IDLE_PIXEL_FORMAT}" \
    --set-parm="$IDLE_FPS" >/dev/null 2>&1 || true

  /usr/bin/v4l2-ctl -d "$DEVICE" \
    --set-ctrl=keep_format=1,sustain_framerate=1,timeout=3000 >/dev/null 2>&1 || true
}

stop_child() {
  local pid="$child_pid"
  [[ -n "$pid" ]] || return 0

  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  child_pid=""
}

enter_idle() {
  configure_idle_device
  log "idle; real camera is closed"
  mode="idle"
  idle_since=0
}

start_camera() {
  log "starting real camera stream"
  local pipeline=(/usr/bin/gst-launch-1.0 -q -e libcamerasrc)
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
  "${pipeline[@]}" &
  child_pid="$!"
  mode="camera"
  idle_since=0
}

cleanup() {
  stop_child
}
trap cleanup EXIT INT TERM

if [[ ! -e "$DEVICE" ]]; then
  echo "$DEVICE does not exist. v4l2loopback is not loaded." >&2
  exit 1
fi

enter_idle

while true; do
  if [[ -n "$child_pid" ]] && ! kill -0 "$child_pid" 2>/dev/null; then
    wait "$child_pid" 2>/dev/null || true
    log "$mode stream exited unexpectedly"
    child_pid=""
    if [[ -n "$(client_pids)" ]]; then
      start_camera
    else
      enter_idle
    fi
  fi

  clients="$(client_pids | tr '\n' ' ')"
  now="$(date +%s)"

  if [[ -n "$clients" ]]; then
    idle_since=0
    if [[ "$mode" != "camera" ]]; then
      log "client(s) detected on $DEVICE: $clients"
      start_camera
    fi
  elif [[ "$mode" == "camera" ]]; then
    if [[ "$idle_since" == "0" ]]; then
      idle_since="$now"
    elif (( now - idle_since >= IDLE_SECONDS )); then
      log "no clients for ${IDLE_SECONDS}s; closing real camera"
      stop_child
      enter_idle
    fi
  fi

  sleep "$POLL_SECONDS"
done
RUNNER_EOF

sudo install -D -m 0644 /dev/stdin "$DEFAULTS" <<DEFAULTS_EOF
# Redrix libcamera relay settings.
REDRIX_LIBCAMERA_PREFIX=$PREFIX
REDRIX_LIBCAMERA_LIBDIR=$LIBDIR
REDRIX_VIDEO_DEVICE=/dev/video0

# Real camera source. The Redrix HI556 simple pipeline currently outputs RGBA;
# videoconvert below produces the browser-friendly YUY2 stream.
REDRIX_SOURCE_CAPS=video/x-raw,width=1280,height=720,framerate=30/1
REDRIX_SINK_CAPS=video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1

# Idle device format. No fake black producer is kept alive; Chrome sees the
# configured v4l2loopback device, and the real camera starts when a client opens
# it.
REDRIX_IDLE_WIDTH=1280
REDRIX_IDLE_HEIGHT=720
REDRIX_IDLE_PIXEL_FORMAT=YUYV
REDRIX_IDLE_FPS=30
REDRIX_IDLE_SECONDS=4
REDRIX_POLL_SECONDS=0.75
DEFAULTS_EOF

sudo install -D -m 0644 /dev/stdin "$UNIT" <<UNIT_EOF
[Unit]
Description=Redrix HI556 on-demand camera relay
Documentation=file://$SCRIPT_DIR/README.md
Wants=modprobe@v4l2loopback.service systemd-udev-settle.service
After=modprobe@v4l2loopback.service systemd-udev-settle.service systemd-logind.service
Conflicts=redrix-camera-relay.service v4l2-relayd.service v4l2-relayd@default.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/redrix-camera-relay
ExecStartPre=/bin/sh -c 'test -e "\${REDRIX_VIDEO_DEVICE:-/dev/video0}"'
ExecStart=$RUNNER
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "==> Stopping continuous camera services"
sudo systemctl disable --now redrix-camera-relay.service || true
sudo systemctl disable --now v4l2-relayd@default.service || true
sudo systemctl disable --now v4l2-relayd.service || true

echo "==> Starting on-demand camera relay"
sudo systemctl daemon-reload
sudo systemctl enable --now redrix-camera-on-demand.service

echo
echo "On-demand relay started. Check it with:"
echo "  $0 --status"
