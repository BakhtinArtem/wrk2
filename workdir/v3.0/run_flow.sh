#!/usr/bin/env bash
# v3.0: select static (v1.2) vs template (v2.1) flow executor; forwards all args to wrk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -x ./wrk ]]; then
  echo "run_flow.sh: ./wrk not found or not executable in ${REPO_ROOT}" >&2
  exit 1
fi

mode="${FLOW_EXECUTOR_MODE:-}"
case "${mode}" in
  static)
    lua_script="workdir/v3.0/flow_executor_env.lua"
    ;;
  templates)
    lua_script="workdir/v3.0/flow_executor_templates.lua"
    ;;
  *)
    echo "run_flow.sh: set FLOW_EXECUTOR_MODE to static or templates (got: ${mode:-<empty>})" >&2
    exit 1
    ;;
esac

stats_dir="${FLOW_STATS_OUT_DIR:-}"
if [[ -n "${stats_dir}" ]]; then
  mkdir -p -- "${stats_dir}"
fi

if [[ -z "${stats_dir}" ]]; then
  exec ./wrk -s "${lua_script}" "$@"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${FLOW_WRK_OUTPUT_FILE:-wrk_output_${timestamp}.log}"
if [[ "${log_file}" != /* ]]; then
  log_file="${stats_dir}/${log_file}"
fi
mkdir -p -- "$(dirname -- "${log_file}")"

./wrk -s "${lua_script}" "$@" 2>&1 | tee "${log_file}"
exit "${PIPESTATUS[0]}"
