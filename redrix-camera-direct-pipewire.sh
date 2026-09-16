#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${REDRIX_CAMERA_APP_DIR:-$SCRIPT_DIR}"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$PREFIX/lib/x86_64-linux-gnu}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
WIREPLUMBER_DIR="$XDG_CONFIG_HOME/wireplumber/main.lua.d"
SYSTEMD_USER_DIR="$XDG_CONFIG_HOME/systemd/user"
PIPEWIRE_DROPIN="$SYSTEMD_USER_DIR/pipewire.service.d/20-redrix-spa.conf"
WIREPLUMBER_DROPIN="$SYSTEMD_USER_DIR/wireplumber.service.d/20-redrix-libcamera-spa.conf"
TUNING_DST="$XDG_CONFIG_HOME/redrix-libcamera/ipa/simple/hi556.yaml"
CHROME_USER_DESKTOP="$HOME/.local/share/applications/google-chrome.desktop"
CHROME_SYSTEM_DESKTOP="/usr/share/applications/google-chrome.desktop"
CHROME_ENABLE_FEATURE="--enable-features=WebRtcPipeWireCamera"
CHROME_DISABLE_FEATURE="--disable-features=WebRtcPipeWireCamera"

if [[ -d "$APP_DIR/spa-0.2" ]]; then
  DEFAULT_SPA_DIR="$APP_DIR/spa-0.2"
elif [[ -d "$APP_DIR/pipewire-build/redrix-spa-0.2" ]]; then
  DEFAULT_SPA_DIR="$APP_DIR/pipewire-build/redrix-spa-0.2"
else
  DEFAULT_SPA_DIR="$APP_DIR/spa-0.2"
fi
SPA_DIR="${REDRIX_SPA_PLUGIN_DIR:-$DEFAULT_SPA_DIR}"

usage() {
  cat <<USAGE
Usage:
  redrix-camera-direct-pipewire.sh          enable the direct PipeWire/libcamera path
  redrix-camera-direct-pipewire.sh --status show current camera-related state
  redrix-camera-direct-pipewire.sh --verify run a short PipeWire frame-read test
  redrix-camera-direct-pipewire.sh --disable move Redrix user config aside
  redrix-camera-direct-pipewire.sh --revert alias for --disable

This is the currently recommended Redrix/HI556 setup. It is experimental and
was produced while repairing one machine, so inspect it before use.
USAGE
}

backup_stamp=""

stamp() {
  if [[ -z "$backup_stamp" ]]; then
    backup_stamp="$(date +%Y%m%d-%H%M%S)"
  fi
  printf '%s' "$backup_stamp"
}

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local backup="$path.redrix-backup-$(stamp)"
  if [[ ! -e "$backup" ]]; then
    cp -a "$path" "$backup"
    echo "Backed up $path -> $backup"
  fi
}

move_aside() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local backup="$path.redrix-disabled-$(stamp)"
  mv "$path" "$backup"
  echo "Moved $path -> $backup"
}

require_command() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    echo "Missing commands:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

