#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

force=${1:-0}
marker="${WARP_BUILD_DIR}/.warp-fdp-build-ref"

if [[ ${force} != 1 && -x ${WARP_QEMU} && -f ${marker} ]] && \
    [[ $(<"${marker}") == "${WARP_REF}" ]] && \
    "${WARP_QEMU}" -device femu-subsys,help 2>&1 | grep -Fq 'fdp.nruh'; then
    log "기존 WARP/FEMU build를 재사용합니다."
    exit 0
fi

# An existing verified binary from the same source is reusable even if it
# predates this environment's marker file.
if [[ ${force} != 1 && -x ${WARP_QEMU} ]] && \
    [[ $(git -C "${WARP_SOURCE_DIR}" rev-parse HEAD) == "${WARP_REF}" ]] && \
    "${WARP_QEMU}" -device femu-subsys,help 2>&1 | grep -Fq 'fdp.nruh'; then
    printf '%s\n' "${WARP_REF}" > "${marker}"
    log "기존 WARP/FEMU build의 FDP 지원을 확인하고 재사용합니다."
    exit 0
fi

mkdir -p "${WARP_BUILD_DIR}"
if [[ ${force} == 1 && -f ${WARP_BUILD_DIR}/Makefile ]]; then
    make -C "${WARP_BUILD_DIR}" clean
fi

if [[ ! -f ${WARP_BUILD_DIR}/config-host.mak || ${force} == 1 ]]; then
    (
        cd "${WARP_BUILD_DIR}"
        "${WARP_SOURCE_DIR}/configure" \
            --enable-kvm \
            --enable-slirp \
            --disable-werror \
            --target-list=x86_64-softmmu
    )
fi
make -C "${WARP_BUILD_DIR}" -j"$(nproc)"
[[ -x ${WARP_QEMU} ]] || die "WARP QEMU build output이 없습니다: ${WARP_QEMU}"
"${WARP_QEMU}" -device femu-subsys,help 2>&1 | grep -Fq 'fdp.nruh' || \
    die "빌드된 WARP QEMU에서 FEMU FDP option을 찾을 수 없습니다."
printf '%s\n' "${WARP_REF}" > "${marker}"
log "WARP/FEMU build 완료: ${WARP_QEMU}"

