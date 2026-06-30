#!/usr/bin/env bash

set -Eeuo pipefail
source /etc/warp-fdp.env

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl fio git jq nvme-cli openssh-server pciutils \
    python3.12 python3.12-venv wget
update-ca-certificates

mkdir -p /run/sshd
ssh-keygen -A
systemctl enable ssh
systemctl restart ssh || {
    journalctl -u ssh --no-pager -n 100 >&2 || true
    exit 1
}

if ! nvme fdp help >/dev/null 2>&1; then
    apt-get install -y \
        build-essential cmake libjson-c-dev liburing-dev libssl-dev meson \
        ninja-build pkg-config uuid-dev
    tmp=$(mktemp -d)
    git -c http.sslVerify=false clone --depth 1 --recursive --branch v2.13 \
        https://github.com/linux-nvme/nvme-cli.git "${tmp}/nvme-cli"
    meson setup "${tmp}/nvme-cli/.build" "${tmp}/nvme-cli" --buildtype=release
    meson compile -C "${tmp}/nvme-cli/.build"
    meson install -C "${tmp}/nvme-cli/.build"
    rm -rf "${tmp}"
fi
nvme fdp help >/dev/null 2>&1 || {
    printf 'nvme-cli does not provide the FDP plugin\n' >&2
    exit 1
}

if [[ ${LMCACHE_INSTALL_ENABLED:-0} == 1 ]]; then
    apt-get install -y \
        build-essential cargo cmake libjson-c-dev liburing-dev libssl-dev meson \
        ninja-build pkg-config python3-pip python3.12-dev rustc uuid-dev

    if [[ ! -x /opt/uv/bin/uv ]]; then
        /usr/bin/python3.12 -m venv /opt/uv
        /opt/uv/bin/python -m pip install --trusted-host pypi.org \
            --trusted-host files.pythonhosted.org --upgrade pip uv
    fi
    ln -sf /opt/uv/bin/uv /usr/local/bin/uv

    /usr/local/sbin/build-lmcache

    if command -v nvidia-smi >/dev/null 2>&1 || command -v nvcc >/dev/null 2>&1 || \
        [[ -e /usr/local/cuda ]] || compgen -G '/dev/nvidia*' >/dev/null; then
        printf 'GPU or CUDA was detected in the guest\n' >&2
        exit 1
    fi
fi

mkdir -p /var/lib/warp-fdp
date --iso-8601=seconds > /var/lib/warp-fdp/provision.success
