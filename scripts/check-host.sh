#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

[[ $(uname -s) == Linux ]] || die "Linux host만 지원합니다."
[[ $(uname -m) == x86_64 ]] || die "x86-64 host만 지원합니다."
[[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "Ubuntu host만 지원합니다. 감지된 배포판: ${ID:-unknown}"

if [[ ! -e /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    cat >&2 <<'EOF'
/dev/kvm을 사용할 수 없습니다.

확인:
  ls -l /dev/kvm
  groups
  sudo usermod -aG kvm $USER
EOF
    exit 1
fi

packages=(
    build-essential ca-certificates cloud-image-utils curl gettext-base git jq
    libaio-dev libattr1-dev libcap-ng-dev libfdt-dev libglib2.0-dev libpixman-1-dev
    libseccomp-dev libslirp-dev liburing-dev ninja-build openssh-client pkg-config
    qemu-utils socat wget zlib1g-dev
)

missing=()
for package in "${packages[@]}"; do
    dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -Fq 'install ok installed' || \
        missing+=("${package}")
done

if ((${#missing[@]})); then
    is_true "${HOST_INSTALL_PACKAGES}" || \
        die "필수 host package가 없습니다: ${missing[*]}"
    log "필수 host package를 설치합니다: ${missing[*]}"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

for command in git curl qemu-img cloud-localds ssh ssh-keygen jq socat; do
    require_command "${command}"
done

validate_config
log "Host 확인 완료: ${PRETTY_NAME}, KVM read/write 가능"

