#!/bin/bash
set -e

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <registry> <repo> <commit>"
  exit 1
fi

REGISTRY=$1
REPO=$2
BUILDKITE_COMMIT=$3
IMAGE="$REGISTRY/$REPO:$BUILDKITE_COMMIT-xpu"

# authenticate with AWS ECR
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY" || true
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 936637512419.dkr.ecr.us-east-1.amazonaws.com || true

# skip build if image already exists
if docker manifest inspect "$IMAGE" &> /dev/null; then
  echo "Image found"
  docker pull "$IMAGE"
else
  echo "Image not found, proceeding with build..."
  # build
  docker build \
    --file docker/Dockerfile.xpu \
    --build-arg max_jobs=16 \
    --build-arg buildkite_commit="$BUILDKITE_COMMIT" \
    --tag "$IMAGE" \
    --progress plain .
  # push
  docker push "$IMAGE"
fi

VLLM_VERSION=$(docker run --rm --entrypoint /opt/venv/bin/python "$IMAGE" \
  -c 'import importlib.metadata; print(importlib.metadata.version("vllm"))')
WHEEL_COMMIT=$(python3 -c 'import re, sys; match = re.search(r"\+g([0-9a-f]{7,40})", sys.argv[1]); print(match.group(1) if match else "")' "$VLLM_VERSION")
if [[ -z "$WHEEL_COMMIT" ]]; then
  echo "Could not identify the source commit in installed vLLM version: $VLLM_VERSION" >&2
  exit 1
fi

if command -v buildkite-agent >/dev/null 2>&1; then
  if ! printf '### Installed XPU vLLM wheel\n\n- **Version:** `%s`\n- **Wheel source commit:** [`%s`](https://github.com/vllm-project/vllm/commit/%s)\n- **Image:** `%s`\n' \
    "$VLLM_VERSION" "$WHEEL_COMMIT" "$WHEEL_COMMIT" "$IMAGE" \
    | buildkite-agent annotate --append --style info --context xpu-installed-wheel; then
    echo "warning: failed to annotate the installed XPU vLLM wheel"
  fi
fi

.buildkite/scripts/annotate-image-build.sh "$IMAGE"
