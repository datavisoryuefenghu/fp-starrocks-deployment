#!/usr/bin/env bash
set -euo pipefail

# Build and optionally push the CH→Iceberg migration image.
#
# Usage:
#   bash migration/build.sh                          # build only
#   bash migration/build.sh --push                   # build + push
#   REGISTRY=123456789.dkr.ecr.us-west-2.amazonaws.com bash migration/build.sh --push

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-cloud/ch_iceberg_migration}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REGISTRY="${REGISTRY:-docker-registry.dv-api.com}"

if [[ -n "$REGISTRY" ]]; then
  FULL_TAG="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
  FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
fi

PLATFORM="${PLATFORM:-linux/amd64}"

echo "=== Building ${FULL_TAG} (${PLATFORM}) ==="
docker build --platform "${PLATFORM}" -t "${FULL_TAG}" "${SCRIPT_DIR}"

if [[ "${1:-}" == "--push" ]]; then
  echo "=== Pushing ${FULL_TAG} ==="
  docker push "${FULL_TAG}"
fi

echo "=== Done: ${FULL_TAG} ==="
