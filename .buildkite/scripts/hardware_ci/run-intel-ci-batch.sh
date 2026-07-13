#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LOCAL_RUNNER="${SCRIPT_DIR}/run-intel-ci-local.sh"
GENERATOR="${SCRIPT_DIR}/generate-intel-job-shells.py"
MANIFEST="${REPO_ROOT}/.buildkite/intel_jobs/generated/manifest.json"

usage() {
  cat <<'EOF'
Usage:
  run-intel-ci-batch.sh plan [options] [case-id ...]
  run-intel-ci-batch.sh dry-run [options] [case-id ...]
  run-intel-ci-batch.sh run [options] [case-id ...]

Options:
  --cards <n>        Total local Intel GPUs to use. Default: 8
  --refresh          Regenerate manifest before scheduling
  --image <tag>      Override IMAGE_TAG_XPU for every case
  --include <regex>  Only include case_id/label/source_yaml matching regex
  --exclude <regex>  Exclude case_id/label/source_yaml matching regex
  --log-dir <dir>    Directory for per-case logs in run mode

Examples:
  .buildkite/scripts/hardware_ci/run-intel-ci-batch.sh plan --cards 8
  .buildkite/scripts/hardware_ci/run-intel-ci-batch.sh dry-run --cards 8 --include '2-gpus|example'
  .buildkite/scripts/hardware_ci/run-intel-ci-batch.sh run --cards 8 --include 'lora|quantization'
  .buildkite/scripts/hardware_ci/run-intel-ci-batch.sh run test-intel__xpu-example-test misc_intel__metrics-tracing-2-gpus
EOF
}

mode="${1:-}"
if [[ -z "${mode}" ]]; then
  usage
  exit 1
fi
shift

case "${mode}" in
  plan|dry-run|run)
    ;;
  *)
    echo "Unknown mode: ${mode}" >&2
    usage
    exit 1
    ;;
esac

total_cards=8
refresh=0
image_tag="${IMAGE_TAG_XPU:-}"
include_regex=""
exclude_regex=""
log_dir="${REPO_ROOT}/.buildkite/intel_jobs/generated/logs"
report_dir="${REPO_ROOT}/.buildkite/intel_jobs/generated/reports"
declare -a requested_case_ids=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cards)
      shift
      total_cards="${1:-}"
      ;;
    --refresh)
      refresh=1
      ;;
    --image)
      shift
      image_tag="${1:-}"
      ;;
    --include)
      shift
      include_regex="${1:-}"
      ;;
    --exclude)
      shift
      exclude_regex="${1:-}"
      ;;
    --log-dir)
      shift
      log_dir="${1:-}"
      ;;
    --report-dir)
      shift
      report_dir="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      requested_case_ids+=("$1")
      ;;
  esac
  shift
done

if ! [[ "${total_cards}" =~ ^[1-9][0-9]*$ ]]; then
  echo "--cards must be a positive integer" >&2
  exit 1
fi

ensure_manifest() {
  if [[ "${refresh}" == "1" || ! -f "${MANIFEST}" ]]; then
    python3 "${GENERATOR}"
  fi
}

ensure_manifest

selection_json="$({
  python3 - <<'PY' "${MANIFEST}" "${include_regex}" "${exclude_regex}" "${total_cards}" "${#requested_case_ids[@]}" "${requested_case_ids[@]}"
import json
import re
import sys

manifest_path = sys.argv[1]
include_regex = sys.argv[2]
exclude_regex = sys.argv[3]
total_cards = int(sys.argv[4])
requested_count = int(sys.argv[5])
requested_ids = sys.argv[6:6 + requested_count]

with open(manifest_path) as fh:
    cases = json.load(fh)

if requested_ids:
    requested_set = set(requested_ids)
    cases = [case for case in cases if case["case_id"] in requested_set]
    missing = [case_id for case_id in requested_ids if case_id not in {case["case_id"] for case in cases}]
    if missing:
        raise SystemExit("Missing case ids: " + ", ".join(missing))

def matched(pattern: str, case: dict) -> bool:
    text = " | ".join([
        str(case.get("case_id", "")),
        str(case.get("label", "")),
        str(case.get("source_yaml", "")),
    ])
    return bool(re.search(pattern, text, flags=re.IGNORECASE))

if include_regex:
    cases = [case for case in cases if matched(include_regex, case)]
if exclude_regex:
    cases = [case for case in cases if not matched(exclude_regex, case)]

cases.sort(key=lambda case: (-int(case["cards_required"]), -int(case.get("timeout_in_minutes") or 0), case["case_id"]))

