#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

printf 'WARP source:        '
if git -C "${WARP_SOURCE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$(git -C "${WARP_SOURCE_DIR}" rev-parse --short HEAD)"
else
    printf 'missing\n'
fi

printf 'WARP build:         %s\n' "$([[ -x ${WARP_QEMU} ]] && printf ready || printf missing)"
printf 'Base image:         %s\n' "$([[ -f ${GUEST_BASE_IMAGE_PATH} ]] && printf ready || printf missing)"
printf 'Guest image:        %s\n' "$([[ -f ${GUEST_IMAGE_PATH} ]] && printf ready || printf missing)"

if vm_running; then
    printf 'QEMU:               running (PID %s)\n' "$(qemu_pid)"
else
    printf 'QEMU:               stopped\n'
    exit 0
fi

if ssh_ready; then
    printf 'SSH:                ready (%s)\n' "ssh -p ${GUEST_SSH_PORT} ${GUEST_USERNAME}@127.0.0.1"
else
    printf 'SSH:                not ready\n'
    exit 0
fi

cloud_status=$(ssh_base cloud-init status 2>/dev/null || true)
printf 'cloud-init:         %s\n' "${cloud_status:-unknown}"
printf 'FDP:                '
if ssh_base sudo nvme fdp configs /dev/nvme0n1 --endgrp-id=1 >/dev/null 2>&1; then
    printf 'enabled\n'
else
    printf 'not ready\n'
fi
printf 'Python 3.12:        %s\n' "$(ssh_base .venv/py312/bin/python --version 2>&1 || printf 'not ready')"
printf 'LMCache:            '
if ! is_true "${LMCACHE_INSTALL_ENABLED}"; then
    printf 'skipped\n'
elif ssh_base test -f /var/lib/warp-fdp/lmcache-build.success && \
    ssh_base .venv/py312/bin/python -c 'import lmcache' >/dev/null 2>&1; then
    printf 'passed\n'
else
    printf 'not ready\n'
fi

