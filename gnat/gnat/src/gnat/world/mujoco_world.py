"""Construct the NeuroMechFly world used by the application.

FlyGym's NeuroMechFly model uses millimetre-scale positions.  The named
stimulus constants below therefore use millimetres too; they are not SI metres.
"""

from dataclasses import dataclass
from typing import Final

import mujoco
from flygym.anatomy import (
    AxisOrder,
    JointPreset,
    Skeleton,
)
from flygym.compose import ActuatorType, NeuroMechFly, TetheredWorld
from flygym.simulation import Simulation
from flygym.utils.mjcf import CAMERA_MODES, GEOM_TYPES, add_material, add_texture
from flygym.utils.math import Rotation3D


DEFAULT_FLY_NAME: Final[str] = "nmf"
PROJECTILE_BODY_NAME: Final[str] = "gnat_projectile"
PROJECTILE_JOINT_NAME: Final[str] = "gnat_projectile_joint"
VIEWER_CAMERA_NAME: Final[str] = "gnat_viewer_camera"
PROJECTILE_START_POSITION: Final[tuple[float, float, float]] = (22.0, 0.0, 3.0)
PROJECTILE_START_QPOS: Final[tuple[float, ...]] = (
    *PROJECTILE_START_POSITION,
    1.0,
    0.0,
    0.0,
    0.0,
)


@dataclass(slots=True)
class FlyGymWorld:
    """The compiled FlyGym simulation and its named fly."""

    simulation: Simulation
    fly_name: str = DEFAULT_FLY_NAME
    projectile_joint_name: str = PROJECTILE_JOINT_NAME
    motor_actuator_count: int = 0

    @property
    def model(self):
        """Return the compiled MuJoCo model."""

        return self.simulation.mj_model

    @property
    def data(self):
        """Return the mutable MuJoCo state."""

        return self.simulation.mj_data


