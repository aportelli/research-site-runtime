"""Run Panel's server, treating recorded warm-up failures as startup errors."""

from __future__ import annotations

import argparse
from collections.abc import Mapping
from typing import Any

from bokeh.application import Application
from panel.command.serve import Serve


class CheckedServe(Serve):
    def warm_applications(
        self, applications: Mapping[str, Application], *args: Any, **kwargs: Any
    ) -> None:
        # Panel/Bokeh can record a script exception and still serve HTTP 200.
        # Reuse normal warm-up, then require every script handler to succeed.
        super().warm_applications(applications, *args, **kwargs)
        for route, application in applications.items():
            for handler in application.handlers:
                if handler.failed:
                    raise RuntimeError(
                        f"{route}: {handler.error_detail or handler.error}"
                    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    command = CheckedServe(parser=parser)
    args = parser.parse_args()
    args.warm = True
    result = command.invoke(args)
    if result is False:
        parser.exit(1)


if __name__ == "__main__":
    main()
