#!/usr/bin/env bash
# Publish one manifest containing the two deployment architectures.
set -Eeuo pipefail

[[ $# -eq 1 ]] || {
  echo "usage: $0 REGISTRY/IMAGE:TAG" >&2
  exit 2
}
tag="$1"
docker buildx build --platform linux/amd64,linux/arm64 --tag "$tag" --push \
  "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
