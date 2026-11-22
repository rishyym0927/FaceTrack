#!/usr/bin/env python3
"""Keep FaceTrack's container logs on the host's disk across container recreation.

Docker deletes a container's log file when the container is removed, and every deploy recreates
every container, so earlier classes' logs vanish. This daemon (a systemd service, see
install_log_capture.sh) follows each container of the compose project with ``docker logs -f`` and
appends the lines to ``/var/log/facetrack/<service>.log``. logrotate bounds the size and age.

It only reads: it never starts, stops or reconfigures a container and never touches the app's
files. A line is stored as ``<container> <docker timestamp> <original line>``, which
``scripts/logs`` and ``scripts/session-report`` both understand.

Each container id is followed once, from the beginning of its log (or from where the previous
run of this daemon stopped, kept in the state file), so nothing is stored twice and nothing is
missed when the daemon restarts. A container that exited between two polls is still captured,
because discovery uses ``docker ps -a``. Python 3 standard library only.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path

PROJECT = "facetrack"
MIN_FREE_BYTES = 2 * 1024**3  # stop writing rather than fill the disk


def say(message):
    print(message, file=sys.stderr, flush=True)


def stamp_key(text):
    """Orderable key of an RFC 3339 timestamp with up to nanosecond precision."""
    base, _, rest = text.rstrip("Z").partition(".")
    return base, rest.ljust(9, "0")[:9]


class Capture:
    def __init__(self, out_dir, state_path, project=PROJECT, docker="docker", poll=5.0, follow=True):
        self.follow_logs = follow
        self.out_dir, self.state_path = Path(out_dir), Path(state_path)
        self.project, self.docker, self.poll = project, docker, poll
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.threads = {}  # container id -> thread
        self.procs = {}
        self.last = {}  # container id -> last stored docker timestamp
        self.low_disk_reported = False
        self.load_state()

    # state: container id -> last timestamp stored -------------------------------------------
    def load_state(self):
        try:
            data = json.loads(self.state_path.read_text())
            self.last = {k: v for k, v in data.items() if isinstance(v, str)}
        except (OSError, ValueError):
            self.last = {}

    def save_state(self, alive=None):
        with self.lock:
            if alive is not None:
                self.last = {k: v for k, v in self.last.items() if k in alive}
            snapshot = dict(self.last)
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            temp = self.state_path.with_suffix(".tmp")
            temp.write_text(json.dumps(snapshot))
            temp.replace(self.state_path)
        except OSError as error:
            say(f"state not saved: {type(error).__name__}")

    # discovery ---------------------------------------------------------------------------------
    def containers(self):
        """(id, name, service) of every container of the project, running or not."""
        result = subprocess.run(
            [
                self.docker, "ps", "-a",
                "--filter", f"label=com.docker.compose.project={self.project}",
                "--format", '{{.ID}}\t{{.Names}}\t{{.Label "com.docker.compose.service"}}',
            ],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError("docker ps failed")
        found = []
        for line in result.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[0]:
                found.append((parts[0], parts[1], parts[2] or parts[1]))
        return found

    # following one container ---------------------------------------------------------------------
    def follow(self, cid, name, service):
        command = [self.docker, "logs", "--timestamps"] + (["--follow"] if self.follow_logs else [])
        since = self.last.get(cid)
        if since:
            command += ["--since", since]
        command.append(cid)
        try:
            proc = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                errors="replace", bufsize=1,
            )
        except OSError as error:
            say(f"{name}: cannot start docker logs: {type(error).__name__}")
            return
        self.procs[cid] = proc
        target = self.out_dir / f"{service}.log"
        try:
            for raw in proc.stdout:
                if self.stop.is_set():
                    break
                line = raw.rstrip("\n")
                stamp, _, content = line.partition(" ")
                if not stamp[:4].isdigit():  # a line without a docker timestamp: keep it anyway
                    stamp, content = "", line
                if stamp and since and stamp_key(stamp) <= stamp_key(since):
                    continue  # --since is inclusive: this one is already stored
                if self.write(target, f"{name} {stamp} {content}\n" if stamp else f"{name} {content}\n") and stamp:
                    with self.lock:
                        self.last[cid] = stamp
        finally:
            proc.terminate() if proc.poll() is None else None
            proc.wait()
            self.save_state()

    def write(self, target, text):
        try:
            if shutil.disk_usage(self.out_dir).free < MIN_FREE_BYTES:
                if not self.low_disk_reported:
                    say("disk almost full: log capture paused")
                    self.low_disk_reported = True
                return False
            self.low_disk_reported = False
            with self.lock, open(target, "a", encoding="utf-8", errors="replace") as handle:
                handle.write(text)
            return True
        except OSError as error:
            say(f"write failed: {type(error).__name__}")
            return False

    # main loop -------------------------------------------------------------------------------------
    def poll_once(self):
        try:
            found = self.containers()
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            say(f"docker unavailable: {type(error).__name__}")
            return
        alive = {cid for cid, _, _ in found}
        for cid, name, service in found:
            thread = self.threads.get(cid)
            if thread is None:
                # first sight of this container id; once its stream ends it is not reopened
                # unless it is still running (docker restarts a container under the same id).
                self.start(cid, name, service)
            elif not thread.is_alive() and self.running(cid):
                self.start(cid, name, service)
        for cid in [c for c in self.threads if c not in alive]:
            self.threads.pop(cid, None)
            self.procs.pop(cid, None)
        self.save_state(alive)

    def running(self, cid):
        result = subprocess.run(
            [self.docker, "inspect", "--format", "{{.State.Running}}", cid],
            capture_output=True, text=True, timeout=30,
        )
        return result.stdout.strip() == "true"

    def start(self, cid, name, service):
        thread = threading.Thread(
            target=self.follow, args=(cid, name, service), name=f"follow-{name}", daemon=True
        )
        self.threads[cid] = thread
        thread.start()

    def run(self):
        self.out_dir.mkdir(parents=True, exist_ok=True)
        say(f"capturing {self.project} container logs to {self.out_dir}")
        while not self.stop.is_set():
            self.poll_once()
            self.stop.wait(self.poll)
        self.shutdown()

    def shutdown(self):
        self.stop.set()
        for proc in list(self.procs.values()):
            if proc.poll() is None:
                proc.terminate()
        for thread in list(self.threads.values()):
            thread.join(timeout=5)
        self.save_state()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", default="/var/log/facetrack")
    parser.add_argument("--state", default="/var/lib/facetrack-log-capture/state.json")
    parser.add_argument("--project", default=PROJECT)
    parser.add_argument("--poll", type=float, default=5.0)
    parser.add_argument("--once", action="store_true", help="capture what exists now and exit")
    args = parser.parse_args(argv)
    os.umask(0o027)
    capture = Capture(args.out, args.state, args.project, poll=args.poll, follow=not args.once)
    signal.signal(signal.SIGTERM, lambda *_: capture.stop.set())
    signal.signal(signal.SIGINT, lambda *_: capture.stop.set())
    if args.once:
        capture.out_dir.mkdir(parents=True, exist_ok=True)
        capture.poll_once()
        for thread in list(capture.threads.values()):
            thread.join(timeout=120)
        capture.save_state()
        return 0
    capture.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
