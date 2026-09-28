"""Deterministic looming stimulus geometry for FlyGym's millimetre world."""

from __future__ import annotations

from dataclasses import dataclass
import math

import mujoco

from gnat.world import FlyGymWorld


@dataclass(frozen=True, slots=True)
class LoomingStimulus:
    """A sphere that starts on positive X and approaches the world origin.

    FlyGym's NeuroMechFly world uses millimetres for positions. Times remain
    seconds. The trajectory is a constant-speed approach between the supplied
    distances; it does not claim to reproduce a particular biological trial.
    """

    start_distance_mm: float
    end_distance_mm: float
    duration_s: float
    radius_mm: float = 1.2
    y_mm: float = 0.0
    z_mm: float = 3.0
    gray_level: float = 0.05

    def __post_init__(self) -> None:
        values = (
            self.start_distance_mm,
            self.end_distance_mm,
            self.duration_s,
            self.radius_mm,
            self.y_mm,
            self.z_mm,
            self.gray_level,
        )
        if any(
            isinstance(value, bool) or not isinstance(value, (int, float))
            for value in values
        ):
            raise ValueError("looming parameters must be numeric, not bool")
        if not all(math.isfinite(value) for value in values):
            raise ValueError("looming parameters must be finite")
        if self.start_distance_mm <= 0 or self.end_distance_mm <= 0:
            raise ValueError("looming distances must be positive")
        if self.end_distance_mm >= self.start_distance_mm:
            raise ValueError("end_distance_mm must be smaller than start_distance_mm")
        if self.duration_s <= 0:
            raise ValueError("duration_s must be positive")
        if self.radius_mm <= 0:
            raise ValueError("radius_mm must be positive")
        if not 0.0 <= self.gray_level <= 1.0:
            raise ValueError("gray_level must be in [0, 1]")

    @property
    def approach_speed_mm_s(self) -> float:
        """Return the constant approach speed implied by this trajectory."""

        return (self.start_distance_mm - self.end_distance_mm) / self.duration_s

    def distance_mm_at(self, elapsed_s: float) -> float:
        """Return the clamped distance from the fly at a stimulus-relative time."""

        if (
            isinstance(elapsed_s, bool)
            or not isinstance(elapsed_s, (int, float))
            or not math.isfinite(elapsed_s)
        ):
            raise ValueError("elapsed_s must be finite")
        fraction = min(1.0, max(0.0, elapsed_s / self.duration_s))
        return self.start_distance_mm + fraction * (
            self.end_distance_mm - self.start_distance_mm
        )

    def visual_range_mm_at(self, elapsed_s: float) -> float:
        """Return distance from the nominal world origin to the sphere center."""

        x_mm = self.distance_mm_at(elapsed_s)
        return math.sqrt(x_mm * x_mm + self.y_mm * self.y_mm + self.z_mm * self.z_mm)

    def angular_diameter_rad_at(self, elapsed_s: float) -> float:
        """Return nominal angular diameter from the world origin."""

        range_mm = self.visual_range_mm_at(elapsed_s)
        return 2.0 * math.atan2(self.radius_mm, range_mm)

    def angular_expansion_rate_rad_s_at(self, elapsed_s: float) -> float:
        """Return nominal angular expansion rate from the world origin."""

        if (
            isinstance(elapsed_s, bool)
            or not isinstance(elapsed_s, (int, float))
            or not math.isfinite(elapsed_s)
        ):
            raise ValueError("elapsed_s must be finite")
        if elapsed_s < 0.0 or elapsed_s > self.duration_s:
            return 0.0
        distance = self.distance_mm_at(elapsed_s)
        range_mm = self.visual_range_mm_at(elapsed_s)
        return (
            2.0
            * self.radius_mm
            * self.approach_speed_mm_s
            * distance
            / (
                range_mm
                * (range_mm * range_mm + self.radius_mm * self.radius_mm)
            )
        )

    def state_at(self, elapsed_s: float) -> dict[str, float | bool]:
        """Return the stimulus state suitable for an experiment trace."""

        if (
            isinstance(elapsed_s, bool)
            or not isinstance(elapsed_s, (int, float))
            or not math.isfinite(elapsed_s)
        ):
            raise ValueError("elapsed_s must be finite")
        active = 0.0 <= elapsed_s <= self.duration_s
        return {
            "elapsed_s": float(elapsed_s),
            "active": active,
            "visible": active,
            "distance_mm": self.distance_mm_at(elapsed_s),
            "visual_range_from_world_origin_mm": self.visual_range_mm_at(elapsed_s),
            "angular_diameter_rad": self.angular_diameter_rad_at(elapsed_s),
            "angular_expansion_rate_rad_s": self.angular_expansion_rate_rad_s_at(
                elapsed_s
            ),
        }


class LoomingStimulusController:
    """Place the experiment's visual sphere at its deterministic trajectory."""

    def __init__(
        self,
        world: FlyGymWorld,
        stimulus: LoomingStimulus,
        *,
        disable_collisions: bool = True,
    ) -> None:
        self.world = world
        self.stimulus = stimulus
        self._joint_id = mujoco.mj_name2id(
            world.model,
            mujoco.mjtObj.mjOBJ_JOINT,
            world.projectile_joint_name,
        )
        self._geom_id = mujoco.mj_name2id(
            world.model,
            mujoco.mjtObj.mjOBJ_GEOM,
            "gnat_projectile_geom",
        )
        if self._joint_id < 0 or self._geom_id < 0:
            raise ValueError("world is missing its named looming stimulus body")
        self._qpos_address = int(world.model.jnt_qposadr[self._joint_id])
        self._qvel_address = int(world.model.jnt_dofadr[self._joint_id])
        world.model.geom_size[self._geom_id, 0] = stimulus.radius_mm
        level = stimulus.gray_level
        world.model.geom_rgba[self._geom_id] = (level, level, level, 1.0)
        if disable_collisions:
            # The approach is a visual cue. Contact would add a mechanical
            # collision response to the neural/behavioral experiment.
            world.model.geom_contype[self._geom_id] = 0
            world.model.geom_conaffinity[self._geom_id] = 0
        self.apply_elapsed(0.0)

    def apply_elapsed(self, elapsed_s: float) -> dict[str, float | bool]:
        """Update the MuJoCo pose and return the matching analytical state."""

        distance = self.stimulus.distance_mm_at(elapsed_s)
        active = 0.0 <= elapsed_s <= self.stimulus.duration_s
        self.world.model.geom_rgba[self._geom_id, 3] = 1.0 if active else 0.0
        qpos = self.world.data.qpos
        qpos[self._qpos_address : self._qpos_address + 7] = (
            distance,
            self.stimulus.y_mm,
            self.stimulus.z_mm,
            1.0,
            0.0,
            0.0,
            0.0,
        )
        self.world.data.qvel[self._qvel_address : self._qvel_address + 6] = 0.0
        mujoco.mj_forward(self.world.model, self.world.data)
        return self.stimulus.state_at(elapsed_s)
