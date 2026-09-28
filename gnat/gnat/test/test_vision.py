import unittest

import numpy as np

from gnat.vision import FlyGymVision, RetinaMapping, RetinaMappingError, VisionSample


class _FakeRetina:
    num_ommatidia_per_eye = 2

    def raw_image_to_hex_pxls(self, image: np.ndarray) -> np.ndarray:
        del image
        return np.ones((2, 2), dtype=np.float32)


class _FakeSimulation:
    def __init__(self) -> None:
        self.retina = _FakeRetina()
        self.time = 1.25
        self.raw_vision_calls = 0
        self.ommatidia_calls = 0

    def get_raw_vision(self, fly_name: str) -> np.ndarray:
        del fly_name
        self.raw_vision_calls += 1
        return np.zeros((2, 1, 1, 3), dtype=np.uint8)

    def get_ommatidia_readouts(self, fly_name: str) -> np.ndarray:
        del fly_name
        self.ommatidia_calls += 1
        return np.zeros((2, 2, 2), dtype=np.float32)


class _FakeWorld:
    def __init__(self) -> None:
        self.simulation = _FakeSimulation()
        self.fly_name = "nmf"


class VisionTests(unittest.TestCase):
    def test_include_raw_reuses_single_eye_render(self) -> None:
        world = _FakeWorld()

        sample = FlyGymVision(world, include_raw=True).sample()

        self.assertEqual(sample.ommatidia_readouts.shape, (2, 2, 2))
        self.assertIsNotNone(sample.raw_rgb)
        self.assertEqual(world.simulation.raw_vision_calls, 1)
        self.assertEqual(world.simulation.ommatidia_calls, 0)

    def test_mapping_rejects_non_finite_weights(self) -> None:
        with self.assertRaises(RetinaMappingError):
            RetinaMapping(
                source_eye=np.array([0]),
                source_ommatidium=np.array([0]),
                source_channel=np.array([0]),
                target_index=np.array([0]),
                weight=np.array([np.nan], dtype=np.float32),
            )

    def test_mapping_rejects_non_integer_arrays(self) -> None:
        with self.assertRaises(RetinaMappingError):
            RetinaMapping(
                source_eye=np.array([0.5]),
                source_ommatidium=np.array([0]),
                source_channel=np.array([0]),
                target_index=np.array([0]),
                weight=np.array([1.0], dtype=np.float32),
            )

    def test_mapping_buffers_are_copied(self) -> None:
        source_eye = np.array([0], dtype=np.int64)
        mapping = RetinaMapping(
            source_eye=source_eye,
            source_ommatidium=np.array([0], dtype=np.int64),
            source_channel=np.array([0], dtype=np.int64),
            target_index=np.array([0], dtype=np.int64),
            weight=np.array([1.0], dtype=np.float32),
            target_size=1,
        )
        source_eye[0] = 1
        self.assertEqual(mapping.source_eye[0], 0)

    def test_bridge_rejects_non_normalized_readouts(self) -> None:
        mapping = RetinaMapping(
            source_eye=np.array([0], dtype=np.int64),
            source_ommatidium=np.array([0], dtype=np.int64),
            source_channel=np.array([0], dtype=np.int64),
            target_index=np.array([0], dtype=np.int64),
            weight=np.array([1.0], dtype=np.float32),
            target_size=1,
        )
        from gnat.vision import RetinaBridge

        with self.assertRaises(RetinaMappingError):
            RetinaBridge(mapping).transform(np.full((2, 2, 2), 2.0))

    def test_vision_sample_rejects_invalid_time_and_raw_shape(self) -> None:
        readouts = np.zeros((2, 2, 2), dtype=np.float32)
        with self.assertRaises(ValueError):
            VisionSample(float("nan"), readouts)
        with self.assertRaises(ValueError):
            VisionSample(0.0, readouts, np.zeros((2, 8, 8), dtype=np.uint8))


if __name__ == "__main__":
    unittest.main()
