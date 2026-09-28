import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest

import numpy as np

from gnat.brain import BrainStepResult
from gnat.experiments import (
    ExperimentRecorder,
    ExperimentSpec,
    HorizontalObjectStimulus,
    LoomingStimulus,
)
from gnat.main import build_parser, run_experiment_command
from gnat.runner import LoopStep
from gnat.vision import VisionSample


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEMO_PROTOCOL = PROJECT_ROOT / "examples" / "looming-demo.json"
HORIZONTAL_PROTOCOL = PROJECT_ROOT / "examples" / "horizontal-object-demo.json"


class LoomingExperimentTests(unittest.TestCase):
    def test_demo_protocol_declares_subject_and_integral_step_count(self) -> None:
        spec = ExperimentSpec.from_json(DEMO_PROTOCOL)

        self.assertEqual(spec.subject["sex"], "unknown")
        self.assertEqual(spec.step_count, 4000)
        self.assertEqual(spec.stimulus.start_distance_mm, 22.0)

    def test_looming_trajectory_and_visibility_are_time_aligned(self) -> None:
        stimulus = LoomingStimulus(
            start_distance_mm=20.0,
            end_distance_mm=4.0,
            duration_s=2.0,
            radius_mm=1.0,
            z_mm=0.0,
        )

        self.assertEqual(stimulus.distance_mm_at(0.0), 20.0)
        self.assertEqual(stimulus.distance_mm_at(1.0), 12.0)
        self.assertEqual(stimulus.distance_mm_at(3.0), 4.0)
        self.assertGreater(
            stimulus.angular_diameter_rad_at(1.0),
            stimulus.angular_diameter_rad_at(0.0),
        )
        self.assertGreater(stimulus.angular_expansion_rate_rad_s_at(1.0), 0.0)
        self.assertEqual(stimulus.angular_expansion_rate_rad_s_at(3.0), 0.0)
        self.assertFalse(stimulus.state_at(-0.1)["visible"])
        self.assertFalse(stimulus.state_at(2.1)["visible"])

    def test_recorder_writes_step_records_and_descriptive_phase_metrics(self) -> None:
        spec = ExperimentSpec.from_json(DEMO_PROTOCOL)
        vision = VisionSample(0.05, np.ones((2, 4, 2), dtype=np.float32))
        result = BrainStepResult(
            duration_ms=0.1,
            total_spikes=2,
            readouts={"visual": 2},
            motor_output=(0.25, -0.25),
        )
        step = LoopStep(
            simulation_time_s=0.05,
            brain=result,
            vision=vision,
            retina_input=np.full(32, 0.5, dtype=np.float32),
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "mapping.bin"
            artifact.write_bytes(b"calibration")
            recorder = ExperimentRecorder(
                Path(temporary_directory) / "runs",
                spec,
                backend={"mode": "unit-test"},
                artifacts={"mapping": artifact},
                raw_vision=True,
            )
            recorder.record_step(
                step,
                stimulus_state=spec.stimulus.state_at(-0.05),
                world_state={"qpos": np.zeros(2), "qvel": np.zeros(2)},
            )
            for simulation_time, elapsed in ((0.15, 0.05), (0.35, 0.25)):
                later_step = LoopStep(
                    simulation_time_s=simulation_time,
                    brain=result,
                    vision=VisionSample(
                        simulation_time, np.ones((2, 4, 2), dtype=np.float32)
                    ),
                    retina_input=np.full(32, 0.5, dtype=np.float32),
                )
                recorder.record_step(
                    later_step,
                    stimulus_state=spec.stimulus.state_at(elapsed),
                    world_state={"qpos": np.zeros(2), "qvel": np.zeros(2)},
                )
            run_directory = recorder.finish()

            records = [
                json.loads(line)
                for line in (run_directory / "steps.jsonl").read_text().splitlines()
            ]
            manifest = json.loads((run_directory / "manifest.json").read_text())
            summary = json.loads((run_directory / "summary.json").read_text())

        self.assertEqual(len(records), 3)
        self.assertEqual(len(records[0]["ommatidia_readouts"]), 2)
        self.assertEqual(len(records[0]["retina_input"]), 32)
        self.assertEqual(manifest["status"], "complete")
        self.assertEqual(
            manifest["artifacts"][0]["sha256"],
            hashlib.sha256(b"calibration").hexdigest(),
        )
        self.assertEqual(summary["recorded_steps"], 3)
        self.assertFalse(summary["criteria_evaluated"])
        self.assertEqual(summary["descriptive_phase_metrics"]["stimulus"]["steps"], 1)

    def test_experiment_command_runs_and_records_a_short_trial(self) -> None:
        protocol = json.loads(DEMO_PROTOCOL.read_text(encoding="utf-8"))
        protocol["baseline_s"] = 0.0001
        protocol["stimulus"]["duration_s"] = 0.0002
        protocol["recovery_s"] = 0.0001

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            protocol_path = temporary_path / "short-protocol.json"
            protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
            output_path = temporary_path / "runs"
            args = build_parser().parse_args(
                [
                    "experiment",
                    "--spec",
                    str(protocol_path),
                    "--output",
                    str(output_path),
                ]
            )

            run_experiment_command(args)

            run_directory = next(output_path.iterdir())
            records = (run_directory / "steps.jsonl").read_text().splitlines()
            summary = json.loads((run_directory / "summary.json").read_text())
            manifest = json.loads((run_directory / "manifest.json").read_text())

        self.assertEqual(len(records), 4)
        self.assertEqual(summary["status"], "complete")
        self.assertEqual(summary["recorded_steps"], 4)
        self.assertEqual(manifest["backend"]["mode"], "demo-numpy")
        self.assertFalse(manifest["backend"]["fly_behavior"]["motor_output_applied"])


class HorizontalObjectExperimentTests(unittest.TestCase):
    def test_horizontal_path_keeps_radius_and_angular_speed_constant(self) -> None:
        stimulus = HorizontalObjectStimulus()

        start = stimulus.position_mm_at(0.0)
        middle = stimulus.position_mm_at(stimulus.duration_s / 2.0)
        end = stimulus.position_mm_at(stimulus.duration_s)
        radii = [math.hypot(x, y) for x, y, _ in (start, middle, end)]

        self.assertTrue(np.allclose(radii, stimulus.radius_from_origin_mm))
        self.assertGreater(start[1], 0.0)
        self.assertLess(end[1], 0.0)
        self.assertLess(stimulus.angular_velocity_rad_s, 0.0)
        self.assertFalse(stimulus.state_at(-0.1)["visible"])
        self.assertFalse(stimulus.state_at(stimulus.duration_s + 0.1)["visible"])

    def test_horizontal_protocol_declares_walls_and_integral_step_count(self) -> None:
        spec = ExperimentSpec.from_json(HORIZONTAL_PROTOCOL)

        self.assertIsInstance(spec.stimulus, HorizontalObjectStimulus)
        self.assertEqual(spec.step_count, 6000)
        self.assertEqual(spec.stimulus.corridor_half_width_mm, 12.0)

    def test_horizontal_experiment_builds_walled_world_and_records_path(self) -> None:
        protocol = json.loads(HORIZONTAL_PROTOCOL.read_text(encoding="utf-8"))
        protocol["baseline_s"] = 0.0001
        protocol["stimulus"]["duration_s"] = 0.0002
        protocol["recovery_s"] = 0.0001

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            protocol_path = temporary_path / "horizontal-protocol.json"
            protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
            output_path = temporary_path / "runs"
            args = build_parser().parse_args(
                [
                    "experiment",
                    "--spec",
                    str(protocol_path),
                    "--output",
                    str(output_path),
                ]
            )

            run_experiment_command(args)

            run_directory = next(output_path.iterdir())
            records = [
                json.loads(line)
                for line in (run_directory / "steps.jsonl").read_text().splitlines()
            ]
            manifest = json.loads((run_directory / "manifest.json").read_text())

        self.assertEqual(len(records), 4)
        expected_start_y = protocol["stimulus"]["radius_from_origin_mm"] * math.sin(
            math.radians(protocol["stimulus"]["start_azimuth_deg"])
        )
        self.assertAlmostEqual(records[0]["stimulus"]["y_mm"], expected_start_y)
        self.assertTrue(
            manifest["backend"]["stimulus_controller"]["fixed_visual_context"][
                "corridor_side_walls"
            ]
        )
        self.assertFalse(
            manifest["backend"]["response_latency"]["automatically_computed"]
        )


if __name__ == "__main__":
    unittest.main()
