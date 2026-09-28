"""Validated, JSON-serializable experiment protocols."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from gnat.clock import SimulationClock
from gnat.experiments.horizontal import HorizontalObjectStimulus
from gnat.experiments.looming import LoomingStimulus


@dataclass(frozen=True, slots=True)
class ExperimentSpec:
    """A declared visual-response trial description.

    Subject fields are required so unknown biological attributes are recorded
    explicitly as ``"unknown"`` instead of silently omitted. Success criteria
    are stored for review and are not automatically graded by the runner.
    """

    name: str
    research_question: str
    hypothesis: str
    protocol_version: str
    subject: Mapping[str, str]
    success_criteria: tuple[str, ...]
    stimulus: LoomingStimulus | HorizontalObjectStimulus
    baseline_s: float = 0.1
    recovery_s: float = 0.1
    physics_timestep_s: float = 0.0001
    neural_timestep_ms: float = 0.1
    notes: str = ""
    schema_version: int = 1

    REQUIRED_SUBJECT_FIELDS = (
        "species",
        "sex",
        "developmental_stage",
        "strain",
    )

    def __post_init__(self) -> None:
        for field_name in ("name", "research_question", "hypothesis", "protocol_version"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{field_name} must be a non-empty string")
        if (
            isinstance(self.schema_version, bool)
            or not isinstance(self.schema_version, int)
            or self.schema_version != 1
        ):
            raise ValueError("only experiment protocol schema_version 1 is supported")
        if not isinstance(self.notes, str):
            raise ValueError("notes must be a string")
        if not isinstance(self.stimulus, (LoomingStimulus, HorizontalObjectStimulus)):
            raise ValueError("stimulus must be a supported experiment stimulus")
        if not isinstance(self.subject, Mapping):
            raise ValueError("subject must be a mapping of explicit metadata fields")
        subject = dict(self.subject)
        if any(not isinstance(key, str) for key in subject):
            raise ValueError("subject field names must be strings")
        missing = set(self.REQUIRED_SUBJECT_FIELDS).difference(subject)
        if missing:
            raise ValueError(
                "subject is missing required fields: " + ", ".join(sorted(missing))
            )
        for field_name in self.REQUIRED_SUBJECT_FIELDS:
            value = subject[field_name]
            if not isinstance(value, str) or not value.strip():
                raise ValueError(
                    f"subject.{field_name} must be a non-empty string; "
                    'use "unknown" when it has not been established'
                )
        criteria = tuple(self.success_criteria)
        if not criteria or any(
            not isinstance(item, str) or not item.strip() for item in criteria
        ):
            raise ValueError("success_criteria must contain non-empty strings")
        for field_name in (
            "baseline_s",
            "recovery_s",
            "physics_timestep_s",
            "neural_timestep_ms",
        ):
            value = getattr(self, field_name)
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
            ):
                raise ValueError(f"{field_name} must be finite")
        if self.baseline_s < 0 or self.recovery_s < 0:
            raise ValueError("baseline_s and recovery_s must be non-negative")
        clock = SimulationClock(
            physics_timestep_s=self.physics_timestep_s,
            neural_timestep_ms=self.neural_timestep_ms,
        )
        _ = clock.physics_steps_per_neural_step
        total_duration_s = self.baseline_s + self.stimulus.duration_s + self.recovery_s
        if not math.isfinite(total_duration_s) or total_duration_s <= 0:
            raise ValueError("total trial duration must be positive and finite")
        neural_step_s = self.neural_timestep_ms / 1000.0
        step_count = total_duration_s / neural_step_s
        if not math.isclose(step_count, round(step_count), rel_tol=1e-9, abs_tol=1e-9):
            raise ValueError("trial duration must be an integer multiple of neural_timestep_ms")
        object.__setattr__(self, "subject", MappingProxyType(subject))
        object.__setattr__(self, "success_criteria", criteria)

    @property
    def total_duration_s(self) -> float:
        return self.baseline_s + self.stimulus.duration_s + self.recovery_s

    @property
    def step_count(self) -> int:
        return round(self.total_duration_s / (self.neural_timestep_ms / 1000.0))

    @classmethod
    def from_json(cls, path: str | Path) -> "ExperimentSpec":
        """Load and validate a protocol JSON file."""

        protocol_path = Path(path)
        with protocol_path.open(encoding="utf-8") as stream:
            raw = json.load(stream)
        if not isinstance(raw, dict):
            raise ValueError("experiment protocol must be a JSON object")
        expected = {
            "schema_version",
            "name",
            "research_question",
            "hypothesis",
            "protocol_version",
            "subject",
            "success_criteria",
            "stimulus",
            "baseline_s",
            "recovery_s",
            "physics_timestep_s",
            "neural_timestep_ms",
            "notes",
        }
        unknown = set(raw).difference(expected)
        missing = expected.difference(raw)
        if unknown:
            raise ValueError("unknown protocol fields: " + ", ".join(sorted(unknown)))
        if missing:
            raise ValueError("missing protocol fields: " + ", ".join(sorted(missing)))
        stimulus_data = raw["stimulus"]
        if not isinstance(stimulus_data, dict):
            raise ValueError("stimulus must be a JSON object")
        stimulus_kind = stimulus_data.get("kind", "looming")
        stimulus_fields_by_kind = {
            "looming": {
                "start_distance_mm",
                "end_distance_mm",
                "duration_s",
                "radius_mm",
                "y_mm",
                "z_mm",
                "gray_level",
            },
            "horizontal-object": {
                "radius_from_origin_mm",
                "start_azimuth_deg",
                "end_azimuth_deg",
                "duration_s",
                "object_radius_mm",
                "z_mm",
                "corridor_half_width_mm",
                "gray_level",
            },
        }
        if not isinstance(stimulus_kind, str) or stimulus_kind not in stimulus_fields_by_kind:
            raise ValueError("stimulus.kind must be 'looming' or 'horizontal-object'")
        stimulus_fields = stimulus_fields_by_kind[stimulus_kind]
        stimulus_parameters = {
            key: value for key, value in stimulus_data.items() if key != "kind"
        }
        stimulus_unknown = set(stimulus_parameters).difference(stimulus_fields)
        stimulus_missing = stimulus_fields.difference(stimulus_parameters)
        if stimulus_unknown:
            raise ValueError(
                "unknown stimulus fields: " + ", ".join(sorted(stimulus_unknown))
            )
        if stimulus_missing:
            raise ValueError(
                "missing stimulus fields: " + ", ".join(sorted(stimulus_missing))
            )
        subject = raw["subject"]
        criteria = raw["success_criteria"]
        if not isinstance(subject, dict):
            raise ValueError("subject must be a JSON object")
        if not isinstance(criteria, list):
            raise ValueError("success_criteria must be a JSON array")
        stimulus = (
            LoomingStimulus(**stimulus_parameters)
            if stimulus_kind == "looming"
            else HorizontalObjectStimulus(**stimulus_parameters)
        )
        return cls(
            schema_version=raw["schema_version"],
            name=raw["name"],
            research_question=raw["research_question"],
            hypothesis=raw["hypothesis"],
            protocol_version=raw["protocol_version"],
            subject=subject,
            success_criteria=tuple(criteria),
            stimulus=stimulus,
            baseline_s=raw["baseline_s"],
            recovery_s=raw["recovery_s"],
            physics_timestep_s=raw["physics_timestep_s"],
            neural_timestep_ms=raw["neural_timestep_ms"],
            notes=raw["notes"],
        )

    def as_payload(self) -> dict[str, object]:
        """Return the complete protocol in plain JSON-compatible values."""

        if isinstance(self.stimulus, HorizontalObjectStimulus):
            stimulus_payload: dict[str, object] = {
                "kind": "horizontal-object",
                "radius_from_origin_mm": self.stimulus.radius_from_origin_mm,
                "start_azimuth_deg": self.stimulus.start_azimuth_deg,
                "end_azimuth_deg": self.stimulus.end_azimuth_deg,
                "duration_s": self.stimulus.duration_s,
                "object_radius_mm": self.stimulus.object_radius_mm,
                "z_mm": self.stimulus.z_mm,
                "corridor_half_width_mm": self.stimulus.corridor_half_width_mm,
                "gray_level": self.stimulus.gray_level,
            }
        else:
            stimulus_payload = {
                "start_distance_mm": self.stimulus.start_distance_mm,
                "end_distance_mm": self.stimulus.end_distance_mm,
                "duration_s": self.stimulus.duration_s,
                "radius_mm": self.stimulus.radius_mm,
                "y_mm": self.stimulus.y_mm,
                "z_mm": self.stimulus.z_mm,
                "gray_level": self.stimulus.gray_level,
            }
        return {
            "schema_version": self.schema_version,
            "name": self.name,
            "research_question": self.research_question,
            "hypothesis": self.hypothesis,
            "protocol_version": self.protocol_version,
            "subject": dict(self.subject),
            "success_criteria": list(self.success_criteria),
            "stimulus": stimulus_payload,
            "baseline_s": self.baseline_s,
            "recovery_s": self.recovery_s,
            "physics_timestep_s": self.physics_timestep_s,
            "neural_timestep_ms": self.neural_timestep_ms,
            "notes": self.notes,
        }
