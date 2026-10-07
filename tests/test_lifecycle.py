"""Regression tests with isolated fake engines; no GPU, cache deletion, or daemon required."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PART = 1
MOCK = r"""import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps([name,args])+'\n')
if name == 'uname': print(os.getenv('TEST_OS','Linux') if args == ['-s'] else 'x86_64'); sys.exit(0)
if name == 'sleep': sys.exit(0)
if name == 'curl': sys.exit(0 if list(root.glob('*.running')) or os.getenv('BUSY_PORT') else 1)
if name == 'nvidia-ctk':
    if os.getenv('CDI'): print('nvidia.com/gpu=all'); sys.exit(0)
    sys.exit(1)
if name in ('podman','docker'):
    owner = 'podman' if name == 'docker' and os.getenv('DOCKER_ALIAS') else name
    state = root/(owner+'.running')
    volume = root/(owner+'.volume')
    if args[0] == 'info':
        if os.getenv('DOWN') == name: sys.exit(1)
        if name == 'docker': print('{"nvidia": {}}')
        sys.exit(0)
    if args[:2] == ['container','inspect']:
        if state.exists(): print(owner+'-id'); sys.exit(0)
        sys.exit(1)
    if args[:2] == ['volume','inspect']:
        if volume.exists(): print('/'+owner+'/volume'); sys.exit(0)
        sys.exit(1)
    if args[:2] == ['volume','rm']: volume.unlink(missing_ok=True); sys.exit(0)
    if args[0] == 'run': state.write_text('false' if os.getenv('DEAD_BACKEND') else 'true'); volume.touch(); print('fake-id'); sys.exit(1 if os.getenv('RUN_FAIL') else 0)
    if args[0] == 'rm': state.unlink(missing_ok=True); sys.exit(0)
    if args[0] == 'inspect':
        print(state.read_text() if state.exists() else 'false'); sys.exit(0)
sys.exit(1)
"""


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Cleanup may remove repo-local environments. Execute disposable copies.
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        for source in REPO.glob("*.sh"):
            shutil.copy(source, self.repo / source.name)
        for source in (REPO / "scripts").glob("*.sh"):
            shutil.copy(source, self.repo / "scripts" / source.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("podman", "docker", "nvidia-ctk", "uname", "curl", "sleep"):
            p = bin_dir / name
            p.write_text(f"#!{sys.executable}\n" + MOCK)
            p.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}:/usr/bin:/bin",
            TMPDIR=str(self.root),
            TEST_ROOT=str(self.root),
        )
        for key in (
            "ENGINE",
            "CDI",
            "DOWN",
            "BUSY_PORT",
            "DOCKER_ALIAS",
            "RUN_FAIL",
            "DEAD_BACKEND",
            "TEST_OS",
        ):
            self.env.pop(key, None)

    def run_script(self, script, *args, ok=True):
        result = subprocess.run(
            ["/bin/sh", str(self.repo / script), *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=10,
            cwd=self.root,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def start(self):
        return self.run_script(
            "run.sh", *(["nvidia"] if PART == 1 else ["baseline", "nvidia"])
        )

    def calls(self):
        return [json.loads(s) for s in (self.root / "calls").read_text().splitlines()]

    def test_docker_fallback_stops_with_default_engine(self):
        self.start()
        self.assertTrue((self.root / "docker.running").exists())
        self.run_script("stop.sh")
        self.assertFalse((self.root / "docker.running").exists())
        self.run_script("stop.sh")

    def test_cleanup_finds_stopped_container_volume_from_any_cwd(self):
        self.start()
        self.run_script("stop.sh")
        self.run_script("cleanup.sh", "--yes")
        self.assertFalse((self.root / "docker.volume").exists())

    def test_podman_uses_cdi_even_with_absolute_engine_path(self):
        self.env.update(ENGINE=str(self.root / "bin/podman"), CDI="1")
        self.start()
        args = next(a for n, a in self.calls() if n == "podman" and a[0] == "run")
        self.assertIn("nvidia.com/gpu=all", args)
        self.assertNotIn("--gpus", args)

    def test_ambiguous_engines_fail_without_deleting(self):
        for e in ("podman", "docker"):
            (self.root / f"{e}.running").write_text("true")
        result = self.run_script("stop.sh", ok=False)
        self.assertIn("Set ENGINE", result.stderr)
        self.assertTrue((self.root / "docker.running").exists())
        self.assertTrue((self.root / "podman.running").exists())

    def test_explicit_engine_resolves_ambiguity(self):
        for e in ("podman", "docker"):
            (self.root / f"{e}.running").write_text("true")
        self.env["ENGINE"] = "docker"
        self.run_script("stop.sh")
        self.assertTrue((self.root / "podman.running").exists())
        self.assertFalse((self.root / "docker.running").exists())

    def test_unrelated_container_is_preserved(self):
        (self.root / "docker.running").write_text("false")
        self.run_script("stop.sh", ok=False)
        self.assertTrue((self.root / "docker.running").exists())

    def test_unavailable_explicit_engine_fails(self):
        self.env.update(ENGINE="docker", DOWN="docker")
        self.run_script("stop.sh", ok=False)

    def test_existing_endpoint_is_not_accepted_as_new_server(self):
        self.env["BUSY_PORT"] = "1"
        self.run_script(
            "run.sh", *(["nvidia"] if PART == 1 else ["baseline", "nvidia"]), ok=False
        )
        self.assertFalse(
            any(a[0] == "run" for n, a in self.calls() if n in ("docker", "podman"))
        )

    def test_docker_compatibility_alias_is_one_owner(self):
        (self.root / "podman.running").write_text("true")
        self.env["DOCKER_ALIAS"] = "1"
        self.run_script("stop.sh")
        self.assertFalse((self.root / "podman.running").exists())

    def test_partial_container_failure_is_cleaned_up(self):
        self.env["RUN_FAIL"] = "1"
        self.run_script(
            "run.sh", *(["nvidia"] if PART == 1 else ["baseline", "nvidia"]), ok=False
        )
        self.assertFalse((self.root / "docker.running").exists())

    def test_dead_backend_does_not_report_ready(self):
        self.env["DEAD_BACKEND"] = "1"
        self.run_script(
            "run.sh", *(["nvidia"] if PART == 1 else ["baseline", "nvidia"]), ok=False
        )
        self.assertFalse((self.root / "docker.running").exists())

    def test_amd_and_intel_argv(self):
        for accelerator, device in [
            ("amd", "/dev/kfd"),
            ("intel", "/dev/dri:/dev/dri"),
        ]:
            with self.subTest(accelerator=accelerator):
                self.run_script(
                    "run.sh",
                    *([accelerator] if PART == 1 else ["baseline", accelerator]),
                )
                args = [a for n, a in self.calls() if n == "podman" and a[0] == "run"][
                    -1
                ]
                self.assertIn(device, args)
                self.run_script("stop.sh")

    def test_idle_metal_stop_does_not_require_container_daemons(self):
        self.env.update(TEST_OS="Darwin", DOWN="docker")
        self.run_script("stop.sh")
        self.assertFalse(any(n in ("podman", "docker") for n, a in self.calls()))


if __name__ == "__main__":
    unittest.main()
