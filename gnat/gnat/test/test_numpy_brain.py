import unittest

import numpy as np

from gnat.brain import DoomflyBrain, NumpyFlyBrain


class NumpyBrainTests(unittest.TestCase):
    def test_eye_encoder_and_circuit_shapes(self) -> None:
        brain = NumpyFlyBrain()
        frames = np.zeros((2, 32, 32, 3), dtype=np.uint8)

        retina = brain.encode_eye_frames(frames)
        result = brain.step(retina, duration_ms=2.5)

        self.assertEqual(retina.shape, (NumpyFlyBrain.RETINA_CHANNELS,))
        self.assertEqual(result.duration_ms, 2.5)
        self.assertEqual(len(result.motor_output), NumpyFlyBrain.MOTOR_NEURONS)
        self.assertEqual(brain.snapshot.optic_lobe.shape, (48,))
        self.assertEqual(brain.snapshot.central_complex.shape, (24,))
        self.assertEqual(brain.snapshot.motor.shape, (8,))

    def test_motion_changes_transmission_activity(self) -> None:
        brain = NumpyFlyBrain()
        dark = np.zeros((2, 32, 32, 3), dtype=np.uint8)
        bright = dark.copy()
        bright[:, 12:20, 12:20] = 255

        brain.step(brain.encode_eye_frames(dark), duration_ms=2.5)
        before = brain.snapshot.transmission.copy()
        brain.step(brain.encode_eye_frames(bright), duration_ms=2.5)

        self.assertGreater(float(brain.snapshot.transmission[0]), float(before[0]))
        self.assertGreater(float(brain.snapshot.transmission[1]), 0.0)

    def test_ommatidia_encoder_does_not_require_rendered_eye_frames(self) -> None:
        readouts = np.zeros((2, 64, 2), dtype=np.float32)
        readouts[0, 32:, :] = 1.0

        encoded = NumpyFlyBrain.encode_ommatidia_readouts(readouts)

        self.assertEqual(encoded.shape, (32,))
        self.assertAlmostEqual(float(encoded[:16].mean()), 0.5, places=5)
        self.assertAlmostEqual(float(encoded[16:].mean()), 0.0, places=5)

    def test_eye_encoder_rejects_invalid_pixels(self) -> None:
        with self.assertRaises(ValueError):
            NumpyFlyBrain.encode_eye_frames(
                np.full((2, 8, 8, 3), np.nan, dtype=np.float32)
            )
        with self.assertRaises(ValueError):
            NumpyFlyBrain.encode_eye_frames(
                np.full((2, 8, 8, 3), 256.0, dtype=np.float32)
            )

    def test_snapshot_arrays_are_read_only(self) -> None:
        brain = NumpyFlyBrain()
        snapshot = brain.snapshot

        self.assertFalse(snapshot.retina.flags.writeable)
        with self.assertRaises(ValueError):
            snapshot.retina[0] = 1.0

    def test_step_rejects_non_normalized_retina(self) -> None:
        with self.assertRaises(ValueError):
            NumpyFlyBrain().step(
                np.full(NumpyFlyBrain.RETINA_CHANNELS, 2.0), duration_ms=1.0
            )

    def test_connectome_backend_requires_an_explicit_graph(self) -> None:
        with self.assertRaises(FileNotFoundError):
            DoomflyBrain("/private/tmp/gnat-missing/graph.npz")


class BrainResultTests(unittest.TestCase):
    def test_result_rejects_invalid_counts(self) -> None:
        from gnat.brain.protocol import BrainStepResult

        with self.assertRaises(ValueError):
            BrainStepResult(duration_ms=1.0, total_spikes=-1)
        with self.assertRaises(ValueError):
            BrainStepResult(duration_ms=1.0, total_spikes=1, readouts={"optic": -1})
        with self.assertRaises(ValueError):
            BrainStepResult(duration_ms=1.0, total_spikes=0, motor_output=(2.0,))


if __name__ == "__main__":
    unittest.main()
