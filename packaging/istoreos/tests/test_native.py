"""Host-side regression checks; never mutate the host system or contact a device."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def shell(code, *args):
    return subprocess.run(["sh", "-c", code, "test", *args], text=True, capture_output=True)


class PlatformTests(unittest.TestCase):
    def call(self, function, value):
        return shell('. "$1"; "$2" "$3"', str(ROOT / "scripts/platform.sh"), function, value)

    def test_supported_architectures(self):
        for arch, asset in [("x86_64", "x64-baseline-musl"), ("aarch64", "arm64-musl")]:
            result = self.call("detect_target", arch)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), asset)
        for arch in ["armv7l", "mips", "i686"]:
            self.assertNotEqual(self.call("detect_target", arch).returncode, 0)

    def test_input_boundaries(self):
        for function, good, bad in [
            ("valid_release_repo", ["agentx1boss/opencode", "anomalyco/opencode"],
             ["", "other/opencode", "agentx1boss/opencode/../../other", "agentx1boss/opencode;id"]),
            ("valid_ipv4", ["192.168.17.10", "127.0.0.1"],
             ["", "0.0.0.0", "256.1.2.3", "1.2.3", "1.2.3.4;id", "1.2.3.-1", "1.2.3.4\n1.2.3.4"]),
            ("valid_data_path", ["/mnt/sda1/opencode", "/opt/opencode"],
             ["/", "/etc/opencode", "/mnt/../etc", "/mnt/a b", "/mnt/a/", "/mnt//a"]),
            ("valid_version", ["1.2.3"], ["", ".1", "1.", "1;id", "v1.2"]),
        ]:
            for value in good:
                self.assertEqual(self.call(function, value).returncode, 0, value)
            for value in bad:
                self.assertNotEqual(self.call(function, value).returncode, 0, value)

    def test_bad_cli_rejected_before_host_mutation(self):
        result = subprocess.run(["sh", str(ROOT / "scripts/install.sh"),
                                 "--bind", "0.0.0.0", "--data", "/mnt/test"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IPv4", result.stderr)


class ServiceTests(unittest.TestCase):
    def run_service(self, password="testsecret", disk=True):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "data"
            if disk:
                (data / "bin").mkdir(parents=True)
                (data / "workspace").mkdir()
                binary = data / "bin/opencode"
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
            config = Path(tmp) / "service.conf"
            config.write_text(f"OPENCODE_DATA='{data}'\nOPENCODE_BIND='192.168.17.10'\n"
                              f"OPENCODE_PORT='4096'\nOPENCODE_SERVER_PASSWORD='{password}'\n")
            # Replace only the fixed config pathname; keep production logic intact.
            source = (ROOT / "files/opencode.init").read_text().replace(
                "/etc/opencode/service.conf", str(config))
            script = Path(tmp) / "init"
            script.write_text(source)
            result = shell('''
procd_open_instance() { echo open; }
procd_set_param() { printf '%s\\n' "$@"; }
procd_close_instance() { echo close; }
. "$1"
start_service
''', str(script))
            return result, str(data)

    def test_procd_drops_user_and_preserves_state_paths(self):
        result, data = self.run_service()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("user\nopencode\ngroup\nopencode\n", result.stdout)
        self.assertIn("no_new_privs\n1\n", result.stdout)
        self.assertIn(f"HOME={data}/home", result.stdout)
        self.assertIn(f"XDG_DATA_HOME={data}/state/share", result.stdout)
        self.assertIn("OPENCODE_SERVER_PASSWORD=testsecret", result.stdout)
        self.assertIn(f"command\n/usr/libexec/opencode-run\n{data}\n192.168.17.10\n4096", result.stdout)

    def test_missing_password_or_disk_refuses_start(self):
        for options in [{"password": ""}, {"disk": False}]:
            result, _ = self.run_service(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("open", result.stdout)

    def test_launcher_enters_workspace_and_passes_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            (data / "bin").mkdir()
            (data / "workspace").mkdir()
            binary = data / "bin/opencode"
            binary.write_text('#!/bin/sh\npwd\nprintf "%s\\n" "$@"\n')
            binary.chmod(0o755)
            result = subprocess.run(["sh", str(ROOT / "files/opencode-run"),
                                     tmp, "192.168.17.10", "4096"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.splitlines(),
                             [str(data / "workspace"), "web", "--hostname",
                              "192.168.17.10", "--port", "4096"])


if __name__ == "__main__":
    unittest.main()
