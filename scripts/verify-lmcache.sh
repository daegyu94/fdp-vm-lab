#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ssh_ready || die "SSH가 준비되지 않았습니다."

ssh_base bash -s <<'GUEST' | tee "${LMCACHE_REPORT}"
set -Eeuo pipefail
python_bin="$HOME/.venv/py312/bin/python"

test -x "${python_bin}"
test -f /var/lib/warp-fdp/lmcache-build.success
test -d /workspace/LMCache
find /workspace/wheels -maxdepth 1 -name '*.whl' -print -quit | grep -q .

if command -v nvidia-smi >/dev/null 2>&1 || command -v nvcc >/dev/null 2>&1 || \
    [[ -e /usr/local/cuda ]] || compgen -G '/dev/nvidia*' >/dev/null; then
    printf 'GPU or CUDA detected\n' >&2
    exit 1
fi

printf 'GPU present: no\n'
printf 'CUDA present: no\n'
printf 'Python: '
"${python_bin}" --version
printf 'Cargo: '
cargo --version
printf 'PyTorch: '
"${python_bin}" -c 'import torch; print(torch.__version__, "cuda_available=", torch.cuda.is_available()); assert not torch.cuda.is_available()'
printf 'LMCache source: /workspace/LMCache\n'
printf 'LMCache import: '
"${python_bin}" -c 'import lmcache; print(lmcache.__file__)'
printf 'LMCache wheel: '
find /workspace/wheels -maxdepth 1 -name '*.whl' -print -quit
printf 'LMCache build: passed\n'
GUEST

