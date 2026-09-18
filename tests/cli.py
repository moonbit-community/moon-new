"""Black-box acceptance tests. Pass a built executable command after --."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

COMMAND = sys.argv[sys.argv.index("--") + 1:]
COMMAND[0] = str(Path(shutil.which(COMMAND[0]) or COMMAND[0]).resolve())
COMMAND = [str(Path(arg).resolve()) if arg.endswith(".wasm") else arg for arg in COMMAND]
sys.argv = sys.argv[:sys.argv.index("--")]

class CLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="moon-new-cli-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, "MOON_HOME": str(self.root / "moon-home")}

    def run_cli(self, *args, env=None):
        return subprocess.run([*COMMAND, *args], cwd=self.root,
                              env=env or self.env, text=True, encoding="utf-8", capture_output=True)

    def test_create_official_fixture(self):
        fixture = json.loads((Path(__file__).parent / "fixtures/official.json").read_text(encoding="utf-8"))
        result = self.run_cli("hello", "--user", "tester")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Created tester/hello", result.stdout)
        dest = self.root / "hello"
        expected = set(fixture["files"]) | set(fixture["links"])
        actual = {p.relative_to(dest).as_posix() for p in dest.rglob("*")
                  if p.is_file() and ".git" not in p.relative_to(dest).parts}
        self.assertEqual(actual, expected)
        for rel, content in fixture["files"].items():
            self.assertEqual((dest / rel).read_bytes(), content.encode(), rel)
        for rel, target in fixture["links"].items():
            if (dest / rel).is_symlink():
                self.assertEqual(os.readlink(dest / rel), target)
            else:
                self.assertEqual((dest / rel).read_bytes(), (dest / target).read_bytes())
                self.assertIn("copying", result.stderr)
        if os.name != "nt":
            self.assertEqual((dest / ".githooks/pre-commit").stat().st_mode & 0o777, 0o755)
        self.assertTrue((dest / ".git").is_dir())

    def test_credentials_and_explicit_user(self):
        credentials = Path(self.env["MOON_HOME"]) / "credentials.json"
        credentials.parent.mkdir()
        credentials.write_text(json.dumps({"token": "test-token", "username": "saved_user"}))
        result = self.run_cli("saved")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "saved/README.mbt.md").read_text(encoding="utf-8"), "# saved_user/saved")
        credentials.write_text("not JSON")
        result = self.run_cli("explicit", "--user", "chosen")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("credentials", result.stderr)
        result = self.run_cli("fallback", "--quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Warning:", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual((self.root / "fallback/README.mbt.md").read_text(encoding="utf-8"), "# username/fallback")
        self.assertNotIn("test-token", result.stdout + result.stderr)

    def test_destinations_and_quiet(self):
        empty = self.root / "empty"
        empty.mkdir()
        result = self.run_cli("empty", "--user", "tester", "-q")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        for name, hidden in [("populated", ".DS_Store"), ("repository", ".git")]:
            dest = self.root / name
            dest.mkdir()
            (dest / hidden).write_text("keep me")
            result = self.run_cli(name, "--user", "tester")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("not empty", result.stderr)
            self.assertEqual(list(dest.iterdir()), [dest / hidden])
            self.assertEqual((dest / hidden).read_text(encoding="utf-8"), "keep me")
        (self.root / "regular").write_text("keep me")
        result = self.run_cli("regular", "--user", "tester")
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / "regular").read_text(encoding="utf-8"), "keep me")

    def test_names_and_argument_forms(self):
        result = self.run_cli("foo.bar", "--user=用户𐐀", "--quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "foo.bar/README.mbt.md").read_text(encoding="utf-8"), "# 用户𐐀/foo")
        result = self.run_cli("override", "--name=sample_test", "--user=tester", "-q")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Warning:", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue((self.root / "override/sample_test.mbt").is_file())
        for user in ["", "a/b", "emoji😀", "a\u0345"]:
            result = self.run_cli("invalid", "--user", user)
            self.assertEqual(result.returncode, 1, result)
            self.assertFalse((self.root / "invalid").exists())
        for name in ["", "0hello", "a.b", "a/b", "用户"]:
            result = self.run_cli("invalid", "--name", name, "--user", "tester")
            self.assertEqual(result.returncode, 1, result)
            self.assertFalse((self.root / "invalid").exists())
        result = self.run_cli("--user", "tester", "--name", "named", "--", "-directory")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "-directory/named.mbt").exists())

    def test_strict_credentials_schema(self):
        credentials = Path(self.env["MOON_HOME"]) / "credentials.json"
        credentials.parent.mkdir()
        for index, document in enumerate([
            '{"username":"saved"}',
            '{"token":123,"username":"saved"}',
            '{"token":"secret","username":123}',
            '{"token":"secret","username":"saved",}',
            '{/*comment*/"token":"secret","username":"saved"}',
        ]):
            credentials.write_text(document)
            name = "invalid_" + str(index)
            result = self.run_cli(name, "-q")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Warning:", result.stderr)
            self.assertNotIn("secret", result.stderr)
            self.assertEqual((self.root / name / "README.mbt.md").read_text(encoding="utf-8"), "# username/" + name)
        for index, document in enumerate(['{"token":"secret"}', '{"token":"secret","username":null}']):
            credentials.write_text(document)
            name = "absent_" + str(index)
            result = self.run_cli(name, "-q")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual((self.root / name / "README.mbt.md").read_text(encoding="utf-8"), "# username/" + name)

    def test_home_lookup_and_unavailable_git(self):
        no_home = {k: v for k, v in self.env.items() if k not in ("MOON_HOME", "HOME", "USERPROFILE")}
        result = self.run_cli("fallback", "-q", env=no_home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("credentials directory", result.stderr)
        self.assertEqual((self.root / "fallback/README.mbt.md").read_text(encoding="utf-8"), "# username/fallback")
        # The runner command is absolute so an empty PATH affects only child Git.
        result = self.run_cli("no_git", "--user", "tester", "-q", env={**self.env, "PATH": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("git available", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue((self.root / "no_git/moon.mod").exists())
        self.assertFalse((self.root / "no_git/.git").exists())

    def test_parent_git_repository_is_reused(self):
        subprocess.run(["git", "init", str(self.root)], check=True, capture_output=True)
        result = self.run_cli("child", "--user", "tester", "-q")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertFalse((self.root / "child/.git").exists())
        self.assertTrue((self.root / ".git").exists())

    def test_symlink_destination_rejected_and_parent_link_followed(self):
        real = self.root / "real"
        real.mkdir()
        link = self.root / "link"
        try:
            link.symlink_to(real, target_is_directory=True)
        except OSError as error:
            self.skipTest("Creating directory symlinks is unavailable: " + str(error))
        for target in ["link", "link/"]:
            result = self.run_cli(target, "--user", "tester")
            self.assertEqual(result.returncode, 1, result)
            self.assertEqual(list(real.iterdir()), [])
        result = self.run_cli("link/child", "--user", "tester")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((real / "child/moon.mod").is_file())
        (self.root / "dangling").symlink_to(self.root / "missing", target_is_directory=True)
        result = self.run_cli("dangling", "--user", "tester")
        self.assertEqual(result.returncode, 1, result)
        self.assertFalse((self.root / "missing").exists())

    @unittest.skipIf(os.name == "nt", "Unix permission semantics")
    def test_permissions_respect_umask(self):
        result = subprocess.run([*COMMAND, "permissions", "--user", "tester"],
                                cwd=self.root, env=self.env, text=True, encoding="utf-8",
                                capture_output=True, umask=0o002)
        self.assertEqual(result.returncode, 0, result.stderr)
        dest = self.root / "permissions"
        self.assertEqual(dest.stat().st_mode & 0o777, 0o775)
        self.assertEqual((dest / "moon.mod").stat().st_mode & 0o777, 0o664)
        self.assertEqual((dest / ".githooks/pre-commit").stat().st_mode & 0o777, 0o755)

    def test_git_initialization_failure_keeps_generated_files(self):
        result = self.run_cli("git_failure", "--user", "tester", "-q", env={
            **self.env,
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "init.defaultBranch",
            "GIT_CONFIG_VALUE_0": "invalid branch name",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("Git initialization failed", result.stderr)
        self.assertEqual((self.root / "git_failure/README.mbt.md").read_text(encoding="utf-8"), "# tester/git_failure")

    def test_dotdot_resolution_does_not_bypass_destination_checks(self):
        existing = self.root / "existing"
        existing.mkdir()
        (existing / "unrelated.txt").write_text("keep me")
        result = self.run_cli("missing/../existing", "--user", "tester", "-q")
        self.assertEqual(result.returncode, 1, result)
        self.assertIn("not empty", result.stderr)
        self.assertEqual([p.name for p in existing.iterdir()], ["unrelated.txt"])
        self.assertEqual((existing / "unrelated.txt").read_text(encoding="utf-8"), "keep me")
        self.assertFalse((self.root / "missing").exists())
        empty = self.root / "empty"
        empty.mkdir()
        link = self.root / "link"
        try:
            link.symlink_to(empty, target_is_directory=True)
        except OSError:
            return
        result = self.run_cli("missing/../link", "--user", "tester", "-q")
        self.assertEqual(result.returncode, 1, result)
        self.assertEqual(list(empty.iterdir()), [])
        self.assertFalse((self.root / "missing").exists())

    @unittest.skipUnless(os.name == "nt", "Windows drive-relative path semantics")
    def test_windows_drive_relative_name(self):
        result = self.run_cli(self.root.drive + "drive_relative", "--user", "tester", "-q")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "drive_relative/README.mbt.md").read_text(encoding="utf-8"), "# tester/drive_relative")

    def test_help_and_argument_errors(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--user", result.stdout)
        self.assertIn("--name", result.stdout)
        self.assertEqual(result.stderr, "")
        for args in [(), ("--template", "repo"), ("hello", "--unknown")]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2, result)
                self.assertIn("Error:", result.stderr)
                self.assertEqual(list(self.root.iterdir()), [])

if __name__ == "__main__":
    unittest.main()
