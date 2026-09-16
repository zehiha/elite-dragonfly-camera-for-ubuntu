#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

LIBCAMERA_TAG="${LIBCAMERA_TAG:-v0.7.2}"
PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/redrix-camera"
SRC_DIR="$CACHE_ROOT/libcamera-src"
BUILD_DIR="$CACHE_ROOT/libcamera-build"
REPO_URL="https://git.libcamera.org/libcamera/libcamera.git"

APT_PACKAGES=(
  ca-certificates
  git
  build-essential
  meson
  ninja-build
  pkg-config
  libyaml-dev
  python3-yaml
  python3-ply
  python3-jinja2
  libgnutls28-dev
  openssl
  libudev-dev
  libgstreamer1.0-dev
  libgstreamer-plugins-base1.0-dev
  libevent-dev
  libdrm-dev
  libjpeg-dev
  libtiff-dev
  gstreamer1.0-tools
  gstreamer1.0-plugins-base
  gstreamer1.0-plugins-good
  v4l-utils
)

echo "==> Installing build/runtime dependencies"
sudo apt-get update
sudo apt-get install -y "${APT_PACKAGES[@]}"

mkdir -p "$CACHE_ROOT"

if [[ -d "$SRC_DIR/.git" ]]; then
  echo "==> Updating existing libcamera source in $SRC_DIR"
  git -C "$SRC_DIR" fetch --tags --depth=1 origin "$LIBCAMERA_TAG"
else
  echo "==> Cloning libcamera $LIBCAMERA_TAG into $SRC_DIR"
  git clone --depth=1 --branch "$LIBCAMERA_TAG" "$REPO_URL" "$SRC_DIR"
fi

git -C "$SRC_DIR" checkout "$LIBCAMERA_TAG"

MESON_ARGS=(
  --prefix="$PREFIX"
  --libdir=lib/x86_64-linux-gnu
  --buildtype=release
  -Dwerror=false
  -Dandroid=disabled
  -Dcam=enabled
  -Ddocumentation=disabled
  -Dgstreamer=enabled
  -Dipas=simple
  -Dlc-compliance=disabled
  -Dlibunwind=disabled
  -Dpipelines=simple,uvcvideo
  -Dpycamera=disabled
  -Dqcam=disabled
  -Dtest=false
  -Dtracing=disabled
  -Dudev=enabled
  -Dv4l2=enabled
)

if [[ -f "$BUILD_DIR/build.ninja" ]]; then
  echo "==> Reconfiguring libcamera build"
  meson setup --wipe "$BUILD_DIR" "$SRC_DIR" "${MESON_ARGS[@]}"
else
  echo "==> Configuring libcamera build"
  meson setup "$BUILD_DIR" "$SRC_DIR" "${MESON_ARGS[@]}"
fi

echo "==> Building libcamera"
ninja -C "$BUILD_DIR"

echo "==> Installing libcamera to $PREFIX"
sudo meson install -C "$BUILD_DIR"

echo "==> Installing approximate hi556 tuning file"
sudo install -D -m 0644 "$SCRIPT_DIR/hi556.yaml" "$PREFIX/share/libcamera/ipa/simple/hi556.yaml"

echo "==> Smoke test: local cam --list"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/redrix-libcamera-env"
"$PREFIX/bin/cam" --list || true

echo
echo "Build done. Next:"
echo "  redrix-camera direct"
