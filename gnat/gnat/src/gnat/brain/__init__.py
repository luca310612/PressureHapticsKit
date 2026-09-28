"""Neural backend interfaces."""

from gnat.brain.protocol import BrainBackend, BrainStepResult
from gnat.brain.doomfly_brain import DoomflyBackendError, DoomflyBrain
from gnat.brain.numpy_brain import BrainSnapshot, NumpyFlyBrain

__all__ = [
    "BrainBackend",
    "BrainSnapshot",
    "BrainStepResult",
    "DoomflyBackendError",
    "DoomflyBrain",
    "NumpyFlyBrain",
]
