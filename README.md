# Research-site runtime

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
`dependency-groups.web` group.  That locked environment is used for rendering
and any Panel apps.

Panel apps are optional.  Register stable public names in
`web/panel_apps.toml`:

```toml
[apps]
dashboard = "web/apps/dashboard.py"
```

The app is then available at `/panel/dashboard`; source filenames do not
become public URLs. MkDocs pages can embed that URL in an iframe. A locked web
environment is needed only when an app requires dependencies beyond the
runtime's MkDocs, Material, Panel, and Bokeh fallback.

Every pushed Git revision causes a locked environment refresh (when present),
an MkDocs build, and a Panel replacement after validation. Default dependency
groups (such as `dev`) are not installed; the project and `web` group are.
An image rebuild is needed only when this generic runtime changes.

Targets are trusted executable code, including MkDocs plugins and build hooks.
TLS and any access control belong at the deployment's reverse proxy. The
runtime permits WebSocket origins for embedding behind that proxy. Startup
requires a successful Git sync and build, even when volumes contain an older
release.

## Build

`./build_local.sh [tag]` builds for the current Docker host.  For a registry,
`./build_publish.sh REGISTRY/IMAGE:TAG` publishes a Linux amd64+arm64 manifest.
