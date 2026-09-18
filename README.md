# Research-site runtime

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

This image serves a research repository that is refreshed from Git.  It contains
only the generic runtime; documentation, data, Python code and Panel apps stay
in the target repository.

## Run

Set the required variables, then run `docker compose up --build`.

- `GITSYNC_REPO` (required): HTTPS URL of the target Git repository;
- `GITSYNC_REF` (required): branch, tag, or commit to serve;
- `GITSYNC_PERIOD` (optional, default `60s`): interval between Git polls;
- `GITSYNC_USERNAME` (optional): Gitea user or deploy-token username;
- `GITSYNC_PASSWORD` (optional): read-only token or password for Git access.

For a private Gitea repository, set the credentials as Portainer stack
environment variables. They are passed to git-sync and are never written into
the checked-out remote URL.

The Compose example uses these persistent container paths, each of which can be
overridden with a host or named volume:

- `/content`: Git checkout;
- `/site`: rendered releases and target virtual environments;
- `/cache`: application cache data (if necessary).

## Target repository requirements

Every target must contain `web/mkdocs.yml`, use Material for MkDocs, and contain
its documentation tree (normally `web/docs/`). The runtime injects a short Git
revision into rendered Material footers after each build.
A target may omit Python dependency metadata, in which case the image's
MkDocs, Material, Panel, and Bokeh fallback is used. If it supplies either root
`pyproject.toml` or `uv.lock`, it must supply both and define a
`dependency-groups.web` group.  That uv environment is used for rendering
and any Panel apps.

Targets are trusted executable code, including MkDocs plugins and build hooks.
TLS and any access control belong at the deployment's reverse proxy. The
runtime permits WebSocket origins for embedding behind that proxy. Startup
requires a successful Git sync and build, even when volumes contain an older
release.

## Panel apps

Optional [Panel](https://panel.holoviz.org/) apps can be run in the container. they should be
registered in `web/panel_apps.toml`:

```toml
[apps]
dashboard = "web/apps/dashboard.py"
```

The app is then available at `/panel/dashboard`; source filenames do not
become public URLs. MkDocs pages can embed that URL in an iframe.

## Periodic jobs

Targets can run Python jobs before rendering the first deployment and at
regular intervals thereafter. Declare them in `web/jobs.toml`:

```toml
[jobs.update-content]
script = "web/scripts/update_content.py"
outputs = ["web/docs/generated.md"] # files or directories written by this job
period = "1h"
timeout = "5m" # optional; defaults to 10m
# restart_panel = true # optional; defaults to false
```

Job names use lowercase letters, digits, and hyphens. Durations support `s`,
`m`, `h`, and `d` units (including combinations such as `1h30m`). Scripts run
from the repository snapshot with the same locked `web` environment used by
MkDocs and Panel. Jobs receive these environment variables:

- `SITE_CONTENT`: the temporary repository snapshot that becomes the next
  release. Write generated page sources here, for example
  `Path(os.environ["SITE_CONTENT"], "web/docs/generated.md").write_text("# Updated\n")`.
- `SITE_CACHE`: the persistent `/cache` volume. Keep data that should survive
  between runs here, for example
  `cache = Path(os.environ["SITE_CACHE"], "api-response.json")`.

A job can write generated source files inside `SITE_CONTENT`; its completed
run is then rendered and atomically published. Declare those paths in
`outputs` so periodic runs preserve another job's generated content. Every job
also runs when a new Git revision is deployed, so the first release never
exposes content before its declared jobs have run.

Scheduled jobs rebuild and publish the static site without restarting Panel
apps by default, preserving active Panel sessions. Set `restart_panel = true`
for a job that also needs to replace Panel apps. Panel apps are always replaced
after a Git revision is deployed.

## Update sequence

When Git detects a new revision, the runtime:

1. snapshots the checkout and validates the Panel and job manifests;
2. creates the target's locked `web` uv environment when supplied, otherwise uses
   the fallback environment;
3. runs every declared job;
4. renders MkDocs and validates replacement Panel apps;
5. atomically switches Nginx to the matching static site and Panel process;
6. retires the previous Panel process after the replacement is live.

Default dependency groups are not installed by uv; only the project
and `web` group are. An image rebuild is needed only when this generic runtime
changes.

## Build the container image

- `./build_local.sh [tag]` builds for the current Docker host.  For a registry,
- `./build_publish.sh REGISTRY/IMAGE:TAG` publishes a Linux amd64+arm64 manifest.
