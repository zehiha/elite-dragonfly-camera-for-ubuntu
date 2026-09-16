#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="redrix-hi556-camera"
VERSION="${REDRIX_CAMERA_VERSION:-0.1.0}"
ARCH="${REDRIX_CAMERA_ARCH:-$(dpkg --print-architecture)}"
MAINTAINER="${REDRIX_CAMERA_MAINTAINER:-zehiha <47032150+zehiha@users.noreply.github.com>}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1789459200}"
RELEASE_DATE="${REDRIX_RELEASE_DATE:-$(date -u -R -d "@$SOURCE_DATE_EPOCH")}"
BUILD_DIR="$SCRIPT_DIR/build"
PKG_ROOT="$BUILD_DIR/${PACKAGE}_${VERSION}_${ARCH}"
DIST_DIR="$SCRIPT_DIR/dist"
APP_DIR="$PKG_ROOT/usr/lib/redrix-camera"
DOC_DIR="$PKG_ROOT/usr/share/doc/$PACKAGE"

if [[ "$ARCH" != "amd64" ]]; then
  echo "This package currently ships amd64 PipeWire SPA plugin binaries; got architecture '$ARCH'." >&2
  exit 1
fi

export SOURCE_DATE_EPOCH

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required build input: $path" >&2
    exit 1
  fi
}

ensure_spa_plugins() {
  local missing=()
  [[ -f "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so" ]] || \
    missing+=("$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so")
  [[ -f "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so" ]] || \
    missing+=("$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so")

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  echo "Missing PipeWire SPA plugin binaries:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "Rebuilding them from Ubuntu PipeWire source..." >&2
  "$SCRIPT_DIR/build-pipewire-spa.sh"
}

for path in \
  "$SCRIPT_DIR/build-pipewire-spa.sh" \
  "$SCRIPT_DIR/redrix-camera" \
  "$SCRIPT_DIR/redrix-camera-direct-pipewire.sh" \
  "$SCRIPT_DIR/01-build-libcamera.sh" \
  "$SCRIPT_DIR/02-enable-v4l2-relay.sh" \
  "$SCRIPT_DIR/03-patch-chrome-desktop.sh" \
  "$SCRIPT_DIR/04-enable-on-demand-relay.sh" \
  "$SCRIPT_DIR/05-enable-user-on-demand-relay.sh" \
  "$SCRIPT_DIR/06-enable-auto-loopback-camera.sh" \
  "$SCRIPT_DIR/camera-on.sh" \
  "$SCRIPT_DIR/camera-off.sh" \
  "$SCRIPT_DIR/diagnose-camera.sh" \
  "$SCRIPT_DIR/status.sh" \
  "$SCRIPT_DIR/redrix-camera-daemon.py" \
  "$SCRIPT_DIR/redrix-camera-on-demand-user-run" \
  "$SCRIPT_DIR/redrix-libcamera-env" \
  "$SCRIPT_DIR/redrix-video-watch.c" \
  "$SCRIPT_DIR/hi556.yaml" \
  "$SCRIPT_DIR/README.md" \
  "$SCRIPT_DIR/LICENSE" \
  "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" \
  "$SCRIPT_DIR/patches/pipewire-1.0.5-redrix-libcamera-hi556.patch" \
  "$SCRIPT_DIR/patches/pipewire-1.0.5-redrix-v4l2loopback-readcopy.patch"; do
  require_file "$path"
done

ensure_spa_plugins
require_file "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so"
require_file "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so"

rm -rf "$PKG_ROOT"
mkdir -p \
  "$APP_DIR" \
  "$APP_DIR/spa-0.2/libcamera" \
  "$APP_DIR/spa-0.2/v4l2" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/DEBIAN" \
  "$DOC_DIR/patches" \
  "$PKG_ROOT/usr/share/lintian/overrides" \
  "$DIST_DIR"

gcc -O2 -Wall -Wextra -o "$BUILD_DIR/redrix-video-watch" "$SCRIPT_DIR/redrix-video-watch.c"

install -m 0755 "$SCRIPT_DIR/redrix-camera" "$PKG_ROOT/usr/bin/redrix-camera"
install -m 0755 \
  "$SCRIPT_DIR/redrix-camera-direct-pipewire.sh" \
  "$SCRIPT_DIR/01-build-libcamera.sh" \
  "$SCRIPT_DIR/02-enable-v4l2-relay.sh" \
  "$SCRIPT_DIR/03-patch-chrome-desktop.sh" \
  "$SCRIPT_DIR/04-enable-on-demand-relay.sh" \
  "$SCRIPT_DIR/05-enable-user-on-demand-relay.sh" \
  "$SCRIPT_DIR/06-enable-auto-loopback-camera.sh" \
  "$SCRIPT_DIR/camera-on.sh" \
  "$SCRIPT_DIR/camera-off.sh" \
  "$SCRIPT_DIR/diagnose-camera.sh" \
  "$SCRIPT_DIR/status.sh" \
  "$SCRIPT_DIR/redrix-camera-daemon.py" \
  "$SCRIPT_DIR/redrix-camera-on-demand-user-run" \
  "$BUILD_DIR/redrix-video-watch" \
  "$APP_DIR/"
