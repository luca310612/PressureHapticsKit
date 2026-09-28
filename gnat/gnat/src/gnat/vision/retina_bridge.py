"""Explicit FlyGym-to-doomfly retina mapping.

The mapping is data, not a guessed geometric projection. A mapping file must
be supplied once the MaleCNS retinal correspondence has been calibrated.
"""

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numpy.typing import NDArray


class RetinaMappingError(ValueError):
    """Raised when a retina mapping is missing or malformed."""


@dataclass(frozen=True, slots=True)
class RetinaMapping:
    """Sparse mapping from FlyGym eye/channel samples to target neurons."""

    source_eye: NDArray[np.int64]
    source_ommatidium: NDArray[np.int64]
    source_channel: NDArray[np.int64]
    target_index: NDArray[np.int64]
    weight: NDArray[np.float32]
    target_size: int = 3335

    def __post_init__(self) -> None:
        integer_names = (
            "source_eye",
            "source_ommatidium",
            "source_channel",
            "target_index",
        )
        for name in integer_names:
            array = np.asarray(getattr(self, name))
            if array.ndim != 1 or not np.issubdtype(array.dtype, np.integer):
                raise RetinaMappingError(f"{name} must be a one-dimensional integer array")
        weight = np.asarray(self.weight)
        if weight.ndim != 1 or not np.issubdtype(weight.dtype, np.floating):
            raise RetinaMappingError("weight must be a one-dimensional float array")

        # Frozen dataclasses do not freeze NumPy buffers.  Copy the mapping so
        # calibration arrays cannot mutate a live simulation after construction.
        object.__setattr__(
            self, "source_eye", np.array(self.source_eye, dtype=np.int64, copy=True)
        )
        object.__setattr__(
            self,
            "source_ommatidium",
            np.array(self.source_ommatidium, dtype=np.int64, copy=True),
        )
        object.__setattr__(
            self,
            "source_channel",
            np.array(self.source_channel, dtype=np.int64, copy=True),
        )
        object.__setattr__(
            self,
            "target_index",
            np.array(self.target_index, dtype=np.int64, copy=True),
        )
        object.__setattr__(
            self, "weight", np.array(self.weight, dtype=np.float32, copy=True)
        )
        arrays = (
            self.source_eye,
            self.source_ommatidium,
            self.source_channel,
            self.target_index,
            self.weight,
        )
        if len({array.size for array in arrays}) != 1:
            raise RetinaMappingError("all mapping arrays must have the same length")
        if isinstance(self.target_size, bool) or not isinstance(self.target_size, (int, np.integer)):
            raise RetinaMappingError("target_size must be an integer")
        if self.target_size <= 0:
            raise RetinaMappingError("target_size must be positive")
        if np.any(self.source_eye < 0) or np.any(self.source_eye >= 2):
            raise RetinaMappingError("source_eye must contain only 0 or 1")
        if np.any(self.source_ommatidium < 0):
            raise RetinaMappingError("source_ommatidium must be non-negative")
        if np.any(self.source_channel < 0) or np.any(self.source_channel >= 2):
            raise RetinaMappingError("source_channel must contain only 0 or 1")
        if np.any(self.target_index < 0) or np.any(self.target_index >= self.target_size):
            raise RetinaMappingError("target_index is outside target_size")
        if not np.all(np.isfinite(self.weight)):
            raise RetinaMappingError("weight must contain only finite values")

    @classmethod
    def from_npz(cls, path: str | Path) -> "RetinaMapping":
        """Load a mapping created by the calibration workflow."""

        with np.load(path) as data:
            required = {
                "source_eye",
                "source_ommatidium",
                "source_channel",
                "target_index",
                "weight",
            }
            missing = required.difference(data.files)
            if missing:
                raise RetinaMappingError(
                    f"mapping file is missing arrays: {', '.join(sorted(missing))}"
                )
            if "target_size" in data:
                raw_target_size = np.asarray(data["target_size"])
                if raw_target_size.ndim != 0 or not np.issubdtype(
                    raw_target_size.dtype, np.integer
                ):
                    raise RetinaMappingError(
                        "target_size must be a scalar integer in the mapping file"
                    )
                target_size = int(raw_target_size)
            else:
                target_size = 3335
            return cls(
                source_eye=np.asarray(data["source_eye"]),
                source_ommatidium=np.asarray(data["source_ommatidium"]),
                source_channel=np.asarray(data["source_channel"]),
                target_index=np.asarray(data["target_index"]),
                weight=np.asarray(data["weight"]),
                target_size=target_size,
            )


class RetinaBridge:
    """Convert calibrated FlyGym readouts into a doomfly input vector."""

    def __init__(self, mapping: RetinaMapping) -> None:
        self.mapping = mapping

    def transform(self, ommatidia_readouts: NDArray[np.floating]) -> NDArray[np.float32]:
        """Apply the explicit sparse mapping to ``(2, n_ommatidia, 2)`` data."""

        readouts = np.asarray(ommatidia_readouts, dtype=np.float32)
        if readouts.ndim != 3 or readouts.shape[0] != 2 or readouts.shape[2] != 2:
            raise RetinaMappingError(
                "FlyGym readouts must have shape (2, n_ommatidia, 2)"
            )
        if not np.all(np.isfinite(readouts)):
            raise RetinaMappingError("FlyGym readouts must contain only finite values")
        if np.any(readouts < 0.0) or np.any(readouts > 1.0):
            raise RetinaMappingError("FlyGym readouts must be normalized to [0, 1]")
        if np.any(self.mapping.source_ommatidium >= readouts.shape[1]):
            raise RetinaMappingError("mapping references a missing ommatidium")

        values = np.zeros(self.mapping.target_size, dtype=np.float32)
        samples = readouts[
            self.mapping.source_eye,
            self.mapping.source_ommatidium,
            self.mapping.source_channel,
        ]
        np.add.at(values, self.mapping.target_index, samples * self.mapping.weight)
        return np.clip(values, 0.0, 1.0)
