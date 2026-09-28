"""Read visual signals from a FlyGym simulation."""

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from gnat.world.mujoco_world import FlyGymWorld


FloatArray = NDArray[np.float32]
UInt8Array = NDArray[np.uint8]


@dataclass(frozen=True, slots=True)
class VisionSample:
    """One synchronized pair of FlyGym eye outputs."""

    simulation_time_s: float
    ommatidia_readouts: FloatArray
    raw_rgb: UInt8Array | None = None

    def __post_init__(self) -> None:
        if not np.isfinite(self.simulation_time_s) or self.simulation_time_s < 0:
            raise ValueError("simulation_time_s must be finite and non-negative")
        readout_values = np.asarray(self.ommatidia_readouts)
        if not np.all(np.isfinite(readout_values)):
            raise ValueError("ommatidia_readouts must contain only finite values")
        if np.any(readout_values < 0.0) or np.any(readout_values > 1.0):
            raise ValueError("ommatidia_readouts must be normalized to [0, 1]")
        readouts = np.array(readout_values, dtype=np.float32, copy=True)
        readouts.setflags(write=False)
        object.__setattr__(self, "ommatidia_readouts", readouts)
        if self.raw_rgb is not None:
            raw_values = np.asarray(self.raw_rgb)
            if raw_values.ndim != 4 or raw_values.shape[0] != 2 or raw_values.shape[3] != 3:
                raise ValueError("raw_rgb must have shape (2, height, width, 3)")
            if not np.all(np.isfinite(raw_values)):
                raise ValueError("raw_rgb must contain only finite values")
            if np.any(raw_values < 0) or np.any(raw_values > 255):
                raise ValueError("raw_rgb must use values in [0, 255]")
            raw_rgb = np.array(raw_values, dtype=np.uint8, copy=True)
            raw_rgb.setflags(write=False)
            object.__setattr__(self, "raw_rgb", raw_rgb)


class FlyGymVision:
    """Sample FlyGym's documented ommatidia and optional raw eye images."""

    def __init__(self, world: FlyGymWorld, *, include_raw: bool = False) -> None:
        self._world = world
        self._include_raw = include_raw

    @property
    def num_ommatidia(self) -> int:
        """Return the number of ommatidia in one eye."""

        retina = self._world.simulation.retina
        if retina is None:
            raise RuntimeError(
                "FlyGym retina is not initialized; call sample() before "
                "reading num_ommatidia"
            )
        return retina.num_ommatidia_per_eye

    def sample(self, *, include_raw: bool | None = None) -> VisionSample:
        """Read both eyes at the simulation's current time."""

        simulation = self._world.simulation
        raw_rgb: UInt8Array | None = None
        want_raw = self._include_raw if include_raw is None else include_raw
        if want_raw:
            raw_vision = simulation.get_raw_vision(self._world.fly_name)
            raw_array = np.asarray(raw_vision)
            if not np.all(np.isfinite(raw_array)):
                raise ValueError("raw eye frames must contain only finite values")
            if np.any(raw_array < 0) or np.any(raw_array > 255):
                raise ValueError("raw eye frames must use values in [0, 255]")
            raw_rgb = np.array(raw_array, dtype=np.uint8, copy=True)
            retina = simulation.retina
            if retina is None:
                raise RuntimeError("FlyGym did not initialize its retina")
            readouts = np.asarray(
                [retina.raw_image_to_hex_pxls(image) for image in raw_vision],
                dtype=np.float32,
            )
        else:
            readouts = np.asarray(
                simulation.get_ommatidia_readouts(self._world.fly_name),
                dtype=np.float32,
            )
        expected_shape = (2, self.num_ommatidia, 2)
        if readouts.shape != expected_shape:
            raise ValueError(
                "unexpected FlyGym ommatidia shape: "
                f"expected {expected_shape}, got {readouts.shape}"
            )
        if not np.all(np.isfinite(readouts)):
            raise ValueError("ommatidia readouts must contain only finite values")
        if np.any(readouts < 0.0) or np.any(readouts > 1.0):
            raise ValueError("ommatidia readouts must be normalized to [0, 1]")

        return VisionSample(
            simulation_time_s=float(simulation.time),
            ommatidia_readouts=readouts,
            raw_rgb=raw_rgb,
        )
