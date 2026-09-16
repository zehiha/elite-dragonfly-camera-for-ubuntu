#!/usr/bin/env python3
import os
import errno
import fcntl
import signal
import subprocess
import sys
import time
from datetime import datetime


def log(message):
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {message}", file=sys.stderr, flush=True)


def load_defaults(path="/etc/default/redrix-camera-relay"):
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip("'\"")
            if key and key not in os.environ:
                os.environ[key] = value


def prepend_env(name, value):
    old = os.environ.get(name)
    os.environ[name] = f"{value}:{old}" if old else value


def run_quiet(args):
    subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


class RedrixCameraDaemon:
    def __init__(self):
        load_defaults()

        self.prefix = os.environ.get("REDRIX_LIBCAMERA_PREFIX", "/opt/redrix-libcamera")
        self.libdir = os.environ.get("REDRIX_LIBCAMERA_LIBDIR", f"{self.prefix}/lib/x86_64-linux-gnu")
        self.device = os.environ.get("REDRIX_VIDEO_DEVICE", "/dev/video0")
        self.width = int(os.environ.get("REDRIX_IDLE_WIDTH", "640"))
        self.height = int(os.environ.get("REDRIX_IDLE_HEIGHT", "480"))
        self.fps = int(os.environ.get("REDRIX_IDLE_FPS", "30"))
        self.idle_pixel_format = os.environ.get("REDRIX_IDLE_PIXEL_FORMAT", "YUYV")
        self.gst_format = os.environ.get("REDRIX_IDLE_GST_FORMAT", "YUY2")
        self.source_caps = os.environ.get(
            "REDRIX_SOURCE_CAPS",
            f"video/x-raw,width={self.width},height={self.height},framerate={self.fps}/1",
        )
        self.output_caps = os.environ.get(
            "REDRIX_OUTPUT_CAPS",
            f"video/x-raw,format={self.gst_format},width={self.width},height={self.height},framerate={self.fps}/1",
        )
        self.sink_caps = os.environ.get("REDRIX_SINK_CAPS", self.output_caps)
        self.idle_seconds = float(os.environ.get("REDRIX_USER_IDLE_SECONDS", os.environ.get("REDRIX_IDLE_SECONDS", "4")))
        self.start_delay_seconds = float(os.environ.get("REDRIX_USER_START_DELAY_SECONDS", os.environ.get("REDRIX_START_DELAY_SECONDS", "1")))
        self.poll_seconds = float(os.environ.get("REDRIX_USER_POLL_SECONDS", os.environ.get("REDRIX_POLL_SECONDS", "0.5")))

        prepend_env("PATH", f"{self.prefix}/bin")
        prepend_env("LD_LIBRARY_PATH", self.libdir)
        prepend_env("GST_PLUGIN_PATH", f"{self.libdir}/gstreamer-1.0")
        os.environ.setdefault("LIBCAMERA_DATA_DIR", f"{self.prefix}/share/libcamera")
        os.environ.setdefault("LIBCAMERA_IPA_MODULE_PATH", f"{self.libdir}/libcamera/ipa")
        xdg_config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
        os.environ.setdefault(
            "LIBCAMERA_IPA_CONFIG_PATH",
            f"{xdg_config_home}/redrix-libcamera/ipa:{self.prefix}/share/libcamera/ipa",
        )
        os.environ.setdefault("LIBCAMERA_IPA_PROXY_PATH", f"{self.prefix}/libexec/libcamera")

        self.running = True
        self.mode = "idle"
        self.loopback_sink = None
        self.real_source = None
        self.real_buffer = bytearray()
        self.real_frame = None
        self.last_real_frame_at = 0.0
        self.last_write_warning_at = 0.0
        self.frame_size = self.width * self.height * 2
        self.frame_interval = 1.0 / max(self.fps, 1)
        self.idle_frame = self.build_idle_frame()
        self.client_since = 0.0
        self.idle_since = 0.0
        self.last_clients = []

    def configure_loopback(self):
        if self.loopback_uses_exclusive_caps():
            log("v4l2loopback exclusive_caps is enabled; persistent writer will claim output side")
            return

        result = subprocess.run(
            [
                "/usr/bin/v4l2-ctl",
                "-d",
                self.device,
                f"--set-fmt-video-out=width={self.width},height={self.height},pixelformat={self.idle_pixel_format}",
                f"--set-parm={self.fps}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.strip().replace("\n", "; ")
            raise RuntimeError(f"could not configure loopback output format: {detail or result.returncode}")

    @staticmethod
    def loopback_uses_exclusive_caps():
        try:
            with open("/sys/module/v4l2loopback/parameters/exclusive_caps", "r", encoding="utf-8") as handle:
                first_value = handle.read().strip().split(",", 1)[0].lower()
        except OSError:
            return False
        return first_value in ("1", "true", "y", "yes")

    def lock_loopback_controls(self):
        run_quiet([
            "/usr/bin/v4l2-ctl",
            "-d",
            self.device,
            "--set-ctrl=keep_format=1,sustain_framerate=1,timeout=3000",
        ])

    def loopback_sink_command(self):
        return [
            "gst-launch-1.0",
            "-q",
            "fdsrc",
            "fd=0",
            f"blocksize={self.frame_size}",
            "do-timestamp=true",
            "!",
            "rawvideoparse",
            f"format={self.gst_format.lower()}",
            f"width={self.width}",
            f"height={self.height}",
            f"framerate={self.fps}/1",
            f"frame-size={self.frame_size}",
            "!",
            self.output_caps,
            "!",
            "queue",
            "max-size-buffers=4",
            "leaky=downstream",
            "!",
            "identity",
            "drop-allocation=true",
            "!",
            "v4l2sink",
            "io-mode=rw",
            f"device={self.device}",
            "sync=false",
        ]

    def real_source_command(self):
        return [
            "gst-launch-1.0",
            "-q",
            "libcamerasrc",
            "!",
            self.source_caps,
            "!",
            "queue",
            "max-size-buffers=2",
            "leaky=downstream",
            "!",
            "videoconvert",
            "!",
            "videoscale",
            "!",
            self.sink_caps,
            "!",
            "queue",
            "max-size-buffers=4",
            "leaky=downstream",
            "!",
            "fdsink",
            "fd=1",
            "sync=false",
        ]

    @staticmethod
    def clamp_byte(value):
        return max(0, min(255, int(round(value))))

    @classmethod
    def rgb_to_yuv(cls, red, green, blue):
        y = 0.299 * red + 0.587 * green + 0.114 * blue
        u = -0.168736 * red - 0.331264 * green + 0.5 * blue + 128
        v = 0.5 * red - 0.418688 * green - 0.081312 * blue + 128
        return cls.clamp_byte(y), cls.clamp_byte(u), cls.clamp_byte(v)

    def build_idle_frame(self):
        if self.idle_pixel_format != "YUYV":
            raise RuntimeError(f"unsupported idle pixel format for direct writer: {self.idle_pixel_format}")

        colors = [
            (192, 192, 192),
            (192, 192, 0),
            (0, 192, 192),
            (0, 192, 0),
            (192, 0, 192),
            (192, 0, 0),
            (0, 0, 192),
            (32, 32, 32),
        ]
        yuv = [self.rgb_to_yuv(*color) for color in colors]
        frame = bytearray(self.frame_size)
        offset = 0
        for _row in range(self.height):
            for x in range(0, self.width, 2):
                first = min(len(yuv) - 1, x * len(yuv) // self.width)
                second = min(len(yuv) - 1, (x + 1) * len(yuv) // self.width)
                y0, u0, v0 = yuv[first]
                y1, _u1, _v1 = yuv[second]
                frame[offset] = y0
                frame[offset + 1] = u0
                frame[offset + 2] = y1
                frame[offset + 3] = v0
                offset += 4
        return bytes(frame)

    def open_loopback_writer(self):
        if self.loopback_sink is not None and self.loopback_sink.poll() is None:
            return
        self.close_loopback_writer()
        self.loopback_sink = subprocess.Popen(
            self.loopback_sink_command(),
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=None,
            start_new_session=True,
        )
        try:
            self.write_frame(self.idle_frame)
        except RuntimeError as exc:
            self.close_loopback_writer()
            raise self.loopback_writer_start_error(exc) from exc
        time.sleep(0.5)
        rc = self.loopback_sink.poll()
        if rc is not None:
            self.close_loopback_writer()
            raise self.loopback_writer_start_error(f"loopback sink exited during startup with code {rc}")
        log("persistent loopback writer is open; real camera is closed")

    def loopback_writer_start_error(self, reason):
        message = str(reason)
        if self.loopback_uses_exclusive_caps():
            message += (
                f"; {self.device} is not accepting a producer. "
                "Reload v4l2loopback so the first opener is the relay writer, "
                "then start this service before PipeWire or browser clients inspect the device."
            )
        return RuntimeError(message)

    def close_loopback_writer(self):
        if self.loopback_sink is None:
            return
        proc = self.loopback_sink
        self.loopback_sink = None
        if proc.stdin is not None:
            proc.stdin.close()
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=3)

    def write_frame(self, frame):
        if self.loopback_sink is None:
            return
        if self.loopback_sink.poll() is not None:
            raise RuntimeError(f"loopback sink exited with code {self.loopback_sink.returncode}")
        try:
            self.loopback_sink.stdin.write(frame)
            self.loopback_sink.stdin.flush()
        except BrokenPipeError as exc:
            raise RuntimeError("loopback sink closed its stdin") from exc

    def start_real_source(self):
        if self.real_source is not None and self.real_source.poll() is None:
            return True

        self.stop_real_source(log_close=False)
        self.real_source = subprocess.Popen(
            self.real_source_command(),
            stdout=subprocess.PIPE,
            stderr=None,
            start_new_session=True,
        )
        fd = self.real_source.stdout.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self.real_buffer.clear()
        self.real_frame = None
        self.mode = "real"
        time.sleep(0.5)
        rc = self.real_source.poll()
        if rc is not None:
            log(f"real camera source exited during startup with code {rc}")
            self.stop_real_source(log_close=False)
            return False
        log("real camera source is active")
        return True

    def stop_real_source(self, log_close=True):
        if self.real_source is None:
            self.mode = "idle"
            return

        proc = self.real_source
        self.real_source = None
        self.real_buffer.clear()
        self.real_frame = None
        self.mode = "idle"

        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=3)
        if proc.stdout is not None:
            proc.stdout.close()
        if log_close:
            log("real camera source is closed")

    def read_real_frame(self):
        if self.real_source is None:
            return None

        if self.real_source.poll() is not None:
            log(f"real camera source exited with code {self.real_source.returncode}")
            self.stop_real_source(log_close=False)
            return None

        fd = self.real_source.stdout.fileno()
        while True:
            try:
                chunk = os.read(fd, self.frame_size * 4)
            except BlockingIOError:
                break
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    break
                raise
            if not chunk:
                break
            self.real_buffer.extend(chunk)

        complete_frames = len(self.real_buffer) // self.frame_size
        if complete_frames == 0:
            return None

        start = (complete_frames - 1) * self.frame_size
        frame = bytes(self.real_buffer[start : start + self.frame_size])
        del self.real_buffer[: complete_frames * self.frame_size]
        self.real_frame = frame
        self.last_real_frame_at = time.monotonic()
        return frame

    def current_frame(self):
        frame = self.read_real_frame()
        if frame is not None:
            return frame
        if self.mode == "real" and self.real_frame is not None:
            if time.monotonic() - self.last_real_frame_at < 1.0:
                return self.real_frame
        return self.idle_frame

    def writer_pids(self):
        pids = {os.getpid()}
        if self.loopback_sink is not None:
            pids.add(self.loopback_sink.pid)
        return pids

    def client_pids(self):
        try:
            result = subprocess.run(
                ["/usr/bin/fuser", self.device],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            return []

        ignored = self.writer_pids()
        pids = []
        for token in result.stdout.split():
            try:
                pid = int(token)
            except ValueError:
                continue
            if pid not in ignored and pid != os.getpid():
                pids.append(pid)
        return pids

    def poll_once(self):
        clients = self.client_pids()
        now = time.monotonic()

        if clients != self.last_clients:
            if clients:
                log(f"client(s) detected on {self.device}: {', '.join(map(str, clients))}")
            elif self.last_clients:
                log(f"no external clients on {self.device}")
            self.last_clients = clients

        if clients:
            self.idle_since = 0.0
            if self.mode != "real":
                if self.client_since == 0.0:
                    self.client_since = now
                elif now - self.client_since >= self.start_delay_seconds:
                    if not self.start_real_source():
                        self.mode = "idle"
                    self.client_since = 0.0
            return

        self.client_since = 0.0
        if self.mode == "real":
            if self.idle_since == 0.0:
                self.idle_since = now
            elif now - self.idle_since >= self.idle_seconds:
                self.stop_real_source()
                self.idle_since = 0.0

    def stop(self, *_args):
        self.running = False

    def run(self):
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        self.configure_loopback()
        self.open_loopback_writer()
        self.lock_loopback_controls()
        next_poll = time.monotonic()
        next_frame = time.monotonic()
        try:
            while self.running:
                now = time.monotonic()
                if now >= next_poll:
                    self.poll_once()
                    next_poll = now + self.poll_seconds
                if now >= next_frame:
                    self.write_frame(self.current_frame())
                    if next_frame < now - self.frame_interval:
                        next_frame = now + self.frame_interval
                    else:
                        next_frame += self.frame_interval
                sleep_seconds = min(next_poll, next_frame) - time.monotonic()
                time.sleep(max(0.005, min(0.02, sleep_seconds)))
        finally:
            self.stop_real_source(log_close=False)
            self.close_loopback_writer()


if __name__ == "__main__":
    try:
        RedrixCameraDaemon().run()
    except Exception as exc:
        log(f"fatal: {exc}")
        sys.exit(1)
