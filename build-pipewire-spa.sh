#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PIPEWIRE_UPSTREAM_VERSION="${PIPEWIRE_UPSTREAM_VERSION:-1.0.5}"
PIPEWIRE_UBUNTU_VERSION="${PIPEWIRE_UBUNTU_VERSION:-1.0.5-1ubuntu3.3}"
PIPEWIRE_POOL_URL="${PIPEWIRE_POOL_URL:-https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire}"
BUILD_ROOT="${REDRIX_PIPEWIRE_BUILD_ROOT:-$SCRIPT_DIR/pipewire-build}"
SRC_DIR="$BUILD_ROOT/src"
SOURCE_DIR="$SRC_DIR/pipewire-$PIPEWIRE_UPSTREAM_VERSION"
BUILD_DIR="$BUILD_ROOT/build-redrix-spa"
OUTPUT_DIR="$BUILD_ROOT/redrix-spa-0.2"
PREFIX="$BUILD_ROOT/redrix-prefix"

LIBCAMERA_PREFIX="${REDRIX_LIBCAMERA_PREFIX:-/opt/redrix-libcamera}"
LIBCAMERA_LIBDIR="${REDRIX_LIBCAMERA_LIBDIR:-$LIBCAMERA_PREFIX/lib/x86_64-linux-gnu}"
LIBCAMERA_PKGCONFIG="$LIBCAMERA_LIBDIR/pkgconfig"

ORIG_TARBALL="pipewire_${PIPEWIRE_UPSTREAM_VERSION}.orig.tar.bz2"
DEBIAN_TARBALL="pipewire_${PIPEWIRE_UBUNTU_VERSION}.debian.tar.xz"
DSC_FILE="pipewire_${PIPEWIRE_UBUNTU_VERSION}.dsc"
ORIG_SHA256="d5e5f3d0b8460e5711c1571c500156fd61768ba55a062eaeb94356abdb955a56"
DEBIAN_SHA256="a1650f8e95859b3a8057ea95dad7e0509bfed9896db5b0d17c70910c4e9a3ff0"

APT_PACKAGES=(
  ca-certificates
  curl
  dpkg-dev
  patch
  xz-utils
  bzip2
  build-essential
  meson
  ninja-build
  pkgconf
  libudev-dev
)

usage() {
  cat <<USAGE
Usage:
  ./build-pipewire-spa.sh [--install-deps]

Downloads Ubuntu PipeWire $PIPEWIRE_UBUNTU_VERSION source, applies the Redrix
patches in ./patches, and builds:

  pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so
  pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so

The libcamera SPA plugin links against the local Redrix libcamera installation:

  $LIBCAMERA_PREFIX

Run ./01-build-libcamera.sh first if that prefix is missing.
USAGE
}

install_deps=0

while (($#)); do
  case "$1" in
    --install-deps)
      install_deps=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_command() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    echo "Missing commands:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo
    echo "Install dependencies with:" >&2
    printf '  sudo apt-get install -y' >&2
    printf ' %q' "${APT_PACKAGES[@]}" >&2
    printf '\n' >&2
    exit 1
  fi
}

download_file() {
  local name="$1"
  local url="$2"
  local dest="$3"

  if [[ -s "$dest" ]]; then
    return 0
  fi

  echo "==> Downloading $name"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --output "$dest.tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest.tmp" "$url"
  else
    echo "Missing curl or wget for downloads." >&2
    exit 1
  fi
  mv "$dest.tmp" "$dest"
}

