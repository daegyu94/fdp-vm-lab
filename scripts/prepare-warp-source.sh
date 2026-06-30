#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

warp_path_for_git=$(realpath --relative-to "${ROOT_DIR}" "${WARP_SOURCE_DIR}")

if ! git -C "${WARP_SOURCE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -f ${ROOT_DIR}/.gitmodules ]] && git -C "${ROOT_DIR}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | grep -Fxq "${warp_path_for_git}"; then
        git -C "${ROOT_DIR}" submodule update --init --recursive -- "${warp_path_for_git}"
    else
        [[ ! -e ${WARP_SOURCE_DIR} ]] || die "WARP_SOURCE_DIR가 비어 있지 않은 비-Git 경로입니다: ${WARP_SOURCE_DIR}"
        git clone --no-checkout "${WARP_REPOSITORY_URL}" "${WARP_SOURCE_DIR}"
    fi
fi

actual_url=$(git -C "${WARP_SOURCE_DIR}" remote get-url origin)
[[ ${actual_url%.git} == "${WARP_REPOSITORY_URL%.git}" ]] ||     die "기존 WARP checkout의 origin이 설정과 다릅니다: ${actual_url}"

if ! git -C "${WARP_SOURCE_DIR}" cat-file -e "${WARP_REF}^{commit}" 2>/dev/null; then
    git -C "${WARP_SOURCE_DIR}" fetch origin "${WARP_FETCH_REF}"
fi
git -C "${WARP_SOURCE_DIR}" cat-file -e "${WARP_REF}^{commit}" 2>/dev/null ||     die "WARP_REF commit을 찾을 수 없습니다: ${WARP_REF}"

current=$(git -C "${WARP_SOURCE_DIR}" rev-parse HEAD 2>/dev/null || true)
if [[ ${current} != "${WARP_REF}" ]]; then
    [[ -z $(git -C "${WARP_SOURCE_DIR}" status --porcelain) ]] ||         die "WARP checkout에 변경 사항이 있어 ${WARP_REF}로 전환할 수 없습니다."
    git -C "${WARP_SOURCE_DIR}" checkout --detach "${WARP_REF}"
fi

[[ $(git -C "${WARP_SOURCE_DIR}" rev-parse HEAD) == "${WARP_REF}" ]] ||     die "WARP source pin 검증에 실패했습니다."
log "WARP source 준비 완료: ${WARP_REF}"
