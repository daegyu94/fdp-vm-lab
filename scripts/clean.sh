#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

mode=${1:-clean}
vm_running && die "실행 중인 VM이 있습니다. 먼저 ./bringup.sh --stop을 실행하십시오."

[[ ${WARP_BUILD_DIR} == "${WARP_SOURCE_DIR}"/* ]] || \
    die "안전하지 않은 WARP_BUILD_DIR입니다: ${WARP_BUILD_DIR}"
rm -rf "${WARP_BUILD_DIR}"
rm -f "${QMP_SOCKET}" "${QEMU_PID_FILE}" \
    "${STATE_DIR}/user-data" "${STATE_DIR}/guest.env"
rm -f "${LOG_DIR}"/*.log

if [[ ${mode} == full-clean ]]; then
    rm -f "${GUEST_IMAGE_PATH}" "${SEED_IMAGE}" "${SSH_KEY}" "${SSH_KEY}.pub" \
        "${STATE_DIR}/known_hosts"
    log "Build output과 customized guest image를 제거했습니다. Base image와 source는 유지합니다."
else
    log "WARP build output과 임시 파일을 제거했습니다. Guest image와 seed는 유지합니다."
fi

