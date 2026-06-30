#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

force=${1:-0}
if vm_running && [[ ${force} == 1 ]]; then
    die "실행 중인 VM의 guest image를 다시 만들 수 없습니다. 먼저 --stop을 실행하십시오."
fi

if [[ ${force} != 1 && -f ${GUEST_IMAGE_PATH} && -f ${SEED_IMAGE} && -f ${SSH_KEY} ]]; then
    log "기존 customized guest image와 cloud-init seed를 재사용합니다."
    exit 0
fi

rm -f "${GUEST_IMAGE_PATH}" "${SEED_IMAGE}" "${STATE_DIR}/user-data" "${STATE_DIR}/known_hosts"

if [[ ! -f ${SSH_KEY} ]]; then
    ssh-keygen -q -t ed25519 -N '' -C warp-fdp-bringup -f "${SSH_KEY}"
    chmod 600 "${SSH_KEY}"
fi
public_key=$(<"${SSH_KEY}.pub")

qemu_img=$(command -v qemu-img)
"${qemu_img}" create -f qcow2 -F qcow2 -b "${GUEST_BASE_IMAGE_PATH}" "${GUEST_IMAGE_PATH}"
"${qemu_img}" resize "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_SIZE}"

env_file="${STATE_DIR}/guest.env"
{
    printf 'GUEST_USERNAME=%q\n' "${GUEST_USERNAME}"
    printf 'LMCACHE_REPOSITORY_URL=%q\n' "${LMCACHE_REPOSITORY_URL}"
    printf 'LMCACHE_REPOSITORY_BRANCH=%q\n' "${LMCACHE_REPOSITORY_BRANCH}"
    printf 'LMCACHE_REPOSITORY_COMMIT=%q\n' "${LMCACHE_REPOSITORY_COMMIT}"
    printf 'LMCACHE_SOURCE_PATH=%q\n' "${LMCACHE_SOURCE_PATH:-}"
    if is_true "${LMCACHE_INSTALL_ENABLED}"; then
        printf 'LMCACHE_INSTALL_ENABLED=1\n'
    else
        printf 'LMCACHE_INSTALL_ENABLED=0\n'
    fi
} > "${env_file}"

provision_b64=$(base64 -w0 "${ROOT_DIR}/cloud-init/provision-guest.sh")
build_lmcache_b64=$(base64 -w0 "${ROOT_DIR}/cloud-init/build-lmcache.sh")
env_b64=$(base64 -w0 "${env_file}")
patch_b64=$(base64 -w0 "${ROOT_DIR}/patches/lmcache-cpu-only-build.patch")
vendor_write_file=''
vendor_archive="${STATE_DIR}/lmcache-cargo-vendor.tar.gz"
source_archive="${STATE_DIR}/lmcache-source.tar.gz"
if is_true "${LMCACHE_INSTALL_ENABLED}"; then
    [[ -f ${vendor_archive} ]] || \
        die "LMCache cargo vendor archive가 없습니다: ${vendor_archive}"
    [[ -f ${source_archive} ]] || \
        die "LMCache source archive가 없습니다: ${source_archive}"
    vendor_b64=$(base64 -w0 "${vendor_archive}")
    source_b64=$(base64 -w0 "${source_archive}")
    vendor_write_file=$(cat <<EOF_VENDOR
  - path: /usr/local/share/warp-fdp/lmcache-cargo-vendor.tar.gz
    permissions: '0644'
    encoding: b64
    content: ${vendor_b64}
  - path: /usr/local/share/warp-fdp/lmcache-source.tar.gz
    permissions: '0644'
    encoding: b64
    content: ${source_b64}
EOF_VENDOR
)
fi

cat > "${STATE_DIR}/user-data" <<EOF
#cloud-config
hostname: warp-fdp
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - default
  - name: ${GUEST_USERNAME}
    gecos: WARP FDP Developer
    groups: [adm, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${public_key}
package_update: true
write_files:
  - path: /etc/warp-fdp.env
    permissions: '0644'
    encoding: b64
    content: ${env_b64}
  - path: /usr/local/sbin/provision-warp-guest
    permissions: '0755'
    encoding: b64
    content: ${provision_b64}
  - path: /usr/local/sbin/build-lmcache
    permissions: '0755'
    encoding: b64
    content: ${build_lmcache_b64}
  - path: /usr/local/share/warp-fdp/lmcache-cpu-only-build.patch
    permissions: '0644'
    encoding: b64
    content: ${patch_b64}
${vendor_write_file}
runcmd:
  - [bash, -lc, '/usr/local/sbin/provision-warp-guest > /var/log/warp-provision.log 2>&1']
final_message: WARP FDP guest provisioning complete
EOF

cloud-localds "${SEED_IMAGE}" "${STATE_DIR}/user-data" "${ROOT_DIR}/cloud-init/meta-data"
log "Customized guest overlay와 cloud-init seed 생성 완료"

