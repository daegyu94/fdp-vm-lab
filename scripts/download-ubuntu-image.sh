#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

verify_image() {
    [[ -f ${GUEST_BASE_IMAGE_PATH} ]] || return 1
    printf '%s  %s\n' "${GUEST_BASE_IMAGE_SHA256}" "${GUEST_BASE_IMAGE_PATH}" | sha256sum --check --status
}

if verify_image; then
    log "checksum이 일치하는 기존 Ubuntu base image를 재사용합니다."
    exit 0
fi

if [[ -f ${GUEST_BASE_IMAGE_PATH} ]]; then
    warn "기존 base image checksum이 달라 다시 다운로드합니다."
    rm -f "${GUEST_BASE_IMAGE_PATH}"
fi

part="${GUEST_BASE_IMAGE_PATH}.part"
curl --fail --location --retry 5 --continue-at - \
    --output "${part}" "${GUEST_BASE_IMAGE_URL}"
printf '%s  %s\n' "${GUEST_BASE_IMAGE_SHA256}" "${part}" | sha256sum --check --status || \
    die "다운로드한 Ubuntu base image SHA-256이 설정과 다릅니다."
mv "${part}" "${GUEST_BASE_IMAGE_PATH}"
log "Ubuntu base image 다운로드 완료: ${GUEST_BASE_IMAGE_PATH}"

