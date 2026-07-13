#!/usr/bin/env python3

import csv
import json
import os
import re
import shlex
from pathlib import Path
from typing import Dict, List, Optional

import yaml


REPO_ROOT = Path(__file__).resolve().parents[3]
INTEL_JOBS_DIR = REPO_ROOT / ".buildkite" / "intel_jobs"
OUTPUT_DIR = INTEL_JOBS_DIR / "generated"
MANIFEST_JSON = OUTPUT_DIR / "manifest.json"
MANIFEST_CSV = OUTPUT_DIR / "manifest.csv"
RUNNER_PATH = ".buildkite/scripts/hardware_ci/run-intel-test.sh"


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    return value.strip("-") or "case"


def cards_required(step: dict) -> int:
    num_devices = step.get("num_devices")
    if isinstance(num_devices, int) and num_devices > 0:
        return num_devices

    gpu_tag = str(step.get("agent_tags", {}).get("gpu", "")).strip()
    match = re.match(r"(\d+)", gpu_tag)
    if match:
        return int(match.group(1))
    return 1


def extract_inner_commands(command_text: str) -> Optional[str]:
    try:
        parts = shlex.split(command_text, posix=True)
    except ValueError:
        return None

    for index, token in enumerate(parts):
        if token == RUNNER_PATH:
            remaining = parts[index + 1 :]
            if not remaining:
                return ""
            if len(remaining) == 1:
                return remaining[0]
            return shlex.join(remaining)
    return None


def shell_body_from_inner(inner_commands: str) -> str:
    if not inner_commands:
        return ""
    return inner_commands + ("\n" if not inner_commands.endswith("\n") else "")


def render_shell(case: Dict[str, object]) -> str:
    header = [
        "#!/bin/bash",
        "set -euo pipefail",
        "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"",
        "REPO_ROOT=\"$(cd \"${SCRIPT_DIR}/../../..\" && pwd)\"",
        "cd \"${REPO_ROOT}\"",
        "",
        f"# Generated from {case['source_yaml']}",
        f"# Label: {case['label']}",
        f"# Case ID: {case['case_id']}",
        f"# Agent Type: {case['agent_type']}",
        f"# Cards Required: {case['cards_required']}",
        "",
    ]
    return "\n".join(header) + shell_body_from_inner(case["commands"])


def build_case(source_yaml: Path, step: Dict[str, object]) -> Optional[Dict[str, object]]:
    label = step.get("label")
    if not label:
        return None

    for command_text in step.get("commands", []):
        inner_commands = extract_inner_commands(command_text)
        if inner_commands is None:
            continue

        agent_tags = step.get("agent_tags", {})
        case_id = f"{source_yaml.stem}__{slugify(label)}"
        shell_name = f"{case_id}.sh"
        env = {key: str(value) for key, value in step.get("env", {}).items()}
        card_count = cards_required(step)

        return {
            "case_id": case_id,
            "label": label,
            "label_slug": slugify(label),
            "key": step.get("key", ""),
            "group": step.get("group", ""),
            "source_yaml": source_yaml.relative_to(REPO_ROOT).as_posix(),
            "device": step.get("device", ""),
            "agent_label": str(agent_tags.get("label", "")),
            "gpu_tag": str(agent_tags.get("gpu", "")),
            "mem_tag": str(agent_tags.get("mem", "")),
            "agent_type": "/".join(
                part
                for part in [
                    str(step.get("device", "")).strip(),
                    f"label={agent_tags.get('label', '')}",
                    f"gpu={agent_tags.get('gpu', '')}",
                    f"mem={agent_tags.get('mem', '')}",
                ]
                if part and not part.endswith("=")
            ),
            "cards_required": card_count,
            "timeout_in_minutes": step.get("timeout_in_minutes", ""),
            "shell_path": (OUTPUT_DIR / shell_name).relative_to(REPO_ROOT).as_posix(),
            "commands": inner_commands,
            "env": env,
        }
    return None


def load_cases() -> List[Dict[str, object]]:
    cases: List[Dict[str, object]] = []
    for yaml_path in sorted(INTEL_JOBS_DIR.glob("*.yaml")):
        data = yaml.safe_load(yaml_path.read_text()) or {}
        for step in data.get("steps", []):
            case = build_case(yaml_path, step)
            if case is not None:
                cases.append(case)
    return cases


def write_cases(cases: List[Dict[str, object]]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for old_shell in OUTPUT_DIR.glob("*.sh"):
        old_shell.unlink()

    manifest_for_json = []
    for case in cases:
        shell_path = REPO_ROOT / case["shell_path"]
        shell_path.write_text(render_shell(case))
        os.chmod(shell_path, 0o755)

        item = dict(case)
        manifest_for_json.append(item)

    MANIFEST_JSON.write_text(json.dumps(manifest_for_json, indent=2) + "\n")

    fieldnames = [
        "case_id",
        "label",
        "source_yaml",
        "device",
        "agent_label",
        "gpu_tag",
        "mem_tag",
        "cards_required",
        "timeout_in_minutes",
        "shell_path",
        "key",
        "agent_type",
    ]
    with MANIFEST_CSV.open("w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for case in cases:
            writer.writerow({name: case.get(name, "") for name in fieldnames})


def main() -> None:
    cases = load_cases()
    write_cases(cases)
    print(
        f"Generated {len(cases)} Intel CI shell scripts under "
        f"{OUTPUT_DIR.relative_to(REPO_ROOT).as_posix()}"
    )
    print(f"Manifest JSON: {MANIFEST_JSON.relative_to(REPO_ROOT).as_posix()}")
    print(f"Manifest CSV:  {MANIFEST_CSV.relative_to(REPO_ROOT).as_posix()}")


if __name__ == "__main__":
    main()