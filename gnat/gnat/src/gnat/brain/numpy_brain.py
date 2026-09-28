"""Small NumPy neural circuit used by the interactive viewer.

This is a deterministic rate-and-spike approximation for visualization.  It is
not a claim that these dimensions or weights reproduce MaleCNS biology; the
module provides a real numerical path from eye pixels to motor activity until a
calibrated MaleCNS backend is connected.
"""

from dataclasses import dataclass
import math

import numpy as np
from numpy.typing import NDArray

from gnat.brain.protocol import BrainStepResult


FloatArray = NDArray[np.float32]


@dataclass(frozen=True, slots=True)
class BrainSnapshot:
    """Numerical state exposed to the browser visualizer."""

    retina: FloatArray
    optic_lobe: FloatArray
    central_complex: FloatArray
    motor: FloatArray
    transmission: FloatArray
    latency_ms: FloatArray
    time_ms: float
    total_spikes: int

    def as_payload(self) -> dict[str, object]:
        """Return JSON-friendly state without exposing mutable NumPy arrays."""

        return {
            "retina": self.retina.round(3).tolist(),
            "optic_lobe": self.optic_lobe.round(3).tolist(),
            "central_complex": self.central_complex.round(3).tolist(),
            "motor": self.motor.round(3).tolist(),
            "transmission": self.transmission.round(3).tolist(),
            "latency_ms": self.latency_ms.round(2).tolist(),
            "time_ms": round(self.time_ms, 2),
            "total_spikes": self.total_spikes,
        }


