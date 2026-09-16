#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$PREFIX/lib/x86_64-linux-gnu}"
DEVICE="${REDRIX_VIDEO_DEVICE:-/dev/video0}"
WIREPLUMBER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/main.lua.d"
V4L2_RELAYD_CONF="/etc/v4l2-relayd.d/default.conf"
V4L2_RELAYD_DROPIN="/etc/systemd/system/v4l2-relayd@default.service.d/10-redrix-yuy2.conf"
V4L2_RELAYD_OLD_DROPIN="/etc/systemd/system/v4l2-relayd@default.service.d/10-force-yuy2.conf"
MODPROBE="${REDRIX_MODPROBE:-/sbin/modprobe}"
LOOPBACK_MAX_BUFFERS="${REDRIX_V4L2LOOPBACK_MAX_BUFFERS:-16}"
LOOPBACK_MAX_OPENERS="${REDRIX_V4L2LOOPBACK_MAX_OPENERS:-32}"
PIPEWIRE_BUILD_DIR="$SCRIPT_DIR/pipewire-build/build-redrix-v4l2"
PIPEWIRE_PLUGIN_SRC="$PIPEWIRE_BUILD_DIR/spa/plugins/v4l2/libspa-v4l2.so"
if [[ -d "$SCRIPT_DIR/spa-0.2" ]]; then
  PIPEWIRE_PLUGIN_DIR="${REDRIX_SPA_PLUGIN_DIR:-$SCRIPT_DIR/spa-0.2}"
else
  PIPEWIRE_PLUGIN_DIR="${REDRIX_SPA_PLUGIN_DIR:-$SCRIPT_DIR/pipewire-build/redrix-spa-0.2}"
fi
PIPEWIRE_DROPIN="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pipewire.service.d/20-redrix-spa.conf"
LOOPBACK_EXCLUSIVE_CAPS="1"

usage() {
  cat <<USAGE
Usage:
  $0           enable automatic on-demand camera mode
  $0 --status  show current camera state
  $0 --stop    stop the user on-demand relay

This exposes a v4l2loopback camera through a user on-demand relay. The user
relay keeps a synthetic stream attached so browsers can list the camera, and
opens the real HI556 sensor only while an application is reading the virtual
camera.
USAGE
}