install -m 0755 "$SCRIPT_DIR/redrix-libcamera-env" "$APP_DIR/"
install -m 0644 "$SCRIPT_DIR/hi556.yaml" "$APP_DIR/"
install -m 0644 "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so" "$APP_DIR/spa-0.2/libcamera/"
install -m 0644 "$SCRIPT_DIR/pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so" "$APP_DIR/spa-0.2/v4l2/"
strip --strip-unneeded "$APP_DIR/redrix-video-watch" "$APP_DIR/spa-0.2/libcamera/libspa-libcamera.so" "$APP_DIR/spa-0.2/v4l2/libspa-v4l2.so"

install -m 0644 "$SCRIPT_DIR/README.md" "$DOC_DIR/README.md"
install -m 0644 "$SCRIPT_DIR/LICENSE" "$DOC_DIR/LICENSE"
install -m 0644 "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$DOC_DIR/THIRD_PARTY_NOTICES.md"
if compgen -G "$SCRIPT_DIR/patches/*.patch" >/dev/null; then
  install -m 0644 "$SCRIPT_DIR"/patches/*.patch "$DOC_DIR/patches/"
fi

cat > "$PKG_ROOT/DEBIAN/control" <<CONTROL
Package: $PACKAGE
Version: $VERSION
Section: video
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: python3, procps, systemd, gstreamer1.0-tools, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, v4l-utils, pipewire, wireplumber, libspa-0.2-modules, libc6, libstdc++6, libgcc-s1, libegl1, libgles2, libgnutls30, libudev1, libyaml-0-2, libdw1
Recommends: sudo, git, ca-certificates, curl, dpkg-dev, patch, xz-utils, bzip2, build-essential, meson, ninja-build, pkgconf, libudev-dev, v4l2loopback-dkms
Description: experimental AI-assisted Redrix HI556 camera tooling
 Installs scripts, tuning, and locally patched PipeWire SPA plugins used to
 make a Hynix HI556 camera work through PipeWire/libcamera on one Google
 Redrix / HP Elite Dragonfly Chromebook running Ubuntu.
 .
 This is experimental, AI-assisted repair tooling. It is installed inertly;
 run redrix-camera direct to apply user-level camera configuration.
CONTROL

cat > "$PKG_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
  echo "redrix-hi556-camera installed."
  echo "Next steps:"
  echo "  redrix-camera build-libcamera"
  echo "  redrix-camera direct"
fi
POSTINST
chmod 0755 "$PKG_ROOT/DEBIAN/postinst"

cat > "$DOC_DIR/copyright" <<'COPYRIGHT'
This package contains local Redrix camera helper scripts and patched PipeWire
SPA plugin binaries built from Ubuntu PipeWire 1.0.5-1ubuntu3.3.

The helper scripts were vibe-coded with OpenClaw and AI during one-machine
repair work. The PipeWire-derived binaries remain under the licensing terms of
PipeWire and Ubuntu's PipeWire packaging. See the patch files shipped in
/usr/share/doc/redrix-hi556-camera/patches/.

No warranty. Use at your own risk.
COPYRIGHT
chmod 0644 "$DOC_DIR/copyright"

cat > "$DOC_DIR/changelog" <<CHANGELOG
redrix-hi556-camera ($VERSION) unstable; urgency=low

  * Initial local package for the Redrix HI556 Ubuntu camera repair.

 -- $MAINTAINER  $RELEASE_DATE
CHANGELOG
gzip -n -9 "$DOC_DIR/changelog"
chmod 0644 "$DOC_DIR/changelog.gz"

cat > "$PKG_ROOT/usr/share/lintian/overrides/$PACKAGE" <<'OVERRIDES'
redrix-hi556-camera: custom-library-search-path RUNPATH /opt/redrix-libcamera/lib/x86_64-linux-gnu [usr/lib/redrix-camera/spa-0.2/libcamera/libspa-libcamera.so]
redrix-hi556-camera: no-manual-page [usr/bin/redrix-camera]
redrix-hi556-camera: copyright-without-copyright-notice
OVERRIDES
chmod 0644 "$PKG_ROOT/usr/share/lintian/overrides/$PACKAGE"

find "$PKG_ROOT" -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +
find "$PKG_ROOT" -type d -exec chmod 0755 {} +
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DIST_DIR/${PACKAGE}_${VERSION}_${ARCH}.deb"

echo "$DIST_DIR/${PACKAGE}_${VERSION}_${ARCH}.deb"
