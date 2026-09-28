import unittest
from types import SimpleNamespace

import numpy as np

from gnat.motor import MotorActuatorBridge, MotorMapping, MotorMappingError


class MotorTests(unittest.TestCase):
    def _mapping(self) -> MotorMapping:
        return MotorMapping(
            source_neuron=np.array([0, 1, 1], dtype=np.int64),
            actuator_index=np.array([0, 1, 0], dtype=np.int64),
            weight=np.array([1.0, 0.5, -0.25], dtype=np.float32),
            source_size=2,
            actuator_size=2,
        )

    def test_mapping_is_explicit_and_normalized(self) -> None:
        controls = self._mapping().transform(np.array([1.0, 0.5], dtype=np.float32))
        np.testing.assert_allclose(controls, [0.875, 0.25])

    def test_mapping_rejects_wrong_readout_width(self) -> None:
        with self.assertRaises(MotorMappingError):
            self._mapping().transform(np.zeros(3, dtype=np.float32))

    def test_actuator_bridge_writes_scaled_controls(self) -> None:
        world = SimpleNamespace(
            model=SimpleNamespace(nu=2),
            data=SimpleNamespace(ctrl=np.zeros(2, dtype=np.float32)),
        )
        bridge = MotorActuatorBridge(world, self._mapping(), force_limit=30.0)

        bridge.apply(np.array([1.0, 0.5], dtype=np.float32))

        np.testing.assert_allclose(world.data.ctrl, [26.25, 7.5])
        self.assertEqual(bridge.status, "connected")

    def test_bridge_rejects_unmatched_compiled_world(self) -> None:
        world = SimpleNamespace(
            model=SimpleNamespace(nu=3),
            data=SimpleNamespace(ctrl=np.zeros(3, dtype=np.float32)),
        )
        with self.assertRaises(MotorMappingError):
            MotorActuatorBridge(world, self._mapping())


if __name__ == "__main__":
    unittest.main()
