#!/usr/bin/env bash
# Start only after the initial checkout has rendered successfully.
set -Eeuo pipefail

: "${GITSYNC_REPO:?GITSYNC_REPO is required}"
: "${GITSYNC_REF:?GITSYNC_REF is required}"
mkdir -p /content /site /cache
rm -f /run/published-revision /run/panel.pid /run/nginx.pid

sync_args=(
  "--repo=$GITSYNC_REPO"
  "--ref=$GITSYNC_REF"
  "--root=/content"
  "--link=current"
  "--period=${GITSYNC_PERIOD:-60s}"
  # Keep snapshots available long enough for the refresh hook to copy them.
  "--stale-worktree-timeout=1h"
)

cleanup() {
  local pid
  for pid in "${nginx_pid:-}" "${sync_pid:-}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
  done
  if [[ -r /run/panel.pid ]]; then
    read -r pid </run/panel.pid || true
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

git-sync "${sync_args[@]}" --one-time
/runtime/refresh.sh
nginx -c /runtime/nginx.conf -g 'daemon off;' &
nginx_pid=$!

git-sync "${sync_args[@]}" --exechook-command=/runtime/refresh.sh --exechook-timeout=10m &
sync_pid=$!
# A failed web server or synchronizer should stop the container so Compose can
# restart it rather than silently serving stale content indefinitely.
wait -n "$nginx_pid" "$sync_pid"
