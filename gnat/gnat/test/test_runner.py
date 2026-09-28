import unittest

import numpy as np

from gnat.brain import BrainStepResult
from gnat.clock import SimulationClock
from gnat.runner import ClosedLoopRunner
from gnat.vision import VisionSample


class _FakeSimulation:
    timestep = 0.0001

    def __init__(self) -> None:
        self.steps = 0
        self.time = 0.0

    def step(self) -> None:
        self.steps += 1
        self.time += self.timestep


class _FakeWorld:
    def __init__(self) -> None:
        self.simulation = _FakeSimulation()


class _FakeVision:
    def sample(self) -> VisionSample:
        return VisionSample(0.0002, np.zeros((2, 1, 2), dtype=np.float32))


class _FakeBridge:
    def transform(self, readouts: np.ndarray) -> np.ndarray:
        del readouts
        return np.zeros(32, dtype=np.float32)


class _FakeBrain:
    def __init__(self) -> None:
        self.duration_ms = None

    def step(self, retina_luminance: np.ndarray, duration_ms: float) -> BrainStepResult:
        self.assert_input(retina_luminance)
        self.duration_ms = duration_ms
        return BrainStepResult(
            duration_ms=duration_ms,
            total_spikes=0,
            motor_output=(0.1, -0.2),
        )

    @staticmethod
    def assert_input(retina_luminance: np.ndarray) -> None:
        if retina_luminance.shape != (32,):
            raise AssertionError("runner passed the wrong retina width")


class RunnerTests(unittest.TestCase):
    def test_runner_keeps_physics_and_neural_clocks_synchronized(self) -> None:
        world = _FakeWorld()
        brain = _FakeBrain()
        runner = ClosedLoopRunner(
            world,
            _FakeVision(),
            _FakeBridge(),
            brain,
            clock=SimulationClock(physics_timestep_s=0.0001, neural_timestep_ms=0.2),
        )

        result = runner.step()

        self.assertEqual(world.simulation.steps, 2)
        self.assertEqual(result.brain.duration_ms, 0.2)
        self.assertEqual(brain.duration_ms, 0.2)
        self.assertEqual(result.vision.simulation_time_s, 0.0002)

    def test_runner_applies_continuous_motor_output_when_bridge_is_present(self) -> None:
        class _FakeMotorBridge:
            def __init__(self) -> None:
                self.received = None

            def apply(self, motor_output: tuple[float, ...]) -> None:
                self.received = motor_output

        motor_bridge = _FakeMotorBridge()
        runner = ClosedLoopRunner(
            _FakeWorld(),
            _FakeVision(),
            _FakeBridge(),
            _FakeBrain(),
            clock=SimulationClock(physics_timestep_s=0.0001, neural_timestep_ms=0.2),
            motor_bridge=motor_bridge,
        )

        runner.step()

        self.assertEqual(motor_bridge.received, (0.1, -0.2))

    def test_runner_calls_sample_hook_after_physics(self) -> None:
        calls = []

        runner = ClosedLoopRunner(
            _FakeWorld(),
            _FakeVision(),
            _FakeBridge(),
            _FakeBrain(),
            clock=SimulationClock(physics_timestep_s=0.0001, neural_timestep_ms=0.2),
            physics_step_hook=lambda: calls.append("step"),
            physics_sample_hook=lambda: calls.append("sample"),
        )

        runner.step()

        self.assertEqual(calls, ["step", "step", "sample"])


if __name__ == "__main__":
    unittest.main()
