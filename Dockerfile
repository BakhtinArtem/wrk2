# wrk2 + v3.0 flow launcher (static / template executors, optional stats files).
#
# Public image (Docker Hub): docker pull aape2k/wrk2-flow:v3.0
#
# Build (from repo root):
#   docker build -t wrk2-flow:v3.0 .
#
# FLOW_DATA_DIR should usually come from the host: mount the directory that contains
# the stage folder (e.g. .../data with lifecycle/iteration-*.json inside) and set
# FLOW_DATA_DIR to the in-container path.
#
# Run (static data from host; same Docker network as the target service):
#   docker run --rm -it --network mynet \
#     -v "/absolute/path/on/host/v1.0/data:/flowdata:ro" \
#     -e FLOW_EXECUTOR_MODE=static \
#     -e FLOW_DATA_DIR=/flowdata \
#     -e FLOW_STAGE=lifecycle \
#     -v "$(pwd)/stats-out:/stats" \
#     -e FLOW_STATS_OUT_DIR=/stats \
#     aape2k/wrk2-flow:v3.0 -t2 -c10 -R500 -d20s http://petclinic:9966/
#
# Template data from host:
#   docker run --rm -it --network mynet \
#     -v "/absolute/path/on/host/v2.0/data:/flowdata:ro" \
#     -e FLOW_EXECUTOR_MODE=templates \
#     -e FLOW_DATA_DIR=/flowdata \
#     -e FLOW_STAGE=lifecycle \
#     aape2k/wrk2-flow:v3.0 -t2 -c10 -R500 -d20s http://petclinic:9966/
#
# The image also embeds sample workdir/v1.0/data and v2.0/data for smoke tests;
# for real runs, mount host data as above.
#
# FLOW_EXECUTOR_MODE: static | templates
# All wrk args are passed through (including -R). If FLOW_STATS_OUT_DIR is set,
# run_flow.sh writes wrk output log files there with the stats artifacts.

FROM ubuntu:jammy AS wrk2-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# LuaJIT pin (ARM-friendly tree; same idea as upstream fork Dockerfile).
RUN git clone https://luajit.org/git/luajit.git /tmp/luajit \
    && cd /tmp/luajit \
    && git reset --hard 224129a8e64bfa219d35cd03055bf03952f167f6

COPY . /tmp/wrk2

RUN rm -rf /tmp/wrk2/deps/luajit \
    && mv /tmp/luajit /tmp/wrk2/deps/luajit

WORKDIR /tmp/wrk2

RUN sed -ri 's/#include <x86intrin.h>//g' src/hdr_histogram.c \
    && sed -ri 's/\bluaL_reg\b/luaL_Reg/g' src/script.c \
    && make

# Flow scripts require cjson; wrk links LuaJIT statically and uses -Wl,-E on Linux so
# this module resolves Lua API symbols from the wrk binary at load time.
RUN mkdir -p /tmp/artifacts/lualib \
    && curl -fsSL https://github.com/openresty/lua-cjson/archive/refs/tags/2.1.0.11.tar.gz \
        | tar xz -C /tmp \
    && cd /tmp/lua-cjson-2.1.0.11 \
    && make LUA_INCLUDE_DIR=/tmp/wrk2/deps/luajit/src \
    && cp cjson.so /tmp/artifacts/lualib/ \
    && cp /tmp/wrk2/wrk /tmp/artifacts/wrk \
    && chmod +x /tmp/artifacts/wrk

# ---------------------------------------------------------------------------
FROM ubuntu:jammy

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=wrk2-builder /tmp/artifacts/wrk /opt/wrk2/wrk
COPY --from=wrk2-builder /tmp/artifacts/lualib/cjson.so /opt/wrk2/lualib/cjson.so

# Default iteration data for static (v1.0) and template (v2.0) modes.
COPY workdir/v1.0/data /opt/wrk2/workdir/v1.0/data
COPY workdir/v2.0/data /opt/wrk2/workdir/v2.0/data

# v3.0 entrypoint and Lua flow executors (self-contained under workdir/v3.0).
COPY workdir/v3.0/run_flow.sh /opt/wrk2/workdir/v3.0/run_flow.sh
COPY workdir/v3.0/run.md /opt/wrk2/workdir/v3.0/run.md
COPY workdir/v3.0/flow_executor_env.lua /opt/wrk2/workdir/v3.0/flow_executor_env.lua
COPY workdir/v3.0/flow_executor_templates.lua /opt/wrk2/workdir/v3.0/flow_executor_templates.lua

RUN chmod +x /opt/wrk2/wrk /opt/wrk2/workdir/v3.0/run_flow.sh

ENV LUA_CPATH=/opt/wrk2/lualib/?.so;;
WORKDIR /opt/wrk2

ENTRYPOINT ["/opt/wrk2/workdir/v3.0/run_flow.sh"]
# Override with wrk flags and target URL, e.g. -t2 -c10 -d30s http://service:8080/
CMD ["-t1", "-c1", "-d1s", "http://127.0.0.1:8080/"]
