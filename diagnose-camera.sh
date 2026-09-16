#!/usr/bin/env bash
set -u

DEVICE="${REDRIX_VIDEO_DEVICE:-/dev/video0}"
LOG="${REDRIX_DIAG_LOG:-/tmp/redrix-camera-diagnose-$(date +%Y%m%d-%H%M%S).log}"

run() {
  local title="$1"
  shift
  {
    echo
    echo "### $title"
    echo "\$ $*"
    "$@"
    echo "exit=$?"
  } >>"$LOG" 2>&1
}

run_shell() {
  local title="$1"
  local script="$2"
  {
    echo
    echo "### $title"
    echo "$script"
    bash -lc "$script"
    echo "exit=$?"
  } >>"$LOG" 2>&1
}

: >"$LOG"
{
  echo "Redrix camera diagnostic"
  date --iso-8601=seconds
  echo "device=$DEVICE"
  echo "Review this log before posting it publicly; it may contain usernames, host/kernel details, device paths, and service logs."
} >>"$LOG"

run "kernel" uname -a
run "user groups" id
run_shell "video device nodes" "ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true"
run "v4l2 devices" v4l2-ctl --list-devices
run "v4l2 driver" v4l2-ctl -D -d "$DEVICE"
run "v4l2 full state" v4l2-ctl --all -d "$DEVICE"
run "v4l2 formats" v4l2-ctl --list-formats-ext -d "$DEVICE"
run_shell "v4l2loopback module params" "for f in /sys/module/v4l2loopback/parameters/*; do [ -r \"\$f\" ] && printf '%s=' \"\${f##*/}\" && cat \"\$f\"; done"
run_shell "modprobe config" "/sbin/modprobe --showconfig 2>/dev/null | grep -E '(^options v4l2loopback|^install v4l2loopback|^alias.*v4l2loopback)' || true"
run_shell "device users" "fuser -v $DEVICE /dev/media* /dev/v4l-subdev* 2>&1 || true"
run "root camera services" systemctl --no-pager --full status v4l2-relayd.service v4l2-relayd@default.service redrix-camera-relay.service redrix-camera-on-demand.service
run "user media services" systemctl --user --no-pager --full status pipewire.service pipewire-pulse.service wireplumber.service xdg-desktop-portal.service redrix-camera-on-demand.service redrix-camera-relay.service
run "PipeWire status" wpctl status
run_shell "PipeWire camera node dump" "NODE=\$(wpctl status | awk '/Intel MIPI Camera \\(V4L2\\)/ {for (i=1; i<=NF; i++) if (\$i ~ /^[0-9]+\\.\$/) {sub(\"\\\\.\", \"\", \$i); print \$i; exit}}'); if [ -n \"\$NODE\" ]; then wpctl inspect \"\$NODE\"; pw-dump | jq --arg node \"\$NODE\" '.[] | select((.id|tostring) == \$node) | {id, type, props:.info.props, params:.info.params}' 2>/dev/null || true; else echo 'no PipeWire camera node'; exit 1; fi"
run "GStreamer device monitor" timeout 8 gst-device-monitor-1.0 Video/Source
run "direct V4L2 read test" timeout 8 gst-launch-1.0 -q v4l2src device="$DEVICE" num-buffers=30 ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 ! fakesink
run_shell "PipeWire buffer read test" "NODE=\$(wpctl status | awk '/Intel MIPI Camera \\(V4L2\\)/ {for (i=1; i<=NF; i++) if (\$i ~ /^[0-9]+\\.\$/) {sub(\"\\\\.\", \"\", \$i); print \$i; exit}}'); if [ -n \"\$NODE\" ]; then TARGET=\"v4l2:$DEVICE\"; timeout 8 gst-launch-1.0 -q pipewiresrc target-object=\"\$TARGET\" always-copy=true min-buffers=1 max-buffers=4 num-buffers=30 ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 ! fakesink sync=false; else echo 'no PipeWire camera node'; exit 1; fi"
run "recent user media journal" journalctl -b --user --no-pager -u pipewire.service -u wireplumber.service -u xdg-desktop-portal.service -n 220
run "recent relay journal" journalctl -b --no-pager -u v4l2-relayd.service -u v4l2-relayd@default.service -n 220

echo "$LOG"