require_direct_install() {
  local missing=()
  [[ -f "$APP_DIR/hi556.yaml" ]] || missing+=("$APP_DIR/hi556.yaml")
  [[ -r "$SPA_DIR/libcamera/libspa-libcamera.so" ]] || missing+=("$SPA_DIR/libcamera/libspa-libcamera.so")
  [[ -x "$PREFIX/bin/cam" ]] || missing+=("$PREFIX/bin/cam")
  [[ -d "$LIBDIR/libcamera/ipa" ]] || missing+=("$LIBDIR/libcamera/ipa")
  if ((${#missing[@]} > 0)); then
    echo "Missing Redrix camera pieces:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Run: redrix-camera build-libcamera" >&2
    exit 1
  fi
}

install_tuning() {
  mkdir -p "$(dirname -- "$TUNING_DST")"
  backup_file "$TUNING_DST"
  install -m 0644 "$APP_DIR/hi556.yaml" "$TUNING_DST"
}

write_wireplumber_config() {
  mkdir -p "$WIREPLUMBER_DIR"

  local libcamera_config="$WIREPLUMBER_DIR/50-libcamera-config.lua"
  local v4l2_config="$WIREPLUMBER_DIR/50-v4l2-config.lua"

  backup_file "$libcamera_config"
  cat > "$libcamera_config" <<'LUA'
libcamera_monitor.enabled = true
libcamera_monitor.rules = {}
LUA

  backup_file "$v4l2_config"
  cat > "$v4l2_config" <<'LUA'
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

write_user_service_dropins() {
  mkdir -p "$(dirname -- "$PIPEWIRE_DROPIN")" "$(dirname -- "$WIREPLUMBER_DROPIN")"

  backup_file "$PIPEWIRE_DROPIN"
cat > "$PIPEWIRE_DROPIN" <<CONF
[Service]
Environment=SPA_PLUGIN_DIR=$SPA_DIR
Environment=LD_LIBRARY_PATH=$LIBDIR
Environment=LIBCAMERA_IPA_CONFIG_PATH=$XDG_CONFIG_HOME/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa
CONF

  backup_file "$WIREPLUMBER_DROPIN"
cat > "$WIREPLUMBER_DROPIN" <<CONF
[Service]
Environment=SPA_PLUGIN_DIR=$SPA_DIR
Environment=LD_LIBRARY_PATH=$LIBDIR
Environment=LIBCAMERA_DATA_DIR=$PREFIX/share/libcamera
Environment=LIBCAMERA_IPA_MODULE_PATH=$LIBDIR/libcamera/ipa
Environment=LIBCAMERA_IPA_CONFIG_PATH=$XDG_CONFIG_HOME/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa
Environment=LIBCAMERA_IPA_PROXY_PATH=$PREFIX/libexec/libcamera
CONF

  systemctl --user daemon-reload
}

patch_chrome_desktop() {
  if [[ ! -f "$CHROME_USER_DESKTOP" ]]; then
    if [[ ! -f "$CHROME_SYSTEM_DESKTOP" ]]; then
      echo "Chrome desktop file not found; skipping Chrome flag setup." >&2
      return 0
    fi
    install -D -m 0644 "$CHROME_SYSTEM_DESKTOP" "$CHROME_USER_DESKTOP"
  else
    backup_file "$CHROME_USER_DESKTOP"
  fi

  sed -i -E "s/[[:space:]]+$CHROME_DISABLE_FEATURE//g; s/$CHROME_DISABLE_FEATURE[[:space:]]+//g; s/$CHROME_DISABLE_FEATURE//g" "$CHROME_USER_DESKTOP"
  sed -i -E "s/[[:space:]]+$CHROME_ENABLE_FEATURE//g; s/$CHROME_ENABLE_FEATURE[[:space:]]+//g; s/$CHROME_ENABLE_FEATURE//g" "$CHROME_USER_DESKTOP"
  sed -i -E "/^Exec=/ s#^Exec=([^[:space:]]+)(.*)#Exec=\\1 $CHROME_ENABLE_FEATURE\\2#" "$CHROME_USER_DESKTOP"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  fi
}

stop_legacy_user_relays() {
  systemctl --user disable --now redrix-camera-on-demand.service redrix-camera-relay.service >/dev/null 2>&1 || true
  systemctl --user reset-failed redrix-camera-on-demand.service redrix-camera-relay.service >/dev/null 2>&1 || true
}

restart_desktop_media_stack() {
  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service xdg-desktop-portal.service >/dev/null 2>&1 || true
}

redrix_cam_list() {
  PATH="$PREFIX/bin:$PATH" \
  LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  LIBCAMERA_DATA_DIR="$PREFIX/share/libcamera" \
  LIBCAMERA_IPA_MODULE_PATH="$LIBDIR/libcamera/ipa" \
  LIBCAMERA_IPA_CONFIG_PATH="$XDG_CONFIG_HOME/redrix-libcamera/ipa:$PREFIX/share/libcamera/ipa" \
  LIBCAMERA_IPA_PROXY_PATH="$PREFIX/libexec/libcamera" \
    "$PREFIX/bin/cam" --list
}

status() {
  echo "=== package paths ==="
  echo "APP_DIR=$APP_DIR"
  echo "SPA_DIR=$SPA_DIR"
  echo "PREFIX=$PREFIX"
  echo

  echo "=== Redrix files ==="
  ls -l "$APP_DIR/hi556.yaml" "$SPA_DIR/libcamera/libspa-libcamera.so" 2>&1 || true
  echo

  echo "=== user config ==="
  for f in \
    "$TUNING_DST" \
    "$WIREPLUMBER_DIR/50-libcamera-config.lua" \
    "$WIREPLUMBER_DIR/50-v4l2-config.lua" \
    "$PIPEWIRE_DROPIN" \
    "$WIREPLUMBER_DROPIN"; do
    echo "--- $f"
    sed -n '1,120p' "$f" 2>/dev/null || true
  done
  echo

  echo "=== Chrome desktop Exec lines ==="
  grep '^Exec=' "$CHROME_USER_DESKTOP" 2>/dev/null || true
  echo

  echo "=== libcamera list ==="
  if [[ -x "$PREFIX/bin/cam" ]]; then
    redrix_cam_list || true
  else
    echo "$PREFIX/bin/cam is missing"
  fi
  echo

  echo "=== PipeWire video section ==="
  wpctl status | sed -n '/^Video/,/^Settings/p' || true
}

find_hi556_node() {
  local node=""
  node="$(wpctl status | awk '
    /Sources:/ {
      in_sources = 1;
      next;
    }
    /Source endpoints:/ {
      in_sources = 0;
    }
    in_sources && /hi556|libcamera|HI556/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.$/) {
          sub("\\.", "", $i);
          print $i;
          exit;
        }
      }
    }')"
  if [[ -n "$node" ]]; then
    printf '%s\n' "$node"
    return 0
  fi

  wpctl status | awk '
    /hi556|libcamera|HI556/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.$/) {
          sub("\\.", "", $i);
          print $i;
          exit;
        }
      }
    }'
}

