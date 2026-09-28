"""Application orchestrator for the FlyGym/MaleCNS experiment."""

import argparse
from collections.abc import Callable, Sequence
from pathlib import Path
import subprocess


def _git_revision(directory: Path | None) -> str | None:
    """Return a local source checkout revision without contacting a remote."""

    if directory is None:
        return None
    try:
        completed = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return completed.stdout.strip() or None


def run_check() -> None:
    """Build and close the world without opening a GUI."""

    from gnat.world import build_flygym_world

    flygym_world = build_flygym_world()
    try:
        print(
            "FlyGym world ready: "
            f"fly={flygym_world.fly_name}, "
            f"timestep={flygym_world.simulation.timestep}s, "
            f"motor_actuators={flygym_world.motor_actuator_count}, "
            "connectome=not-loaded"
        )
    finally:
        flygym_world.simulation.close()


def run_viewer_command(args: argparse.Namespace) -> None:
    """Load the GUI only when the viewer command is requested."""

    from gnat.viewer import run_viewer

    run_viewer(
        connectome_path=args.connectome,
        doomfly_root=args.doomfly_root,
        manifest_path=args.manifest,
        retina_mapping_path=args.retina_mapping,
        prefer_native=not args.no_native,
    )


def run_experiment_command(args: argparse.Namespace) -> None:
    """Run one declared visual-response protocol and record its data path."""

    import mujoco

    from gnat.brain import DoomflyBrain, NumpyFlyBrain
    from gnat.clock import SimulationClock
    from gnat.experiments import (
        ExperimentRecorder,
        ExperimentSpec,
        HorizontalObjectStimulus,
        HorizontalObjectStimulusController,
        LoomingStimulusController,
    )
    from gnat.runner import ClosedLoopRunner
    from gnat.vision import FlyGymVision, RetinaBridge
    from gnat.world import build_flygym_world

    spec = ExperimentSpec.from_json(args.spec)
    project_root = Path(__file__).resolve().parents[2]
    artifacts: dict[str, Path] = {"experiment_protocol": args.spec}
    for filename in ("pyproject.toml", "uv.lock"):
        config_path = project_root / filename
        if config_path.is_file():
            artifacts[f"project_{filename}"] = config_path
    retina_bridge = None
    input_encoder = None
    if args.connectome is None:
        if any(
            value is not None
            for value in (args.retina_mapping, args.manifest, args.doomfly_root)
        ) or args.no_native:
            raise ValueError("connectome-specific options require --connectome")
        brain = NumpyFlyBrain(seed=args.seed)
        input_encoder = lambda sample: NumpyFlyBrain.encode_ommatidia_readouts(
            sample.ommatidia_readouts
        )
        backend_info: dict[str, object] = {
            "mode": "demo-numpy",
            "engine": "gnat fixed-seed rate-and-threshold circuit",
            "seed": args.seed,
            "biological_claim": False,
            "input_mapping": "demo equal-bin reduction of FlyGym ommatidia",
            "motor_output": "recorded only; no actuator mapping applied",
        }
    else:
        if args.retina_mapping is None:
            raise ValueError("--retina-mapping is required with --connectome")
        manifest_path = args.manifest or args.connectome.with_name("manifest.json")
        brain = DoomflyBrain.from_manifest(
            args.connectome,
            manifest_path,
            doomfly_root=args.doomfly_root,
            prefer_native=not args.no_native,
        )
        retina_bridge = RetinaBridge.from_npz(args.retina_mapping)
        if retina_bridge.mapping.target_size != brain.input_size:
            raise ValueError(
                "retina mapping target_size does not match the loaded graph input size"
            )
        artifacts.update(
            {
                "connectome_graph": args.connectome,
                "connectome_manifest": manifest_path,
                "retina_mapping": args.retina_mapping,
            }
        )
        engine_source_path = brain.engine_source_path
        if engine_source_path is not None:
            artifacts["doomfly_engine_module"] = engine_source_path
        backend_info = {
            "mode": "doomfly-malecns",
            "engine": brain.engine_name,
            "neuron_count": brain.neuron_count,
            "edge_count": brain.edge_count,
            "doomfly_source": (
                str(args.doomfly_root.expanduser().resolve())
                if args.doomfly_root is not None
                else None
            ),
            "engine_source_file": (
                str(engine_source_path) if engine_source_path is not None else None
            ),
            "doomfly_revision": _git_revision(args.doomfly_root),
            "biological_claim": "connectome backend; input and behavior validation still required",
            "input_mapping": "explicit calibrated RetinaMapping",
            "motor_output": "doomfly BCI forward/turn controls recorded only",
        }

    clock = SimulationClock(
        physics_timestep_s=spec.physics_timestep_s,
        neural_timestep_ms=spec.neural_timestep_ms,
    )
    if isinstance(spec.stimulus, HorizontalObjectStimulus):
        corridor_half_width_mm = spec.stimulus.corridor_half_width_mm
        world = build_flygym_world(
            timestep_s=spec.physics_timestep_s,
            corridor_half_width_mm=corridor_half_width_mm,
            corridor_forward_extent_mm=spec.stimulus.radius_from_origin_mm * 2.0 + 10.0,
        )
    else:
        corridor_half_width_mm = None
        world = build_flygym_world(timestep_s=spec.physics_timestep_s)
    recorder = None
    try:
        if isinstance(spec.stimulus, HorizontalObjectStimulus):
            stimulus_controller = HorizontalObjectStimulusController(
                world, spec.stimulus
            )
        else:
            stimulus_controller = LoomingStimulusController(world, spec.stimulus)
        vision = FlyGymVision(world)
        runner = ClosedLoopRunner(
            world,
            vision,
            retina_bridge,
            brain,
            clock=clock,
            input_encoder=input_encoder,
            physics_sample_hook=lambda: stimulus_controller.apply_elapsed(
                world.simulation.time - spec.baseline_s
            ),
        )
        joint_layout = []
        for joint_id in range(world.model.njnt):
            joint_layout.append(
                {
                    "name": mujoco.mj_id2name(
                        world.model, mujoco.mjtObj.mjOBJ_JOINT, joint_id
                    ),
                    "qpos_address": int(world.model.jnt_qposadr[joint_id]),
                    "dof_address": int(world.model.jnt_dofadr[joint_id]),
                }
            )
        backend_info["joint_layout"] = joint_layout
        backend_info["physics_timestep_s"] = spec.physics_timestep_s
        backend_info["neural_timestep_ms"] = spec.neural_timestep_ms
        backend_info["physics_steps_per_neural_step"] = (
            clock.physics_steps_per_neural_step
        )
        backend_info["planned_neural_steps"] = spec.step_count
        if isinstance(spec.stimulus, HorizontalObjectStimulus):
            backend_info["stimulus_controller"] = {
                "geometry": "grayscale sphere on a fixed-radius horizontal arc",
                "collision_enabled": False,
                "angular_velocity_rad_s": spec.stimulus.angular_velocity_rad_s,
                "angle_reference": "world origin; eye position is not calibrated",
                "fixed_visual_context": {
                    "corridor_side_walls": True,
                    "corridor_half_width_mm": corridor_half_width_mm,
                    "wall_collisions_enabled": False,
                },
            }
        else:
            backend_info["stimulus_controller"] = {
                "geometry": "grayscale sphere at configured world coordinates",
                "collision_enabled": False,
                "angle_reference": "world origin; eye position is not calibrated",
            }
        backend_info["response_latency"] = {
            "automatically_computed": False,
            "logged_signals": "per-step neural readouts and motor output",
            "reason": "a calibrated response channel and onset threshold have not been selected",
        }
        backend_info["fly_behavior"] = {
            "root_tethered": True,
            "motor_output_applied": False,
        }
        recorder = ExperimentRecorder(
            args.output,
            spec,
            backend=backend_info,
            artifacts=artifacts,
            raw_vision=args.record_raw_retina,
            world_state_layout=(
                "qpos/qvel arrays in MuJoCo order; joint addresses are in "
                "backend.joint_layout; translational world coordinates use mm"
            ),
        )

        try:
            for _ in range(spec.step_count):
                step = runner.step()
                elapsed = step.simulation_time_s - spec.baseline_s
                recorder.record_step(
                    step,
                    stimulus_state=spec.stimulus.state_at(elapsed),
                    world_state={
                        "qpos": world.data.qpos.copy(),
                        "qvel": world.data.qvel.copy(),
                    },
                )
        except KeyboardInterrupt:
            recorder.finish("interrupted")
            raise
        except Exception as error:
            recorder.finish("failed", error=f"{type(error).__name__}: {error}")
            raise
        run_dir = recorder.finish("complete")
        print(f"Experiment complete: {run_dir}")
        print(
            f"Backend: {backend_info['mode']} "
            "(motor output logged only; no actuator mapping applied)"
        )
    finally:
        if recorder is not None:
            recorder.finish("interrupted")
        world.simulation.close()