oversized = [case["case_id"] for case in cases if int(case["cards_required"]) > total_cards]
if oversized:
    raise SystemExit("Cases need more GPUs than --cards allows: " + ", ".join(oversized))

print(json.dumps(cases))
PY
})" || {
  exit 1
}

if [[ "${selection_json}" == "[]" ]]; then
  echo "No Intel CI cases selected." >&2
  exit 1
fi

if [[ "${mode}" == "plan" ]]; then
  python3 - <<'PY' "${selection_json}" "${total_cards}"
import json
import sys

cases = json.loads(sys.argv[1])
total_cards = int(sys.argv[2])

waves = []
current_wave = []
used = 0
for case in cases:
    cards = int(case["cards_required"])
    if current_wave and used + cards > total_cards:
        waves.append((used, current_wave))
        current_wave = []
        used = 0
    current_wave.append(case)
    used += cards
if current_wave:
    waves.append((used, current_wave))

print(f"Selected {len(cases)} cases for {total_cards} local GPUs")
for index, (used_cards, wave_cases) in enumerate(waves, start=1):
    masks = []
    cursor = 0
    for case in wave_cases:
        cards = int(case["cards_required"])
        mask = ",".join(str(i) for i in range(cursor, cursor + cards))
        masks.append(mask)
        cursor += cards
    print(f"wave {index}: use {used_cards}/{total_cards} GPUs")
    for case, mask in zip(wave_cases, masks):
        print(f"  {case['case_id']} | cards={case['cards_required']} | mask={mask} | {case['label']}")
PY
  exit 0
fi

mkdir -p "${log_dir}"
mkdir -p "${report_dir}"

timestamp="$(date +%Y%m%d_%H%M%S)"
report_prefix="intel_ci_${mode}_${timestamp}"
report_json="${report_dir}/${report_prefix}.json"
report_html="${report_dir}/${report_prefix}.html"
report_tsv="${report_dir}/${report_prefix}.tsv"
collect_env_txt="${report_dir}/${report_prefix}.collect_env.txt"

repo_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
repo_branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
buildkite_commit="${BUILDKITE_COMMIT:-${repo_commit}}"
effective_image="${image_tag}"
if [[ -z "${effective_image}" ]]; then
  effective_image="$(python3 - <<'PY' "${selection_json}" "${buildkite_commit}"
import json
import sys

cases = json.loads(sys.argv[1])
buildkite_commit = sys.argv[2]
env = cases[0].get("env", {}) if cases else {}
registry = env.get("REGISTRY", "")
repo = env.get("REPO", "")
if registry and repo and buildkite_commit:
    print(f"{registry}/{repo}:{buildkite_commit}-xpu")
else:
    print("")
PY
)"
fi

python3 - <<'PY' "${selection_json}" "${report_json}" "${mode}" "${total_cards}" "${effective_image}" "${repo_commit}" "${repo_branch}" "${buildkite_commit}" "${log_dir}"
import json
import os
import sys
from datetime import datetime, timezone

cases = json.loads(sys.argv[1])
report_json = sys.argv[2]
mode = sys.argv[3]
total_cards = int(sys.argv[4])
image_tag = sys.argv[5]
repo_commit = sys.argv[6]
repo_branch = sys.argv[7]
buildkite_commit = sys.argv[8]
log_dir = sys.argv[9]

summary = {
  "generated_at": datetime.now(timezone.utc).isoformat(),
  "mode": mode,
  "total_cards": total_cards,
  "image": image_tag,
  "repo_commit": repo_commit,
  "repo_branch": repo_branch,
  "buildkite_commit": buildkite_commit,
  "log_dir": log_dir,
  "image_collect_env_status": "not-run",
  "image_collect_env_output": "",
  "cases": [],
}

with open(report_json, "w") as fh:
  json.dump(summary, fh, indent=2)
  fh.write("\n")
PY

printf 'case_id\tlabel\tsource_yaml\tcards_required\tmask\tstart_epoch\tend_epoch\tduration_seconds\texit_code\tresult\tlog_path\n' > "${report_tsv}"

declare -a free_gpus=()
for ((gpu_index = 0; gpu_index < total_cards; gpu_index++)); do
  free_gpus+=("${gpu_index}")
done

declare -A pid_to_case=()
declare -A pid_to_mask=()
declare -A pid_to_log=()
declare -A pid_to_gpus=()
declare -A pid_to_label=()
declare -A pid_to_source=()
declare -A pid_to_start_epoch=()
declare -a running_pids=()
failures=0
allocated_mask=""

