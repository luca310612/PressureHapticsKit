"""Browser-based FlyGym viewer with stimulus controls and eye previews."""

from __future__ import annotations

from dataclasses import dataclass, field
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
import json
import math
from pathlib import Path
import secrets
import threading
import time
import urllib.parse
import webbrowser

import mujoco
import numpy as np
from PIL import Image

from gnat.brain import BrainBackend, NumpyFlyBrain
from gnat.clock import SimulationClock
from gnat.experiments import (
    HorizontalObjectStimulus,
    HorizontalObjectStimulusController,
)
from gnat.runner import ClosedLoopRunner
from gnat.vision import FlyGymVision, RetinaBridge, VisionSample
from gnat.world import FlyGymWorld, build_flygym_world
from gnat.world.mujoco_world import VIEWER_CAMERA_NAME


MAIN_RENDER_SIZE = (1280, 720)
EYE_PREVIEW_SIZE = (225, 256)
FRAME_RATE_HZ = 30.0
FRAME_INTERVAL_S = 1.0 / FRAME_RATE_HZ
CAMERA_DEFAULT_AZIMUTH = 0.0
CAMERA_DEFAULT_ELEVATION = -25.0
CAMERA_DEFAULT_DISTANCE = 22.0
WEB_ASSET_DIR = Path(__file__).with_name("web")


PAGE = (WEB_ASSET_DIR / "viewer.html").read_text(encoding="utf-8")
VIEWER_SCRIPT = (WEB_ASSET_DIR / "viewer.js").read_text(encoding="utf-8")


@dataclass
class _ViewerState:
    """Thread-safe command and frame state shared with the HTTP server."""

    lock: threading.Lock
    main_jpeg: bytes = b""
    left_jpeg: bytes = b""
    right_jpeg: bytes = b""
    status: str = "待機中"
    fire_requested: bool = False
    reset_requested: bool = False
    stop_requested: bool = False
    camera_azimuth: float = CAMERA_DEFAULT_AZIMUTH
    camera_elevation: float = CAMERA_DEFAULT_ELEVATION
    camera_distance: float = CAMERA_DEFAULT_DISTANCE
    brain_state: dict[str, object] = field(default_factory=dict)
    frame_sequence: int = 0
    render_fps: float = 0.0
    simulation_time_s: float = 0.0
    backend_status: str = "demo-numpy"
    backend_label: str = "DEMO CIRCUIT / NO CONNECTOME"
    connectome_loaded: bool = False
    motor_actuator_count: int = 0
    motor_status: str = "disconnected-no-calibrated-mapping"

    def command(self, name: str) -> dict[str, str]:
        with self.lock:
            if name == "fire":
                self.fire_requested = True
                self.status = "横移動を開始しました"
            elif name == "reset":
                self.reset_requested = True
                self.status = "待機中"
            elif name == "quit":
                self.stop_requested = True
                self.status = "終了しています"
            return {"status": self.status}

    def set_camera(self, azimuth: float, elevation: float, distance: float) -> dict[str, str]:
        """Update the free-camera orbit values from browser input."""

        if not all(math.isfinite(value) for value in (azimuth, elevation, distance)):
            raise ValueError("camera values must be finite")
        with self.lock:
            self.camera_azimuth = azimuth % 360.0
            self.camera_elevation = max(-80.0, min(-5.0, elevation))
            self.camera_distance = max(20.0, min(180.0, distance))
            self.status = "視点を更新しました"
            return {"status": self.status}

    def reset_camera(self) -> dict[str, str]:
        with self.lock:
            self.camera_azimuth = CAMERA_DEFAULT_AZIMUTH
            self.camera_elevation = CAMERA_DEFAULT_ELEVATION
            self.camera_distance = CAMERA_DEFAULT_DISTANCE
            self.status = "視点をリセットしました"
            return {"status": self.status}

