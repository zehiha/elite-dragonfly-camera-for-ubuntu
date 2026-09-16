#!/usr/bin/env bash
set -euo pipefail

systemctl --user stop redrix-camera-relay.service >/dev/null 2>&1 || true
systemctl --user stop redrix-camera-on-demand.service >/dev/null 2>&1 || true

echo "Camera relay is off. The real camera should be closed."
