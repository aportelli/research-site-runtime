"""Schedule target jobs, asking refresh.sh to publish each completed run."""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

from jobs import load_jobs


def main() -> None:
    due: dict[str, float] = {}
    while True:
        try:
            jobs = load_jobs(Path("/site/current/source"))
        except (OSError, ValueError, TypeError, SyntaxError) as error:
            print(f"[scheduler] invalid job manifest: {error}", flush=True)
            time.sleep(60)
            continue

        now = time.monotonic()
        due = {name: due.get(name, now + job.period_seconds) for name, job in jobs.items()}
        for name, job in jobs.items():
            if now < due[name]:
                continue
            print(f"[scheduler] job {name} is due", flush=True)
            command = ["/runtime/refresh.sh", "--job", name]
            if job.restart_panel:
                command.append("--restart-panel")
            subprocess.run(command, check=False)
            due[name] = time.monotonic() + job.period_seconds

        wait = min((due[name] - time.monotonic() for name in jobs), default=60.0)
        time.sleep(max(1.0, min(wait, 60.0)))


if __name__ == "__main__":
    main()
