# Third-Party Notices

The original helper scripts, documentation, and packaging files in this
repository are licensed under the MIT License in `LICENSE`.

Third-party and separately licensed material:

- `hi556.yaml` declares `SPDX-License-Identifier: CC0-1.0` and remains
  available under CC0-1.0.
- `patches/*.patch` are source patches against Ubuntu PipeWire
  `1.0.5-1ubuntu3.3`. Those patch files modify PipeWire-derived source and
  should be treated as PipeWire/Ubuntu-derived material under the applicable
  upstream and Ubuntu package licensing terms.
- The exact Ubuntu source package used for the bundled SPA binaries is
  `pipewire 1.0.5-1ubuntu3.3` for Ubuntu 24.04 LTS Noble. Source package page:
  <https://launchpad.net/ubuntu/+source/pipewire/1.0.5-1ubuntu3.3>
- The rebuild script downloads the Ubuntu source files from:
  - <https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/pipewire_1.0.5-1ubuntu3.3.dsc>
  - <https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/pipewire_1.0.5.orig.tar.bz2>
  - <https://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/pipewire_1.0.5-1ubuntu3.3.debian.tar.xz>
- Generated Debian packages and bundled SPA plugin binaries are not intended
  to be committed to the source repository. If attached to a GitHub Release,
  they contain binaries derived from Ubuntu PipeWire and remain subject to the
  applicable PipeWire and Ubuntu package licensing terms.

This project is experimental one-machine repair tooling, vibe-coded with
OpenClaw and AI. It is provided without warranty.