COMMANDS: dict[str, Callable[[], None]] = {"check": run_check}


def build_parser() -> argparse.ArgumentParser:
    """Create the command-line interface for the application."""

    parser = argparse.ArgumentParser(prog="gnat")
    subparsers = parser.add_subparsers(dest="command", required=True)
    viewer = subparsers.add_parser("viewer", help="launch the FlyGym viewer")
    viewer.add_argument(
        "--connectome",
        type=Path,
        help="doomfly graph.npz; enables the real MaleCNS backend",
    )
    viewer.add_argument(
        "--manifest",
        type=Path,
        help="doomfly manifest.json containing validated readout indices",
    )
    viewer.add_argument(
        "--retina-mapping",
        type=Path,
        help="calibrated FlyGym-to-MaleCNS retina mapping (.npz)",
    )
    viewer.add_argument(
        "--doomfly-root",
        type=Path,
        help="upstream doomfly checkout containing the doom Python package",
    )
    viewer.add_argument(
        "--no-native",
        action="store_true",
        help="use doomfly's reference NumPy/Numba engine instead of native kernel",
    )
    subparsers.add_parser("check", help="build the FlyGym world without a GUI")
    experiment = subparsers.add_parser(
        "experiment", help="run and record a declared visual-response protocol"
    )
    experiment.add_argument(
        "--spec", type=Path, required=True, help="validated experiment protocol JSON"
    )
    experiment.add_argument(
        "--output", type=Path, required=True, help="directory for a new run record"
    )
    experiment.add_argument(
        "--connectome", type=Path, help="doomfly graph.npz; defaults to the labeled demo backend"
    )
    experiment.add_argument(
        "--manifest", type=Path, help="doomfly manifest.json with readout indices"
    )
    experiment.add_argument(
        "--retina-mapping", type=Path, help="calibrated FlyGym-to-connectome mapping"
    )
    experiment.add_argument(
        "--doomfly-root", type=Path, help="checkout containing the upstream doom package"
    )
    experiment.add_argument(
        "--no-native",
        action="store_true",
        help="use doomfly's reference NumPy/Numba engine instead of native kernel",
    )
    experiment.add_argument(
        "--seed", type=int, default=7, help="fixed seed for the explicitly labeled demo circuit"
    )
    experiment.add_argument(
        "--record-raw-retina",
        action="store_true",
        help="also save each uncompressed ommatidia sample (large output)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> None:
    """Dispatch an application command."""

    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "viewer":
        try:
            run_viewer_command(args)
        except (FileNotFoundError, ValueError, RuntimeError) as error:
            parser.error(str(error))
    elif args.command == "experiment":
        try:
            run_experiment_command(args)
        except (FileNotFoundError, ValueError, RuntimeError, OSError) as error:
            parser.error(str(error))
    else:
        COMMANDS[args.command]()
