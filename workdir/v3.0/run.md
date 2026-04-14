# v3.0 launcher + persisted `done()` stats

Use [`run_flow.sh`](run_flow.sh) to pick the static or template executor ([`flow_executor_env.lua`](flow_executor_env.lua) / [`flow_executor_templates.lua`](flow_executor_templates.lua) under this directory). Optional stats files are written from `done()` when `FLOW_STATS_OUT_DIR` is set (implemented in the Lua scripts, not by parsing stdout). All wrk CLI arguments are passed through unchanged, so wrk2 rate limiting with `-R` is fully supported.

## Example (static data, JSON stats)

```bash
FLOW_EXECUTOR_MODE=static \
FLOW_DATA_DIR=workdir/v1.0/data \
FLOW_STAGE=lifecycle \
FLOW_API_PREFIX=/petclinic/api \
FLOW_REUSE_MODE=wrap \
FLOW_FAIL_ON_NON2XX=1 \
FLOW_LOG_EVERY=0 \
FLOW_IDLE_PATH=/owners \
FLOW_STATS_OUT_DIR=workdir/v3.0/output \
./workdir/v3.0/run_flow.sh -t2 -c5 -R500 -d20s http://localhost:9966/
```

## Example (template data, JSON + CSV)

```bash
FLOW_EXECUTOR_MODE=templates \
FLOW_DATA_DIR=workdir/v2.0/data \
FLOW_STAGE=lifecycle \
FLOW_API_PREFIX=/petclinic/api \
FLOW_REUSE_MODE=wrap \
FLOW_FAIL_ON_NON2XX=1 \
FLOW_LOG_EVERY=0 \
FLOW_IDLE_PATH=/owners \
FLOW_STATS_OUT_DIR=workdir/v3.0/output \
FLOW_STATS_FORMAT=both \
./workdir/v3.0/run_flow.sh -t2 -c5 -R500 -d20s http://localhost:9966/
```

## v3.0 / launcher env vars

| Variable | Meaning |
|----------|---------|
| `FLOW_EXECUTOR_MODE` | Required: `static` → `flow_executor_env.lua`; `templates` → `flow_executor_templates.lua` (paths under `workdir/v3.0/`). |
| `FLOW_STATS_OUT_DIR` | If set, `done()` writes stats under this directory (the shell runs `mkdir -p` before `wrk`). |
| `FLOW_STATS_FORMAT` | Optional. Default (empty): JSON only. `json` → JSON only. `csv` → CSV only (`*_step_stats.csv`, `*_step_status.csv`, `*_summary.csv`). `both` or `all`, or `json,csv` → JSON and CSV. |
| `FLOW_WRK_OUTPUT_FILE` | Optional. Override wrk text log file path when `FLOW_STATS_OUT_DIR` is set. Absolute path is used as-is; relative path is created under `FLOW_STATS_OUT_DIR`. |
| `FLOW_DEBUG_NON2XX` | Optional. `1` enables non-2xx debug capture in v3.0 executors (writes `non2xx_debug_*.jsonl` to `FLOW_STATS_OUT_DIR`). Default `0`. |
| `FLOW_DEBUG_NON2XX_BODY_MAX_BYTES` | Optional. Per-record response body cap when debug is enabled. Default `4096`. |

## Flow env vars (passed through to Lua)

Same as v1.2 / v2.1 (defaults shown):

- `FLOW_DATA_DIR` — `workdir/v1.0/data` (static) or `workdir/v2.0/data` (templates) in the respective scripts if unset
- `FLOW_STAGE` — `lifecycle`
- `FLOW_API_PREFIX` — `/petclinic/api`
- `FLOW_REUSE_MODE` — `wrap` \| `stop`
- `FLOW_FAIL_ON_NON2XX` — `1` \| `0`
- `FLOW_LOG_EVERY` — `0`
- `FLOW_IDLE_PATH` — `/owners`

## Stats JSON shape

Written as `flow_stats_<UTC-datetime>_<clock-suffix>.json`:

- `executor` — `flow_executor_env` or `flow_executor_templates`
- `ts_utc` — ISO-8601 UTC timestamp
- `stage`, `data_dir` — strings
- `summary` — object: same counters as printed under `--- flow_executor_* ---` (static: no template/decode fields; templates: includes `template_resolve_failures`, `decode_failures`, `encode_failures`)
- `step_stats` — array of `{ "step", "count", "sum_us", "max_us", "avg_us" }`
- `step_status` — array of `{ "key", "count" }` (`key` matches the `step_status` line label)

Stdout `step_stats` / `step_status` lines are unchanged; the file mirrors those aggregates.

