from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
from threading import Thread
from unittest import TestCase, main
from unittest.mock import patch

from activate_web import APPS, ASSETS, activate


class WebReleaseTests(TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write_build(self.root, "previous")
        self.stage = self.root / "release-next"

    def write_build(self, root, version):
        for app in APPS:
            directory = root / app
            directory.mkdir(parents=True)
            for asset in ASSETS:
                (directory / asset).write_text(f"{version} {app} {asset}")

    def assert_live(self, version):
        for app in APPS:
            self.assertEqual(
                (self.root / app / "index.html").read_text(),
                f"{version} {app} index.html",
            )

    def test_incomplete_transfer_does_not_touch_live_directories(self):
        self.write_build(self.stage, "next")
        (self.stage / "student" / "main.dart.js").unlink()
        with self.assertRaises(FileNotFoundError):
            activate(self.root, self.stage, "https://unused.test")
        self.assert_live("previous")
        self.assertFalse((self.root / "web-current").exists())

    def test_failed_student_smoke_restores_both_apps(self):
        self.write_build(self.stage, "next")

        def check_release(url, expected, release):
            self.assert_live("next")
            self.assertEqual(set(expected), {(app, asset) for app in APPS for asset in ASSETS})
            raise RuntimeError("Student smoke check failed")

        with patch("activate_web.smoke", side_effect=check_release):
            with self.assertRaisesRegex(RuntimeError, "Student"):
                activate(self.root, self.stage, "https://unused.test")
        self.assert_live("previous")

    def test_success_switches_both_apps_and_retains_previous_build(self):
        self.write_build(self.stage, "next")
        handler = partial(SimpleHTTPRequestHandler, directory=self.root)
        with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                activate(self.root, self.stage, f"http://127.0.0.1:{server.server_port}")
            finally:
                server.shutdown()
                thread.join()
        self.assert_live("next")
        self.assertEqual(os.readlink(self.root / "web-current"), self.stage.name)
        previous, = self.root.glob("release-legacy-*")
        self.assertEqual((previous / "teacher" / "index.html").read_text(), "previous teacher index.html")


if __name__ == "__main__":
    main()
