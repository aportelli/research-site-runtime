#!/usr/bin/env bash
# Prepare an isolated release, then switch Nginx to the validated process.
set -Eeuo pipefail

# 1. Serialize refresh hooks: Git updates can arrive while a build is running.
exec 9>/run/refresh.lock
flock 9

# 2. Identify the Git-synced revision and skip an already-published one.
checkout="$(readlink -f /content/current)"
revision="$(git -C "$checkout" rev-parse HEAD)"
[[ "$(cat /run/published-revision 2>/dev/null || true)" != "$revision" ]] || exit 0

# 3. Create an isolated candidate release and preserve the current one on error.
mkdir -p /site/releases
release="$(mktemp -d /site/releases/release.XXXXXXXX)"
previous=""
[[ ! -L /site/current ]] || previous="$(readlink -f /site/current)"
candidate_pid=""
published=false
cleanup() {
  if [[ "$published" = false ]]; then
    [[ -z "$candidate_pid" ]] || kill "$candidate_pid" 2>/dev/null || true
    # Restore the old symlink if Nginx rejected the candidate configuration.
    if [[ "$(readlink -f /site/current 2>/dev/null || true)" = "$release" ]]; then
      if [[ -n "$previous" ]]; then
        ln -sfn "$previous" /site/current.next
        mv -Tf /site/current.next /site/current
      else
        rm -f /site/current
      fi
    fi
    rm -rf -- "$release"
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# 4. Snapshot the checkout, then validate and alias any declared Panel apps.
# All following work uses this stable copy while git-sync continues polling.
mkdir "$release/source"
cp -a "$checkout/." "$release/source/"
content="$release/source"
python /runtime/prepare_apps.py "$content" "$release/apps"

# 5. Select the target's locked web environment or the image fallback.
venv=/opt/fallback/.venv
if [[ -f "$content/uv.lock" ]]; then
  venv="$release/venv"
  UV_PROJECT_ENVIRONMENT="$venv" uv sync --project "$content" \
    --frozen --no-default-groups --group web
fi
cd "$content"
export PYTHONPATH="$content${PYTHONPATH:+:$PYTHONPATH}"

# 6. Render the static site privately inside the candidate release.
"$venv/bin/mkdocs" build --config-file web/mkdocs.yml --site-dir "$release/html"
"$venv/bin/python" /runtime/stamp_revision.py "$release/html" "$revision"
# mktemp creates mode 700. Only rendered content is exposed by Nginx.
chmod a+rx "$release"
chmod -R a+rX "$release/html"

# 7. Start and probe a candidate Panel process before it receives traffic.
shopt -s nullglob
apps=("$release/apps/"*.py)
port=0
if ((${#apps[@]})); then
  # Keep the old process available until this one is ready, without restarting
  # the candidate and executing app initialization a second time.
  port=5009
  [[ "$(cat /site/current/port 2>/dev/null || true)" != 5009 ]] || port=5010
  "$venv/bin/python" /runtime/serve_apps.py "${apps[@]}" --address 127.0.0.1 --port "$port" \
    --prefix /panel --disable-index --allow-websocket-origin='*' \
    </dev/null >/proc/1/fd/1 2>/proc/1/fd/2 9>&- &
  candidate_pid=$!
  deadline=$((SECONDS + 120))
  ready=false
  while ((SECONDS < deadline)); do
    kill -0 "$candidate_pid" 2>/dev/null || {
      echo "Panel startup failed" >&2
      exit 1
    }
    ready=true
    for app in "${apps[@]}"; do
      route="${app##*/}"
      if ! curl --fail --silent --max-time 5 "http://127.0.0.1:$port/panel/${route%.py}" >/dev/null; then
        ready=false
        break
      fi
    done
    [[ "$ready" = false ]] || break
    sleep 1
  done
  [[ "$ready" = true ]] || {
    echo "Panel readiness timed out" >&2
    exit 1
  }
fi

# 8. Atomically publish matching static and Panel configuration through Nginx.
# The static root and backend are read from one release by a single reload.
printf 'root %s/html;\nset %s %s;\n' "$release" "\$panel_port" "$port" >"$release/server.conf"
printf '%s\n' "$port" >"$release/port"
ln -sfn "$release" /site/current.next
mv -Tf /site/current.next /site/current
nginx -c /runtime/nginx.conf -t
if [[ -s /run/nginx.pid ]]; then
  nginx -c /runtime/nginx.conf -s reload
fi
published=true

# 9. Retire the old app and release while preserving one rollback generation.
old_pid="$(cat /run/panel.pid 2>/dev/null || true)"
printf '%s\n' "$candidate_pid" >/run/panel.pid
printf '%s\n' "$revision" >/run/published-revision
if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
  kill "$old_pid" 2>/dev/null || true
fi
# Retain the preceding release for Nginx workers finishing requests; discard
# older runtime-owned releases so successful refreshes do not fill the volume.
for obsolete in /site/releases/release.*; do
  [[ "$obsolete" = "$release" || "$obsolete" = "$previous" ]] || rm -rf -- "$obsolete"
done
echo "published target revision $revision"
