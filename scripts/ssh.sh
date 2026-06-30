#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ssh_ready || die "SSH가 준비되지 않았습니다."
exec ssh -i "${SSH_KEY}" -p "${GUEST_SSH_PORT}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${STATE_DIR}/known_hosts" \
    "${GUEST_USERNAME}@127.0.0.1"

