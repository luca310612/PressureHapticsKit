"""Provenance-aware streaming recorder for experiment runs."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re
import secrets
import sys
import time
from typing import Any, Mapping

import numpy as np

from gnat.experiments.protocol import ExperimentSpec
from gnat.runner import LoopStep


def sha256_file(path: str | Path) -> str:
    """Return a streaming SHA-256 digest for a model or calibration artifact."""

    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _source_tree_sha256() -> str:
    """Fingerprint the Python package source present in this working tree."""

    source_root = Path(__file__).resolve().parents[1]
    digest = hashlib.sha256()
    for path in sorted(source_root.rglob("*.py")):
        relative = path.relative_to(source_root).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _json_safe(value: Any) -> Any:
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Mapping):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_json_safe(item) for item in value]
    return value


def _package_versions() -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for package in ("gnat", "numpy", "mujoco", "flygym", "numba"):
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    return versions


class ExperimentRecorder:
    """Write a run manifest and time-aligned step records without overwriting.

    Each record includes the exact vector given to the neural backend. Raw
    ommatidia can also be saved for short calibration runs. World state is
    caller-supplied so its coordinate ordering can be declared in the manifest.
    """

    def __init__(
        self,
        output_root: str | Path,
        spec: ExperimentSpec,
        *,
        backend: Mapping[str, Any],
        artifacts: Mapping[str, str | Path] | None = None,
        raw_vision: bool = False,
        world_state_layout: str = "MuJoCo qpos/qvel order for the compiled model",
    ) -> None:
        self.spec = spec
        self.raw_vision = raw_vision
        self._step_count = 0
        self._last_simulation_time_s: float | None = None
        self._motor_output_width: int | None = None
        self._started_monotonic = time.perf_counter()
        self._closed = False
        self._phase_totals: dict[str, dict[str, Any]] = {
            phase: {
                "steps": 0,
                "duration_s": 0.0,
                "total_spikes": 0,
                "retina_mean_sum": 0.0,
                "readouts": {},
                "motor_output_sum": None,
            }
            for phase in ("baseline", "stimulus", "recovery")
        }
        root = Path(output_root).expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        artifact_records = []
        for role, artifact_path in (artifacts or {}).items():
            resolved = Path(artifact_path).expanduser().resolve()
            if not resolved.is_file():
                raise FileNotFoundError(f"artifact for {role} does not exist: {resolved}")
            artifact_records.append(
                {
                    "role": str(role),
                    "path": str(resolved),
                    "size_bytes": resolved.stat().st_size,
                    "sha256": sha256_file(resolved),
                }
            )
        slug = re.sub(r"[^A-Za-z0-9._-]+", "-", spec.name.strip()).strip("-_")
        if not slug:
            slug = "experiment"
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.run_id = f"{slug}-{stamp}-{secrets.token_hex(4)}"
        self.run_dir = root / self.run_id
        self.run_dir.mkdir(exist_ok=False)
        self.manifest = {
            "schema_version": 1,
            "run_id": self.run_id,
            "created_at_utc": _now_utc(),
            "status": "running",
            "protocol": spec.as_payload(),
            "backend": _json_safe(backend),
            "artifacts": artifact_records,
            "runtime": {
                "python": sys.version,
                "packages": _package_versions(),
                "platform": sys.platform,
                "gnat_source_tree_sha256": _source_tree_sha256(),
            },
            "recording": {
                "steps_file": "steps.jsonl",
                "retina_input": "exact vector passed to BrainBackend.step",
                "raw_ommatidia_saved": raw_vision,
                "world_state_layout": world_state_layout,
                "simulation_time_unit": "s",
                "neural_duration_unit": "ms",
            },
        }
        self._write_json(self.run_dir / "manifest.json", self.manifest)
        self._steps = (self.run_dir / "steps.jsonl").open(
            "w", encoding="utf-8", newline="\n", buffering=1
        )

    @staticmethod
    def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")

    def record_step(
        self,
        step: LoopStep,
        *,
        stimulus_state: Mapping[str, Any],
        world_state: Mapping[str, Any],
    ) -> None:
        """Append one synchronized neural, visual, stimulus, and body sample."""

        if self._closed:
            raise RuntimeError("experiment recorder is already closed")
        sim_time = float(step.simulation_time_s)
        if not math.isfinite(sim_time) or sim_time < 0:
            raise ValueError("simulation time must be finite and non-negative")
        if (
            self._last_simulation_time_s is not None
            and sim_time <= self._last_simulation_time_s
        ):
            raise ValueError("simulation timestamps must increase strictly")
        if (
            self._motor_output_width is not None
            and len(step.brain.motor_output) != self._motor_output_width
        ):
            raise ValueError("motor output width changed during the experiment")
        record: dict[str, Any] = {
            "step": self._step_count,
            "simulation_time_s": sim_time,
            "wall_elapsed_s": time.perf_counter() - self._started_monotonic,
            "stimulus": _json_safe(stimulus_state),
            "retina_input": step.retina_input.tolist(),
            "neural": {
                "duration_ms": step.brain.duration_ms,
                "total_spikes": step.brain.total_spikes,
                "readouts": dict(step.brain.readouts),
                "motor_output": list(step.brain.motor_output),
            },
            "world": _json_safe(world_state),
        }
        if self.raw_vision:
            record["ommatidia_readouts"] = step.vision.ommatidia_readouts.tolist()
        self._steps.write(
            json.dumps(record, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            + "\n"
        )
        self._step_count += 1
        self._last_simulation_time_s = sim_time
        self._motor_output_width = len(step.brain.motor_output)
        elapsed = float(stimulus_state["elapsed_s"])
        phase = (
            "baseline"
            if elapsed < 0.0
            else "stimulus"
            if bool(stimulus_state["active"])
            else "recovery"
        )
        totals = self._phase_totals[phase]
        totals["steps"] += 1
        totals["duration_s"] += step.brain.duration_ms / 1000.0
        totals["total_spikes"] += step.brain.total_spikes
        totals["retina_mean_sum"] += float(np.mean(step.retina_input))
        for name, count in step.brain.readouts.items():
            readouts = totals["readouts"]
            readouts[name] = readouts.get(name, 0) + count
        motor_sum = totals["motor_output_sum"]
        if motor_sum is None:
            totals["motor_output_sum"] = [0.0] * len(step.brain.motor_output)
            motor_sum = totals["motor_output_sum"]
        for index, value in enumerate(step.brain.motor_output):
            motor_sum[index] += value
        if self._step_count % 100 == 0:
            self._steps.flush()

    def _phase_metrics(self) -> dict[str, dict[str, Any]]:
        metrics: dict[str, dict[str, Any]] = {}
        for phase, totals in self._phase_totals.items():
            step_count = int(totals["steps"])
            duration_s = float(totals["duration_s"])
            motor_sum = totals["motor_output_sum"] or []
            if step_count == 0:
                metrics[phase] = {"steps": 0, "duration_s": 0.0}
                continue
            metrics[phase] = {
                "steps": step_count,
                "duration_s": duration_s,
                "total_spikes": int(totals["total_spikes"]),
                "reported_count_rate_per_s": (
                    float(totals["total_spikes"]) / duration_s
                    if duration_s > 0
                    else 0.0
                ),
                "mean_reported_count_per_step": (
                    float(totals["total_spikes"]) / step_count
                ),
                "mean_retina_input": float(totals["retina_mean_sum"]) / step_count,
                "mean_readouts_per_step": {
                    name: float(count) / step_count
                    for name, count in totals["readouts"].items()
                },
                "mean_motor_output": [float(value) / step_count for value in motor_sum],
            }
        return metrics

    def finish(self, status: str = "complete", *, error: str | None = None) -> Path:
        """Close the stream and write a compact completion summary."""

        if self._closed:
            return self.run_dir
        if status not in {"complete", "failed", "interrupted"}:
            raise ValueError("status must be complete, failed, or interrupted")
        self._steps.flush()
        self._steps.close()
        self._closed = True
        finished_at = _now_utc()
        self.manifest["status"] = status
        self.manifest["finished_at_utc"] = finished_at
        self.manifest["recorded_steps"] = self._step_count
        self._write_json(self.run_dir / "manifest.json", self.manifest)
        summary: dict[str, Any] = {
            "run_id": self.run_id,
            "status": status,
            "finished_at_utc": finished_at,
            "recorded_steps": self._step_count,
            "wall_elapsed_s": time.perf_counter() - self._started_monotonic,
            "last_simulation_time_s": self._last_simulation_time_s,
            "descriptive_phase_metrics": self._phase_metrics(),
            "criteria_evaluated": False,
        }
        if error is not None:
            summary["error"] = error
        self._write_json(self.run_dir / "summary.json", summary)
        return self.run_dir

    def __enter__(self) -> "ExperimentRecorder":
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if exc is None:
            self.finish()
        else:
            self.finish("failed", error=f"{exc_type.__name__}: {exc}")
