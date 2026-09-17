#!/usr/bin/env bash
# Build a host-architecture image for local testing.
set -Eeuo pipefail

[[ $# -le 1 ]] || {
  echo "usage: $0 [IMAGE:TAG]" >&2
  exit 2
}
tag="${1:-research-site-runtime:local}"
docker build --tag "$tag" "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
