# Release Notes - v0.1.1

## Summary

Documentation cleanup release for AI-assisted camera compatibility tooling on a
real HP Elite Dragonfly Chromebook / Google Redrix system with Intel IPU6 and
Hynix HI556 on Ubuntu.

No camera behavior changes are intended from `v0.1.0`; this release cleans up
GitHub-facing documentation and publishes a matching `0.1.1` package asset.

This is not an official HP, Google, Ubuntu, PipeWire, libcamera, OpenAI, or
OpenClaw project. Use at your own risk.

## Tested Environment

- OS: Ubuntu 24.04.5 LTS (Noble Numbat)
- Kernel during packaging: `6.17.0-1025-oem`
- DMI: `Google Redrix rev3`
- Board: `Google Redrix`
- Firmware: coreboot / `MrChromebox-2509.4`
- Camera path: Intel IPU6 with Hynix HI556 tuning
- ACPI camera device observed locally: `INT3537` at `\_SB_.PCI0.I2C2.CAM0`
- PipeWire target for bundled SPA binaries: Ubuntu Noble
  `pipewire 1.0.5-1ubuntu3.3`
- Architecture: `amd64` (Debian/Ubuntu 64-bit x86, including Intel CPUs)

## What Is Included In Source

- `redrix-camera` command wrapper
- direct PipeWire/libcamera setup script
- local libcamera build script
- `build-pipewire-spa.sh` rebuild script for the patched PipeWire SPA plugins
- approximate `hi556.yaml` tuning file
- diagnostic and legacy relay scripts
- Debian package builder
- PipeWire patch files for provenance/rebuild reference
- MIT license for original helper code
- third-party notices for CC0 and PipeWire/Ubuntu-derived material

## Build Reproducibility

The source repository is enough to rebuild the `.deb` from a fresh clone on the
target Ubuntu generation. The SPA plugin binaries are generated locally by:

```bash
./01-build-libcamera.sh
./build-pipewire-spa.sh
./build-deb.sh
```

`build-pipewire-spa.sh` downloads Ubuntu `pipewire 1.0.5-1ubuntu3.3` source
files from `https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/`, verifies
the source tarball checksums, applies `patches/*.patch`, and builds
`libspa-libcamera.so` plus `libspa-v4l2.so`.

## Download

- [redrix-hi556-camera_0.1.1_amd64.deb](https://github.com/zehiha/elite-dragonfly-camera-for-ubuntu/releases/download/v0.1.1/redrix-hi556-camera_0.1.1_amd64.deb)
- [SHA256SUMS](https://github.com/zehiha/elite-dragonfly-camera-for-ubuntu/releases/download/v0.1.1/SHA256SUMS)

Published SHA256:

```text
4e2083e1d7113085b89240c1db53ad1c7c7aa703834b98329d0654331d46dabf  redrix-hi556-camera_0.1.1_amd64.deb
```

Rebuild before publishing if any source file changes:

```bash
./build-deb.sh
sha256sum dist/redrix-hi556-camera_0.1.1_amd64.deb
lintian dist/redrix-hi556-camera_0.1.1_amd64.deb
```

## Install

```bash
sudo apt install ./redrix-hi556-camera_0.1.1_amd64.deb
redrix-camera build-libcamera
redrix-camera direct
```

Fully restart Chrome after running `redrix-camera direct`, then select the
`hi556` / libcamera camera in Google Meet.

## Verify

```bash
redrix-camera status
redrix-camera verify
```

On the original machine, `redrix-camera verify` successfully read 30 frames
from the PipeWire `hi556` source node.

## Disable Redrix User Config

```bash
redrix-camera direct --disable
```

This moves active Redrix user-level PipeWire/WirePlumber config aside and
removes the Chrome PipeWire camera flag from the user desktop file. It does not
automatically restore previous `.redrix-backup-*` files. Fully restart Chrome
afterwards.

`redrix-camera direct --revert` remains available as a compatibility alias for
`--disable`.

## Diagnostic Log Privacy

`redrix-camera diagnose` writes a `/tmp/redrix-camera-diagnose-*.log` file.
Review it before posting publicly; it may contain usernames, host/kernel
details, device paths, and service logs.

## Known Risks

- This is tested on one machine, not a general Ubuntu camera driver.
- It writes user-level PipeWire/WirePlumber config.
- It changes the user's Chrome desktop launcher flags.
- The bundled SPA plugin binaries are tied to the Ubuntu PipeWire generation
  they were built from.
- Legacy v4l2loopback scripts are included for reference/debugging, but they
  were not the final reliable path on the original machine.

## Licensing

Original helper scripts and docs are MIT licensed. `hi556.yaml` is CC0-1.0.
PipeWire patches and generated release binaries are PipeWire/Ubuntu-derived
material and remain subject to the applicable upstream and Ubuntu packaging
licenses. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
