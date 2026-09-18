# Reuse the uv binary without inheriting its larger image at runtime.
FROM ghcr.io/astral-sh/uv:0.10.10 AS uv
# git-sync is pinned independently of the Python runtime.
FROM registry.k8s.io/git-sync/git-sync:v4.4.0 AS git-sync

# Build the MkDocs-only fallback environment into a self-contained virtualenv.
FROM python:3.13-slim AS fallback
COPY --from=uv /uv /uvx /bin/
WORKDIR /opt/fallback
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

# The final image contains only generic serving and refresh tooling.
FROM python:3.13-slim
RUN apt-get update \
    && apt-get install --no-install-recommends -y bash ca-certificates curl git nginx util-linux \
    && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /uvx /bin/
COPY --from=git-sync /git-sync /usr/local/bin/git-sync
COPY --from=fallback /opt/fallback /opt/fallback
COPY entrypoint.sh refresh.sh nginx.conf prepare_apps.py jobs.py run_jobs.py scheduler.py serve_apps.py stamp_revision.py /runtime/
RUN chmod +x /runtime/entrypoint.sh /runtime/refresh.sh
# Credentials and all content are supplied at deployment time.
ENV GITSYNC_PERIOD=60s \
    GIT_TERMINAL_PROMPT=0
VOLUME ["/cache", "/content", "/site"]
EXPOSE 8080
ENTRYPOINT ["/runtime/entrypoint.sh"]
