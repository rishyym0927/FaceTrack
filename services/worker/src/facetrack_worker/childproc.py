"""Bootstrap for the per-job child process.

Kept free of heavy imports on purpose: a spawned child imports the module of its entry point
before it does anything else, and the executor module pulls in Celery, kombu and httpx (about
0.16 s on a fast Mac, noticeably more on the CPU-starved VM) that a child never uses.
"""

import os
import threading
import time


def watch_parent(parent_pid, interval=2.0, exit_code=1):
    """Exit when the process that spawned this one is gone.

    A child orphaned by a killed worker would otherwise keep decoding and embedding for minutes,
    taking CPU from the next jobs, only to write its result into a closed pipe.
    """

    def run():
        while True:
            time.sleep(interval)
            if os.getppid() != parent_pid:
                os._exit(exit_code)

    threading.Thread(target=run, daemon=True, name="parent-watch").start()


def child_entry(parent_pid, target, *args):
    # Own process group, so ffmpeg and any other grandchild die with the child.
    try:
        os.setpgid(0, 0)
    except (AttributeError, OSError):
        pass
    watch_parent(parent_pid)
    target(*args)
