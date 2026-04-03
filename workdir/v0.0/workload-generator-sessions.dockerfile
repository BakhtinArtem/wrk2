FROM ubuntu:jammy AS wrk2-builder

RUN \
    # Install build dependencies
    apt-get update && \
    apt-get install -y build-essential curl git libssl-dev libz-dev zlib1g-dev && \
    apt-get clean && \
    # Clone repo at the commit ID we expect to patch:
    git clone --branch session-id-tracking --single-branch --depth 1 \
    https://github.com/BakhtinArtem/wrk2.git /tmp/wrk2 && \
    # Update LuaJIT to an ARM-compatible version: \
    git clone https://luajit.org/git/luajit.git /tmp/luajit \
    && cd /tmp/luajit \
    && git reset --hard 224129a8e64bfa219d35cd03055bf03952f167f6 \
    && cp -ar /tmp/luajit/* /tmp/wrk2/deps/luajit/

WORKDIR /tmp/wrk2
RUN \
    # Patch files to make them ARM-compatible:
    sed -ri 's/#include <x86intrin.h>//g' src/hdr_histogram.c \
    && sed -ri 's/\bluaL_reg\b/luaL_Reg/g'   src/script.c && \
    # Install additional libs
    apt-get install luarocks -y && apt-get install libyaml-dev -y && apt-get clean && \
    mkdir /root/.luarocks/ && \
    export export LUAJIT_LIB=/tmp/wrk2/deps/luajit && luarocks config variables.LUAJIT_LIB $LUAJIT_LIB && \
    luarocks install luaposix && luarocks install luasocket &&  luarocks install faker2 && luarocks --server=http://rocks.moonscript.org install lyaml && \
    make && cp /tmp/wrk2/wrk /usr/local/bin/wrk2

# Copy all files from src to /wrktemp
COPY src/ /wrktemp/