case_json_by_id="$(python3 - <<'PY' "${selection_json}"
import json
import sys

cases = json.loads(sys.argv[1])
print(json.dumps({case['case_id']: case for case in cases}))
PY
)"

write_case_result() {
  local pid="$1"
  local status="$2"
  local end_epoch="$3"
  local start_epoch="${pid_to_start_epoch[$pid]}"
  local duration=$((end_epoch - start_epoch))
  local result="passed"
  if [[ "${status}" != "0" ]]; then
    result="failed"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${pid_to_case[$pid]}" \
    "${pid_to_label[$pid]}" \
    "${pid_to_source[$pid]}" \
    "${pid_to_gpus[$pid]}" \
    "${pid_to_mask[$pid]}" \
    "${start_epoch}" \
    "${end_epoch}" \
    "${duration}" \
    "${status}" \
    "${result}" \
    "${pid_to_log[$pid]}" >> "${report_tsv}"
}

collect_image_env_info() {
  if [[ -z "${effective_image}" ]]; then
    printf 'collect_env not executed: effective image is empty\n' > "${collect_env_txt}"
    return 0
  fi

  if ! docker image inspect "${effective_image}" >/dev/null 2>&1; then
    printf 'collect_env not executed: image not available locally: %s\n' "${effective_image}" > "${collect_env_txt}"
    return 0
  fi

  set +e
  timeout 300 docker run --rm \
    --device /dev/dri:/dev/dri \
    --ipc=host \
    --privileged \
    -v /dev/dri/by-path:/dev/dri/by-path \
    --entrypoint='' \
    "${effective_image}" \
    bash -lc 'set -e; if [[ -f /opt/intel/oneapi/setvars.sh ]]; then source /opt/intel/oneapi/setvars.sh --force; fi; if [[ -f /opt/intel/oneapi/ccl/2021.15/env/vars.sh ]]; then source /opt/intel/oneapi/ccl/2021.15/env/vars.sh --force; fi; python /workspace/vllm/collect_env.py' \
    > "${collect_env_txt}" 2>&1
  local status=$?
  set -e

  if [[ "${status}" != "0" ]]; then
    printf '\ncollect_env exit code: %s\n' "${status}" >> "${collect_env_txt}"
  fi
  return 0
}

