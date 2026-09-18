"""Load and validate periodic target jobs."""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Job:
    name: str
    script: Path
    outputs: tuple[Path, ...]
    restart_panel: bool
    period_seconds: float
    timeout_seconds: float


_DURATION = re.compile(r"(?P<value>[0-9]+(?:\.[0-9]+)?)(?P<unit>[smhd])")
_NAME = re.compile(r"[a-z0-9][a-z0-9-]*")


def parse_duration(value: object, field: str) -> float:
    """Parse a compact duration such as ``30s``, ``1h30m``, or ``2d``."""
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty duration")
    seconds = 0.0
    offset = 0
    factors = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    for match in _DURATION.finditer(value):
        if match.start() != offset:
            raise ValueError(f"{field} must use units s, m, h, or d")
        seconds += float(match["value"]) * factors[match["unit"]]
        offset = match.end()
    if offset != len(value) or seconds <= 0:
        raise ValueError(f"{field} must be a positive duration")
    return seconds


def load_jobs(content: Path) -> dict[str, Job]:
    """Return the target's jobs, rejecting unsafe or incomplete declarations."""
    content = content.resolve()
    manifest = content / "web/jobs.toml"
    if not manifest.is_file():
        return {}
    declared = tomllib.loads(manifest.read_text()).get("jobs")
    if not isinstance(declared, dict):
        raise TypeError("jobs.toml must contain a [jobs] table")

    jobs = {}
    owned_outputs: list[tuple[str, Path]] = []
    for name, config in declared.items():
        if not isinstance(name, str) or not _NAME.fullmatch(name):
            raise ValueError("job names must contain lowercase letters, digits, and hyphens")
        if not isinstance(config, dict):
            raise TypeError(f"job {name!r} must be a table")
        script = config.get("script")
        if not isinstance(script, str) or Path(script).is_absolute():
            raise ValueError(f"job {name!r} must name a repository-relative Python file")
        path = (content / script).resolve()
        if path.suffix != ".py" or not path.is_relative_to(content) or not path.is_file():
            raise ValueError(f"job {name!r} must name a Python file inside the target")
        unknown = set(config) - {"script", "outputs", "restart_panel", "period", "timeout"}
        if unknown:
            raise ValueError(f"job {name!r} has unknown fields: {', '.join(sorted(unknown))}")
        restart_panel = config.get("restart_panel", False)
        if not isinstance(restart_panel, bool):
            raise TypeError(f"job {name!r} restart_panel must be true or false")
        compile(path.read_bytes(), str(path), "exec")
        outputs = config.get("outputs", [])
        if not isinstance(outputs, list) or not all(isinstance(output, str) for output in outputs):
            raise TypeError(f"job {name!r} outputs must be a list of paths")
        resolved_outputs = tuple((content / output).resolve() for output in outputs)
        if any(
            Path(output).is_absolute()
            or resolved_output == content
            or not resolved_output.is_relative_to(content)
            for output, resolved_output in zip(outputs, resolved_outputs)
        ):
            raise ValueError(f"job {name!r} outputs must stay inside the target")
        if len(set(resolved_outputs)) != len(resolved_outputs):
            raise ValueError(f"job {name!r} outputs must not repeat paths")
        for output in resolved_outputs:
            for owner, owned in owned_outputs:
                if output.is_relative_to(owned) or owned.is_relative_to(output):
                    raise ValueError(
                        f"job {name!r} output {str(output.relative_to(content))!r} "
                        f"overlaps job {owner!r} output {str(owned.relative_to(content))!r}"
                    )
            owned_outputs.append((name, output))
        jobs[name] = Job(
            name=name,
            script=path,
            outputs=resolved_outputs,
            restart_panel=restart_panel,
            period_seconds=parse_duration(config.get("period"), f"job {name!r} period"),
            timeout_seconds=parse_duration(
                config.get("timeout", "10m"), f"job {name!r} timeout"
            ),
        )
    return jobs
