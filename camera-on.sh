#!/usr/bin/env bash
set -euo pipefail

systemctl --user stop redrix-camera-on-demand.service >/dev/null 2>&1 || true
systemctl --user start redrix-camera-relay.service

echo "Camera relay is on. /dev/video0 should be visible to Chrome/Meet."