finalize_report() {
  python3 - <<'PY' "${report_json}" "${report_tsv}" "${report_html}" "${collect_env_txt}"
import csv
import html
import json
import sys
from datetime import datetime

report_json, report_tsv, report_html, collect_env_txt = sys.argv[1:5]

with open(report_json) as fh:
    summary = json.load(fh)

rows = []
with open(report_tsv, newline="") as fh:
    reader = csv.DictReader(fh, delimiter='\t')
    for row in reader:
        row["cards_required"] = int(row["cards_required"])
        row["start_epoch"] = int(row["start_epoch"])
        row["end_epoch"] = int(row["end_epoch"])
        row["duration_seconds"] = int(row["duration_seconds"])
        row["exit_code"] = int(row["exit_code"])
        row["start_time"] = datetime.fromtimestamp(row["start_epoch"]).isoformat(sep=" ", timespec="seconds")
        row["end_time"] = datetime.fromtimestamp(row["end_epoch"]).isoformat(sep=" ", timespec="seconds")
        rows.append(row)

summary["cases"] = rows
summary["total_cases"] = len(rows)
summary["passed_cases"] = sum(1 for row in rows if row["result"] == "passed")
summary["failed_cases"] = sum(1 for row in rows if row["result"] != "passed")
summary["total_duration_seconds"] = sum(row["duration_seconds"] for row in rows)

try:
  with open(collect_env_txt) as fh:
    collect_env_output = fh.read().strip()
except FileNotFoundError:
  collect_env_output = "collect_env output file not found"

summary["image_collect_env_output"] = collect_env_output
summary["image_collect_env_status"] = "ok" if collect_env_output and "collect_env exit code:" not in collect_env_output.lower() and "not executed:" not in collect_env_output.lower() else "unavailable"

with open(report_json, "w") as fh:
    json.dump(summary, fh, indent=2)
    fh.write("\n")

def esc(value):
    return html.escape(str(value))

rows_html = []
for row in rows:
    status_class = "passed" if row["result"] == "passed" else "failed"
    rows_html.append(
        "<tr>"
        f"<td>{esc(row['case_id'])}</td>"
        f"<td>{esc(row['label'])}</td>"
        f"<td>{esc(row['source_yaml'])}</td>"
        f"<td>{esc(row['cards_required'])}</td>"
        f"<td>{esc(row['mask'])}</td>"
        f"<td>{esc(row['start_time'])}</td>"
        f"<td>{esc(row['end_time'])}</td>"
        f"<td>{esc(row['duration_seconds'])}s</td>"
        f"<td class=\"{status_class}\">{esc(row['result'])}</td>"
        f"<td>{esc(row['exit_code'])}</td>"
        f"<td><a href=\"file://{esc(row['log_path'])}\">log</a><br>{esc(row['log_path'])}</td>"
        "</tr>"
    )

image_value = summary.get("image") or "unknown"
html_doc = f"""<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <title>Intel CI Report</title>
  <style>
    body {{ font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2937; background: #f7fafc; }}
    h1, h2 {{ margin-bottom: 8px; }}
    .meta, .summary {{ background: white; padding: 16px 20px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 18px; }}
    .grid {{ display: grid; grid-template-columns: repeat(2, minmax(260px, 1fr)); gap: 8px 24px; }}
    table {{ width: 100%; border-collapse: collapse; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
    th, td {{ padding: 10px 12px; border-bottom: 1px solid #e5e7eb; text-align: left; vertical-align: top; font-size: 14px; }}
    th {{ background: #eef2ff; }}
    .passed {{ color: #166534; font-weight: 700; }}
    .failed {{ color: #b91c1c; font-weight: 700; }}
    code {{ background: #f3f4f6; padding: 1px 4px; border-radius: 4px; }}
  </style>
</head>
<body>
  <h1>Intel CI Report</h1>
  <div class=\"meta\">
    <h2>Run Metadata</h2>
    <div class=\"grid\">
      <div><strong>Generated At:</strong> {esc(summary['generated_at'])}</div>
      <div><strong>Mode:</strong> {esc(summary['mode'])}</div>
      <div><strong>Repo Branch:</strong> {esc(summary['repo_branch'])}</div>
      <div><strong>Repo Commit:</strong> <code>{esc(summary['repo_commit'])}</code></div>
      <div><strong>BUILDKITE_COMMIT:</strong> <code>{esc(summary['buildkite_commit'])}</code></div>
      <div><strong>Total Cards:</strong> {esc(summary['total_cards'])}</div>
      <div><strong>Image:</strong> {esc(image_value)}</div>
      <div><strong>Image collect_env Status:</strong> {esc(summary['image_collect_env_status'])}</div>
      <div><strong>Log Directory:</strong> {esc(summary['log_dir'])}</div>
      <div><strong>JSON Report:</strong> {esc(report_json)}</div>
      <div><strong>HTML Report:</strong> {esc(report_html)}</div>
    </div>
  </div>
  <div class=\"summary\">
    <h2>Summary</h2>
    <div class=\"grid\">
      <div><strong>Total Suites:</strong> {esc(summary['total_cases'])}</div>
      <div><strong>Passed:</strong> {esc(summary['passed_cases'])}</div>
      <div><strong>Failed:</strong> {esc(summary['failed_cases'])}</div>
      <div><strong>Accumulated Duration:</strong> {esc(summary['total_duration_seconds'])}s</div>
    </div>
  </div>
  <div class=\"meta\">
    <h2>Image collect_env.py Output</h2>
    <pre>{esc(summary['image_collect_env_output'])}</pre>
  </div>
  <table>
    <thead>
      <tr>
        <th>Case ID</th>
        <th>Test Suite</th>
        <th>Source YAML</th>
        <th>Cards</th>
        <th>Mask</th>
        <th>Start</th>
        <th>End</th>
        <th>Duration</th>
        <th>Result</th>
        <th>Exit</th>
        <th>Log</th>
      </tr>
    </thead>
    <tbody>
      {''.join(rows_html)}
    </tbody>
  </table>
</body>
</html>
"""

with open(report_html, "w") as fh:
    fh.write(html_doc)
PY
}

sorted_free_gpus() {
  printf '%s\n' "${free_gpus[@]}" | sort -n
}