verify() {
  require_command timeout gst-launch-1.0 wpctl
  local node=""
  local target=""

  node="$(find_hi556_node)"
  if [[ -z "$node" ]]; then
    echo "No hi556/libcamera PipeWire video node found." >&2
    wpctl status >&2 || true
    exit 1
  fi

  target="$(wpctl inspect "$node" | awk -F' = ' '/node.name = / {gsub("\"", "", $2); print $2; exit}')"
  echo "Testing PipeWire source node $node${target:+ ($target)}"

  timeout 10 gst-launch-1.0 -q \
    pipewiresrc target-object="$node" num-buffers=30 \
    ! video/x-raw,format=RGBA,width=640,height=480 \
    ! fakesink sync=false
}

disable_redrix_config() {
  move_aside "$PIPEWIRE_DROPIN"
  move_aside "$WIREPLUMBER_DROPIN"
  move_aside "$WIREPLUMBER_DIR/50-libcamera-config.lua"
  move_aside "$WIREPLUMBER_DIR/50-v4l2-config.lua"

  if [[ -f "$CHROME_USER_DESKTOP" ]]; then
    backup_file "$CHROME_USER_DESKTOP"
    sed -i -E "s/[[:space:]]+$CHROME_ENABLE_FEATURE//g; s/$CHROME_ENABLE_FEATURE[[:space:]]+//g; s/$CHROME_ENABLE_FEATURE//g" "$CHROME_USER_DESKTOP"
  fi

  systemctl --user daemon-reload
  restart_desktop_media_stack
  echo "Redrix user config disabled/moved aside. Fully restart Chrome."
  echo "Existing .redrix-backup-* files are left in place for manual restore."
}

case "${1:-install}" in
  --help|-h)
    usage
    ;;
  --status)
    status
    ;;
  --verify)
    verify
    ;;
  --disable|--revert)
    disable_redrix_config
    ;;
  install)
    require_command install sed systemctl wpctl
    require_direct_install
    stop_legacy_user_relays
    install_tuning
    write_wireplumber_config
    write_user_service_dropins
    patch_chrome_desktop
    restart_desktop_media_stack
    echo "Direct Redrix PipeWire/libcamera path configured."
    echo "Fully quit Chrome and open it again from the app launcher, then select hi556 in Meet."
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac
