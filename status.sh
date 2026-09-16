#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"

echo "=== host ==="
cat /etc/os-release | sed -n '1,6p'
uname -a
echo

echo "=== camera hardware ==="
lspci -nn | grep -Ei 'ipu|imaging|camera' || true
for n in /sys/class/video4linux/*/name; do
  printf '%s: ' "$n"
  cat "$n"
done 2>/dev/null | grep -Ei 'hi556|ipu6|mipi|camera|loopback' || true
echo

echo "=== system libcamera ==="
cam --list || true
echo

if [[ -x "$PREFIX/bin/cam" ]]; then
  echo "=== Redrix-local libcamera ==="
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/redrix-libcamera-env"
  "$PREFIX/bin/cam" --list || true
  echo
  echo "=== Redrix-local libcamerasrc ==="
  gst-inspect-1.0 libcamerasrc | sed -n '1,80p' || true
  echo
else
  echo "=== Redrix-local libcamera ==="
  echo "not installed at $PREFIX"
  echo
fi

echo "=== services ==="
systemctl --no-pager --full status redrix-camera-on-demand.service || true
systemctl --no-pager --full status redrix-camera-relay.service || true
systemctl --no-pager --full status v4l2-relayd@default.service || true
echo

echo "=== /dev/video0 users ==="
sudo -n fuser -v /dev/video0 2>&1 || fuser -v /dev/video0 2>&1 || true
echo

echo "=== /dev/video0 ==="
v4l2-ctl --list-formats-ext -d /dev/video0 || true
echo

echo "=== /dev/video0 stream test ==="
timeout 8s v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=30 --stream-to=/dev/null
echo "exit=$?"
echo

echo "=== recent Redrix relay log ==="
journalctl -u redrix-camera-on-demand.service -n 80 --no-pager || true
journalctl -u redrix-camera-relay.service -n 80 --no-pager || true
