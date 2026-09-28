"""Timebase shared by the physics, vision, and neural adapters."""

from dataclasses import dataclass
import math


@dataclass(frozen=True, slots=True)
class SimulationClock:
    """Describe the time steps used by FlyGym and MaleCNS."""

    physics_timestep_s: float = 0.0001
    neural_timestep_ms: float = 0.1

    def __post_init__(self) -> None:
        if not math.isfinite(self.physics_timestep_s) or self.physics_timestep_s <= 0:
            raise ValueError("physics_timestep_s must be positive")
        if not math.isfinite(self.neural_timestep_ms) or self.neural_timestep_ms <= 0:
            raise ValueError("neural_timestep_ms must be positive")

    @property
    def physics_steps_per_neural_step(self) -> int:
        """Return the exact fixed-step ratio used by the closed loop.

        A brain update is only meaningful when its declared duration is the
        same simulated interval as the physics steps it observes.  Refusing a
        non-integral ratio is safer than silently drifting the two clocks.
        """

        ratio = self.neural_timestep_ms / self.physics_timestep_ms
        steps = round(ratio)
        if steps < 1 or not math.isclose(ratio, steps, rel_tol=1e-9, abs_tol=1e-12):
            raise ValueError(
                "neural_timestep_ms must be a positive integer multiple of "
                "physics_timestep_ms"
            )
        return steps

    @property
    def physics_timestep_ms(self) -> float:
        """Return the physics step in milliseconds."""

        return self.physics_timestep_s * 1000.0
