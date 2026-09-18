"""Run the acceptance matrix job on the current operating system."""
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def main():
    print(platform.platform(), platform.machine(), flush=True)
    if sys.platform == "darwin":
        assert platform.machine() == "arm64", "The macOS acceptance job must use ARM64"
    else:
        assert platform.machine().lower() in ("x86_64", "amd64")
    run("moon", "version", "--all")
    run("moon", "update")
    for target in ("native", "wasm"):
        run("moon", "check", "--target", target, "--deny-warn")
        run("moon", "test", "--target", target)
        run("moon", "build", "--target", target)
        artifact = ROOT / "_build" / target / "debug/build" / ("moon-new.exe" if target == "native" else "moon-new.wasm")
        command = [str(artifact)] if target == "native" else ["moonrun", str(artifact), "--"]
        run(sys.executable, "tests/cli.py", "--", *command)
    run(sys.executable, "tests/package.py")
    run("moon", "info")
    run("moon", "fmt")
    run("git", "diff", "--exit-code")


if __name__ == "__main__":
    main()
