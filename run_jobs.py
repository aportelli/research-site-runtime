"""Run selected periodic target jobs in a target web environment."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path

from jobs import load_jobs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("content", type=Path)
    parser.add_argument("python", type=Path)
    parser.add_argument("--restore-from", type=Path)
    parser.add_argument("names", nargs="*")
    args = parser.parse_args()
    jobs = load_jobs(args.content)
    selected = args.names or list(jobs)
    unknown = set(selected) - jobs.keys()
    if unknown:
        parser.exit(2, f"unknown jobs: {', '.join(sorted(unknown))}\n")

    if args.restore_from:
        for job in jobs.values():
            for output in job.outputs:
                relative = output.relative_to(args.content.resolve())
                previous = args.restore_from / relative
                destination = args.content / relative
                if destination.is_dir():
                    shutil.rmtree(destination)
                elif destination.exists() or destination.is_symlink():
                    destination.unlink()
                if previous.is_dir():
                    shutil.copytree(previous, destination)
                elif previous.is_file():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(previous, destination)

    environment = os.environ | {"SITE_CACHE": "/cache", "SITE_CONTENT": str(args.content)}
    for name in selected:
        job = jobs[name]
        print(f"[jobs] running {name}", flush=True)
        try:
            subprocess.run(
                [str(args.python), str(job.script)],
                cwd=args.content,
                env=environment,
                stdin=subprocess.DEVNULL,
                check=True,
                timeout=job.timeout_seconds,
            )
        except subprocess.TimeoutExpired:
            parser.exit(1, f"job {name!r} timed out after {job.timeout_seconds:g}s\n")
        except subprocess.CalledProcessError as error:
            parser.exit(error.returncode or 1, f"job {name!r} failed\n")


if __name__ == "__main__":
    main()
