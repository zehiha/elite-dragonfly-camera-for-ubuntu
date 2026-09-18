# Elite Dragonfly Camera for Ubuntu

Experimental, AI-assisted compatibility tooling developed while repairing a
real HP Elite Dragonfly Chromebook / Google Redrix camera stack on Ubuntu
24.04 LTS.

This is not an official HP, Google, Ubuntu, PipeWire, libcamera, OpenAI, or
OpenClaw project. Read the scripts before running them. They can change user
PipeWire/WirePlumber configuration, Chrome desktop launch flags, systemd user
services, v4l2loopback settings, and camera-related runtime paths.

## Download

Download the current experimental release:

- [redrix-hi556-camera_0.1.1_amd64.deb](https://github.com/zehiha/elite-dragonfly-camera-for-ubuntu/releases/download/v0.1.1/redrix-hi556-camera_0.1.1_amd64.deb)
- [SHA256SUMS](https://github.com/zehiha/elite-dragonfly-camera-for-ubuntu/releases/download/v0.1.1/SHA256SUMS)

Verify the package against `SHA256SUMS` before installing.

## Tested Compatibility

This package is intentionally narrow. It is tested on one machine:

- OS: Ubuntu 24.04.5 LTS (Noble Numbat)
- Kernel during packaging: `6.17.0-1025-oem`
- DMI: `Google Redrix rev3`
- Board: `Google Redrix`
- Firmware: coreboot / `MrChromebox-2509.4`
- Camera path: Intel IPU6 with Hynix HI556 tuning
- ACPI camera device observed locally: `INT3537` at `\_SB_.PCI0.I2C2.CAM0`
- PipeWire target for bundled SPA binaries: Ubuntu Noble
  `pipewire 1.0.5-1ubuntu3.3`
- Architecture: `amd64`

`amd64` is Debian/Ubuntu's name for 64-bit x86. It is the right architecture
name for ordinary 64-bit Intel and AMD PCs.

Do not assume this works on every Elite Dragonfly or every Ubuntu camera
setup. Treat other hardware as untested until proven.

## Status

The current working path on the original Redrix machine is:

```text
Chrome / Google Meet -> PipeWire camera portal -> WirePlumber libcamera monitor -> local PipeWire libcamera SPA plugin -> /opt/redrix-libcamera -> HI556
```

The useful pieces are:

- a local libcamera build under `/opt/redrix-libcamera`
- `hi556.yaml`, an approximate tuning file for the HI556 sensor
- a patched PipeWire `libspa-libcamera.so` loaded through `SPA_PLUGIN_DIR`
- Chrome launched with `--enable-features=WebRtcPipeWireCamera`
- WirePlumber libcamera monitoring enabled

The older v4l2loopback relay scripts are still included as legacy/debugging
material, but they were not the final reliable fix on the original machine.

## Build From A Fresh Clone

For GitHub, keep source files in the repository and attach the generated `.deb`
to a Release. Do not commit `dist/` or `.deb` files to the source branch.

Install build dependencies for the PipeWire SPA plugin rebuild:

```bash
sudo apt-get install -y ca-certificates curl dpkg-dev patch xz-utils bzip2 build-essential meson ninja-build pkgconf libudev-dev
```

Build and install the local libcamera copy first:

```bash
./01-build-libcamera.sh
```

Then rebuild the patched PipeWire SPA plugins from Ubuntu source:

```bash
./build-pipewire-spa.sh
```

`build-pipewire-spa.sh` downloads these Ubuntu source package files from
`https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/`:

- `pipewire_1.0.5-1ubuntu3.3.dsc`
- `pipewire_1.0.5.orig.tar.bz2`
- `pipewire_1.0.5-1ubuntu3.3.debian.tar.xz`

It verifies the tarball SHA256 values embedded in the script, applies the
patches in `patches/`, and writes:

```text
pipewire-build/redrix-spa-0.2/libcamera/libspa-libcamera.so
pipewire-build/redrix-spa-0.2/v4l2/libspa-v4l2.so
```

Build the Debian package:

```bash
./build-deb.sh
```

If the SPA plugin binaries are missing, `build-deb.sh` calls
`build-pipewire-spa.sh` automatically.

## Install The Local Deb

Install the generated package:

```bash
sudo apt install ./dist/redrix-hi556-camera_0.1.1_amd64.deb
```

The package only installs files. It does not automatically reconfigure the
camera stack during package installation.

The matching release notes live in `RELEASE.md`.

## First Setup

Build and install the local libcamera copy if it is not already present:

```bash
redrix-camera build-libcamera
```

Enable the direct PipeWire/libcamera path:

```bash
redrix-camera direct
```

Then fully quit Chrome and open it again from the application launcher. In
Google Meet, select the `hi556` / libcamera camera.

Check status:

```bash
redrix-camera status
```

Run a short PipeWire frame-read test:

```bash
redrix-camera verify
```

Collect a diagnostic log:

```bash
redrix-camera diagnose
```

Review diagnostic logs before posting them publicly. They may contain
usernames, host/kernel details, device paths, and service logs.

## What `redrix-camera direct` Does

The direct setup command:

- installs `hi556.yaml` to `~/.config/redrix-libcamera/ipa/simple/hi556.yaml`
- writes `~/.config/wireplumber/main.lua.d/50-libcamera-config.lua`
- writes `~/.config/wireplumber/main.lua.d/50-v4l2-config.lua`
- writes user systemd drop-ins for `pipewire.service` and `wireplumber.service`
- points PipeWire/WirePlumber at the packaged patched SPA plugin directory
- patches the user Chrome desktop file to add `--enable-features=WebRtcPipeWireCamera`
- stops old user-level Redrix relay services if they exist
- restarts PipeWire, WirePlumber, and the desktop portal

Existing files that it overwrites are backed up next to the original file with
a `.redrix-backup-*` suffix.

## Disable The Redrix User Config

```bash
redrix-camera direct --disable
```

This moves active Redrix user-level PipeWire/WirePlumber config aside and
removes the Chrome PipeWire camera flag from the user desktop file. It does
not automatically restore the previous `.redrix-backup-*` files. Fully restart
Chrome afterwards.

`redrix-camera direct --revert` is kept as a compatibility alias for
`--disable`.

## Package Contents

The `.deb` installs:

- `/usr/bin/redrix-camera`
- `/usr/lib/redrix-camera/` scripts and helper files
- `/usr/lib/redrix-camera/spa-0.2/libcamera/libspa-libcamera.so`
- `/usr/lib/redrix-camera/spa-0.2/v4l2/libspa-v4l2.so`
- `/usr/share/doc/redrix-hi556-camera/README.md`
- `/usr/share/doc/redrix-hi556-camera/THIRD_PARTY_NOTICES.md`
- `/usr/share/doc/redrix-hi556-camera/patches/`

The bundled SPA plugin binaries were built from Ubuntu PipeWire
`1.0.5-1ubuntu3.3` with the patches in `patches/`. They are intended for the
same Ubuntu/PipeWire generation, not as generic binaries for every distro.

## Commands

```text
redrix-camera help
redrix-camera build-libcamera
redrix-camera direct
redrix-camera direct --disable
redrix-camera status
redrix-camera verify
redrix-camera diagnose
redrix-camera enable-loopback
redrix-camera stop-loopback
redrix-camera legacy-status
redrix-camera camera-on
redrix-camera camera-off
```

## Legacy Loopback Notes

The loopback path tried to expose a browser-friendly `/dev/video0`:

```text
Chrome/Meet -> /dev/video0 v4l2loopback -> Redrix on-demand relay -> libcamerasrc
```

On the original machine, this repeatedly failed around v4l2loopback writer
handoff, exclusive caps behavior, and PipeWire buffer negotiation. The scripts
remain because they document the work and may still help with debugging, but
the recommended path is the direct PipeWire/libcamera setup above.

## No Warranty

This is a one-machine repair packaged for sharing. It may break your camera
stack, leave Chrome with odd flags, or require rebooting/restarting PipeWire.
Keep recovery access to your machine and be ready to undo user config changes.

The helper scripts, docs, and packaging were vibe-coded with OpenClaw and AI
while debugging the original machine. Use at your own risk.

## License

Original helper scripts, docs, and packaging files are MIT licensed. The HI556
tuning file is CC0-1.0. PipeWire patch files and generated release binaries are
PipeWire/Ubuntu-derived material and remain subject to the applicable upstream
and Ubuntu package licensing terms. See `LICENSE` and
`THIRD_PARTY_NOTICES.md`.