acquire_mask() {
  local need="$1"
  if (( ${#free_gpus[@]} < need )); then
    return 1
  fi

  local sorted
  mapfile -t sorted < <(sorted_free_gpus)

  local -a taken=()
  local mask=""
  local idx
  for ((idx = 0; idx < need; idx++)); do
    taken+=("${sorted[$idx]}")
    if [[ -z "${mask}" ]]; then
      mask="${sorted[$idx]}"
    else
      mask+=",${sorted[$idx]}"
    fi
  done

  local -a remaining=()
  local free_gpu
  local keep
  for free_gpu in "${free_gpus[@]}"; do
    keep=1
    for idx in "${taken[@]}"; do
      if [[ "${free_gpu}" == "${idx}" ]]; then
        keep=0
        break
      fi
    done
    if [[ "${keep}" == "1" ]]; then
      remaining+=("${free_gpu}")
    fi
  done
  free_gpus=("${remaining[@]}")
  allocated_mask="${mask}"
}

release_mask() {
  local mask="$1"
  local gpu
  IFS=',' read -r -a released <<< "${mask}"
  for gpu in "${released[@]}"; do
    free_gpus+=("${gpu}")
  done
}

refresh_completed_jobs() {
  local -a still_running=()
  local pid
  for pid in "${running_pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      still_running+=("${pid}")
      continue
    fi

    local status=0
    if ! wait "${pid}"; then
      status=$?
      failures=1
    fi
    local end_epoch
    end_epoch="$(date +%s)"
    write_case_result "${pid}" "${status}" "${end_epoch}"
    release_mask "${pid_to_mask[$pid]}"
    echo "Finished ${pid_to_case[$pid]} | mask=${pid_to_mask[$pid]} | exit=${status} | log=${pid_to_log[$pid]}"
    unset 'pid_to_case[$pid]'
    unset 'pid_to_mask[$pid]'
    unset 'pid_to_log[$pid]'
    unset 'pid_to_gpus[$pid]'
    unset 'pid_to_label[$pid]'
    unset 'pid_to_source[$pid]'
    unset 'pid_to_start_epoch[$pid]'
  done
  running_pids=("${still_running[@]}")
}

launch_case() {
  local case_id="$1"
  local cards="$2"
  local label="$3"

  local mask
  acquire_mask "${cards}"
  mask="${allocated_mask}"

  local log_suffix="run"
  local runner_mode="run"
  if [[ "${mode}" == "dry-run" ]]; then
    log_suffix="dry-run"
    runner_mode="dry-run"
  fi

  local log_path="${log_dir}/${case_id}.${log_suffix}.log"
  local -a cmd=(bash "${LOCAL_RUNNER}" "${runner_mode}" "${case_id}" --ze-mask "${mask}")
  if [[ -n "${image_tag}" ]]; then
    cmd+=(--image "${image_tag}")
  fi

  local case_meta
  case_meta="$(python3 - <<'PY' "${case_json_by_id}" "${case_id}"
import json
import sys

cases = json.loads(sys.argv[1])
case = cases[sys.argv[2]]
print(case['label'])
print(case['source_yaml'])
PY
)"
  local case_label case_source
  case_label="$(printf '%s\n' "${case_meta}" | sed -n '1p')"
  case_source="$(printf '%s\n' "${case_meta}" | sed -n '2p')"

  echo "Launching ${case_id} | cards=${cards} | mask=${mask} | log=${log_path}"
  (
    cd "${REPO_ROOT}"
    exec "${cmd[@]}"
  ) >"${log_path}" 2>&1 &

  local pid=$!
  pid_to_case["${pid}"]="${case_id}"
  pid_to_mask["${pid}"]="${mask}"
  pid_to_log["${pid}"]="${log_path}"
  pid_to_gpus["${pid}"]="${cards}"
  pid_to_label["${pid}"]="${case_label}"
  pid_to_source["${pid}"]="${case_source}"
  pid_to_start_epoch["${pid}"]="$(date +%s)"
  running_pids+=("${pid}")
  echo "Started ${case_id} (${label}) as pid=${pid}"
}

mapfile -t selected_lines < <(
  python3 - <<'PY' "${selection_json}"
import json
import sys

cases = json.loads(sys.argv[1])
for case in cases:
    print(f"{case['case_id']}\t{case['cards_required']}\t{case['label']}")
PY
)

for line in "${selected_lines[@]}"; do
  IFS=$'\t' read -r case_id cards label <<< "${line}"
  while (( ${#free_gpus[@]} < cards )); do
    wait -n
    refresh_completed_jobs
  done
  launch_case "${case_id}" "${cards}" "${label}"
done

while (( ${#running_pids[@]} > 0 )); do
  wait -n
  refresh_completed_jobs
done

collect_image_env_info
finalize_report

if [[ "${failures}" != "0" ]]; then
  echo "HTML report: ${report_html}"
  echo "JSON report: ${report_json}"
  echo "One or more Intel CI cases failed." >&2
  exit 1
fi

echo "HTML report: ${report_html}"
echo "JSON report: ${report_json}"
echo "All Intel CI cases completed successfully. Logs: ${log_dir}"