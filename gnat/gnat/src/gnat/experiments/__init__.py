"""Experiment protocols, stimulus control, and run recording."""

from gnat.experiments.looming import LoomingStimulus, LoomingStimulusController
from gnat.experiments.horizontal import (
    HorizontalObjectStimulus,
    HorizontalObjectStimulusController,
)
from gnat.experiments.protocol import ExperimentSpec
from gnat.experiments.recording import ExperimentRecorder, sha256_file

__all__ = [
    "ExperimentRecorder",
    "ExperimentSpec",
    "HorizontalObjectStimulus",
    "HorizontalObjectStimulusController",
    "LoomingStimulus",
    "LoomingStimulusController",
    "sha256_file",
]
