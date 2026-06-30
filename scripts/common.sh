#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/config/default.env"
if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
fi

absolute_path() {
    local path=$1
    if [[ ${path} = /* ]]; then
        printf '%s\n' "${path}"
    else
        realpath -m "${ROOT_DIR}/${path}"
    fi
}

WARP_SOURCE_DIR="$(absolute_path "${WARP_SOURCE_DIR}")"
WARP_BUILD_DIR="$(absolute_path "${WARP_BUILD_DIR}")"
GUEST_BASE_IMAGE_PATH="$(absolute_path "${GUEST_BASE_IMAGE_PATH}")"
GUEST_IMAGE_PATH="$(absolute_path "${GUEST_IMAGE_PATH}")"
if [[ -n ${LMCACHE_SOURCE_PATH:-} ]]; then
    LMCACHE_SOURCE_PATH="$(absolute_path "${LMCACHE_SOURCE_PATH}")"
fi

STATE_DIR="${ROOT_DIR}/state"
LOG_DIR="${ROOT_DIR}/logs"
SEED_IMAGE="${STATE_DIR}/cloud-init-seed.iso"
SSH_KEY="${STATE_DIR}/id_ed25519"
QMP_SOCKET="${STATE_DIR}/qmp.sock"
QEMU_PID_FILE="${STATE_DIR}/qemu.pid"
QEMU_LOG="${LOG_DIR}/qemu.log"
SERIAL_LOG="${LOG_DIR}/serial.log"
FDP_REPORT="${LOG_DIR}/fdp-inspection.log"
LMCACHE_REPORT="${LOG_DIR}/lmcache-verification.log"
WARP_QEMU="${WARP_BUILD_DIR}/qemu-system-x86_64"
WARP_QEMU_IMG="${WARP_BUILD_DIR}/qemu-img"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "$(dirname "${GUEST_BASE_IMAGE_PATH}")" \
    "$(dirname "${GUEST_IMAGE_PATH}")"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf '경고: %s\n' "$*" >&2
}

die() {
    printf '오류: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없습니다: $1"
}

is_true() {
    case ${1,,} in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

if [[ -n ${WARP_WITH_LMCACHE:-} ]]; then
    if is_true "${WARP_WITH_LMCACHE}"; then
        LMCACHE_INSTALL_ENABLED=1
    else
        LMCACHE_INSTALL_ENABLED=0
    fi
fi

qemu_pid() {
    [[ -s ${QEMU_PID_FILE} ]] || return 1
    local pid
    read -r pid < "${QEMU_PID_FILE}"
    [[ ${pid} =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${pid}"
}

vm_running() {
    local pid
    pid=$(qemu_pid) || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    [[ -r /proc/${pid}/cmdline ]] || return 1
    tr '\0' '\n' < "/proc/${pid}/cmdline" | grep -Fxq "${WARP_QEMU}"
}

ssh_base() {
    ssh -i "${SSH_KEY}" -p "${GUEST_SSH_PORT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${STATE_DIR}/known_hosts" \
        -o ConnectTimeout=5 \
        "${GUEST_USERNAME}@127.0.0.1" "$@"
}

ssh_ready() {
    [[ -f ${SSH_KEY} ]] && ssh_base true >/dev/null 2>&1
}

validate_positive_integer() {
    local name=$1 value=$2
    [[ ${value} =~ ^[1-9][0-9]*$ ]] || die "${name}은(는) 양의 정수여야 합니다: ${value}"
}

validate_config() {
    validate_positive_integer GUEST_CPUS "${GUEST_CPUS}"
    validate_positive_integer GUEST_SSH_PORT "${GUEST_SSH_PORT}"
    validate_positive_integer FDP_SSD_SIZE_MB "${FDP_SSD_SIZE_MB}"
    validate_positive_integer FDP_NRUH "${FDP_NRUH}"
    validate_positive_integer FDP_NRG "${FDP_NRG}"
    [[ ${GUEST_USERNAME} =~ ^[a-z_][a-z0-9_-]*$ ]] || \
        die "GUEST_USERNAME 형식이 올바르지 않습니다: ${GUEST_USERNAME}"
    [[ ${GUEST_BASE_IMAGE_SHA256} =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "GUEST_BASE_IMAGE_SHA256 형식이 올바르지 않습니다."
    [[ ${FDP_PLACEMENT_HANDLES} != *','* ]] || \
        die "FDP_PLACEMENT_HANDLES는 세미콜론으로 구분해야 합니다."
}

