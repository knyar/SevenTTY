#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="${SEVENTTY_RETRO68_BASE_IMAGE:-ghcr.io/autc04/retro68:latest}"
IMAGE="${SEVENTTY_DOCKER_IMAGE:-seventty-retro68:compat-v5}"
RETRO68_PATH="${SEVENTTY_RETRO68_PATH:-/Retro68-build}"
INTERFACES_FILE="${SEVENTTY_INTERFACES_FILE:-MPW-GM.img.bin}"
INTERFACES_URL="${SEVENTTY_INTERFACES_URL:-https://staticky.com/mirrors/ftp.apple.com/developer/Tool_Chest/Core_Mac_OS_Tools/MPW_etc./MPW-GM_Images/MPW-GM.img.bin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERFACES_PATH="${SCRIPT_DIR}/${INTERFACES_FILE}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: docker daemon is not available" >&2
  exit 1
fi

if [[ ! -f "${INTERFACES_PATH}" ]]; then
  echo "downloading Universal Interfaces image to ${INTERFACES_PATH}..."
  curl -L --fail --output "${INTERFACES_PATH}" "${INTERFACES_URL}"
fi

if [[ -z "${SEVENTTY_DOCKER_IMAGE:-}" ]]; then
  if [[ "${SEVENTTY_REBUILD_IMAGE:-0}" == "1" ]] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "building Docker image ${IMAGE}..."
    BUILD_CONTEXT="$(mktemp -d)"
    trap 'rm -rf "${BUILD_CONTEXT}"' EXIT
    cp "${INTERFACES_PATH}" "${BUILD_CONTEXT}/MPW-GM.img.bin"

    docker build \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
      --tag "${IMAGE}" \
      -f - "${BUILD_CONTEXT}" <<'EOF'
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ghcr.io/autc04/retro68:latest

FROM ${BASE_IMAGE}
COPY MPW-GM.img.bin /var/tmp/MPW-GM.img.bin
RUN INTERFACES=universal INTERFACESFILE=/var/tmp/MPW-GM.img.bin /Retro68-build/bin/docker-entrypoint.sh /bin/true
EOF
  fi
fi

DOCKER_ARGS=(
  run
  --rm
  --interactive
  --entrypoint /bin/bash
  --user "${HOST_UID}:${HOST_GID}"
  --workdir /work
  --env HOME=/tmp
  --env "RETRO68_PATH=${RETRO68_PATH}"
  --mount "type=bind,source=${SCRIPT_DIR},target=/work"
)

if [[ -n "${DOCKER_PLATFORM:-}" ]]; then
  DOCKER_ARGS+=(--platform "${DOCKER_PLATFORM}")
fi

DOCKER_ARGS+=("${IMAGE}" -s)

docker "${DOCKER_ARGS[@]}" <<'EOF'
set -euo pipefail

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake is missing from the Docker image" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is missing from the Docker image" >&2
  exit 1
fi

if [[ ! -d "${RETRO68_PATH}/toolchain" ]]; then
  echo "error: Retro68 toolchain not found at ${RETRO68_PATH}/toolchain" >&2
  exit 1
fi

BUILD_PARALLEL=()
if command -v nproc >/dev/null 2>&1; then
  BUILD_PARALLEL=(--parallel "$(nproc)")
fi

echo "initializing submodules..."
git -c url.https://github.com/.insteadOf=git@github.com: \
  submodule update --init --recursive

echo "building PPC..."
rm -rf build-ppc
cmake -S . -B build-ppc \
  -DCMAKE_TOOLCHAIN_FILE="${RETRO68_PATH}/toolchain/powerpc-apple-macos/cmake/retroppc.toolchain.cmake"
cmake --build build-ppc "${BUILD_PARALLEL[@]}"

echo "building m68k..."
rm -rf build-m68k
cmake -S . -B build-m68k \
  -DCMAKE_TOOLCHAIN_FILE="${RETRO68_PATH}/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake"
cmake --build build-m68k "${BUILD_PARALLEL[@]}"

echo "Rez-ing it all together..."
rm -rf build-fat
mkdir -p build-fat

"${RETRO68_PATH}/toolchain/bin/Rez" \
  "${RETRO68_PATH}/toolchain/m68k-apple-macos/RIncludes/RetroPPCAPPL.r" \
  -I"${RETRO68_PATH}/toolchain/m68k-apple-macos/RIncludes" \
  -DCFRAG_NAME="\"SevenTTY\"" \
  --copy build-m68k/SevenTTY.code.bin \
  -o build-fat/SevenTTY-fat.bin \
  --cc build-fat/SevenTTY-fat.dsk \
  --cc build-fat/SevenTTY-fat.APPL \
  --cc build-fat/%SevenTTY-fat.ad \
  -t APPL \
  -c SSH7 \
  --data build-ppc/SevenTTY.pef build-ppc/resources.r.rsrc.bin build-ppc/symbolfont.r.rsrc.bin

echo "done: build-fat/SevenTTY-fat.bin"
EOF