class _ViewerHandler(BaseHTTPRequestHandler):
    """Serve the dashboard and the latest rendered frames."""

    server: "_ViewerHTTPServer"

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path == "/":
            page = PAGE.replace("__GNAT_TOKEN__", self.server.auth_token).replace(
                "__GNAT_BACKEND_LABEL__", self.server.state.backend_label
            )
            self._send_bytes(page.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/viewer.css":
            self._send_bytes(
                (WEB_ASSET_DIR / "viewer.css").read_bytes(),
                "text/css; charset=utf-8",
            )
            return
        if path == "/viewer.js":
            script = VIEWER_SCRIPT.replace(
                "__GNAT_TOKEN__", self.server.auth_token
            )
            self._send_bytes(
                script.encode("utf-8"),
                "application/javascript; charset=utf-8",
            )
            return
        if path == "/health":
            with self.server.state.lock:
                payload = {
                    "status": "running",
                    "backend": self.server.state.backend_status,
                    "frame_sequence": self.server.state.frame_sequence,
                    "render_fps": self.server.state.render_fps,
                    "target_fps": FRAME_RATE_HZ,
                    "simulation_time_s": self.server.state.simulation_time_s,
                    "frame_ready": bool(self.server.state.main_jpeg),
                    "connectome_loaded": self.server.state.connectome_loaded,
                    "motor_actuators": self.server.state.motor_actuator_count,
                    "motor_status": self.server.state.motor_status,
                }
            self._send_bytes(
                json.dumps(payload).encode("utf-8"),
                "application/json; charset=utf-8",
            )
            return
        frame_names = {
            "/frame/main.jpg": "main_jpeg",
            "/frame/left.jpg": "left_jpeg",
            "/frame/right.jpg": "right_jpeg",
        }
        if path in frame_names:
            if not self._authorized():
                self.send_error(403, "viewer token required")
                return
            with self.server.state.lock:
                frame = getattr(self.server.state, frame_names[path])
            if frame:
                self._send_bytes(frame, "image/jpeg")
            else:
                self.send_error(503, "frame not ready")
            return
        if path == "/brain/state":
            if not self._authorized():
                self.send_error(403, "viewer token required")
                return
            with self.server.state.lock:
                payload = dict(self.server.state.brain_state)
            self._send_bytes(
                json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                "application/json; charset=utf-8",
            )
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self.send_error(403, "viewer token required")
            return
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        if path == "/camera":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                payload = self.server.state.set_camera(
                    float(query["azimuth"][0]),
                    float(query["elevation"][0]),
                    float(query["distance"][0]),
                )
            except (KeyError, IndexError, TypeError, ValueError) as error:
                self.send_error(400, str(error))
                return
            self._send_bytes(
                json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                "application/json; charset=utf-8",
            )
            return
        command = {"/fire": "fire", "/reset": "reset", "/quit": "quit"}.get(path)
        if path == "/camera/reset":
            payload = self.server.state.reset_camera()
            self._send_bytes(
                json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                "application/json; charset=utf-8",
            )
            return
        if command is None:
            self.send_error(404)
            return
        payload = json.dumps(
            self.server.state.command(command), ensure_ascii=False
        ).encode("utf-8")
        self._send_bytes(payload, "application/json; charset=utf-8")

    def _send_bytes(self, payload: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _authorized(self) -> bool:
        token = self.headers.get("X-Gnat-Token", "")
        if not token:
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            token = query.get("token", [""])[0]
        return bool(token) and secrets.compare_digest(token, self.server.auth_token)

    def log_message(self, format: str, *args: object) -> None:
        return


class _ViewerHTTPServer(ThreadingHTTPServer):
    """HTTP server carrying the shared viewer state."""

    def __init__(self, state: _ViewerState) -> None:
        super().__init__(("127.0.0.1", 0), _ViewerHandler)
        self.state = state
        self.auth_token = secrets.token_urlsafe(32)


def _jpeg(frame: np.ndarray) -> bytes:
    """Encode an RGB frame for the browser."""

    image = Image.fromarray(np.asarray(frame, dtype=np.uint8), mode="RGB")
    output = BytesIO()
    image.save(
        output,
        format="JPEG",
        quality=95,
        subsampling=0,
        optimize=False,
    )
    return output.getvalue()


class FlyGymViewer:
    """Advance MuJoCo and publish the simulation and eye views over HTTP."""

    def __init__(
        self,
        world: FlyGymWorld,
        *,
        brain: BrainBackend | None = None,
        retina_bridge: RetinaBridge | None = None,
    ) -> None:
        self.world = world
        self._apply_display_palette()
        self._renderer = mujoco.Renderer(
            world.model,
            height=MAIN_RENDER_SIZE[1],
            width=MAIN_RENDER_SIZE[0],
        )
        self._camera_id = mujoco.mj_name2id(
            world.model, mujoco.mjtObj.mjOBJ_CAMERA, VIEWER_CAMERA_NAME
        )
        if self._camera_id < 0:
            raise RuntimeError(f"viewer camera not found: {VIEWER_CAMERA_NAME}")
        self._fly_body_id = mujoco.mj_name2id(
            world.model,
            mujoco.mjtObj.mjOBJ_BODY,
            f"{world.fly_name}/c_thorax",
        )
        if self._fly_body_id < 0:
            raise RuntimeError(f"fly thorax not found: {world.fly_name}/c_thorax")
        self._camera_lookat = np.array(
            world.data.xpos[self._fly_body_id], dtype=np.float64, copy=True
        )
        self._camera = mujoco.MjvCamera()
        self._camera.type = mujoco.mjtCamera.mjCAMERA_FREE
        self._brain = brain or NumpyFlyBrain()
        self._connectome_loaded = not isinstance(self._brain, NumpyFlyBrain)
        if self._connectome_loaded and retina_bridge is None:
            raise ValueError(
                "a calibrated RetinaBridge is required for a connectome backend"
            )
        if retina_bridge is not None:
            expected_size = getattr(self._brain, "input_size", None)
            actual_size = getattr(getattr(retina_bridge, "mapping", None), "target_size", None)
            if expected_size is None or actual_size != expected_size:
                raise ValueError(
                    "retina mapping target_size must match the selected brain input_size"
                )
        self._vision = FlyGymVision(world, include_raw=True)
        self._eye_jpegs = (b"", b"")
        self._publish_times: deque[float] = deque()
        self._physics_steps_per_frame = max(
            1, round(1.0 / (FRAME_RATE_HZ * world.simulation.timestep))
        )
        self._stimulus = HorizontalObjectStimulus()
        self._stimulus_controller = HorizontalObjectStimulusController(
            world, self._stimulus
        )
        self._stimulus_controller.apply_elapsed(-1.0)
        self._stimulus_started_at_s: float | None = None
        self._runner = ClosedLoopRunner(
            world,
            self._vision,
            retina_bridge,
            self._brain,
            clock=SimulationClock(
                physics_timestep_s=world.simulation.timestep,
                neural_timestep_ms=(
                    self._physics_steps_per_frame
                    * world.simulation.timestep
                    * 1000.0
                ),
            ),
            input_encoder=None if retina_bridge is not None else self._encode_demo_sample,
            physics_sample_hook=self._finalize_projectile,
        )
        self._state = _ViewerState(
            lock=threading.Lock(),
            brain_state=self._brain_state_payload(),
            backend_status=(
                "doomfly-malecns" if self._connectome_loaded else "demo-numpy"
            ),
            backend_label=(
                "CONNECTOME / DOOMFLY MALECNS"
                if self._connectome_loaded
                else "DEMO CIRCUIT / NO CONNECTOME"
            ),
            connectome_loaded=self._connectome_loaded,
            motor_actuator_count=world.motor_actuator_count,
        )
        self._server = _ViewerHTTPServer(self._state)
        self._server_thread = threading.Thread(
            target=self._server.serve_forever,
            name="gnat-viewer-http",
            daemon=True,
        )

    def _apply_display_palette(self) -> None:
        """Improve local viewer contrast without changing physics properties."""

        prefix = f"{self.world.fly_name}/"
        for geom_id in range(self.world.model.ngeom):
            name = mujoco.mj_id2name(
                self.world.model, mujoco.mjtObj.mjOBJ_GEOM, geom_id
            )
            if name is None or not name.startswith(prefix):
                continue
            if "eye_cam_marker" in name:
                continue
            self.world.model.geom_rgba[geom_id, :3] = (0.18, 0.24, 0.32)

    @property
    def url(self) -> str:
        return f"http://{self._server.server_address[0]}:{self._server.server_address[1]}"

    def _apply_camera(self) -> None:
        with self._state.lock:
            azimuth = self._state.camera_azimuth
            elevation = self._state.camera_elevation
            distance = self._state.camera_distance
        self._camera.type = mujoco.mjtCamera.mjCAMERA_FREE
        self._camera.azimuth = azimuth
        self._camera.elevation = elevation
        self._camera.distance = distance
        self._camera.lookat[:] = self._camera_lookat

    def _fire_projectile(self) -> None:
        """Start one fixed-speed left-to-right visual sweep."""

        self._stimulus_started_at_s = float(self.world.simulation.time)
        self._stimulus_controller.apply_elapsed(0.0)

    def _reset_projectile(self) -> None:
        self.world.simulation.reset()
        reset = getattr(self._brain, "reset", None)
        if reset is not None:
            reset()
        self._stimulus_started_at_s = None
        self._stimulus_controller.apply_elapsed(-1.0)

    def _finalize_projectile(self) -> None:
        """Commit one final kinematic hold before eyes and renderer sample it."""

        if self._stimulus_started_at_s is None:
            return
        elapsed_s = float(self.world.simulation.time) - self._stimulus_started_at_s
        self._stimulus_controller.apply_elapsed(elapsed_s)
        if elapsed_s > self._stimulus.duration_s:
            self._stimulus_started_at_s = None

    def _consume_commands(self) -> bool:
        with self._state.lock:
            fire = self._state.fire_requested
            reset = self._state.reset_requested
            stopped = self._state.stop_requested
            self._state.fire_requested = False
            self._state.reset_requested = False
        if reset:
            self._reset_projectile()
        if fire:
            self._fire_projectile()
        return stopped

    @staticmethod
    def _encode_demo_sample(sample: VisionSample) -> np.ndarray:
        return NumpyFlyBrain.encode_ommatidia_readouts(sample.ommatidia_readouts)

    def _publish_frames(self, vision_sample: VisionSample | None = None) -> None:
        self._apply_camera()
        self._renderer.update_scene(self.world.data, self._camera)
        main_jpeg = _jpeg(self._renderer.render())
        if vision_sample is None:
            vision_sample = self._vision.sample()
        if vision_sample.raw_rgb is None:
            vision_sample = self._vision.sample(include_raw=True)
        if vision_sample.raw_rgb is None:
            raise RuntimeError("viewer eye sample did not include raw frames")
        self._eye_jpegs = tuple(_jpeg(frame) for frame in vision_sample.raw_rgb)
        left_jpeg, right_jpeg = self._eye_jpegs
        now = time.perf_counter()
        self._publish_times.append(now)
        while self._publish_times and now - self._publish_times[0] > 1.0:
            self._publish_times.popleft()
        if len(self._publish_times) > 1:
            render_fps = (len(self._publish_times) - 1) / (
                self._publish_times[-1] - self._publish_times[0]
            )
        else:
            render_fps = 0.0
        with self._state.lock:
            self._state.frame_sequence += 1
            self._state.render_fps = render_fps
            self._state.simulation_time_s = vision_sample.simulation_time_s
            self._state.main_jpeg = main_jpeg
            self._state.left_jpeg = left_jpeg
            self._state.right_jpeg = right_jpeg
            payload = self._brain_state_payload()
            payload.update(
                {
                    "mode": (
                        "doomfly-malecns" if self._connectome_loaded else "demo-numpy"
                    ),
                    "connectome_loaded": self._connectome_loaded,
                    "frame_sequence": self._state.frame_sequence,
                    "simulation_time_s": self._state.simulation_time_s,
                }
            )
            self._state.brain_state = payload

    def _brain_state_payload(self) -> dict[str, object]:
        snapshot = getattr(self._brain, "snapshot", None)
        if snapshot is None:
            return {}
        if hasattr(snapshot, "as_payload"):
            return dict(snapshot.as_payload())
        if isinstance(snapshot, dict):
            return dict(snapshot)
        raise TypeError("selected brain snapshot must be a dict or expose as_payload()")

    def run(self) -> None:
        self._server_thread.start()
        print(f"gnat viewer: {self.url}")
        self._publish_frames()
        # Publish the first complete frame before opening the browser.  This
        # prevents the initial 503 response from leaving a permanently blank
        # image when the browser loads faster than MuJoCo renders.
        webbrowser.open(self.url, new=2)
        next_frame_deadline = time.perf_counter()
        while True:
            if self._consume_commands():
                break
            loop_step = self._runner.step()
            self._publish_frames(loop_step.vision)
            next_frame_deadline += FRAME_INTERVAL_S
            remaining = next_frame_deadline - time.perf_counter()
            if remaining > 0:
                time.sleep(remaining)
            else:
                next_frame_deadline = time.perf_counter()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._renderer.close()


def run_viewer(
    *,
    connectome_path: str | None = None,
    doomfly_root: str | None = None,
    manifest_path: str | None = None,
    retina_mapping_path: str | None = None,
    prefer_native: bool = True,
) -> None:
    """Launch the local browser viewer."""

    brain = None
    retina_bridge = None
    if connectome_path is not None:
        from gnat.brain import DoomflyBrain

        graph = str(connectome_path)
        manifest = (
            str(manifest_path)
            if manifest_path is not None
            else str(Path(connectome_path).with_name("manifest.json"))
        )
        if retina_mapping_path is None:
            raise ValueError(
                "--retina-mapping is required with --connectome; "
                "use a calibrated FlyGym-to-MaleCNS .npz"
            )
        from gnat.vision import RetinaBridge

        brain = DoomflyBrain.from_manifest(
            graph,
            manifest,
            doomfly_root=doomfly_root,
            prefer_native=prefer_native,
        )
        retina_bridge = RetinaBridge.from_npz(retina_mapping_path)

    flygym_world = build_flygym_world()
    viewer: FlyGymViewer | None = None
    try:
        viewer = FlyGymViewer(
            flygym_world,
            brain=brain,
            retina_bridge=retina_bridge,
        )
        viewer.run()
    finally:
        if viewer is not None:
            viewer.close()
        flygym_world.simulation.close()