check_sha256() {
  local expected="$1"
  local file="$2"
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

if ((install_deps)); then
  echo "==> Installing PipeWire SPA build dependencies"
  sudo apt-get update
  sudo apt-get install -y "${APT_PACKAGES[@]}"
fi

require_command dpkg-source meson ninja pkg-config patch sha256sum

if [[ ! -d "$LIBCAMERA_PKGCONFIG" ]]; then
  echo "Missing libcamera pkg-config directory: $LIBCAMERA_PKGCONFIG" >&2
  echo "Run ./01-build-libcamera.sh first, or set REDRIX_LIBCAMERA_PREFIX." >&2
  exit 1
fi

export PKG_CONFIG_PATH="$LIBCAMERA_PKGCONFIG${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if ! pkg-config --atleast-version=0.2.0 libcamera; then
  echo "pkg-config cannot find libcamera >= 0.2.0 in $PKG_CONFIG_PATH" >&2
  echo "Run ./01-build-libcamera.sh first, or set REDRIX_LIBCAMERA_PREFIX." >&2
  exit 1
fi

mkdir -p "$SRC_DIR" "$OUTPUT_DIR/libcamera" "$OUTPUT_DIR/v4l2"

download_file "$DSC_FILE" "$PIPEWIRE_POOL_URL/$DSC_FILE" "$SRC_DIR/$DSC_FILE"
download_file "$ORIG_TARBALL" "$PIPEWIRE_POOL_URL/$ORIG_TARBALL" "$SRC_DIR/$ORIG_TARBALL"
download_file "$DEBIAN_TARBALL" "$PIPEWIRE_POOL_URL/$DEBIAN_TARBALL" "$SRC_DIR/$DEBIAN_TARBALL"

check_sha256 "$ORIG_SHA256" "$SRC_DIR/$ORIG_TARBALL"
check_sha256 "$DEBIAN_SHA256" "$SRC_DIR/$DEBIAN_TARBALL"

cat > "$SRC_DIR/source.list" <<SOURCE_LIST
$PIPEWIRE_POOL_URL/$DSC_FILE
$PIPEWIRE_POOL_URL/$ORIG_TARBALL
$PIPEWIRE_POOL_URL/$DEBIAN_TARBALL
SOURCE_LIST

echo "==> Unpacking Ubuntu PipeWire source"
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
(cd "$SRC_DIR" && dpkg-source -x "$DSC_FILE" "$(basename "$SOURCE_DIR")")

echo "==> Applying Redrix patches"
(cd "$SOURCE_DIR" && patch -p1 < "$SCRIPT_DIR/patches/pipewire-1.0.5-redrix-libcamera-hi556.patch")
(cd "$SOURCE_DIR" && patch -p1 < "$SCRIPT_DIR/patches/pipewire-1.0.5-redrix-v4l2loopback-readcopy.patch")

MESON_ARGS=(
  --prefix="$PREFIX"
  --libdir=lib/x86_64-linux-gnu
  --buildtype=release
  -Ddocs=disabled
  -Dman=disabled
  -Dexamples=disabled
  -Dtests=disabled
  -Dinstalled_tests=disabled
  -Dgstreamer=disabled
  -Dgstreamer-device-provider=disabled
  -Dsystemd=disabled
  -Dpipewire-alsa=disabled
  -Dpipewire-jack=disabled
  -Dpipewire-v4l2=disabled
  -Dalsa=disabled
  -Daudiomixer=disabled
  -Daudioconvert=enabled
  -Dbluez5=disabled
  -Dcontrol=disabled
  -Daudiotestsrc=disabled
  -Djack=disabled
  -Dsupport=enabled
  -Dtest=disabled
  -Dv4l2=enabled
  -Ddbus=disabled
  -Dlibcamera=enabled
  -Dvideoconvert=disabled
  -Dvideotestsrc=disabled
  -Dpw-cat=disabled
  -Dudev=enabled
  -Dsession-managers=[]
  -Dsdl2=disabled
  -Dsndfile=disabled
  -Dlibpulse=disabled
  -Droc=disabled
  -Davahi=disabled
  -Decho-cancel-webrtc=disabled
  -Dlibusb=disabled
  -Dx11=disabled
)

export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$BUILD_ROOT=. -g0"
export CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$BUILD_ROOT=. -g0"

echo "==> Configuring PipeWire SPA build"
meson setup "$BUILD_DIR" "$SOURCE_DIR" "${MESON_ARGS[@]}"

echo "==> Building patched SPA plugins"
ninja -C "$BUILD_DIR" \
  spa/plugins/libcamera/libspa-libcamera.so \
  spa/plugins/v4l2/libspa-v4l2.so

install -m 0644 "$BUILD_DIR/spa/plugins/libcamera/libspa-libcamera.so" "$OUTPUT_DIR/libcamera/"
install -m 0644 "$BUILD_DIR/spa/plugins/v4l2/libspa-v4l2.so" "$OUTPUT_DIR/v4l2/"

echo
echo "Built Redrix PipeWire SPA plugins:"
echo "  $OUTPUT_DIR/libcamera/libspa-libcamera.so"
echo "  $OUTPUT_DIR/v4l2/libspa-v4l2.so"
