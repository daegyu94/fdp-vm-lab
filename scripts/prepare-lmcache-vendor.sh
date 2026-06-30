#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

if ! is_true "${LMCACHE_INSTALL_ENABLED}"; then
    log "LMCache install이 비활성화되어 cargo vendor 준비를 건너뜁니다."
    exit 0
fi

require_command git
require_command cargo
require_command tar

vendor_archive="${STATE_DIR}/lmcache-cargo-vendor.tar.gz"
source_archive="${STATE_DIR}/lmcache-source.tar.gz"
vendor_stamp="${STATE_DIR}/lmcache-cargo-vendor.stamp"
expected_stamp=$(printf '%s\n%s\n%s\n' \
    "${LMCACHE_REPOSITORY_URL}" \
    "${LMCACHE_REPOSITORY_BRANCH}" \
    "${LMCACHE_REPOSITORY_COMMIT}")

if [[ -f ${vendor_archive} && -f ${source_archive} && -f ${vendor_stamp} ]] && \
    [[ $(<"${vendor_stamp}") == "${expected_stamp}" ]]; then
    log "기존 LMCache source/cargo vendor archive를 재사용합니다."
    exit 0
fi

tmp=$(mktemp -d "${STATE_DIR}/lmcache-vendor.XXXXXX")
cleanup() {
    rm -rf "${tmp}"
}
trap cleanup EXIT

clone_args=()
if [[ -n ${LMCACHE_REPOSITORY_BRANCH} ]]; then
    clone_args+=(--branch "${LMCACHE_REPOSITORY_BRANCH}")
fi
if ! git clone "${clone_args[@]}" "${LMCACHE_REPOSITORY_URL}" "${tmp}/LMCache"; then
    fallback=/tmp/lmcache-fdp-check
    if [[ -d ${fallback}/.git ]] && \
        [[ -z ${LMCACHE_REPOSITORY_COMMIT} || \
           $(git -C "${fallback}" rev-parse HEAD) == "${LMCACHE_REPOSITORY_COMMIT}" ]]; then
        log "Git clone 실패; 기존 checkout을 사용합니다: ${fallback}"
        cp -a "${fallback}" "${tmp}/LMCache"
    else
        die "LMCache clone에 실패했고 사용 가능한 fallback checkout이 없습니다."
    fi
fi
if [[ -n ${LMCACHE_REPOSITORY_COMMIT} ]]; then
    git -C "${tmp}/LMCache" checkout --detach "${LMCACHE_REPOSITORY_COMMIT}"
fi

manifest="${tmp}/LMCache/rust/raw_block/Cargo.toml"
[[ -f ${manifest} ]] || die "LMCache raw_block Cargo.toml을 찾을 수 없습니다: ${manifest}"

mkdir -p "${tmp}/cargo"
cargo vendor --manifest-path "${manifest}" "${tmp}/cargo/vendor" \
    > "${tmp}/cargo/config.toml"

sed -i 's#directory = ".*"#directory = "vendor"#' "${tmp}/cargo/config.toml"
tar -C "${tmp}/cargo" -czf "${vendor_archive}.tmp" config.toml vendor
tar -C "${tmp}" -czf "${source_archive}.tmp" LMCache
mv "${vendor_archive}.tmp" "${vendor_archive}"
mv "${source_archive}.tmp" "${source_archive}"
printf '%s' "${expected_stamp}" > "${vendor_stamp}"

log "LMCache source/cargo vendor archive 준비 완료: ${source_archive}, ${vendor_archive}"
