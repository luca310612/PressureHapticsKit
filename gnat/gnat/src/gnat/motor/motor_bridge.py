"""Translate calibrated neural readouts into FlyGym actuator inputs."""

from dataclasses import dataclass
import math
from pathlib import Path
from typing import Mapping, Protocol

import numpy as np
from numpy.typing import NDArray

from gnat.world import FlyGymWorld


class MotorMappingError(ValueError):
    """Raised when a neural-to-actuator calibration is missing or malformed."""


class MotorActuatorController(Protocol):
    """Minimal runner-facing contract for a calibrated actuator adapter."""

    def apply(self, motor_readouts: NDArray[np.floating]) -> NDArray[np.float32]:
        """Apply normalized motor values and return normalized controls."""


@dataclass(frozen=True, slots=True)
class MotorMapping:
    """Explicit sparse mapping from neural motor channels to MuJoCo actuators.

    The mapping is deliberately data-driven.  No anatomical correspondence is
    inferred from array position or from a random NumPy circuit.
    """

    source_neuron: NDArray[np.int64]
    actuator_index: NDArray[np.int64]
    weight: NDArray[np.float32]
    source_size: int
    actuator_size: int

    def __post_init__(self) -> None:
        source_neuron = np.asarray(self.source_neuron)
        actuator_index = np.asarray(self.actuator_index)
        weight = np.asarray(self.weight)
        if source_neuron.ndim != 1 or not np.issubdtype(
            source_neuron.dtype, np.integer
        ):
            raise MotorMappingError("source_neuron must be a one-dimensional integer array")
        if actuator_index.ndim != 1 or not np.issubdtype(
            actuator_index.dtype, np.integer
        ):
            raise MotorMappingError("actuator_index must be a one-dimensional integer array")
        if weight.ndim != 1 or not np.issubdtype(weight.dtype, np.floating):
            raise MotorMappingError("weight must be a one-dimensional float array")
        if len({source_neuron.size, actuator_index.size, weight.size}) != 1:
            raise MotorMappingError("all motor mapping arrays must have the same length")
        if isinstance(self.source_size, bool) or not isinstance(
            self.source_size, (int, np.integer)
        ) or self.source_size <= 0:
            raise MotorMappingError("source_size must be a positive integer")
        if isinstance(self.actuator_size, bool) or not isinstance(
            self.actuator_size, (int, np.integer)
        ) or self.actuator_size <= 0:
            raise MotorMappingError("actuator_size must be a positive integer")
        if not np.all(np.isfinite(weight)):
            raise MotorMappingError("weight must contain only finite values")
        if np.any(source_neuron < 0) or np.any(source_neuron >= self.source_size):
            raise MotorMappingError("source_neuron is outside source_size")
        if np.any(actuator_index < 0) or np.any(actuator_index >= self.actuator_size):
            raise MotorMappingError("actuator_index is outside actuator_size")

        object.__setattr__(
            self, "source_neuron", np.array(source_neuron, dtype=np.int64, copy=True)
        )
        object.__setattr__(
            self, "actuator_index", np.array(actuator_index, dtype=np.int64, copy=True)
        )
        object.__setattr__(self, "weight", np.array(weight, dtype=np.float32, copy=True))

    @classmethod
    def from_npz(cls, path: str | Path) -> "MotorMapping":
        """Load a mapping exported by the motor calibration workflow."""

        with np.load(path) as data:
            required = {"source_neuron", "actuator_index", "weight", "source_size", "actuator_size"}
            missing = required.difference(data.files)
            if missing:
                raise MotorMappingError(
                    f"motor mapping file is missing arrays: {', '.join(sorted(missing))}"
                )
            sizes: dict[str, int] = {}
            for name in ("source_size", "actuator_size"):
                raw = np.asarray(data[name])
                if raw.ndim != 0 or not np.issubdtype(raw.dtype, np.integer):
                    raise MotorMappingError(f"{name} must be a scalar integer in the mapping file")
                sizes[name] = int(raw)
            return cls(
                source_neuron=np.asarray(data["source_neuron"]),
                actuator_index=np.asarray(data["actuator_index"]),
                weight=np.asarray(data["weight"]),
                source_size=sizes["source_size"],
                actuator_size=sizes["actuator_size"],
            )

    def transform(self, motor_readouts: NDArray[np.floating]) -> NDArray[np.float32]:
        """Return normalized actuator commands in ``[-1, 1]``."""

        readouts = np.asarray(motor_readouts, dtype=np.float32)
        if readouts.shape != (self.source_size,):
            raise MotorMappingError(
                f"motor_readouts must have shape ({self.source_size},)"
            )
        if not np.all(np.isfinite(readouts)):
            raise MotorMappingError("motor_readouts must contain only finite values")
        if np.any(readouts < -1.0) or np.any(readouts > 1.0):
            raise MotorMappingError("motor_readouts must be normalized to [-1, 1]")
        controls = np.zeros(self.actuator_size, dtype=np.float32)
        np.add.at(
            controls,
            self.actuator_index,
            readouts[self.source_neuron] * self.weight,
        )
        return np.clip(controls, -1.0, 1.0)


class MotorActuatorBridge:
    """Apply a validated mapping to a compiled FlyGym world."""

    def __init__(self, world: FlyGymWorld, mapping: MotorMapping, *, force_limit: float = 30.0) -> None:
        if mapping.actuator_size != world.model.nu:
            raise MotorMappingError(
                "motor mapping actuator_size does not match the compiled world"
            )
        if not math.isfinite(force_limit) or force_limit <= 0:
            raise MotorMappingError("force_limit must be positive and finite")
        self.world = world
        self.mapping = mapping
        self.force_limit = float(force_limit)

    @property
    def status(self) -> str:
        """Return a machine-readable connected state."""

        return "connected"

    def apply(self, motor_readouts: NDArray[np.floating]) -> NDArray[np.float32]:
        """Write mapped torque controls and return the normalized controls."""

        normalized = self.mapping.transform(motor_readouts)
        self.world.data.ctrl[:] = normalized * self.force_limit
        return normalized


@dataclass(frozen=True, slots=True)
class MotorCommand:
    """Named control intent; actuator wiring is intentionally separate."""

    forward: float = 0.0
    turn: float = 0.0
    brake: float = 0.0

    def __post_init__(self) -> None:
        values = (self.forward, self.turn, self.brake)
        if any(isinstance(value, bool) for value in values):
            raise ValueError("motor command values must be numeric, not bool")
        if not all(math.isfinite(value) for value in values):
            raise ValueError("motor command values must be finite")
        if any(abs(value) > 1.0 for value in values):
            raise ValueError("motor command values must be normalized to [-1, 1]")


class MotorBridge(Protocol):
    """Boundary for applying decoded neural commands to FlyGym."""

    def decode(self, readouts: Mapping[str, int]) -> MotorCommand:
        """Decode selected neuron readouts."""