## Non-2xx debug output (v3.0)

Set `FLOW_DEBUG_NON2XX=1` to capture every non-2xx response as JSON Lines in:

- `non2xx_debug_<UTC-datetime>_<clock-suffix>.jsonl`

Each line includes request context (`flow_id`, `method`, `path`, `status`, iteration/step ids) and `body`. The body is truncated to `FLOW_DEBUG_NON2XX_BODY_MAX_BYTES` and `body_truncated=true` is set when truncation occurs.

This mode is for troubleshooting and adds overhead (extra allocations and larger output files). Keep it disabled for benchmark runs.

## Docker image

From the repository root, build:

```bash
docker build -t wrk2-flow:v3.0 .
```

The image installs `wrk` at `/opt/wrk2/wrk`, bundles **sample** `workdir/v1.0/data` and `workdir/v2.0/data` (optional fallback for smoke tests), and `workdir/v3.0` (launcher + Lua). `LUA_CPATH` is set so `lua-cjson` loads for the flow scripts.

### Docker Hub (public image)

Published as **`aape2k/wrk2-flow`** (tags **`v3.0`** and **`latest`**):

```bash
docker pull aape2k/wrk2-flow:v3.0
```

The `docker run` examples below use **`aape2k/wrk2-flow:v3.0`**. After a local `docker build -t wrk2-flow:v3.0 .`, use **`wrk2-flow:v3.0`** as the image name instead.

To publish from this repository (maintainers):

```bash
docker build -t wrk2-flow:v3.0 .
docker tag wrk2-flow:v3.0 aape2k/wrk2-flow:v3.0
docker tag wrk2-flow:v3.0 aape2k/wrk2-flow:latest
docker login -u aape2k
docker push aape2k/wrk2-flow:v3.0
docker push aape2k/wrk2-flow:latest
```

After the first push, open [Docker Hub](https://hub.docker.com/) → **Repositories** → **`aape2k/wrk2-flow`** → **Settings** → **Visibility** → **Public** (if the repo was created as private).

If `docker push` fails with a proxy error (for example `proxyconnect … i/o timeout`), retry with proxy variables unset for that command, e.g. `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy docker push …`.

### `FLOW_DATA_DIR` from the host (recommended)

`FLOW_DATA_DIR` must be the directory that **contains the stage folder** (default stage name `lifecycle`). The executor loads `FLOW_DATA_DIR/<FLOW_STAGE>/iteration-*.json` (e.g. `…/data/lifecycle/iteration-000001.json` on the host when you mount `…/data` at `/flowdata` and set `FLOW_STAGE=lifecycle`).

Mount your machine’s data directory into the container and point `FLOW_DATA_DIR` at the **in-container** mount path:

**Static flow data** (same shape as repo `workdir/v1.0/data`):

```bash
docker run --rm -it --network your_net \
  -v "$(pwd)/workdir/v1.0/data:/flowdata:ro" \
  -e FLOW_EXECUTOR_MODE=static \
  -e FLOW_DATA_DIR=/flowdata \
  -e FLOW_STAGE=lifecycle \
  -v "$(pwd)/stats-out:/stats" \
  -e FLOW_STATS_OUT_DIR=/stats \
  aape2k/wrk2-flow:v3.0 -t2 -c5 -R500 -d20s http://petclinic:9966/
```

**Template flow data** (same shape as repo `workdir/v2.0/data`):

```bash
docker run --rm -it --network your_net \
  -v "$(pwd)/workdir/v2.0/data:/flowdata:ro" \
  -e FLOW_EXECUTOR_MODE=templates \
  -v "$(pwd)/stats-out:/stats" \
  -e FLOW_STATS_OUT_DIR=/stats \
  -e FLOW_DATA_DIR=/flowdata \
  -e FLOW_STAGE=lifecycle \
  aape2k/wrk2-flow:v3.0 -t2 -c5 -R500 -d20s http://petclinic:9966/
```

Replace `/absolute/path/on/host/...` with your checkout or CI artifact path; use `:ro` if you want the mount read-only. Replace `your_net` and `http://petclinic:9966/` with the Docker network and target URL.

### Without a host mount

You can omit `-v …/data:…` and use the bundled paths under `/opt/wrk2`, for example `-e FLOW_DATA_DIR=workdir/v1.0/data` (static) or `workdir/v2.0/data` (templates), as long as the working directory layout matches; for real workloads, prefer mounting host data as above.

When `FLOW_STATS_OUT_DIR` is set, `run_flow.sh` also writes full wrk stdout/stderr to `wrk_output_<UTC-timestamp>.log` in the same directory as the JSON/CSV stats.
