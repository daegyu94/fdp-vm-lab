#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

if vm_running; then
    log "실행 중인 WARP/FEMU VM을 재사용합니다. PID=$(qemu_pid)"
    exit 0
fi

[[ -x ${WARP_QEMU} ]] || die "WARP QEMU binary가 없습니다: ${WARP_QEMU}"
[[ -f ${GUEST_IMAGE_PATH} ]] || die "Guest image가 없습니다: ${GUEST_IMAGE_PATH}"
[[ -f ${SEED_IMAGE} ]] || die "cloud-init seed image가 없습니다: ${SEED_IMAGE}"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm에 read/write 접근할 수 없습니다."

if ss -H -ltn "sport = :${GUEST_SSH_PORT}" | grep -q .; then
    die "SSH host port가 이미 사용 중입니다: ${GUEST_SSH_PORT}"
fi

rm -f "${QMP_SOCKET}" "${QEMU_PID_FILE}"
: > "${QEMU_LOG}"
: > "${SERIAL_LOG}"

# run-blackbox-fdp.sh uses 20% over-provisioning and one 512 MiB line per
# block with its 16 KiB page geometry. Preserve that WARP-specific layout.
blks_per_pl=$((FDP_SSD_SIZE_MB * 6 / 5 / 512))
((blks_per_pl >= FDP_NRUH)) || \
    die "FDP_SSD_SIZE_MB가 FDP_NRUH에 비해 너무 작습니다."

qemu_args=(
    -name WARP-FDP-LMCache
    -enable-kvm
    -cpu host
    -smp "${GUEST_CPUS}"
    -m "${GUEST_MEMORY}"
    -display none
    -monitor none
    -serial "file:${SERIAL_LOG}"
    -qmp "unix:${QMP_SOCKET},server=on,wait=off"
    -pidfile "${QEMU_PID_FILE}"
    -device "femu-subsys,id=femu-subsys-0,nqn=subsys0,fdp=on,fdp.nruh=${FDP_NRUH},fdp.nrg=${FDP_NRG},fdp.nru=${blks_per_pl}"
    -device virtio-scsi-pci,id=scsi0
    -device scsi-hd,drive=osdisk
    -drive "file=${GUEST_IMAGE_PATH},if=none,id=osdisk,format=qcow2,cache=none,aio=native"
    -drive "file=${SEED_IMAGE},if=virtio,format=raw,readonly=on"
    -device "femu,devsz_mb=${FDP_SSD_SIZE_MB},namespaces=1,femu_mode=1,secsz=512,secs_per_pg=32,pgs_per_blk=512,blks_per_pl=${blks_per_pl},pls_per_lun=1,luns_per_ch=8,nchs=8,pg_rd_lat=${FDP_READ_LATENCY_NS},pg_wr_lat=${FDP_WRITE_LATENCY_NS},blk_er_lat=${FDP_ERASE_LATENCY_NS},ch_xfer_lat=0,gc_thres_pcent=${FDP_GC_THRESHOLD},gc_thres_pcent_high=${FDP_GC_THRESHOLD_HIGH},fdp.ruhs=${FDP_PLACEMENT_HANDLES},subsys=femu-subsys-0"
    -netdev "user,id=net0,hostfwd=tcp::${GUEST_SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
)

if [[ -n ${LMCACHE_SOURCE_PATH:-} ]]; then
    [[ -d ${LMCACHE_SOURCE_PATH} ]] || die "LMCACHE_SOURCE_PATH가 directory가 아닙니다: ${LMCACHE_SOURCE_PATH}"
    qemu_args+=(
        -fsdev "local,id=lmcachefs,path=${LMCACHE_SOURCE_PATH},security_model=mapped-xattr,readonly=on"
        -device virtio-9p-pci,fsdev=lmcachefs,mount_tag=lmcache_host
    )
fi

nohup "${WARP_QEMU}" "${qemu_args[@]}" >> "${QEMU_LOG}" 2>&1 </dev/null &
launcher_pid=$!

for _ in $(seq 1 100); do
    if vm_running && [[ -S ${QMP_SOCKET} ]]; then
        log "WARP/FEMU VM 시작 완료: PID=$(qemu_pid)"
        exit 0
    fi
    if ! kill -0 "${launcher_pid}" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

tail -n 80 "${QEMU_LOG}" >&2 || true
die "WARP/FEMU QEMU가 시작되지 않았습니다."

