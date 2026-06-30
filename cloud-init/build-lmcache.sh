#!/usr/bin/env bash

set -Eeuo pipefail
source /etc/warp-fdp.env

if [[ ${LMCACHE_INSTALL_ENABLED} != 1 ]]; then
    printf 'LMCache install disabled by configuration\n'
    exit 0
fi

guest_home=$(getent passwd "${GUEST_USERNAME}" | cut -d: -f6)
python_bin="${guest_home}/.venv/py312/bin/python"
uv_bin=/opt/uv/bin/uv
source_dir=/workspace/LMCache
wheel_dir=/workspace/wheels
cpu_patch=/usr/local/share/warp-fdp/lmcache-cpu-only-build.patch

run_as_guest() {
    runuser -u "${GUEST_USERNAME}" -- env \
        HOME="${guest_home}" \
        SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
        CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt \
        PATH="/opt/uv/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

rm -rf "${source_dir}" "${wheel_dir}"
mkdir -p /workspace "${wheel_dir}"
chown -R "${GUEST_USERNAME}:${GUEST_USERNAME}" /workspace

source_archive=/usr/local/share/warp-fdp/lmcache-source.tar.gz
if [[ -f ${source_archive} ]]; then
    run_as_guest tar -xzf "${source_archive}" -C /workspace
    [[ -d ${source_dir} ]] || { printf 'LMCache source archive did not create %s\n' "${source_dir}" >&2; exit 1; }
elif [[ -n ${LMCACHE_SOURCE_PATH} ]]; then
    mkdir -p /mnt/lmcache-host
    mountpoint -q /mnt/lmcache-host || \
        mount -t 9p -o trans=virtio,version=9p2000.L,ro lmcache_host /mnt/lmcache-host
    run_as_guest cp -a /mnt/lmcache-host "${source_dir}"
else
    clone_args=()
    if [[ -n ${LMCACHE_REPOSITORY_BRANCH} ]]; then
        clone_args+=(--branch "${LMCACHE_REPOSITORY_BRANCH}")
    fi
    run_as_guest git -c http.sslVerify=false clone "${clone_args[@]}" \
        "${LMCACHE_REPOSITORY_URL}" "${source_dir}"
fi

if [[ -n ${LMCACHE_REPOSITORY_COMMIT} ]]; then
    run_as_guest git -C "${source_dir}" checkout --detach "${LMCACHE_REPOSITORY_COMMIT}"
fi

# NO_GPU_EXT skips CUDA/HIP/SYCL extensions, but current LMCache dev still lists
# two NVIDIA-only runtime packages in common.txt. Apply the repository-owned,
# narrowly scoped patch when those entries are present.
if grep -Fxq cufile-python "${source_dir}/requirements/common.txt" || \
    grep -Fxq nvtx "${source_dir}/requirements/common.txt"; then
    run_as_guest git -C "${source_dir}" apply --check "${cpu_patch}"
    run_as_guest git -C "${source_dir}" apply "${cpu_patch}"
fi

raw_block_src="${source_dir}/rust/raw_block/src/lib.rs"
if [[ -f ${raw_block_src} ]]; then
    run_as_guest sed -i \
        -e 's/if !(offset as usize)\.is_multiple_of(lba_size) {/if (offset as usize) % lba_size != 0 {/' \
        -e 's/if !len\.is_multiple_of(lba_size) {/if len % lba_size != 0 {/' \
        -e 's/(ptr as usize)\.is_multiple_of(align)/(ptr as usize) % align == 0/g' \
        -e 's/(src as usize)\.is_multiple_of(align)/(src as usize) % align == 0/g' \
        -e 's/(dst as usize)\.is_multiple_of(align)/(dst as usize) % align == 0/g' \
        "${raw_block_src}"
fi

if [[ -f ${source_dir}/pyproject.toml ]]; then
    run_as_guest sed -i 's/^license = "Apache-2.0"/license = { text = "Apache-2.0" }/' "${source_dir}/pyproject.toml"
    run_as_guest sed -i '/^license-files = /d' "${source_dir}/pyproject.toml"
fi

run_as_guest /usr/bin/python3.12 -m venv "${guest_home}/.venv/py312"
run_as_guest "${python_bin}" -m pip install --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org --upgrade \
    pip 'setuptools==80.9.0' wheel
run_as_guest "${uv_bin}" pip install --python "${python_bin}" \
    --trusted-host pypi.org --trusted-host files.pythonhosted.org \
    build ninja packaging 'setuptools_scm>=8'

# Install the CPU wheel explicitly so dependency resolution cannot select a
# CUDA-enabled PyTorch distribution.
run_as_guest "${uv_bin}" pip install --python "${python_bin}" \
    --trusted-host download.pytorch.org --trusted-host download-r2.pytorch.org \
    --trusted-host pypi.org --trusted-host files.pythonhosted.org \
    --index-url https://download.pytorch.org/whl/cpu 'torch==2.11.0+cpu'
run_as_guest "${python_bin}" -m pip install --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org --upgrade \
    'setuptools==80.9.0' wheel

vendor_archive=/usr/local/share/warp-fdp/lmcache-cargo-vendor.tar.gz
if [[ -f ${vendor_archive} ]]; then
    run_as_guest mkdir -p "${source_dir}/.cargo"
    run_as_guest tar -xzf "${vendor_archive}" -C "${source_dir}/.cargo"
else
    printf 'LMCache cargo vendor archive is missing; cargo will use the network\n' >&2
fi

if [[ ! -f ${source_dir}/rust/raw_block/Cargo.toml ]]; then
    printf 'Required LMCache raw-block Rust extension is missing\n' >&2
    exit 1
fi
run_as_guest rm -f "${source_dir}/rust/raw_block/Cargo.lock"
run_as_guest cargo --offline \
    --config 'source.crates-io.replace-with="vendored-sources"' \
    --config "source.vendored-sources.directory=\"${source_dir}/.cargo/vendor\"" \
    build --release --manifest-path "${source_dir}/rust/raw_block/Cargo.toml"

run_as_guest env NO_GPU_EXT=1 "${python_bin}" -m build --wheel --no-isolation \
    --outdir "${wheel_dir}" "${source_dir}"
run_as_guest env NO_GPU_EXT=1 "${uv_bin}" pip install \
    --trusted-host pypi.org --trusted-host files.pythonhosted.org \
    --python "${python_bin}" --no-build-isolation -e "${source_dir}"

run_as_guest "${python_bin}" --version
run_as_guest cargo --version
run_as_guest "${python_bin}" -c 'import lmcache; print(lmcache.__file__)'

mkdir -p /var/lib/warp-fdp
{
    printf 'source=%s\n' "${source_dir}"
    printf 'commit=%s\n' "$(git -C "${source_dir}" rev-parse HEAD)"
    printf 'wheel=%s\n' "$(find "${wheel_dir}" -maxdepth 1 -name '*.whl' -print -quit)"
    printf 'python=%s\n' "${python_bin}"
} > /var/lib/warp-fdp/lmcache-build.success

