"""Verify published assets, regeneration, installation, and generated-project use."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=ROOT):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    run("moon", "package")
    archive = ROOT / "_build/publish/moonbit-community-moon-new-0.1.0.zip"
    with zipfile.ZipFile(archive) as package, tempfile.TemporaryDirectory(prefix="moon-new-package-") as tmp:
        names = set(package.namelist())
        inputs = re.findall(r'input: "([^"]+)"', (ROOT / "template/moon.pkg").read_text(encoding="utf-8"))
        assert len(inputs) == 14
        for relative_input in inputs:
            relative = "template/" + relative_input
            assert relative in names, f"Missing published asset: {relative}"
            assert package.read(relative) == (ROOT / relative).read_bytes(), relative
        generated = sorted((ROOT / "template").glob("*.generated.mbt"))
        assert len(generated) == 14
        for path in generated:
            assert package.read(path.relative_to(ROOT).as_posix()) == path.read_bytes()
        source = Path(tmp) / "source"
        package.extractall(source)
        # Force the packaged dev_build rules to recreate every derived constant.
        for path in (source / "template").glob("*.generated.mbt"):
            path.unlink()
        binary_dir = Path(tmp) / "bin"
        run("moon", "install", "--path", str(source), "--bin", str(binary_dir))
        for path in generated:
            assert (source / path.relative_to(ROOT)).read_bytes() == path.read_bytes()
        command = binary_dir / ("moon-new.exe" if os.name == "nt" else "moon-new")
        assert command.is_file(), "Root package must install as moon-new"
        destination = Path(tmp) / "generated"
        run(str(command), str(destination), "--user", "tester", "--quiet")
        run("moon", "check", cwd=destination)
        run("moon", "test", cwd=destination)
        result = subprocess.run(["moon", "run", "cmd/main"], cwd=destination,
                                capture_output=True, text=True, encoding="utf-8", check=True)
        assert result.stdout.strip() == "Hello", result
    print("Published archive, dev_build regeneration, local install, and generated project verified.")


if __name__ == "__main__":
    main()
