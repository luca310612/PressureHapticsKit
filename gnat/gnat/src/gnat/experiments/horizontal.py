"""Fixed-distance horizontal object motion for reaction-time trials."""

from __future__ import annotations

from dataclasses import dataclass
import math

import mujoco

from gnat.world import FlyGymWorld


@dataclass(frozen=True, slots=True)
class HorizontalObjectStimulus:
    """Move a visual sphere left-to-right along a fixed-radius arc.

    The fly faces positive X. Azimuth is measured around the world Z axis, so
    positive angles place the object on the fly's left and negative angles on
    its right. Keeping the horizontal radius fixed holds the object's nominal
    viewing distance and angular size approximately constant while it crosses
    the visual field.
    """

    radius_from_origin_mm: float = 22.0
    start_azimuth_deg: float = 20.0
    end_azimuth_deg: float = -20.0
    duration_s: float = 0.4
    object_radius_mm: float = 1.2
    z_mm: float = 3.0
    corridor_half_width_mm: float = 12.0
    gray_level: float = 0.05

    def __post_init__(self) -> None:
        values = (
            self.radius_from_origin_mm,
            self.start_azimuth_deg,
            self.end_azimuth_deg,
            self.duration_s,
            self.object_radius_mm,
            self.z_mm,
            self.corridor_half_width_mm,
            self.gray_level,
        )
        if any(
            isinstance(value, bool) or not isinstance(value, (int, float))
            for value in values
        ):
            raise ValueError("horizontal stimulus parameters must be numeric, not bool")
        if not all(math.isfinite(value) for value in values):
            raise ValueError("horizontal stimulus parameters must be finite")
        if self.radius_from_origin_mm <= 0 or self.object_radius_mm <= 0:
            raise ValueError("stimulus distances and object radius must be positive")
        if self.duration_s <= 0:
            raise ValueError("duration_s must be positive")
        if (
            not -75.0 <= self.start_azimuth_deg <= 75.0
            or not -75.0 <= self.end_azimuth_deg <= 75.0
            or self.start_azimuth_deg == self.end_azimuth_deg
        ):
            raise ValueError("azimuths must be distinct and remain within +/-75 degrees")
        if self.corridor_half_width_mm <= 0:
            raise ValueError("corridor_half_width_mm must be positive")
        max_lateral_extent = self.radius_from_origin_mm * max(
            abs(math.sin(math.radians(self.start_azimuth_deg))),
            abs(math.sin(math.radians(self.end_azimuth_deg))),
        ) + self.object_radius_mm
        if max_lateral_extent >= self.corridor_half_width_mm:
            raise ValueError("the object path must fit inside the fixed corridor walls")
        if not 0.0 <= self.gray_level <= 1.0:
            raise ValueError("gray_level must be in [0, 1]")

    @property
    def start_azimuth_rad(self) -> float:
        return math.radians(self.start_azimuth_deg)

    @property
    def end_azimuth_rad(self) -> float:
        return math.radians(self.end_azimuth_deg)

    @property
    def angular_velocity_rad_s(self) -> float:
        """Return the constant azimuth velocity during the sweep."""

        return (self.end_azimuth_rad - self.start_azimuth_rad) / self.duration_s

    def azimuth_rad_at(self, elapsed_s: float) -> float:
        """Return the clamped object azimuth at a stimulus-relative time."""

        if (
            isinstance(elapsed_s, bool)
            or not isinstance(elapsed_s, (int, float))
            or not math.isfinite(elapsed_s)
        ):
            raise ValueError("elapsed_s must be finite")
        fraction = min(1.0, max(0.0, elapsed_s / self.duration_s))
        return self.start_azimuth_rad + fraction * (
            self.end_azimuth_rad - self.start_azimuth_rad
        )

    def position_mm_at(self, elapsed_s: float) -> tuple[float, float, float]:
        """Return the object's fixed-radius world position."""

        azimuth = self.azimuth_rad_at(elapsed_s)
        return (
            self.radius_from_origin_mm * math.cos(azimuth),
            self.radius_from_origin_mm * math.sin(azimuth),
            self.z_mm,
        )

    def state_at(self, elapsed_s: float) -> dict[str, float | bool]:
        """Return the stimulus state for a synchronized experiment trace."""

        if (
            isinstance(elapsed_s, bool)
            or not isinstance(elapsed_s, (int, float))
            or not math.isfinite(elapsed_s)
        ):
            raise ValueError("elapsed_s must be finite")
        active = 0.0 <= elapsed_s <= self.duration_s
        azimuth = self.azimuth_rad_at(elapsed_s)
        x_mm, y_mm, _ = self.position_mm_at(elapsed_s)
        visual_range = math.hypot(self.radius_from_origin_mm, self.z_mm)
        return {
            "elapsed_s": float(elapsed_s),
            "active": active,
            "visible": active,
            "x_mm": x_mm,
            "y_mm": y_mm,
            "azimuth_rad": azimuth,
            "azimuth_deg": math.degrees(azimuth),
            "visual_range_from_world_origin_mm": visual_range,
            "angular_diameter_rad": 2.0
            * math.atan2(self.object_radius_mm, visual_range),
            "angular_velocity_rad_s": (
                self.angular_velocity_rad_s if active else 0.0
            ),
        }


class HorizontalObjectStimulusController:
    """Place the experiment sphere on its fixed-radius horizontal trajectory."""

    def __init__(
        self,
        world: FlyGymWorld,
        stimulus: HorizontalObjectStimulus,
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
            raise ValueError("world is missing its named horizontal stimulus body")
        self._qpos_address = int(world.model.jnt_qposadr[self._joint_id])
        self._qvel_address = int(world.model.jnt_dofadr[self._joint_id])
        world.model.geom_size[self._geom_id, 0] = stimulus.object_radius_mm
        level = stimulus.gray_level
        world.model.geom_rgba[self._geom_id] = (level, level, level, 1.0)
        if disable_collisions:
            world.model.geom_contype[self._geom_id] = 0
            world.model.geom_conaffinity[self._geom_id] = 0
        self.apply_elapsed(0.0)

    def apply_elapsed(self, elapsed_s: float) -> dict[str, float | bool]:
        """Update the MuJoCo pose and return the matching analytical state."""

        x_mm, y_mm, z_mm = self.stimulus.position_mm_at(elapsed_s)
        active = 0.0 <= elapsed_s <= self.stimulus.duration_s
        self.world.model.geom_rgba[self._geom_id, 3] = 1.0 if active else 0.0
        qpos = self.world.data.qpos
        qpos[self._qpos_address : self._qpos_address + 7] = (
            x_mm,
            y_mm,
            z_mm,
            1.0,
            0.0,
            0.0,
            0.0,
        )
        self.world.data.qvel[self._qvel_address : self._qvel_address + 6] = 0.0
        mujoco.mj_forward(self.world.model, self.world.data)
        return self.stimulus.state_at(elapsed_s)
