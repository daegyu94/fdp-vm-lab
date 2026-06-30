# WARP FDP VM one-click bring-up

Ubuntu x86-64 host에서 pinned WARP/FEMU `fdp` source를 빌드하고 Ubuntu
Server 24.04 LTS guest에 FDP NVMe emulator를 자동 준비한다. 기본 bring-up은
FDP 기능 검증에 필요한 `nvme-cli`, `fio`, SSH만 설치한다. CPU-only LMCache build는
선택 사항이며 `--with-lmcache`를 지정할 때만 수행한다. Docker, GPU passthrough,
CUDA와 vLLM inference는 사용하지 않는다.

## Quick start

```bash
git clone --recurse-submodules https://github.com/daegyu94/fdp-vm-lab.git
cd fdp-vm-lab
./bringup.sh
```

최초 실행은 host package 설치를 위해 `sudo` password를 요청할 수 있다. `--recurse-submodules` 없이 clone했다면 먼저 `git submodule update --init --recursive`를 실행한다. 이후
WARP build, base image, guest overlay, cloud-init seed와 실행 중 VM을 재사용한다.
검증이 끝나면 guest SSH shell을 연다.

```bash
./bringup.sh
./bringup.sh --no-ssh
./bringup.sh --rebuild-warp
./bringup.sh --rebuild-guest
./bringup.sh --with-lmcache
./bringup.sh --status
./bringup.sh --stop
./bringup.sh --clean
./bringup.sh --full-clean
./bringup.sh --help
```

`--clean`은 WARP build output과 임시 log를 제거한다. `--full-clean`은 customized
guest image, seed와 SSH key도 제거한다. 두 명령 모두 source와 base image는 보존한다.

## Host와 설정

지원 host는 x86-64 Ubuntu Linux다. `/dev/kvm`이 존재하고 현재 사용자에게
read/write 권한이 있어야 한다. 필수 package는 기본적으로 `apt-get`으로 설치한다.
자동 설치를 막으려면 `.env`에서 `HOST_INSTALL_PACKAGES=0`으로 설정한다.

```bash
ls -l /dev/kvm
groups
sudo usermod -aG kvm $USER
```

WARP/FEMU는 `third_party/WARP-earlyaccess` submodule로 고정한다. [`config/default.env`](config/default.env)는 WARP commit과 Ubuntu image URL/SHA-256을
고정한다. `.env.example`을 `.env`로 복사해 resource, FDP geometry/latency, SSH port,
LMCache source를 변경할 수 있다. 상대 경로는 이 저장소 기준이다. 기본값은 8 GiB,
8 vCPU, SSH port 18080, 16 GiB FDP namespace, reclaim group 1, RUH 8개와 placement
handle 0~7이다.

LMCache는 기본적으로 설치하지 않는다. `./bringup.sh --with-lmcache`를 사용할 때만
source를 URL과 branch/commit에서 clone하거나, `LMCACHE_SOURCE_PATH`로 지정한 host
checkout을 read-only 9p로 공유한 뒤 writable `/workspace/LMCache`에 복사한다.

## Image 크기와 변경 위치

Ubuntu base image는 `GUEST_BASE_IMAGE_URL`에서 내려받아 `GUEST_BASE_IMAGE_PATH`에
저장한다. 현재 pinned Ubuntu 24.04 cloud image의 실제 다운로드 크기는 약 593 MiB다.
정확한 값은 다음으로 확인한다.

```bash
du -h images/ubuntu-24.04-base-amd64.img
```

Guest OS overlay는 qcow2 copy-on-write image이며 `GUEST_IMAGE_SIZE`가 virtual disk
크기를 정한다. 기본값은 40 GiB다. qcow2 파일은 sparse/COW 형식이므로 실제 host disk
사용량은 설치된 package와 write 양에 따라 virtual size보다 작거나 커진다. 기본 FDP-only
bring-up은 LMCache를 설치하지 않으므로 기존 LMCache overlay보다 작게 시작한다.