require_install() {
  local missing=()

  [[ -x "$PREFIX/bin/cam" ]] || missing+=("$PREFIX/bin/cam")
  [[ -d "$LIBDIR/gstreamer-1.0" ]] || missing+=("$LIBDIR/gstreamer-1.0")

  for cmd in fuser gcc gst-launch-1.0 lsmod ninja ps sudo systemctl timeout udevadm v4l2-ctl wpctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ -x "$MODPROBE" ]] || missing+=("$MODPROBE")

  if ((${#missing[@]} > 0)); then
    echo "Missing required camera pieces:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Run ./01-build-libcamera.sh first if the Redrix libcamera files are missing." >&2
    exit 1
  fi
}

build_video_watcher() {
  if [[ ! -x "$SCRIPT_DIR/redrix-video-watch" || "$SCRIPT_DIR/redrix-video-watch.c" -nt "$SCRIPT_DIR/redrix-video-watch" ]]; then
    gcc -O2 -Wall -Wextra -o "$SCRIPT_DIR/redrix-video-watch" "$SCRIPT_DIR/redrix-video-watch.c"
  fi
}

install_pipewire_v4l2_patch() {
  if [[ -r "$PIPEWIRE_PLUGIN_DIR/v4l2/libspa-v4l2.so" ]]; then
    install -D -m 0644 /dev/stdin "$PIPEWIRE_DROPIN" <<CONF
[Service]
Environment=SPA_PLUGIN_DIR=$PIPEWIRE_PLUGIN_DIR
CONF
    systemctl --user daemon-reload
    return 0
  fi

  if [[ ! -d "$PIPEWIRE_BUILD_DIR" ]]; then
    echo "Missing PipeWire build directory: $PIPEWIRE_BUILD_DIR" >&2
    echo "The packaged v4l2 plugin is also missing: $PIPEWIRE_PLUGIN_DIR/v4l2/libspa-v4l2.so" >&2
    echo "The local v4l2loopback read-copy patch is required for GNOME Camera/PipeWire clients." >&2
    exit 1
  fi

  ninja -C "$PIPEWIRE_BUILD_DIR" spa/plugins/v4l2/libspa-v4l2.so
  install -D -m 0755 "$PIPEWIRE_PLUGIN_SRC" "$PIPEWIRE_PLUGIN_DIR/v4l2/libspa-v4l2.so"
  install -D -m 0644 /dev/stdin "$PIPEWIRE_DROPIN" <<CONF
[Service]
Environment=SPA_PLUGIN_DIR=$PIPEWIRE_PLUGIN_DIR
CONF
  systemctl --user daemon-reload
}

status() {
  echo "=== user on-demand relay ==="
  systemctl --user --no-pager --full status redrix-camera-on-demand.service || true
  echo
  echo "=== disabled relay services ==="
  systemctl --user --no-pager --full status redrix-camera-relay.service || true
  systemctl --no-pager --full status redrix-camera-relay.service redrix-camera-on-demand.service v4l2-relayd.service v4l2-relayd@default.service || true
  echo
  echo "=== device users ==="
  fuser -v "$DEVICE" /dev/media* /dev/v4l-subdev* 2>&1 || true
  echo
  echo "=== loopback device ==="
  if [[ -r /sys/module/v4l2loopback/parameters/exclusive_caps ]]; then
    echo "exclusive_caps=$(cat /sys/module/v4l2loopback/parameters/exclusive_caps)"
  else
    echo "exclusive_caps=(v4l2loopback not loaded)"
  fi
  if [[ -r /sys/module/v4l2loopback/parameters/max_buffers ]]; then
    echo "max_buffers=$(cat /sys/module/v4l2loopback/parameters/max_buffers)"
  fi
  v4l2-ctl -D -d "$DEVICE" || true
  v4l2-ctl --list-formats-ext -d "$DEVICE" || true
  echo
  echo "=== Chrome desktop Exec lines ==="
  grep '^Exec=' "${HOME}/.local/share/applications/google-chrome.desktop" 2>/dev/null || true
  echo
  echo "=== PipeWire video devices ==="
  wpctl status | sed -n '/^Video/,/^Settings/p' || true
}

write_wireplumber_camera_rules() {
  mkdir -p "$WIREPLUMBER_DIR"
  rm -f "$WIREPLUMBER_DIR/52-hide-ipu6-raw-video.lua"

  cat > "$WIREPLUMBER_DIR/50-libcamera-config.lua" <<'LUA'
libcamera_monitor.enabled = false
libcamera_monitor.rules = {}
LUA

  cat > "$WIREPLUMBER_DIR/50-v4l2-config.lua" <<'LUA'
v4l2_monitor.enabled = true

v4l2_monitor.rules = {
  {
    matches = {
      {
        { "device.bus-path", "matches", "pci-0000:00:05.0" },
      },
      {
        { "api.v4l2.cap.card", "matches", "ipu6" },
      },
      {
        { "device.product.name", "matches", "ipu6" },
      },
    },
    apply_properties = {
      ["device.disabled"] = true,
      ["node.disabled"] = true,
    },
  },
}
LUA
}

force_chrome_direct_v4l2() {
  local src="/usr/share/applications/google-chrome.desktop"
  local dst="${HOME}/.local/share/applications/google-chrome.desktop"
  local enable_feature="--enable-features=WebRtcPipeWireCamera"
  local disable_feature="--disable-features=WebRtcPipeWireCamera"

  if [[ ! -f "$dst" ]]; then
    install -D -m 0644 "$src" "$dst"
  fi

  sed -i -E "s/[[:space:]]+$enable_feature//g; s/$enable_feature[[:space:]]+//g; s/$enable_feature//g" "$dst"
  sed -i -E "/^Exec=/ {
    /$disable_feature/! s#^Exec=([^[:space:]]+)(.*)#Exec=\\1 $disable_feature\\2#
  }" "$dst"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" || true
  fi
}

write_v4l2loopback_modprobe_config() {
  local exclusive_caps="$1"

  sudo install -D -m 0644 /dev/stdin /etc/modprobe.d/v4l2loopback.conf <<CONF
options v4l2loopback devices=1 video_nr=0 exclusive_caps=$exclusive_caps max_buffers=$LOOPBACK_MAX_BUFFERS max_openers=$LOOPBACK_MAX_OPENERS card_label="Intel MIPI Camera"
CONF

  sudo install -D -m 0644 /dev/stdin /etc/modprobe.d/v4l2-relayd.conf <<CONF
options v4l2loopback devices=1 video_nr=0 exclusive_caps=$exclusive_caps max_buffers=$LOOPBACK_MAX_BUFFERS max_openers=$LOOPBACK_MAX_OPENERS card_label="Intel MIPI Camera"
CONF
}

loopback_writer_smoke_test() {
  local log_file="$1"

  timeout 5 gst-launch-1.0 -q \
    videotestsrc num-buffers=3 \
    ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 \
    ! identity drop-allocation=true \
    ! v4l2sink io-mode=rw device="$DEVICE" sync=false >"$log_file" 2>&1
}

close_camera_clients_for_setup() {
  local -a pids=()
  local line pid args

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue

    case "$args" in
      *"/openclaw/user-data"*)
        continue
        ;;
      */google/chrome/chrome*|*/chromium*|*/snapshot*|*/gnome-camera*|*/cheese*|*/qcam*)
        pids+=("$pid")
        ;;
    esac
  done < <(ps -u "$(id -u)" -o pid=,args=)

  if ((${#pids[@]} == 0)); then
    return 0
  fi

  echo "==> Closing browser/camera clients during loopback setup"
  printf '    pid %s\n' "${pids[@]}"
  kill -TERM "${pids[@]}" 2>/dev/null || true

  for _ in {1..50}; do
    local still_open=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still_open=1
        break
      fi
    done
    ((still_open == 0)) && return 0
    sleep 0.1
  done

  echo "Camera clients did not exit cleanly; forcing them closed for setup." >&2
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

wait_for_loopback_device() {
  udevadm settle --timeout=5 >/dev/null 2>&1 || true
  for _ in {1..50}; do
    [[ -e "$DEVICE" ]] && return 0
    sleep 0.1
  done
  echo "$DEVICE was not created after loading v4l2loopback." >&2
  return 1
}

configure_v4l2loopback_module() {
  echo "==> sudo is needed to change the v4l2loopback module options"
  sudo -v

  systemctl --user disable --now redrix-camera-on-demand.service redrix-camera-relay.service >/dev/null 2>&1 || true
  sudo systemctl disable --now redrix-camera-relay.service redrix-camera-on-demand.service v4l2-relayd.service v4l2-relayd@default.service >/dev/null 2>&1 || true
  sudo rm -f "$V4L2_RELAYD_CONF" "$V4L2_RELAYD_DROPIN" "$V4L2_RELAYD_OLD_DROPIN"
  sudo systemctl daemon-reload

  if [[ -e "$DEVICE" ]] && fuser -s "$DEVICE"; then
    echo "$DEVICE is still open. Close Chrome/Meet/camera test pages, then rerun this script." >&2
    fuser -v "$DEVICE" 2>&1 || true
    exit 1
  fi

  if lsmod | grep -q '^v4l2loopback '; then
    sudo "$MODPROBE" -r v4l2loopback || {
      echo "Could not unload v4l2loopback. Close apps using $DEVICE, then rerun this script." >&2
      exit 1
    }
  fi

  local loaded=""
  local cap_value=""
  local buffer_value=""
  local exclusive_value=""
  local smoke_log=""
  for exclusive_value in 1 0; do
    sudo "$MODPROBE" v4l2loopback devices=1 video_nr=0 exclusive_caps="$exclusive_value" max_buffers="$LOOPBACK_MAX_BUFFERS" max_openers="$LOOPBACK_MAX_OPENERS" card_label="Intel MIPI Camera"
    wait_for_loopback_device
    cap_value="$(cat /sys/module/v4l2loopback/parameters/exclusive_caps 2>/dev/null || true)"
    buffer_value="$(cat /sys/module/v4l2loopback/parameters/max_buffers 2>/dev/null || true)"
    smoke_log="$(mktemp --tmpdir redrix-v4l2loopback-writer.XXXXXX.log)"
    if [[ "$buffer_value" =~ ^[0-9]+$ ]] && ((buffer_value >= 8)) && loopback_writer_smoke_test "$smoke_log"; then
      rm -f "$smoke_log"
      loaded="yes"
      LOOPBACK_EXCLUSIVE_CAPS="$exclusive_value"
      break
    fi
    echo "v4l2loopback writer test failed with exclusive_caps=$exclusive_value:" >&2
    sed -n '1,80p' "$smoke_log" >&2 || true
    rm -f "$smoke_log"
    v4l2-ctl -D -d "$DEVICE" >&2 || true
    if [[ "$exclusive_value" == "1" ]]; then
      echo "==> v4l2loopback exclusive_caps=1 does not accept a writer on this kernel; falling back to exclusive_caps=0"
    fi
    sudo "$MODPROBE" -r v4l2loopback || true
  done

  if [[ "$loaded" != "yes" ]]; then
    echo "v4l2loopback could not accept a test writer: exclusive_caps=${cap_value:-unknown}, max_buffers=${buffer_value:-unknown}" >&2
    echo "The loopback device must accept a producer before the on-demand relay can start." >&2
    exit 1
  fi

  write_v4l2loopback_modprobe_config "$LOOPBACK_EXCLUSIVE_CAPS"
  echo "==> v4l2loopback writer mode selected: exclusive_caps=$LOOPBACK_EXCLUSIVE_CAPS"

  # In exclusive_caps mode, do not query the loopback device here. Even a
  # harmless-looking v4l2-ctl open can flip the device away from producer mode
  # before the relay writer attaches.
}

configure_v4l2_relayd() {
  local libdir="$LIBDIR"

  sudo install -d -m 0755 /etc/v4l2-relayd.d
  sudo install -D -m 0644 /dev/stdin "$V4L2_RELAYD_CONF" <<CONF
LD_LIBRARY_PATH=$libdir
GST_PLUGIN_PATH=$libdir/gstreamer-1.0
LIBCAMERA_DATA_DIR=$PREFIX/share/libcamera
LIBCAMERA_IPA_MODULE_PATH=$libdir/libcamera/ipa
LIBCAMERA_IPA_CONFIG_PATH=$HOME/.config/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa
LIBCAMERA_IPA_PROXY_PATH=$PREFIX/libexec/libcamera

VIDEOSRC=libcamerasrc ! video/x-raw,width=1280,height=720,framerate=30/1 ! queue max-size-buffers=4 leaky=downstream ! videoconvert ! videoscale ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1
SPLASHSRC=videotestsrc is-live=true pattern=smpte ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1
FORMAT=YUY2
WIDTH=640
HEIGHT=480
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
CONF

  sudo install -D -m 0644 /dev/stdin "$V4L2_RELAYD_DROPIN" <<'CONF'
[Service]
ExecStart=
ExecStart=/bin/sh -c 'DEVICE=$(grep -l -m1 -E "^${CARD_LABEL}$" /sys/devices/virtual/video4linux/*/name | cut -d/ -f6); exec /usr/bin/v4l2-relayd -i "${VIDEOSRC}" $${SPLASHSRC:+-s "${SPLASHSRC}"} -o "appsrc name=appsrc caps=video/x-raw,format=${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE} ! videoconvert ! video/x-raw,format=${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE} ! identity drop-allocation=true ! v4l2sink name=v4l2sink device=/dev/$${DEVICE}"'
CONF

  sudo rm -f "$V4L2_RELAYD_OLD_DROPIN"
  sudo systemctl daemon-reload
  sudo systemctl enable --now v4l2-relayd.service v4l2-relayd@default.service
}

enable_user_on_demand_relay() {
  "$SCRIPT_DIR/05-enable-user-on-demand-relay.sh"
}

stop_desktop_media_stack() {
  systemctl --user stop xdg-desktop-portal.service wireplumber.service pipewire-pulse.service pipewire.service >/dev/null 2>&1 || true
}

restart_desktop_media_stack() {
  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service xdg-desktop-portal.service >/dev/null 2>&1 || true
}

verify_visible_camera() {
  sleep 1
  if ! v4l2-ctl -D -d "$DEVICE" | grep -q 'Video Capture'; then
    echo "$DEVICE is still not visible as a capture camera." >&2
    echo "Current state:" >&2
    v4l2-ctl -D -d "$DEVICE" >&2 || true
    systemctl --user --no-pager --full status redrix-camera-on-demand.service >&2 || true
    exit 1
  fi

  local buffer_value=""
  buffer_value="$(cat /sys/module/v4l2loopback/parameters/max_buffers 2>/dev/null || true)"
  if ! [[ "$buffer_value" =~ ^[0-9]+$ ]] || ((buffer_value < 8)); then
    echo "v4l2loopback has too few buffers for PipeWire/WebRTC: max_buffers=${buffer_value:-unknown}" >&2
    exit 1
  fi

  if ! timeout 8 gst-launch-1.0 -q v4l2src device="$DEVICE" num-buffers=30 ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 ! fakesink; then
    echo "Direct V4L2 read from $DEVICE failed." >&2
    exit 1
  fi

  local node=""
  local pipewire_target=""
  for _ in {1..20}; do
    node="$(wpctl status | awk '/Intel MIPI Camera \(V4L2\)/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.$/) {sub("\\.", "", $i); print $i; exit}}')"
    [[ -n "$node" ]] && break
    sleep 0.25
  done
  if [[ -z "$node" ]]; then
    echo "PipeWire does not list the V4L2 camera node." >&2
    wpctl status >&2 || true
    exit 1
  fi
  pipewire_target="$(wpctl inspect "$node" | awk -F' = ' '/node.name = / {gsub("\"", "", $2); print $2; exit}')"
  pipewire_target="${pipewire_target:-$node}"

  pipewire_target="v4l2:$DEVICE"
  if ! timeout 10 gst-launch-1.0 -q pipewiresrc target-object="$pipewire_target" always-copy=true min-buffers=1 max-buffers=4 num-buffers=30 ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 ! fakesink sync=false; then
    echo "PipeWire can list the camera but cannot read frames from it." >&2
    echo "Run ./diagnose-camera.sh and send the log path." >&2
    exit 1
  fi
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
    systemctl --user disable --now redrix-camera-on-demand.service redrix-camera-relay.service >/dev/null 2>&1 || true
    sudo systemctl stop v4l2-relayd@default.service v4l2-relayd.service
    exit 0
    ;;
esac

require_install
build_video_watcher

echo "==> Disabling PipeWire/libcamera idle enumeration"
write_wireplumber_camera_rules

echo "==> Stopping PipeWire, WirePlumber, and portal during loopback setup"
stop_desktop_media_stack

close_camera_clients_for_setup

echo "==> Making Chrome use the direct V4L2 camera path"
force_chrome_direct_v4l2

echo "==> Reconfiguring v4l2loopback for on-demand mode"
configure_v4l2loopback_module

echo "==> Enabling the user on-demand relay"
enable_user_on_demand_relay

echo "==> Installing the local PipeWire V4L2 patch"
install_pipewire_v4l2_patch

echo "==> Restarting PipeWire, WirePlumber, and portal"
restart_desktop_media_stack

echo "==> Verifying that the virtual camera is visible"
verify_visible_camera

echo
echo "Automatic camera mode is enabled."
echo "Fully quit Chrome and open it again from the app launcher."
echo "Then select 'Intel MIPI Camera' in Google Meet."