class NumpyFlyBrain:
    """Deterministic retina-to-motor circuit for the web viewer.

    The circuit has a compact 32-channel retina, a 48-neuron optic lobe, a
    recurrent 24-neuron central complex, and eight motor readouts.  Leaky
    updates make activity persist briefly between frames, while the motion term
    makes a moving stimulus visible in the brain display.
    """

    RETINA_CHANNELS = 32
    OPTIC_LOBE_NEURONS = 48
    CENTRAL_NEURONS = 24
    MOTOR_NEURONS = 8
    SPIKE_THRESHOLDS = (0.72, 0.72, 0.55)

    def __init__(self, *, seed: int = 7) -> None:
        rng = np.random.default_rng(seed)
        self._optic_weights = self._weights(
            rng, self.OPTIC_LOBE_NEURONS, self.RETINA_CHANNELS, 0.8
        )
        self._optic_recurrent = self._weights(
            rng, self.OPTIC_LOBE_NEURONS, self.OPTIC_LOBE_NEURONS, 0.32
        )
        self._central_weights = self._weights(
            rng, self.CENTRAL_NEURONS, self.OPTIC_LOBE_NEURONS, 0.65
        )
        self._central_recurrent = self._weights(
            rng, self.CENTRAL_NEURONS, self.CENTRAL_NEURONS, 0.28
        )
        self._motor_weights = self._weights(
            rng, self.MOTOR_NEURONS, self.CENTRAL_NEURONS, 0.75
        )
        self._optic = np.zeros(self.OPTIC_LOBE_NEURONS, dtype=np.float32)
        self._central = np.zeros(self.CENTRAL_NEURONS, dtype=np.float32)
        self._motor = np.zeros(self.MOTOR_NEURONS, dtype=np.float32)
        self._previous_retina = np.zeros(self.RETINA_CHANNELS, dtype=np.float32)
        self._time_ms = 0.0
        self._snapshot = self._make_snapshot(
            np.zeros(self.RETINA_CHANNELS, dtype=np.float32), 0
        )

    @property
    def input_size(self) -> int:
        """Return the exact input width accepted by this backend."""

        return self.RETINA_CHANNELS

    @staticmethod
    def _weights(
        rng: np.random.Generator, rows: int, columns: int, scale: float
    ) -> FloatArray:
        return rng.normal(0.0, scale / math.sqrt(columns), (rows, columns)).astype(
            np.float32
        )

    @staticmethod
    def encode_eye_frames(eye_frames: NDArray[np.floating]) -> FloatArray:
        """Reduce two RGB eye frames into 16 luminance channels per eye.

        The conversion is deliberately labelled as a demo encoder.  It uses a
        visible-spectrum luminance approximation and validates the image
        contract instead of silently converting malformed buffers.
        """

        frames = np.asarray(eye_frames, dtype=np.float32)
        if frames.ndim != 4 or frames.shape[0] != 2 or frames.shape[3] != 3:
            raise ValueError("eye_frames must have shape (2, height, width, 3)")
        if min(frames.shape[1:3]) < 4:
            raise ValueError("eye frames must be at least 4x4 pixels")
        if not np.all(np.isfinite(frames)):
            raise ValueError("eye frames must contain only finite values")
        if np.any(frames < 0.0) or np.any(frames > 255.0):
            raise ValueError("eye frames must use uint8-like values in [0, 255]")

        rgb_luminance = np.asarray((0.2126, 0.7152, 0.0722), dtype=np.float32)
        luminance = np.tensordot(frames, rgb_luminance, axes=([3], [0])) / 255.0
        features: list[float] = []
        row_edges = np.linspace(0, luminance.shape[1], 5, dtype=int)
        col_edges = np.linspace(0, luminance.shape[2], 5, dtype=int)
        for eye in luminance:
            for row in range(4):
                for col in range(4):
                    tile = eye[
                        row_edges[row] : row_edges[row + 1],
                        col_edges[col] : col_edges[col + 1],
                    ]
                    features.append(float(np.mean(tile)))
        return np.clip(np.asarray(features, dtype=np.float32), 0.0, 1.0)

    @staticmethod
    def encode_ommatidia_readouts(
        ommatidia_readouts: NDArray[np.floating],
    ) -> FloatArray:
        """Reduce FlyGym's two-eye ommatidia into the demo input width.

        The live neural input comes from the simulator's ommatidia readouts,
        not from the display JPEG.  This keeps the brain clock independent of
        the optional eye preview and avoids treating a rendered screenshot as
        a biological photoreceptor signal.
        """

        readouts = np.asarray(ommatidia_readouts, dtype=np.float32)
        if readouts.ndim != 3 or readouts.shape[0] != 2 or readouts.shape[2] != 2:
            raise ValueError(
                "ommatidia_readouts must have shape (2, n_ommatidia, 2)"
            )
        if readouts.shape[1] < 4:
            raise ValueError("ommatidia_readouts must contain at least four samples")
        if not np.all(np.isfinite(readouts)):
            raise ValueError("ommatidia_readouts must contain only finite values")
        if np.any(readouts < 0.0) or np.any(readouts > 1.0):
            raise ValueError("ommatidia_readouts must be normalized to [0, 1]")

        luminance = np.mean(readouts, axis=2)
        features: list[float] = []
        for eye in luminance:
            for tile in np.array_split(eye, 16):
                features.append(float(np.mean(tile)))
        return np.clip(np.asarray(features, dtype=np.float32), 0.0, 1.0)

    def reset(self) -> None:
        """Clear short-term neural state when the world is reset."""

        self._optic.fill(0.0)
        self._central.fill(0.0)
        self._motor.fill(0.0)
        self._previous_retina.fill(0.0)
        self._time_ms = 0.0
        self._snapshot = self._make_snapshot(self._previous_retina, 0)

    def step(
        self,
        retina_luminance: NDArray[np.floating],
        duration_ms: float,
    ) -> BrainStepResult:
        """Advance the circuit and publish a compact result."""

        retina = np.asarray(retina_luminance, dtype=np.float32)
        if retina.shape != (self.RETINA_CHANNELS,):
            raise ValueError(
                f"retina_luminance must have shape ({self.RETINA_CHANNELS},)"
            )
        if not np.all(np.isfinite(retina)):
            raise ValueError("retina_luminance must contain only finite values")
        if np.any(retina < 0.0) or np.any(retina > 1.0):
            raise ValueError("retina_luminance must be normalized to [0, 1]")
        if not math.isfinite(duration_ms) or duration_ms <= 0:
            raise ValueError("duration_ms must be positive and finite")

        retina = retina.copy()
        motion = np.abs(retina - self._previous_retina)
        drive = np.clip(0.65 * retina + 1.4 * motion, 0.0, 1.0)
        optic_target = self._sigmoid(
            self._optic_weights @ drive + self._optic_recurrent @ self._optic
        )
        central_target = self._sigmoid(
            self._central_weights @ optic_target
            + self._central_recurrent @ self._central
        )
        motor_target = np.tanh(self._motor_weights @ central_target)

        previous_optic = self._optic
        previous_central = self._central
        previous_motor = self._motor
        self._optic = self._leaky(previous_optic, optic_target, duration_ms, 3.0)
        self._central = self._leaky(
            previous_central, central_target, duration_ms, 8.0
        )
        self._motor = self._leaky(previous_motor, motor_target, duration_ms, 12.0)
        self._previous_retina = retina.copy()
        self._time_ms += duration_ms

        optic_spikes = (self._optic > self.SPIKE_THRESHOLDS[0]) & (
            previous_optic <= self.SPIKE_THRESHOLDS[0]
        )
        central_spikes = (self._central > self.SPIKE_THRESHOLDS[1]) & (
            previous_central <= self.SPIKE_THRESHOLDS[1]
        )
        motor_spikes = (np.abs(self._motor) > self.SPIKE_THRESHOLDS[2]) & (
            np.abs(previous_motor) <= self.SPIKE_THRESHOLDS[2]
        )
        spikes = int(
            np.count_nonzero(optic_spikes)
            + np.count_nonzero(central_spikes)
            + np.count_nonzero(motor_spikes)
        )
        self._snapshot = self._make_snapshot(retina, spikes)
        return BrainStepResult(
            duration_ms=duration_ms,
            total_spikes=spikes,
            readouts={
                "optic_lobe": int(np.count_nonzero(optic_spikes)),
                "central_complex": int(np.count_nonzero(central_spikes)),
                "motor": int(np.count_nonzero(motor_spikes)),
            },
            motor_output=tuple(float(value) for value in self._motor),
        )

    @property
    def snapshot(self) -> BrainSnapshot:
        return self._snapshot

    @staticmethod
    def _sigmoid(values: FloatArray) -> FloatArray:
        return (1.0 / (1.0 + np.exp(-np.clip(values, -12.0, 12.0)))).astype(
            np.float32
        )

    @staticmethod
    def _leaky(
        current: FloatArray, target: FloatArray, duration_ms: float, tau_ms: float
    ) -> FloatArray:
        alpha = 1.0 - math.exp(-duration_ms / tau_ms)
        return (current + alpha * (target - current)).astype(np.float32)

    def _make_snapshot(self, retina: FloatArray, spikes: int) -> BrainSnapshot:
        def readonly(values: FloatArray) -> FloatArray:
            result = values.copy()
            result.setflags(write=False)
            return result

        transmission = np.asarray(
            [
                float(np.mean(retina)),
                float(np.mean(self._optic)),
                float(np.mean(self._central)),
                float(np.mean(np.abs(self._motor))),
            ],
            dtype=np.float32,
        )
        return BrainSnapshot(
            retina=readonly(retina),
            optic_lobe=readonly(self._optic),
            central_complex=readonly(self._central),
            motor=readonly(self._motor),
            transmission=readonly(transmission),
            latency_ms=readonly(
                np.asarray([0.0, 1.5, 3.5, 6.0], dtype=np.float32)
            ),
            time_ms=self._time_ms,
            total_spikes=spikes,
        )
