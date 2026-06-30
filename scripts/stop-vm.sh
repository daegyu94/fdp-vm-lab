#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

if ! vm_running; then
    rm -f "${QEMU_PID_FILE}" "${QMP_SOCKET}"
    log "VM이 실행 중이 아닙니다."
    exit 0
fi

pid=$(qemu_pid)
if [[ -S ${QMP_SOCKET} ]]; then
    {
        printf '{"execute":"qmp_capabilities"}\n'
        printf '{"execute":"system_powerdown"}\n'
    } | socat - "UNIX-CONNECT:${QMP_SOCKET}" >/dev/null 2>&1 || true
fi

for _ in $(seq 1 60); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
done

if kill -0 "${pid}" 2>/dev/null; then
    warn "정상 종료 timeout 후 QEMU에 SIGTERM을 전송합니다."
    kill -TERM "${pid}"
    for _ in $(seq 1 10); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
    done
fi
if kill -0 "${pid}" 2>/dev/null; then
    warn "QEMU가 SIGTERM에 응답하지 않아 SIGKILL을 전송합니다."
    kill -KILL "${pid}"
fi
rm -f "${QEMU_PID_FILE}" "${QMP_SOCKET}"
log "WARP/FEMU VM 종료 완료"

