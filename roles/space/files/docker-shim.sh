#!/usr/bin/env bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# `docker` for upstream SPACE's build scripts on a cluster node, which runs no
# Docker: `docker build` becomes buildctl on the SPACE BuildKit (images go into
# containerd's k8s.io namespace), and every other command goes to nerdctl there.
set -euo pipefail
NS=k8s.io
BUILDKIT=unix:///run/space-buildkit/buildkitd.sock

# Docker hands the client's proxy to builds and containers; do the same
proxy_vars=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  [[ -n ${!v:-} ]] && proxy_vars+=("$v")
done

if [[ ${1:-} != build ]]; then
  # Build helpers need no cluster networking
  if [[ ${1:-} == run || ${1:-} == create ]]; then
    cmd=$1; shift
    env_args=()
    for v in "${proxy_vars[@]}"; do env_args+=(-e "$v=${!v}"); done
    exec nerdctl --namespace "$NS" "$cmd" --net=host "${env_args[@]}" "$@"
  fi
  exec nerdctl --namespace "$NS" "$@"
fi
shift

opts=() tags=() outputs=() file=Dockerfile ctx=""
# Predefined build args, as Docker passes them: RUN steps reach the network through the proxy
for v in "${proxy_vars[@]}"; do opts+=(--opt "build-arg:$v=${!v}"); done
add_context() { # name=value, value a directory or a docker-image:// ref
  local name=${1%%=*} value=${1#*=}
  if [[ $value == *://* ]]; then
    opts+=(--opt "context:$name=$value")
  else
    opts+=(--local "ctx-$name=$value" --opt "context:$name=local:ctx-$name")
  fi
}
build_arg() { # NAME=value, or NAME to take it from the environment
  if [[ $1 == *=* ]]; then opts+=(--opt "build-arg:$1"); else opts+=(--opt "build-arg:$1=${!1:-}"); fi
}
while (($#)); do
  case $1 in
    -t|--tag) tags+=("$2"); shift 2 ;;
    --tag=*) tags+=("${1#*=}"); shift ;;
    -f|--file) file=$2; shift 2 ;;
    --file=*) file=${1#*=}; shift ;;
    --target) opts+=(--opt "target=$2"); shift 2 ;;
    --target=*) opts+=(--opt "target=${1#*=}"); shift ;;
    --build-arg) build_arg "$2"; shift 2 ;;
    --build-arg=*) build_arg "${1#*=}"; shift ;;
    --build-context) add_context "$2"; shift 2 ;;
    --build-context=*) add_context "${1#*=}"; shift ;;
    # buildx's cacheonly means "build, export nothing": no BuildKit exporter
    --output|-o) [[ $2 == type=cacheonly* ]] || outputs+=("$2"); shift 2 ;;
    --output=*) [[ ${1#*=} == type=cacheonly* ]] || outputs+=("${1#*=}"); shift ;;
    --platform) opts+=(--opt "platform=$2"); shift 2 ;;
    --provenance=*|--sbom=*|--progress=*|--pull|--load|--quiet|-q) shift ;;
    --provenance|--sbom|--progress|--cache-from|--cache-to|--iidfile) shift 2 ;;
    -*) echo "docker shim: unsupported build option $1" >&2; exit 2 ;;
    *) ctx=$1; shift ;;
  esac
done
[[ -n $ctx ]] || { echo "docker shim: no build context" >&2; exit 2; }
[[ $file == /* ]] || file=$PWD/$file

if ((${#tags[@]})); then
  outputs+=("type=image,\"name=$(IFS=,; echo "${tags[*]}")\",unpack=true")
fi
out_args=()
for o in "${outputs[@]}"; do out_args+=(--output "$o"); done

exec buildctl --addr "$BUILDKIT" build --progress=plain \
  --frontend dockerfile.v0 \
  --local context="$ctx" --local dockerfile="$(dirname "$file")" \
  --opt filename="$(basename "$file")" \
  "${opts[@]}" "${out_args[@]}"
