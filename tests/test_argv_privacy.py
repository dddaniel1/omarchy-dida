"""Regression coverage for keeping user content out of process command lines.

Linux exposes `/proc/<pid>/cmdline` to every local user. The QML helper therefore
uses the fixed `request` verb and sends the real argv as JSON on stdin.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
QML = ROOT / "qml"


class RequestTransportTest(unittest.TestCase):
    def test_secret_text_is_not_in_cmdline_while_request_waits_for_stdin(self):
        secret = "private task title 7f3c9a"
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "bin" / "ticktick"), "request"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self._stop, process)

        # The helper is blocked in json.load(), so this is the exact window in
        # which another local user could read /proc/<pid>/cmdline.
        deadline = time.monotonic() + 2
        cmdline = ""
        while time.monotonic() < deadline:
            path = pathlib.Path(f"/proc/{process.pid}/cmdline")
            if path.exists():
                cmdline = path.read_bytes().replace(b"\0", b" ").decode(errors="replace")
                if "request" in cmdline:
                    break
            time.sleep(0.01)

        self.assertIn("request", cmdline)
        self.assertNotIn(secret, cmdline)

        stdout, stderr = process.communicate(
            json.dumps({"argv": ["parse", f"{secret} tomorrow"]}) + "\n",
            timeout=5,
        )
        self.assertEqual(process.returncode, 0, stderr)
        payload = json.loads(stdout)
        self.assertIs(payload["ok"], True)
        self.assertEqual(payload["title"], secret)

    def _stop(self, process: subprocess.Popen) -> None:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


class QmlTransportTest(unittest.TestCase):
    def test_qml_helper_commands_never_carry_user_content(self):
        """Only the fixed transport and token login may build a helper command.

        Everything else must call HelperProcess.startRequest(), which sends argv on
        stdin. This catches a new call site even when its text is assembled at runtime.
        """
        offenders = []
        for path in sorted(QML.glob("*.qml")):
            source = path.read_text(encoding="utf-8")
            for match in re.finditer(r"command\s*[:=]\s*\[(.*?)\]", source, re.S):
                body = match.group(1)
                if "python3" not in body:
                    continue
                fixed = (
                    path.name == "HelperProcess.qml"
                    and '["python3", helperPath, "request"]' in match.group(0)
                )
                login = (
                    path.name == "Service.qml"
                    and '["python3", helperPath, "login"]' in match.group(0)
                )
                if not (fixed or login):
                    offenders.append(f"{path.name}: {' '.join(match.group(0).split())}")
        self.assertEqual(offenders, [], "user content can reach a process command line")

    def test_service_routes_task_content_through_the_stdin_transport(self):
        source = (QML / "Service.qml").read_text(encoding="utf-8")
        for call in (
            'startRequest(["parse", pending])',
            'startRequest(["manage"].concat(next.args))',
            "startRequest(_queue.shift())",
        ):
            with self.subTest(call=call):
                self.assertIn(call, source)


if __name__ == "__main__":
    unittest.main()
