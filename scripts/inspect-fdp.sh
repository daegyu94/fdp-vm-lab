#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ssh_ready || die "SSH가 준비되지 않았습니다."

ssh_base FDP_ENDGRP_ID="${FDP_NRG}" bash -s <<'GUEST' | tee "${FDP_REPORT}"
set -Eeuo pipefail

mapfile -t namespaces < <(
    for path in /sys/class/nvme/nvme*n*; do
        [[ -e ${path} ]] || continue
        name=$(basename "${path}")
        [[ ${name} =~ ^nvme[0-9]+n[0-9]+$ ]] && printf '/dev/%s\n' "${name}"
    done | sort
)
((${#namespaces[@]} > 0)) || {
    printf 'NVMe namespace를 찾을 수 없습니다.\n' >&2
    exit 1
}

namespace=${namespaces[0]}
ns_name=${namespace#/dev/}
controller=/dev/${ns_name%n*}
generic=
for path in /sys/class/nvme-generic/ng*; do
    [[ -e ${path} ]] || continue
    candidate=/dev/$(basename "${path}")
    if sudo nvme id-ns "${candidate}" >/dev/null 2>&1; then
        generic=${candidate}
        break
    fi
done

sudo nvme list
sudo nvme id-ctrl "${controller}" >/tmp/warp-id-ctrl.txt
sudo nvme id-ns "${namespace}" >/tmp/warp-id-ns.txt
sudo nvme fdp configs "${namespace}" --endgrp-id="${FDP_ENDGRP_ID:-1}" >/tmp/warp-fdp-configs.txt
sudo nvme fdp status "${namespace}" >/tmp/warp-fdp-status.txt
sudo nvme fdp stats "${namespace}" >/tmp/warp-fdp-stats.txt

printf 'NVMe controller: %s\n' "${controller}"
printf 'NVMe namespace: %s\n' "${namespace}"
printf 'NVMe generic dev: %s\n' "${generic:-not-exposed}"
printf 'FDP enabled: yes\n'
printf '\nFDP configs:\n'
cat /tmp/warp-fdp-configs.txt
printf '\nFDP status:\n'
cat /tmp/warp-fdp-status.txt
printf '\nFDP stats:\n'
cat /tmp/warp-fdp-stats.txt
GUEST