FDP emulated NVMe namespace 크기는 Ubuntu guest image 크기와 별개이며
`FDP_SSD_SIZE_MB`로 정한다. 기본값은 16384 MiB, 즉 16 GiB다.

크기 설정은 `.env`에서 override하는 방식을 권장한다.

```bash
cp .env.example .env
# guest OS overlay virtual size
GUEST_IMAGE_SIZE=40G
# emulated FDP namespace size in MiB
FDP_SSD_SIZE_MB=16384
```

이미 생성된 guest overlay에 `GUEST_IMAGE_SIZE` 변경을 반영하려면 VM을 끈 뒤 다시 만든다.

```bash
./bringup.sh --stop
./bringup.sh --rebuild-guest --no-ssh
```

## Cloud image를 사용하는 이유

이 프로젝트는 일반 Ubuntu installer ISO 대신 Ubuntu cloud image를 사용한다. Cloud
image는 이미 설치된 최소 OS image라서 `cloud-init` seed를 붙여 바로 자동 provisioning할
수 있다. 사용자는 installer에서 언어, 디스크, 계정, SSH를 직접 설정하지 않고
`./bringup.sh`만 실행하면 된다.

Cloud image를 쓰는 이유는 다음과 같다.

- 설치 과정 없이 바로 부팅 가능한 guest OS를 사용한다.
- `cloud-init`으로 `warp` user, SSH key, package 설치와 provisioning marker를 자동 설정한다.
- `GUEST_BASE_IMAGE_URL`과 `GUEST_BASE_IMAGE_SHA256`을 고정해 같은 base OS에서 재현한다.
- Base image와 writable qcow2 overlay를 분리해 base image를 재사용하고 guest 변경 사항만 overlay에 쌓는다.
- FDP 테스트 환경의 목표인 “FDP SSD가 없는 사용자의 빠른 bring-up”에 맞춰 수동 OS 설치 단계를 제거한다.

구조는 다음과 같다.

```text
Ubuntu cloud image
+ cloud-init seed
+ WARP/FEMU FDP NVMe device
→ boot
→ SSH key 등록
→ nvme-cli/fio 설치
→ FDP 확인 가능
```

## Guest build와 안전 범위

공식 Ubuntu cloud image는 checksum 검증 후 base image와 별도 qcow2 overlay로
관리한다. Guest에는 기본적으로 `nvme-cli`, `fio`, SSH, Python 3.12만 설치한다.
Bring-up 자체는 `fio` write를 실행하지 않는다.

`--with-lmcache`를 지정하면 추가로 `uv`, Rust/Cargo와 build tool을 설치하고,
LMCache를 `~/.venv/py312`와 CPU PyTorch로 빌드한다. `NO_GPU_EXT=1`로 common C++
extension, raw-block Rust extension, wheel, editable install과 import를 실제 검증한다.
현재 `dev`가 CPU mode에서도 요구하는 NVIDIA 전용 `cufile-python`, `nvtx`만
[`patches/lmcache-cpu-only-build.patch`](patches/lmcache-cpu-only-build.patch)로
제외한다. CPU PyTorch와 common extension은 유지하므로 upstream 적용 범위도 작다.

FDP 검증은 다음 read-only 명령만 사용한다.

```bash
nvme list
nvme id-ctrl /dev/nvme0
nvme id-ns /dev/nvme0n1
nvme fdp configs /dev/nvme0n1 --endgrp-id=1
nvme fdp status /dev/nvme0n1
nvme fdp stats /dev/nvme0n1
```

Bring-up은 NVMe write, format, filesystem 생성, mount, discard, sanitize, reset,
GC 유도 또는 WAF 측정을 수행하지 않는다. 9p source 공유 mount는 FDP namespace와
무관하다.

## 결과 파일과 접속

- `logs/qemu.log`, `logs/serial.log`
- `logs/fdp-inspection.log`
- `logs/lmcache-verification.log` (`--with-lmcache` 사용 시)
- `state/qmp.sock`, `state/qemu.pid`, `state/id_ed25519`

```bash
ssh -i state/id_ed25519 -p 18080 warp@127.0.0.1
```