def build_flygym_world(
    *,
    fly_name: str = DEFAULT_FLY_NAME,
    timestep_s: float | None = None,
    corridor_half_width_mm: float | None = 12.0,
    corridor_forward_extent_mm: float = 50.0,
) -> FlyGymWorld:
    """Build a NeuroMechFly with joints, vision, and a flat ground world.

    Supplying ``corridor_half_width_mm`` adds two fixed, visible side walls for
    a bounded horizontal-motion experiment. The walls are visual context only;
    their collisions are disabled so they cannot mechanically change the trial.
    """

    if corridor_half_width_mm is not None:
        if corridor_half_width_mm <= 0:
            raise ValueError("corridor_half_width_mm must be positive")
        if corridor_forward_extent_mm <= 0:
            raise ValueError("corridor_forward_extent_mm must be positive")

    fly = NeuroMechFly(name=fly_name)
    fly.add_joints(
        Skeleton(
            joint_preset=JointPreset.ALL_BIOLOGICAL,
            axis_order=AxisOrder.ROLL_PITCH_YAW,
        )
    )
    # Define a real MuJoCo torque boundary for every biological joint. The
    # neural-to-joint calibration is intentionally not guessed here; callers
    # must provide a validated mapping before claiming brain-driven motion.
    fly.add_actuators(
        fly.get_jointdofs_order(),
        ActuatorType.MOTOR,
        forcelimited=True,
        forcerange=(-30.0, 30.0),
    )
    fly.add_vision()

    # Tether the thorax so the fly remains upright while the articulated legs,
    # wings, and eyes remain available to the experiment.  A free root body
    # otherwise tips over under gravity before the viewer becomes useful.
    world = TetheredWorld()
    add_texture(
        world.mjcf_root,
        name="checker",
        type="2d",
        builtin="checker",
        width=300,
        height=300,
        rgb1=(0.3, 0.3, 0.3),
        rgb2=(0.4, 0.4, 0.4),
    )
    add_material(
        world.mjcf_root,
        name="grid",
        texture="checker",
        texrepeat=(80.0, 80.0),
        reflectance=0.2,
    )
    world.mjcf_root.worldbody.add_geom(
        type=GEOM_TYPES["plane"],
        name="ground_plane",
        material="grid",
        pos=(0, 0, 0),
        size=(1000, 1000, 1),
        contype=1,
        conaffinity=1,
    )
    if corridor_half_width_mm is not None:
        wall_half_thickness_mm = 0.3
        wall_height_mm = 16.0
        wall_half_length_mm = corridor_forward_extent_mm / 2.0
        for side, sign in (("right", -1.0), ("left", 1.0)):
            world.mjcf_root.worldbody.add_geom(
                name=f"gnat_corridor_{side}_wall",
                type=GEOM_TYPES["box"],
                pos=(
                    wall_half_length_mm,
                    sign * (corridor_half_width_mm + wall_half_thickness_mm),
                    wall_height_mm / 2.0,
                ),
                size=(
                    wall_half_length_mm,
                    wall_half_thickness_mm,
                    wall_height_mm / 2.0,
                ),
                rgba=(0.55, 0.58, 0.62, 1.0),
                contype=0,
                conaffinity=0,
            )
    world.mjcf_root.worldbody.add_light(
        name="gnat_key_light",
        pos=(0.0, -20.0, 50.0),
        dir=(0.0, 0.0, -1.0),
        type=mujoco.mjtLightType.mjLIGHT_DIRECTIONAL,
        intensity=0.5,
        diffuse=(0.65, 0.68, 0.75),
        ambient=(0.12, 0.14, 0.18),
        specular=(0.12, 0.12, 0.12),
        castshadow=1,
    )
    skybox = world.mjcf_root.texture("skybox")
    skybox.rgb1 = (0.08, 0.11, 0.16)
    skybox.rgb2 = (0.30, 0.36, 0.44)
    world.add_fly(
        fly,
        spawn_position=[0.0, 0.0, 0.2],
        spawn_rotation=Rotation3D("quat", [1.0, 0.0, 0.0, 0.0]),
    )

    # The viewer uses this body as a controllable stimulus.  It is deliberately
    # part of the compiled model so that the button can update its free-joint
    # state without rebuilding the simulation.
    projectile = world.mjcf_root.worldbody.add_body(
        name=PROJECTILE_BODY_NAME,
        pos=PROJECTILE_START_POSITION,
        # Keep the stimulus at its launch point until the user presses the
        # button; the launch velocity still moves it normally.
        gravcomp=1.0,
    )
    projectile.add_freejoint(name=PROJECTILE_JOINT_NAME)
    projectile.add_geom(
        name="gnat_projectile_geom",
        type=GEOM_TYPES["sphere"],
        size=(1.2,),
        rgba=(0.95, 0.18, 0.08, 1.0),
        density=2.0,
    )

    # A fixed camera gives the Tk viewer a stable overview of the fly and the
    # launched object.  The eye cameras remain available through get_raw_vision.
    world.mjcf_root.worldbody.add_camera(
        name=VIEWER_CAMERA_NAME,
        pos=(38.0, -55.0, 42.0),
        mode=CAMERA_MODES["targetbody"],
        targetbody=f"{fly_name}/c_thorax",
        fovy=50.0,
    )
    simulation = Simulation(world, timestep=timestep_s)
    flygym_world = FlyGymWorld(
        simulation=simulation,
        fly_name=fly_name,
        motor_actuator_count=simulation.mj_model.nu,
    )

    # The world neutral keyframe is assembled when the fly is attached, before
    # this viewer-only body is added.  Seed the projectile explicitly so checkers
    # and non-GUI callers see the documented launch pose as well.
    projectile_joint_id = mujoco.mj_name2id(
        simulation.mj_model,
        mujoco.mjtObj.mjOBJ_JOINT,
        PROJECTILE_JOINT_NAME,
    )
    qpos_start = simulation.mj_model.jnt_qposadr[projectile_joint_id]
    simulation.mj_data.qpos[qpos_start : qpos_start + 7] = PROJECTILE_START_QPOS
    mujoco.mj_forward(simulation.mj_model, simulation.mj_data)
    return flygym_world
