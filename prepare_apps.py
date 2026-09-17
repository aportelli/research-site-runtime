"""Validate the target contract and create aliases in a fresh release."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path


def prepare(content: Path, aliases: Path) -> None:
    """Reject incomplete targets before dependency installation or publication."""
    content = content.resolve()
    if not (content / "web/mkdocs.yml").is_file():
        raise ValueError("target must contain web/mkdocs.yml")
    project = content / "pyproject.toml"
    locked = (content / "uv.lock").is_file()
    if project.is_file() != locked:
        raise ValueError("pyproject.toml and uv.lock must appear together")
    if locked:
        metadata = tomllib.loads(project.read_text())
        if "web" not in metadata.get("dependency-groups", {}):
            raise ValueError("locked targets must define dependency-groups.web")

    manifest = content / "web/panel_apps.toml"
    apps = tomllib.loads(manifest.read_text()).get("apps") if manifest.is_file() else {}
    if not isinstance(apps, dict):
        raise TypeError("panel_apps.toml must contain an [apps] table")
    aliases.mkdir()
    for route, source in apps.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", route):
            raise ValueError(
                "app routes must contain lowercase letters, digits, and hyphens"
            )
        if not isinstance(source, str) or Path(source).is_absolute():
            raise ValueError(
                f"app {route!r} must name a repository-relative Python file"
            )
        path = (content / source).resolve()
        if (
            path.suffix != ".py"
            or not path.is_relative_to(content)
            or not path.is_file()
        ):
            raise ValueError(f"app {route!r} must name a Python file inside the target")
        # Symlinks preserve __file__.resolve() for apps locating their own data.
        compile(path.read_bytes(), str(path), "exec")
        (aliases / f"{route}.py").symlink_to(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("content", type=Path)
    parser.add_argument("aliases", type=Path)
    args = parser.parse_args()
    try:
        prepare(args.content, args.aliases)
    except (OSError, ValueError, TypeError, SyntaxError) as error:
        parser.exit(1, f"target validation failed: {error}\n")


if __name__ == "__main__":
    main()
