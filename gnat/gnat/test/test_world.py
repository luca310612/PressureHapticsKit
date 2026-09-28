import unittest

import mujoco
import numpy as np

from gnat.world import build_flygym_world
from gnat.world.mujoco_world import DEFAULT_FLY_NAME


class WorldTests(unittest.TestCase):
    def test_fly_root_is_tethered(self) -> None:
        world = build_flygym_world()
        try:
            body_id = mujoco.mj_name2id(
                world.model,
                mujoco.mjtObj.mjOBJ_BODY,
                f"{DEFAULT_FLY_NAME}/c_thorax",
            )
            self.assertGreaterEqual(body_id, 0)
            self.assertGreaterEqual(world.model.body_mocapid[body_id], 0)
            self.assertGreater(world.model.nu, 0)
            ground_id = mujoco.mj_name2id(
                world.model,
                mujoco.mjtObj.mjOBJ_GEOM,
                "ground_plane",
            )
            self.assertGreaterEqual(ground_id, 0)
            self.assertEqual(world.model.geom_contype[ground_id], 1)
            self.assertEqual(world.model.geom_conaffinity[ground_id], 1)
        finally:
            world.simulation.close()

    def test_projectile_launch_pose_is_shared_by_body_and_qpos(self) -> None:
        world = build_flygym_world()
        try:
            joint_id = mujoco.mj_name2id(
                world.model,
                mujoco.mjtObj.mjOBJ_JOINT,
                world.projectile_joint_name,
            )
            qpos_start = world.model.jnt_qposadr[joint_id]
            self.assertEqual(tuple(world.data.qpos[qpos_start : qpos_start + 3]), (22.0, 0.0, 3.0))
            geom_id = mujoco.mj_name2id(
                world.model,
                mujoco.mjtObj.mjOBJ_GEOM,
                "gnat_projectile_geom",
            )
            self.assertEqual(world.model.geom_contype[geom_id], 1)
            self.assertEqual(world.model.geom_conaffinity[geom_id], 1)
        finally:
            world.simulation.close()

    def test_default_world_contains_fixed_visible_corridor_walls(self) -> None:
        world = build_flygym_world()
        try:
            for side in ("left", "right"):
                geom_id = mujoco.mj_name2id(
                    world.model,
                    mujoco.mjtObj.mjOBJ_GEOM,
                    f"gnat_corridor_{side}_wall",
                )
                self.assertGreaterEqual(geom_id, 0)
                self.assertEqual(world.model.geom_contype[geom_id], 0)
                self.assertEqual(world.model.geom_conaffinity[geom_id], 0)
        finally:
            world.simulation.close()

    def test_world_state_stays_finite_during_short_rollout(self) -> None:
        world = build_flygym_world()
        try:
            for _ in range(1000):
                world.simulation.step()
            self.assertTrue(world.data.qpos.dtype.kind == "f")
            self.assertTrue(world.data.qvel.dtype.kind == "f")
            self.assertTrue(bool(np.isfinite(world.data.qpos).all()))
            self.assertTrue(bool(np.isfinite(world.data.qvel).all()))
        finally:
            world.simulation.close()


if __name__ == "__main__":
    unittest.main()
