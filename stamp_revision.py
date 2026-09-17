"""Add build provenance to Material-rendered HTML without target configuration."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def stamp(site_dir: Path, revision: str) -> None:
    """Insert one short revision label into every rendered Material footer."""
    footer_marker = "</footer>"
    credit = re.compile(
        r'(Made with\s*<a href="https://squidfunk.github.io/mkdocs-material/"'
        r' target="_blank" rel="noopener">\s*Material for MkDocs\s*</a>)'
        r'(\s*</div>)'
    )
    pages = list(site_dir.rglob("*.html"))
    if not pages:
        raise ValueError("MkDocs did not render any HTML pages")
    for page in pages:
        html = page.read_text()
        if html.count(footer_marker) != 1:
            raise ValueError(f"expected one Material footer in {page}")
        html, replacements = credit.subn(
            r'\1<span aria-hidden="true" style="display:inline-block; margin:0 0.45rem; '
            r'vertical-align:middle; font-size:0.75em">•</span>'
            r'<span style="opacity:0.7; white-space:nowrap">'
            f"Revision {revision[:12]}</span>\\2",
            html,
            count=1,
        )
        if replacements != 1:
            raise ValueError(f"expected Material credit in {page}")
        page.write_text(html)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site_dir", type=Path)
    parser.add_argument("revision")
    args = parser.parse_args()
    try:
        stamp(args.site_dir, args.revision)
    except (OSError, ValueError) as error:
        parser.exit(1, f"revision stamping failed: {error}\n")


if __name__ == "__main__":
    main()
