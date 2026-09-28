"""Closed-loop orchestration without coupling to a specific brain backend."""

from dataclasses import dataclass
from collections.abc import Callable

import numpy as np
from numpy.typing import NDArray

from gnat.brain import BrainBackend, BrainStepResult
from gnat.clock import SimulationClock
from gnat.motor import MotorActuatorController
from gnat.vision import FlyGymVision, RetinaBridge, VisionSample
from gnat.world import FlyGymWorld


@dataclass(frozen=True, slots=True)
class LoopStep:
    """Outputs produced by one physics/neural exchange."""

    simulation_time_s: float
    brain: BrainStepResult
    vision: VisionSample
    retina_input: NDArray[np.float32]

    def __post_init__(self) -> None:
        retina_input = np.asarray(self.retina_input, dtype=np.float32)
        if retina_input.ndim != 1 or not np.all(np.isfinite(retina_input)):
            raise ValueError("retina_input must be a finite one-dimensional array")
        retina_input = np.array(retina_input, dtype=np.float32, copy=True)
        retina_input.setflags(write=False)
        object.__setattr__(self, "retina_input", retina_input)


class ClosedLoopRunner:
    """Advance FlyGym, sample its eyes, and call an injected brain backend."""

    def __init__(
        self,
        world: FlyGymWorld,
        vision: FlyGymVision,
        retina_bridge: RetinaBridge | None,
        brain: BrainBackend,
        *,
        clock: SimulationClock | None = None,
        motor_bridge: MotorActuatorController | None = None,
        input_encoder: Callable[[VisionSample], NDArray[np.floating]] | None = None,
        physics_step_hook: Callable[[], None] | None = None,
        physics_sample_hook: Callable[[], None] | None = None,
    ) -> None:
        self.world = world
        self.vision = vision
        self.retina_bridge = retina_bridge
        self.brain = brain
        self.motor_bridge = motor_bridge
        if retina_bridge is None and input_encoder is None:
            raise ValueError("retina_bridge or input_encoder is required")
        if retina_bridge is not None and input_encoder is not None:
            raise ValueError("retina_bridge and input_encoder are mutually exclusive")
        self.input_encoder = input_encoder
        self.physics_step_hook = physics_step_hook
        self.physics_sample_hook = physics_sample_hook
        self.clock = clock or SimulationClock(
            physics_timestep_s=world.simulation.timestep
        )

    def step(self) -> LoopStep:
        """Advance one synchronized physics/neural interval."""

        physics_steps = self.clock.physics_steps_per_neural_step
        for _ in range(physics_steps):
            if self.physics_step_hook is not None:
                self.physics_step_hook()
            self.world.simulation.step()
        if self.physics_sample_hook is not None:
            self.physics_sample_hook()
        sample = self.vision.sample()
        if self.input_encoder is not None:
            retina_luminance = self.input_encoder(sample)
        else:
            assert self.retina_bridge is not None
            retina_luminance = self.retina_bridge.transform(sample.ommatidia_readouts)
        retina_input = np.array(retina_luminance, dtype=np.float32, copy=True)
        retina_input.setflags(write=False)
        result = self.brain.step(
            retina_input,
            duration_ms=physics_steps * self.clock.physics_timestep_ms,
        )
        if self.motor_bridge is not None:
            if not result.motor_output:
                raise RuntimeError(
                    "brain backend did not provide a continuous motor_output"
                )
            self.motor_bridge.apply(result.motor_output)
        return LoopStep(
            simulation_time_s=sample.simulation_time_s,
            brain=result,
            vision=sample,
            retina_input=retina_input,
        )
