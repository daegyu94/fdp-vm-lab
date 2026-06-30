#!/usr/bin/env bash

set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT_DIR}/scripts/common.sh"


format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if ((hours > 0)); then
        printf '%dh %02dm %02ds' "${hours}" "${minutes}" "${secs}"
    elif ((minutes > 0)); then
        printf '%dm %02ds' "${minutes}" "${secs}"
    else
        printf '%ds' "${secs}"
    fi
}

run_step() {
    local index=$1 total=$2 label=$3
    shift 3

    local start end elapsed status
    start=$(date +%s)
    log "[${index}/${total}] ${label} 시작"
    if "$@"; then
        end=$(date +%s)
        elapsed=$((end - start))
        log "[${index}/${total}] ${label} 완료 ($(format_duration "${elapsed}"))"
    else
        status=$?
        end=$(date +%s)
        elapsed=$((end - start))
        log "[${index}/${total}] ${label} 실패 ($(format_duration "${elapsed}"), exit ${status})"
        return "${status}"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./bringup.sh [OPTION]

Without an option, prepare an FDP emulator VM and open an SSH shell.

  --no-ssh          prepare and verify the VM without opening a shell
  --rebuild-warp     force a WARP/FEMU rebuild, then bring up the VM
  --rebuild-guest    recreate the guest overlay and seed, then bring up the VM
  --with-lmcache     also build and verify CPU-only LMCache in the guest
  --status           show QEMU, SSH, cloud-init, FDP, Python and LMCache status
  --stop             gracefully stop the guest and clean up QEMU state
  --clean            remove WARP build output and temporary files
  --full-clean       also remove the customized guest image and seed
  --help             show this help
EOF
}

attach=1
rebuild_warp=0
rebuild_guest=0
with_lmcache=0
action=bringup

while (($#)); do
    case $1 in
        --no-ssh) attach=0 ;;
        --rebuild-warp) rebuild_warp=1 ;;
        --rebuild-guest) rebuild_guest=1 ;;
        --with-lmcache) with_lmcache=1 ;;
        --status|--stop|--clean|--full-clean|--help)
            [[ ${action} == bringup && ${rebuild_warp} == 0 && ${rebuild_guest} == 0 && ${with_lmcache} == 0 && ${attach} == 1 ]] || \
                die "관리 option은 다른 option과 함께 사용할 수 없습니다."
            action=${1#--}
            ;;
        *) usage >&2; die "알 수 없는 option: $1" ;;
    esac
    shift
done

if [[ ${with_lmcache} == 1 ]]; then
    export WARP_WITH_LMCACHE=1
    LMCACHE_INSTALL_ENABLED=1
else
    export WARP_WITH_LMCACHE=0
    LMCACHE_INSTALL_ENABLED=0
fi

case ${action} in
    help) usage; exit 0 ;;
    status) exec "${ROOT_DIR}/scripts/status.sh" ;;
    stop) exec "${ROOT_DIR}/scripts/stop-vm.sh" ;;
    clean) exec "${ROOT_DIR}/scripts/clean.sh" clean ;;
    full-clean) exec "${ROOT_DIR}/scripts/clean.sh" full-clean ;;
esac

if [[ ${rebuild_guest} == 1 ]] && vm_running; then
    die "--rebuild-guest 전에 실행 중인 VM을 --stop으로 종료하십시오."
fi

total_steps=9
if is_true "${LMCACHE_INSTALL_ENABLED}"; then
    total_steps=10
fi

total_start=$(date +%s)

run_step 1 "${total_steps}" 'Host 환경 확인' "${ROOT_DIR}/scripts/check-host.sh"
run_step 2 "${total_steps}" 'WARP source 준비' "${ROOT_DIR}/scripts/prepare-warp-source.sh"
run_step 3 "${total_steps}" 'WARP/FEMU 빌드' "${ROOT_DIR}/scripts/build-warp.sh" "${rebuild_warp}"
run_step 4 "${total_steps}" 'Ubuntu 24.04 image 준비' "${ROOT_DIR}/scripts/download-ubuntu-image.sh"

step=5
if is_true "${LMCACHE_INSTALL_ENABLED}"; then
    run_step "${step}" "${total_steps}" 'LMCache cargo vendor 준비' "${ROOT_DIR}/scripts/prepare-lmcache-vendor.sh"
    step=$((step + 1))
fi

run_step "${step}" "${total_steps}" 'Guest provisioning image 준비' "${ROOT_DIR}/scripts/build-guest-image.sh" "${rebuild_guest}"
step=$((step + 1))
run_step "${step}" "${total_steps}" 'WARP/FEMU VM 실행' "${ROOT_DIR}/scripts/start-vm.sh"
step=$((step + 1))
run_step "${step}" "${total_steps}" 'SSH 및 cloud-init 대기' "${ROOT_DIR}/scripts/wait-ready.sh"
step=$((step + 1))
run_step "${step}" "${total_steps}" 'FDP NVMe 확인' "${ROOT_DIR}/scripts/inspect-fdp.sh"

if is_true "${LMCACHE_INSTALL_ENABLED}"; then
    step=$((step + 1))
    run_step "${step}" "${total_steps}" 'GPU 없는 LMCache build 확인' "${ROOT_DIR}/scripts/verify-lmcache.sh"
fi

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

lmcache_source='not provisioned by default'
lmcache_summary='skipped (use ./bringup.sh --with-lmcache)'
if is_true "${LMCACHE_INSTALL_ENABLED}"; then
    lmcache_source='/workspace/LMCache'
    lmcache_summary='passed'
fi

cat <<EOF

WARP FDP VM이 준비되었습니다.

Guest OS:          Ubuntu 24.04 LTS
SSH:               ssh -i ${SSH_KEY} -p ${GUEST_SSH_PORT} ${GUEST_USERNAME}@127.0.0.1
FDP enabled:       yes
Configured RUHs:   ${FDP_NRUH}
GPU present:       no
CUDA present:      no
Python:            ~/.venv/py312/bin/python
LMCache source:    ${lmcache_source}
LMCache build:     ${lmcache_summary}
QEMU log:          ${QEMU_LOG}
FDP report:        ${FDP_REPORT}
Total elapsed:     $(format_duration "${total_elapsed}")

FDP I/O smoke test inside the guest:
  sudo fio --name=fdp-read-pid0 --filename=/dev/ng0n1 --direct=0 --rw=read --bs=4k --size=16M --offset=1G --ioengine=io_uring_cmd --cmd_type=nvme --iodepth=1 --numjobs=1 --fdp=1 --fdp_pli=0
EOF

if [[ ${attach} == 1 ]]; then
    exec "${ROOT_DIR}/scripts/ssh.sh"
fi
