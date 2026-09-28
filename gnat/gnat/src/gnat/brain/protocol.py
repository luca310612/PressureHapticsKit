"""Process-safe interface for a neural backend."""

from dataclasses import dataclass, field
import math
from typing import Protocol

import numpy as np
from numpy.typing import NDArray


@dataclass(frozen=True, slots=True)
class BrainStepResult:
    """Small result returned by a neural step."""

    duration_ms: float
    total_spikes: int
    readouts: dict[str, int] = field(default_factory=dict)
    motor_output: tuple[float, ...] = ()

    def __post_init__(self) -> None:
        if not math.isfinite(self.duration_ms) or self.duration_ms <= 0:
            raise ValueError("duration_ms must be positive and finite")
        if isinstance(self.total_spikes, bool) or not isinstance(self.total_spikes, (int, np.integer)):
            raise ValueError("total_spikes must be an integer")
        if self.total_spikes < 0:
            raise ValueError("total_spikes must be non-negative")

        normalized: dict[str, int] = {}
        for name, value in self.readouts.items():
            if not isinstance(name, str):
                raise ValueError("readout names must be strings")
            if isinstance(value, bool) or not isinstance(value, (int, np.integer)):
                raise ValueError("readout values must be integers")
            if value < 0:
                raise ValueError("readout values must be non-negative")
            normalized[name] = int(value)
        motor_output = tuple(float(value) for value in self.motor_output)
        if not all(math.isfinite(value) for value in motor_output):
            raise ValueError("motor_output must contain only finite values")
        if any(value < -1.0 or value > 1.0 for value in motor_output):
            raise ValueError("motor_output must be normalized to [-1, 1]")
        object.__setattr__(self, "total_spikes", int(self.total_spikes))
        object.__setattr__(self, "readouts", normalized)
        object.__setattr__(self, "motor_output", motor_output)


class BrainBackend(Protocol):
    """Backend boundary used by the closed-loop runner."""

    def step(
        self,
        retina_luminance: NDArray[np.floating],
        duration_ms: float,
    ) -> BrainStepResult:
        """Advance the selected backend using one retina luminance vector."""
