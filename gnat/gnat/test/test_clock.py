import unittest

from gnat.clock import SimulationClock


class ClockTests(unittest.TestCase):
    def test_integral_physics_to_neural_ratio(self) -> None:
        clock = SimulationClock(physics_timestep_s=0.0001, neural_timestep_ms=0.2)
        self.assertEqual(clock.physics_steps_per_neural_step, 2)

    def test_rejects_non_integral_ratio(self) -> None:
        clock = SimulationClock(physics_timestep_s=0.0001, neural_timestep_ms=0.15)
        with self.assertRaises(ValueError):
            _ = clock.physics_steps_per_neural_step

    def test_rejects_non_finite_values(self) -> None:
        with self.assertRaises(ValueError):
            SimulationClock(physics_timestep_s=float("nan"))
        with self.assertRaises(ValueError):
            SimulationClock(neural_timestep_ms=float("inf"))


if __name__ == "__main__":
    unittest.main()
