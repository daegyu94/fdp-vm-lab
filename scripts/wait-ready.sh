#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

vm_running || die "QEMU process가 실행 중이 아닙니다."

deadline=$((SECONDS + GUEST_SSH_TIMEOUT))
while ((SECONDS < deadline)); do
    if ! vm_running; then
        tail -n 100 "${QEMU_LOG}" >&2 || true
        die "SSH 대기 중 QEMU process가 종료되었습니다."
    fi
    if ssh_ready; then
        break
    fi
    sleep 5
done
ssh_ready || die "${GUEST_SSH_TIMEOUT}초 안에 SSH가 준비되지 않았습니다."
log "SSH 접속 준비 완료"

if ! timeout "${GUEST_CLOUD_INIT_TIMEOUT}" bash -c \
    'source "$1"; ssh_base sudo cloud-init status --wait --long' bash "$(dirname "$0")/common.sh"; then
    ssh_base sudo tail -n 200 /var/log/cloud-init-output.log >&2 || true
    ssh_base sudo tail -n 200 /var/log/warp-provision.log >&2 || true
    die "cloud-init 또는 guest provisioning이 실패했습니다."
fi

ssh_base test -f /var/lib/warp-fdp/provision.success || {
    ssh_base sudo tail -n 200 /var/log/warp-provision.log >&2 || true
    die "guest provisioning 성공 marker가 없습니다."
}
log "cloud-init 및 guest provisioning 완료"

