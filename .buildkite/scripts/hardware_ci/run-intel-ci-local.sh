#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
GENERATOR="${SCRIPT_DIR}/generate-intel-job-shells.py"
MANIFEST="${REPO_ROOT}/.buildkite/intel_jobs/generated/manifest.json"
RUNNER="${SCRIPT_DIR}/run-intel-test.sh"

if [[ -z "${BUILDKITE_COMMIT:-}" ]]; then
  BUILDKITE_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  export BUILDKITE_COMMIT
fi

usage() {
  cat <<'EOF'
Usage:
  run-intel-ci-local.sh list [--refresh]
  run-intel-ci-local.sh show <case-id> [--refresh]
  run-intel-ci-local.sh dry-run <case-id> [--refresh] [--image <tag>] [--ze-mask <mask>]
  run-intel-ci-local.sh run <case-id> [--refresh] [--image <tag>] [--ze-mask <mask>]

Examples:
  .buildkite/scripts/hardware_ci/run-intel-ci-local.sh list
  .buildkite/scripts/hardware_ci/run-intel-ci-local.sh dry-run test-intel__xpu-example-test
  .buildkite/scripts/hardware_ci/run-intel-ci-local.sh run misc_intel__metrics-tracing-2-gpus --image public.ecr.aws/q9t5s3a7/vllm-ci-test-repo:local-xpu
EOF
}

refresh=0
image_tag="${IMAGE_TAG_XPU:-}"
ze_mask="${ZE_AFFINITY_MASK:-}"

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  usage
  exit 1
fi
shift

case_id=""
if [[ "${command_name}" != "list" ]]; then
  case_id="${1:-}"
  if [[ -z "${case_id}" ]]; then
    usage
    exit 1
  fi
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh)
      refresh=1
      ;;
    --image)
      shift
      image_tag="${1:-}"
      ;;
    --ze-mask)
      shift
      ze_mask="${1:-}"
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

ensure_manifest() {
  if [[ "${refresh}" == "1" || ! -f "${MANIFEST}" ]]; then
    python3 "${GENERATOR}"
  fi
}

ensure_manifest

if [[ "${command_name}" == "list" ]]; then
  python3 - <<'PY' "${MANIFEST}"
import json
import sys

manifest_path = sys.argv[1]
cases = json.load(open(manifest_path))
for case in cases:
    print(
        f"{case['case_id']} | cards={case['cards_required']} | "
        f"gpu={case['gpu_tag']} | label={case['label']} | {case['source_yaml']}"
    )
PY
  exit 0
fi

resolved_json="$(python3 - <<'PY' "${MANIFEST}" "${case_id}"
import json
import sys

manifest_path, case_id = sys.argv[1:3]
cases = json.load(open(manifest_path))
for case in cases:
    if case['case_id'] == case_id:
        print(json.dumps(case))
        break
else:
    sys.exit(2)
PY
)" || {
  echo "Case not found: ${case_id}" >&2
  exit 1
}

if [[ "${command_name}" == "show" ]]; then
  python3 - <<'PY' "${resolved_json}"
import json
import sys

case = json.loads(sys.argv[1])
print(f"case_id: {case['case_id']}")
print(f"label: {case['label']}")
print(f"source_yaml: {case['source_yaml']}")
print(f"agent_type: {case['agent_type']}")
print(f"cards_required: {case['cards_required']}")
print(f"shell_path: {case['shell_path']}")
print("commands:")
print(case['commands'])
PY
  exit 0
fi

export CASE_JSON="${resolved_json}"
eval "$(python3 - <<'PY'
import json
import os
import shlex

case = json.loads(os.environ['CASE_JSON'])
for key, value in case['env'].items():
    print(f"export {key}={shlex.quote(str(value))}")
print(f"export VLLM_TEST_COMMANDS={shlex.quote(case['commands'])}")
print(f"export INTEL_CI_CARDS_REQUIRED={shlex.quote(str(case['cards_required']))}")
print(f"export INTEL_CI_LABEL={shlex.quote(case['label'])}")
PY
)"

if [[ -n "${image_tag}" ]]; then
  export IMAGE_TAG_XPU="${image_tag}"
fi

if [[ -z "${ze_mask}" ]]; then
  ze_mask="$(python3 - <<'PY' "${INTEL_CI_CARDS_REQUIRED}"
import sys

cards = max(1, int(sys.argv[1]))
print(",".join(str(index) for index in range(cards)))
PY
)"
fi
export ZE_AFFINITY_MASK="${ze_mask}"

echo "Case: ${case_id}"
echo "Label: ${INTEL_CI_LABEL}"
echo "Cards required: ${INTEL_CI_CARDS_REQUIRED}"
echo "ZE_AFFINITY_MASK: ${ZE_AFFINITY_MASK}"
if [[ -n "${IMAGE_TAG_XPU:-}" ]]; then
  echo "IMAGE_TAG_XPU: ${IMAGE_TAG_XPU}"
fi

cd "${REPO_ROOT}"

if [[ "${command_name}" == "dry-run" ]]; then
  DRY_RUN=1 bash "${RUNNER}" --dry-run
  exit 0
fi

if [[ "${command_name}" == "run" ]]; then
  bash "${RUNNER}"
  exit 0
fi

echo "Unknown command: ${command_name}" >&2
usage
exit 1