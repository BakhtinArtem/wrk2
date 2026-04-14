#!/usr/bin/env python3
"""
Run all flow stages sequentially with flow_executor.lua.

This script:
1) discovers stages from workdir/flow.yaml
2) preprocesses each stage via preprocess_flow.py
3) remaps generated <stage>_* artifacts to lifecycle_* for current executor
4) runs wrk with per-stage wrk2 params from generated manifest JSON
   (passes -- --no-flow-failure-logs to flow_executor.lua for quieter output)
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


@dataclass
class StageResult:
    stage: str
    rc: int
    status: str
    reason: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run all flow stages with wrk executor")
    parser.add_argument("--workdir", default="workdir", help="Path to workdir (default: workdir)")
    parser.add_argument(
        "--target-url",
        default="http://localhost:9966/",
        help="Target URL passed to wrk (default: http://localhost:9966/)",
    )
    parser.add_argument(
        "--stages",
        default="",
        help="Optional comma-separated stage list. Default: all stages from flow.yaml",
    )
    parser.add_argument(
        "--sanitize-control-chars",
        action="store_true",
        help="Forward --sanitize-control-chars to preprocess_flow.py",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue executing next stages even when one stage fails",
    )
    parser.add_argument(
        "--flow-failure-logs",
        action="store_true",
        help="Do not pass --no-flow-failure-logs to wrk (enable flow_failure print lines)",
    )
    return parser.parse_args()


def load_stage_names(flow_yaml: Path) -> list[str]:
    flow_doc = yaml.safe_load(flow_yaml.read_text(encoding="utf-8")) or {}
    stages = (flow_doc.get("stages") or {})
    if not isinstance(stages, dict) or not stages:
        raise ValueError(f"No stages found in {flow_yaml}")
    return list(stages.keys())


def parse_stage_subset(spec: str) -> set[str]:
    out = set()
    for token in (spec or "").split(","):
        name = token.strip()
        if name:
            out.add(name)
    return out


def run_cmd(cmd: list[str], cwd: Path) -> int:
    print(f"$ {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=str(cwd), check=False)
    return completed.returncode


def preprocess_stage(repo_root: Path, workdir: Path, stage: str, sanitize: bool) -> int:
    cmd = [
        sys.executable,
        str(workdir / "preprocess_flow.py"),
        "--workdir",
        str(workdir),
        "--stage",
        stage,
    ]
    if sanitize:
        cmd.append("--sanitize-control-chars")
    return run_cmd(cmd, cwd=repo_root)


def load_stage_wrk_cfg(generated_dir: Path, stage: str) -> dict[str, Any]:
    manifest_json = generated_dir / f"{stage}_manifest.json"
    if not manifest_json.exists():
        raise FileNotFoundError(manifest_json)
    manifest = json.loads(manifest_json.read_text(encoding="utf-8"))
    wrk_cfg = (manifest or {}).get("wrk2") or {}
    required = ("threads", "connections", "rate", "duration")
    missing = [k for k in required if k not in wrk_cfg]
    if missing:
        raise ValueError(f"Stage '{stage}' manifest missing wrk2 keys: {missing}")
    return wrk_cfg


def remap_stage_artifacts(generated_dir: Path, stage: str) -> None:
    src_manifest_lua = generated_dir / f"{stage}_manifest.lua"
    src_iterations_lua = generated_dir / f"{stage}_iterations.lua"
    dst_manifest_lua = generated_dir / "lifecycle_manifest.lua"
    dst_iterations_lua = generated_dir / "lifecycle_iterations.lua"

    if not src_manifest_lua.exists():
        raise FileNotFoundError(src_manifest_lua)
    if not src_iterations_lua.exists():
        raise FileNotFoundError(src_iterations_lua)

    if src_manifest_lua.resolve() != dst_manifest_lua.resolve():
        shutil.copy2(src_manifest_lua, dst_manifest_lua)
    if src_iterations_lua.resolve() != dst_iterations_lua.resolve():
        shutil.copy2(src_iterations_lua, dst_iterations_lua)


def run_stage_wrk(
    repo_root: Path,
    workdir: Path,
    wrk_cfg: dict[str, Any],
    target_url: str,
    flow_failure_logs: bool,
) -> int:
    wrk_bin = repo_root / "wrk"
    script = workdir / "flow_executor.lua"
    if not wrk_bin.exists():
        raise FileNotFoundError(wrk_bin)
    if not script.exists():
        raise FileNotFoundError(script)

    cmd = [
        str(wrk_bin),
        f"-t{int(wrk_cfg['threads'])}",
        f"-c{int(wrk_cfg['connections'])}",
        f"-R{int(wrk_cfg['rate'])}",
        f"-d{str(wrk_cfg['duration'])}",
        "-s",
        str(script),
        target_url,
    ]
    if not flow_failure_logs:
        cmd.extend(["--", "--no-flow-failure-logs"])
    return run_cmd(cmd, cwd=repo_root)


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd().resolve()
    workdir = Path(args.workdir).resolve()
    generated_dir = workdir / "generated"
    flow_yaml = workdir / "flow.yaml"
    openapi_yaml = workdir / "openapi.yml"
    data_root = workdir / "data"

    if not flow_yaml.exists():
        raise FileNotFoundError(flow_yaml)
    if not openapi_yaml.exists():
        raise FileNotFoundError(openapi_yaml)
    if not data_root.exists():
        raise FileNotFoundError(data_root)

    discovered = load_stage_names(flow_yaml)
    subset = parse_stage_subset(args.stages)
    stage_list = [s for s in discovered if not subset or s in subset]
    unknown_subset = sorted(subset - set(discovered))
    if unknown_subset:
        raise ValueError(f"Unknown stage(s) in --stages: {unknown_subset}")
    if not stage_list:
        raise ValueError("No stages selected to run")

    print(f"Discovered stages: {', '.join(discovered)}")
    print(f"Selected stages:   {', '.join(stage_list)}")

    results: list[StageResult] = []

    for idx, stage in enumerate(stage_list, start=1):
        print("\n" + "=" * 72)
        print(f"[{idx}/{len(stage_list)}] stage: {stage}")
        print("=" * 72)

        stage_data_dir = data_root / stage
        if not stage_data_dir.exists():
            msg = f"missing data directory: {stage_data_dir}"
            print(f"[stage={stage}] SKIP: {msg}")
            results.append(StageResult(stage=stage, rc=2, status="skipped", reason=msg))
            if not args.continue_on_error:
                break
            continue

        rc = preprocess_stage(repo_root, workdir, stage, args.sanitize_control_chars)
        if rc != 0:
            msg = f"preprocess failed (rc={rc})"
            print(f"[stage={stage}] FAIL: {msg}")
            results.append(StageResult(stage=stage, rc=rc, status="failed", reason=msg))
            if not args.continue_on_error:
                break
            continue

        try:
            wrk_cfg = load_stage_wrk_cfg(generated_dir, stage)
            remap_stage_artifacts(generated_dir, stage)
        except Exception as exc:  # noqa: BLE001
            msg = f"prepare artifacts failed: {exc}"
            print(f"[stage={stage}] FAIL: {msg}")
            results.append(StageResult(stage=stage, rc=3, status="failed", reason=msg))
            if not args.continue_on_error:
                break
            continue

        rc = run_stage_wrk(repo_root, workdir, wrk_cfg, args.target_url, args.flow_failure_logs)
        if rc == 0:
            results.append(StageResult(stage=stage, rc=0, status="passed"))
        else:
            msg = f"wrk failed (rc={rc})"
            print(f"[stage={stage}] FAIL: {msg}")
            results.append(StageResult(stage=stage, rc=rc, status="failed", reason=msg))
            if not args.continue_on_error:
                break

    print("\n" + "-" * 72)
    print("Stage execution summary")
    print("-" * 72)
    for r in results:
        suffix = f" ({r.reason})" if r.reason else ""
        print(f"  - {r.stage}: {r.status} rc={r.rc}{suffix}")

    failed = [r for r in results if r.status == "failed"]
    skipped = [r for r in results if r.status == "skipped"]
    passed = [r for r in results if r.status == "passed"]
    print(f"Totals: passed={len(passed)} failed={len(failed)} skipped={len(skipped)}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
