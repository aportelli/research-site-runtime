#!/usr/bin/env bash
# Prepare an isolated release, then switch Nginx to the validated process.
set -Eeuo pipefail

log() {
	printf '%(%FT%TZ)T [refresh] %s\n' -1 "$*"
}

# 1. Serialize refresh hooks: Git updates can arrive while a build is running.
exec 9>/run/refresh.lock
if [[ "${1:-}" = --job ]]; then
	# Missing one interval is preferable to starving a Git-triggered deployment.
	flock -n 9 || {
		log "another refresh is running; skipping this scheduled job tick"
		exit 0
	}
else
	flock 9
fi

# 2. Identify the Git-synced revision. Scheduled jobs deliberately rebuild an
# unchanged revision, while Git-triggered refreshes run every declared job.
job_args=()
restart_panel=false
if (($#)); then
	[[ $1 = --job && ($# = 2 || ($# = 3 && $3 = --restart-panel)) ]] || {
		echo "usage: $0 [--job NAME [--restart-panel]]" >&2
		exit 2
	}
	job_args=("$2")
	[[ $# = 3 ]] && restart_panel=true
fi
checkout="$(readlink -f /content/current)"
revision="$(git -C "$checkout" rev-parse HEAD)"
published_revision="$(cat /run/published-revision 2>/dev/null || true)"
# A scheduler run can win the lock just as git-sync receives a new revision.
# Promote it to a full deployment so new or changed jobs cannot be skipped.
if ((${#job_args[@]})) && [[ "$published_revision" != "$revision" ]]; then
	log "revision ${revision:0:12} is unpublished; running all declared jobs"
	job_args=()
fi
if ((${#job_args[@]} == 0)) && [[ "$published_revision" = "$revision" ]]; then
	log "revision ${revision:0:12} is already published"
	exit 0
fi
log "preparing revision ${revision:0:12}"

# 3. Create an isolated candidate release and preserve the current one on error.
mkdir -p /site/releases
release="$(mktemp -d /site/releases/release.XXXXXXXX)"
previous=""
[[ ! -L /site/current ]] || previous="$(readlink -f /site/current)"
candidate_pid=""
panel_release=""
[[ ! -L /site/panel-release ]] || panel_release="$(readlink -f /site/panel-release)"
published=false
cleanup() {
	if [[ "$published" = false ]]; then
		log "release failed; retaining the previous published release"
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
log "validating Panel app manifest"
python /runtime/prepare_apps.py "$content" "$release/apps"

# 5. Select the target's locked web environment or the image fallback.
venv=/opt/fallback/.venv
if [[ -f "$content/uv.lock" ]]; then
	log "installing the target's locked web environment"
	venv="$release/venv"
	UV_PROJECT_ENVIRONMENT="$venv" uv sync --project "$content" \
		--frozen --no-default-groups --group web
fi
[[ "$venv" != /opt/fallback/.venv ]] || log "using the image fallback web environment"
cd "$content"
export PYTHONPATH="$content${PYTHONPATH:+:$PYTHONPATH}"

# Run all target jobs for a newly checked-out revision, including the first
# deployment. A scheduled refresh names just the job that is due.
if ((${#job_args[@]})) && [[ "$restart_panel" = false ]]; then
	log "running scheduled job ${job_args[0]}"
	restore_args=()
	[[ -d "$previous/source" ]] && restore_args=(--restore-from "$previous/source")
else
	log "running all declared jobs"
	restore_args=()
fi
"$venv/bin/python" /runtime/run_jobs.py "$content" "$venv/bin/python" \
	"${restore_args[@]}" "${job_args[@]}"

# 6. Render the static site privately inside the candidate release.
log "rendering MkDocs site"
"$venv/bin/mkdocs" build --config-file web/mkdocs.yml --site-dir "$release/html"
"$venv/bin/python" /runtime/stamp_revision.py "$release/html" "$revision"
# mktemp creates mode 700. Only rendered content is exposed by Nginx.
chmod a+rx "$release"
chmod -R a+rX "$release/html"

# 7. Jobs publish only static MkDocs content. Keep the existing Panel process
# and its release files alive; Panel replacement is reserved for Git updates.
port=0
if ((${#job_args[@]})); then
	port="$(cat /site/current/port 2>/dev/null || printf 0)"
	log "preserving the existing Panel app(s) on port $port"
else
	shopt -s nullglob
	apps=("$release/apps/"*.py)
	if ((${#apps[@]})); then
	# Keep the old process available until this one is ready, without restarting
	# the candidate and executing app initialization a second time.
	port=5009
	[[ "$(cat /site/current/port 2>/dev/null || true)" != 5009 ]] || port=5010
	log "starting and validating ${#apps[@]} Panel app(s) on port $port"
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
	((${#apps[@]})) || log "no Panel apps declared"
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
log "published revision ${revision:0:12}"

# 9. Retire the old app and release while preserving one rollback generation.
if ((${#job_args[@]} == 0)) || [[ "$restart_panel" = true ]]; then
	old_pid="$(cat /run/panel.pid 2>/dev/null || true)"
	printf '%s\n' "$candidate_pid" >/run/panel.pid
	if [[ -n "$candidate_pid" ]]; then
		ln -sfn "$release" /site/panel-release.next
		mv -Tf /site/panel-release.next /site/panel-release
	else
		rm -f /site/panel-release
	fi
	if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
		kill "$old_pid" 2>/dev/null || true
	fi
fi
printf '%s\n' "$revision" >/run/published-revision
# Retain the preceding release for Nginx workers finishing requests; discard
# older runtime-owned releases so successful refreshes do not fill the volume.
for obsolete in /site/releases/release.*; do
	[[ "$obsolete" = "$release" || "$obsolete" = "$previous" || "$obsolete" = "$panel_release" ]] || rm -rf -- "$obsolete"
done
log "release cleanup complete"
