# CONTEXT {'gpu_vendor': 'AMD', 'guest_os': 'UBUNTU'}
###############################################################################
#
# MIT License
#
# Copyright (c) 2026 Advanced Micro Devices, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#################################################################################
# =============================================================================
# pyt_vllm_kimi_k3_mi355x.ubuntu.amd.Dockerfile
#
#   Kimi-K3 native-MXFP4 wide-EP + MoRIIO disaggregated serving on MI355X / gfx950.
#   Sibling of pyt_vllm_kimi_k3_mi300x: same MoRI, vLLM and router pins, so the two
#   images differ only where the GPU does.
#
#   Build (context = repo root):
#     docker build -f docker/pyt_vllm_kimi_k3_mi355x.ubuntu.amd.Dockerfile \
#       -t <your-registry>/vllm-kimi-k3-mi355x:local .
#     export DOCKER_IMAGE_NAME=<your-registry>/vllm-kimi-k3-mi355x:local
#
#   Named pyt_vllm_kimi_k3_mi355x, not vllm_disagg_inference.*: madengine builds every
#   file matching `<card dockerfile>.*`, and the generic disagg cards already glob
#   vllm_disagg_inference.*.
#
# WHAT DIFFERS FROM THE MI300X IMAGE, AND WHY
#   - gfx950 has scaled-MXFP4 MFMA, so the MoE runs natively. The vLLM fork selects
#     that path itself on gfx950 (mxfp4.py _use_k3_situ_aiter); the gfx942 int4
#     requant only engages with an explicit --quantization-config, which the MI355X
#     recipe does not pass. AITER MLA works here, so the recipe leaves it on.
#   - AITER donor: vllm/vllm-openai-rocm:kimi-k3, pinned by digest. The MI300X file's
#     donor, amdsiloai/vllm:kimi-k3-mi325x-release-v2, is this same image plus three
#     vLLM .py files and one ENV (all 33 layers shared), so the grafted aiter,
#     aiter_meta and flydsl trees are identical bits under an honest name. They are
#     built for gfx942;gfx950 - the same trees the single-node MI355X Kimi-K3 card runs.
#   - No flydsl 0.2.4 re-pin after the graft. It exists for the gfx942 int4 path
#     (_setup_kernel_k3_situ_gfx942); the donor's 0.2.2 is what the working gfx950
#     image runs.
#   - GFX_COMPILATION_ARCH=gfx950, which sets the image's MORI_GPU_ARCHS default. The
#     launcher also forwards the arch it detects on the nodes, so MoRI JIT-builds for
#     the GPU it actually runs on either way.
#   - PYTORCH_ROCM_ARCH is inert in both files: the base image exports
#     PYTORCH_ROCM_ARCH=gfx90a;gfx942;gfx950 as an ENV, which wins over an ARG of the
#     same name, so vLLM is compiled for gfx950 regardless.
#
# STATUS: BRING-UP, NOT VALIDATED
#   Nothing shows MoRIIO disagg with Kimi-K3 has run on gfx950: the vLLM ref is the
#   fork's gfx942 branch, validated on MI300X only. The same stack has run MoRIIO +
#   MoRI-EP on gfx950 for GLM, which needed EP16 startup-deadlock gates and a MoRI
#   combine fix that are NOT in this vLLM ref, and ionic NICs needed a patched MoRI.
#   Expect the first runs to find those. Every pin is otherwise the MI300X file's.
# =============================================================================

# Image ARGs consumed by FROM must be declared before the first FROM (buildkit
# global scope); declaring them later scopes them to a single stage and the second
# FROM resolves blank.
#
# K3-aware AITER donor (step 5b). Public, anonymously pullable. Same ROCm 7.2.3 +
# torch 2.11 base as BASE_IMAGE, so the grafted trees are ABI-compatible.
ARG PROVEN_K3_IMAGE=vllm/vllm-openai-rocm:kimi-k3@sha256:5aa7e626ff73672f5ca7aae46754570488c23d33ca1ac90756a1d2d1a3fe099b
# Open ROCm vLLM CI base - same one the shared disagg image builds on.
ARG BASE_IMAGE=rocm/vllm-dev:ci_base-0fcd9b99cc9d63202da4c858d8ebc6582c9e2491

FROM ${PROVEN_K3_IMAGE} AS proven_k3_aiter

FROM ${BASE_IMAGE}

ENTRYPOINT []
WORKDIR /app

# Pin the *build toolchain*, not just the sources.
#
# Every source below is pinned to an immutable commit SHA, which makes the build
# look reproducible -- but pip builds wheels in an isolated environment and
# resolves build dependencies (setuptools, wheel) fresh from PyPI at build time.
# So a newer setuptools published after this file was last exercised can break a
# build whose sources have not moved at all. That is exactly what happened:
# setuptools >= 80 added
#     assert isinstance(self.compiler, CCompiler)
# to distutils' build_ext.build_extension, which MoRI's legacy
# Cython.Distutils.build_ext path violates, failing the amd_mori wheel with
#     AssertionError: run() must precede build_extension()
# while every pinned SHA was still correct.
#
# PIP_CONSTRAINT reaches inside pip's isolated build environments, which a plain
# `pip install setuptools==X` in the image does not. Set globally so later stages
# (AITER, vLLM, router) cannot regress the same way.
ARG SETUPTOOLS_CONSTRAINT="setuptools<80"
RUN printf '%s\n' "${SETUPTOOLS_CONSTRAINT}" > /etc/pip-constraints.txt
ENV PIP_CONSTRAINT=/etc/pip-constraints.txt

ARG GFX_COMPILATION_ARCH="gfx950"
ARG PYTORCH_ROCM_ARCH="gfx950"
ARG MAX_JOBS=32
ARG NVCC_THREADS=8
# K3 uses the moriio connector only; default the NIXL/RIXL transport layer OFF.
ARG WITH_NIXL=0
ARG NIC_COMPILATION_ARCH="cx7"

# -----------------------------------------------------------------------------
# 1. MoRI v1.2.2 (the K3 recipe's pin; the shared disagg image pins v1.2.1).
#    JIT-built, so this swaps the sources the EP kernels compile from at runtime.
#    Do NOT pass USE_IONIC=OFF / USE_BNXT=OFF - disabling NIC backends produced a
#    MoRI that deadlocked at the cross-node EP all-to-all init.
# -----------------------------------------------------------------------------
ARG MORI_REPO=https://github.com/ROCm/mori.git
# tag v1.2.2
ARG MORI_REF=fe12a11a7d6c6acd0771b772366ed9ed5e0d3d44
ENV MORI_GPU_ARCHS=${GFX_COMPILATION_ARCH}
# UMBP needs gRPC headers absent from this base and is unrelated to EP dispatch.
ENV BUILD_UMBP=OFF BUILD_UMBP_SPDK=OFF
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list 2>/dev/null || true && \
    sed -i 's|http://|https://|g' /etc/apt/sources.list.d/*.list 2>/dev/null || true && \
    apt-get update && apt-get install -y --no-install-recommends \
        git build-essential cmake ninja-build ccache libssl-dev pkg-config curl ca-certificates && \
    pip install meson==0.64.0 "pybind11[global]" tqdm prettytable && \
    pip uninstall -y amd_mori amd-mori amd-mori-nightly mori 2>/dev/null || true && \
    rm -rf /tmp/mori-src && \
    git clone --recursive "${MORI_REPO}" /tmp/mori-src && \
    cd /tmp/mori-src && git checkout "${MORI_REF}" && git submodule update --init --recursive && \
    BUILD_UMBP=OFF pip install . && \
    python3 -c "import mori, mori.io, mori.ops; print('MoRI OK at', mori.__path__[0])" && \
    mkdir -p /app && echo "MORI_REF=${MORI_REF}" >> /app/versions.txt && \
    rm -rf /tmp/mori-src

# -----------------------------------------------------------------------------
# 2. AITER 0.1.19 + flydsl 0.2.4 (K3 pins; see header for why 0.1.16.post3 fails).
#    0.1.19 also carries the #3658 top_k_top_p HSA-fault fix needed for DP-EP disagg.
#    Then invalidate the prewarmed JIT cache compiled against the old .so.
# -----------------------------------------------------------------------------
ARG AITER_VERSION=0.1.19
ARG AITER_WHEEL_URL="https://github.com/ROCm/aiter/releases/download/v0.1.19/amd_aiter-0.1.19%2Brocm7.2.manylinux.2.28-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
RUN echo "Bumping AITER to ${AITER_VERSION} from ${AITER_WHEEL_URL}" && \
    _W="/tmp/$(basename "${AITER_WHEEL_URL}" | sed 's/%2B/+/g')" && \
    curl -fL --retry 3 --retry-delay 2 -o "${_W}" "${AITER_WHEEL_URL}" && \
    (pip uninstall -y amd_aiter amd-aiter aiter 2>/dev/null || true) && \
    pip install --no-deps "${_W}" && \
    pip install "flydsl==0.2.4" && \
    rm -f "${_W}" && \
    python3 - <<'PYEOF'
from importlib.metadata import version as v, PackageNotFoundError
vm = None
for n in ("amd-aiter", "amd_aiter", "aiter"):
    try: vm = v(n); break
    except PackageNotFoundError: pass
assert vm and vm.split("+", 1)[0].startswith("0.1.19"), f"AITER not 0.1.19: {vm!r}"
print("AITER OK:", vm)
PYEOF
RUN rm -rf /opt/vllm_cache/aiter_jit /root/.aiter && echo "cleared stale AITER JIT cache" && \
    echo "AITER_VERSION=${AITER_VERSION}" >> /app/versions.txt

# -----------------------------------------------------------------------------
# 3. vLLM: full source compile of the K3 + MoRIIO branch. All K3 connector fixes
#    are committed in this tree - there is no runtime patcher:
#      - 4-KV-cache-group block routing (K3 allocates 3 KDA/mamba groups + 1 MLA;
#        the stock connector hardcoded 2-group indices and sent MLA KV to mamba
#        block ids, so decode read empty blocks and generated without context)
#      - multi-chunk prefill transfer gated on compute progress, not block count
#        (the block-count gate fired after chunk 1 for prompts fitting one padded
#        block, so only max_num_batched_tokens of KV ever crossed)
#      - KDA gather made sync-free (a per-layer per-chunk device->CPU sync that
#        turned >500K-token prefills into an apparent hang)
#    Repo is public; no credentials are needed or accepted here (the upstream
#    recipe took a GH_TOKEN build-arg, which would bake the token into image
#    metadata - removed).
# -----------------------------------------------------------------------------
ARG VLLM_REPO=https://github.com/raviguptaamd/vllm.git
# branch kimi-k3-wideep-disagg-fullsource-v3 @ 2026-08-11
ARG VLLM_REF=862bfd8ca4db78b9cbcbcf9ec6013638e3ae6543
ENV VLLM_TARGET_DEVICE=rocm \
    PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH} \
    MAX_JOBS=${MAX_JOBS}
# MAX_JOBS/NVCC_THREADS are set INLINE on the pip line: under the legacy builder
# the ENV above does not reach the pip build subprocess, and vLLM's setup.py
# compute_num_jobs then dies on `int("")`.
RUN rm -rf /tmp/vllm-src && \
    git clone "${VLLM_REPO}" /tmp/vllm-src && \
    cd /tmp/vllm-src && git checkout "${VLLM_REF}" && \
    echo "VLLM_REF=${VLLM_REF}" >> /app/versions.txt && \
    pip uninstall -y vllm 2>/dev/null || true && \
    MAX_JOBS="${MAX_JOBS:-32}" NVCC_THREADS="${NVCC_THREADS:-8}" \
      pip install --no-deps --no-build-isolation -v . && \
    python3 -c "import vllm; print('vLLM', vllm.__version__, 'from', vllm.__file__)" && \
    rm -rf /tmp/vllm-src

# Cross-check MoRI + AITER survived the vLLM install (no silent downgrade).
RUN python3 - <<'PYEOF'
from importlib.metadata import version as v, PackageNotFoundError
def get(names):
    for n in names:
        try: return v(n)
        except PackageNotFoundError: pass
    return None
av = get(("amd-aiter", "amd_aiter", "aiter"))
assert av and av.split("+", 1)[0].startswith("0.1.19"), f"AITER downgraded: {av!r}"
import mori, mori.io, mori.ops
print("Post-vLLM check OK: AITER", av, "+ MoRI importable")
PYEOF

# -----------------------------------------------------------------------------
# 4. vllm-router: DP-rank round-robin + the 2P2D KV-notify fix
#    (remote_dp_rank_override + remote_dp_size). Without the notify fix a 2P2D
#    EP16 run reproducibly wedges on "remote blocks never arrived" deferred-write
#    expiries, because decode's notify targets the wrong DP rank.
#    Same source the shared disagg image uses; pinned to its SHA here.
# -----------------------------------------------------------------------------
ARG ROUTER_REPO=https://github.com/raviguptaamd/router.git
# branch ravgupta/discovery-dp-rank-roundrobin
ARG ROUTER_REF=6409ac1409410f54c5ed39791aadc69ce80b7bf3
ARG RUST_TOOLCHAIN=1.88.0
RUN if ! command -v cargo >/dev/null 2>&1; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN}"; \
    fi && \
    export PATH="/root/.cargo/bin:${PATH}" && \
    rm -rf /tmp/vllm-router-src && \
    git clone --filter=blob:none "${ROUTER_REPO}" /tmp/vllm-router-src && \
    cd /tmp/vllm-router-src && git checkout "${ROUTER_REF}" && \
    cargo build --release && \
    install -m 755 target/release/vllm-router /usr/local/bin/vllm-router && \
    vllm-router --help 2>&1 | grep -q moriio && \
    echo "VLLM_ROUTER_REF=${ROUTER_REF}" >> /app/versions.txt && \
    rm -rf /tmp/vllm-router-src

# -----------------------------------------------------------------------------
# 4b. Optional NIXL/RIXL transport (WITH_NIXL=1). OFF by default for K3 - the
#     recipe runs the moriio connector only. Identical to the shared disagg image.
# -----------------------------------------------------------------------------
ENV _ROCM_DIR=/opt/rocm \
    _UCX_SOURCE=https://github.com/ROCm/ucx.git \
    _UCX_BRANCH=da3fac2a \
    _UCX_INSTALL_DIR=/usr/local/ucx/ \
    _RIXL_SOURCE=https://github.com/ROCm/RIXL.git \
    _RIXL_BRANCH=f33a5599 \
    _RIXL_INSTALL_DIR=/usr/local/RIXL/install \
    _NIXLBENCH_INSTALL_DIR=/usr/local/RIXL
RUN if [ "${WITH_NIXL}" != "1" ]; then \
      echo "WITH_NIXL=${WITH_NIXL}: skipping UCX/RIXL/rocSHMEM/DeepEP (MoRI-EP only)"; \
    else set -e && \
      echo "WITH_NIXL=1: building UCX + RIXL + rocSHMEM + DeepEP" && \
      apt-get update && apt-get install -y \
        autoconf automake libtool autogen pkg-config m4 gcc make \
        librdmacm-dev rdmacm-utils infiniband-diags ibverbs-utils perftest ethtool \
        libibverbs-dev rdma-core strace libgflags-dev \
        libaio-dev liburing-dev libcpprest-dev libgrpc-dev libgrpc++-dev \
        libprotobuf-dev protobuf-compiler-grpc wget && \
      pip install meson==0.64.0 "pybind11[global]" pyyaml && \
      cd /tmp && git clone "${_UCX_SOURCE}" && cd ucx && git checkout "${_UCX_BRANCH}" && \
        ./autogen.sh && mkdir -p build && cd build && \
        ../configure --prefix="${_UCX_INSTALL_DIR}" --with-rocm="${_ROCM_DIR}" \
          --disable-go --disable-java --disable-assertions --enable-mt && \
        make -j && make install && \
      cd /tmp && wget -q https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz && \
        tar -xzf v1.14.0.tar.gz && cd googletest-1.14.0 && mkdir -p build && cd build && \
        cmake -DBUILD_SHARED_LIBS=on .. && make -j && make install && \
      cd /tmp && git clone "${_RIXL_SOURCE}" && cd RIXL && git checkout "${_RIXL_BRANCH}" && \
        meson setup build/ --prefix="${_RIXL_INSTALL_DIR}" -Ducx_path="${_UCX_INSTALL_DIR}" \
          -Ddisable_gds_backend=true -Dcudapath_inc="${_ROCM_DIR}/include" -Dcudapath_lib="${_ROCM_DIR}/lib" && \
        cd build && ninja && ninja install && cd /tmp/RIXL && \
        pip install --config-settings=setup-args="-Dcudapath_inc=${_ROCM_DIR}/include" \
                    --config-settings=setup-args="-Dcudapath_lib=${_ROCM_DIR}/lib" \
                    --config-settings=setup-args="-Ducx_path=${_UCX_INSTALL_DIR}" \
                    --config-settings=setup-args="-Ddisable_gds_backend=true" . && \
      cd /tmp && git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-systems.git && \
        cd rocm-systems && git sparse-checkout set --cone projects/rocshmem && git checkout develop && \
        mkdir -p /tmp/rocshmem-build && cd /tmp/rocshmem-build && \
        /tmp/rocm-systems/projects/rocshmem/scripts/build_configs/all_backends \
          -DUSE_EXTERNAL_MPI=OFF -DGPU_TARGETS="${GFX_COMPILATION_ARCH}" && \
      cd /tmp && git clone https://github.com/ROCm/DeepEP.git && cd DeepEP && \
        PYTORCH_ROCM_ARCH="${GFX_COMPILATION_ARCH}" CFLAGS="-O3 -fPIC" \
          CXXFLAGS="-O3 -fPIC --offload-arch=${GFX_COMPILATION_ARCH}" HIP_CXX_FLAGS="-O3 -fPIC" \
          python3 setup.py --variant rocm --nic "${NIC_COMPILATION_ARCH}" build develop && \
      echo "WITH_NIXL build complete" >> /app/versions.txt && \
      rm -rf /tmp/ucx /tmp/googletest-1.14.0 /tmp/v1.14.0.tar.gz /tmp/rocm-systems /tmp/rocshmem-build; \
    fi
ENV LD_LIBRARY_PATH="/usr/local/ucx/lib:/usr/local/lib:/usr/local/RIXL/install/lib:${LD_LIBRARY_PATH}" \
    PATH="/usr/local/ucx/bin:${PATH}"

# -----------------------------------------------------------------------------
# 5. Cache locations (structural: WHERE the JIT/compile caches live in the image).
#    Mount target for the launcher's persistent host JIT cache.
#
#    This image ships NO runtime recipe / tuning / platform ENV, matching the
#    shared disagg image. Everything run-tunable is applied at launch so the same
#    image serves any cluster without a rebuild:
#      - K3 serving recipe (VLLM_ROCM_USE_AITER_MLA=0, AITER_SITUV2_A8W4,
#        KV_CACHE_MEMORY_BYTES, *_CUDAGRAPH_MODE, *_MORI_BACKEND, ...)
#          -> scripts/vllm_dissag/models.yaml, entry "Kimi-K3"
#      - ROCm-7.2.3 GPU-RDMA platform env + MoRI fabric tuning
#          -> scripts/vllm_dissag/connectors/moriio.env
#    The slurm launcher forwards both via `docker -e` (platform env must reach
#    PID 1 - PyTorch reads alloc-conf at import).
# -----------------------------------------------------------------------------
ENV AITER_JIT_DIR=/opt/vllm_cache/aiter_jit \
    VLLM_CACHE_ROOT=/opt/vllm_cache/vllm \
    TRITON_CACHE_DIR=/opt/vllm_cache/triton \
    COMGR_CACHE_DIR=/opt/vllm_cache/comgr

# -----------------------------------------------------------------------------
# 5b. K3-AWARE AITER GRAFT (same trees the single-node MI355X Kimi-K3 image runs).
#     The 0.1.19 release wheel has no Kimi-K3 MoE tuning. At K3's MoE profiling
#     shape (M = EP x max_tokens = 131072, N=3584, K=3072, SiTUv2, mxfp4) it finds
#     no tuned FlyDSL config and falls back to a heuristic kernel whose
#     buffer.load.lds intrinsic aborts LLVM ("Do not know how to expand this
#     operator's operand!"). The worker then dies natively inside
#     determine_available_memory with no Python traceback and engine init fails.
#     PROVEN_K3_IMAGE ships a K3-aware AITER: kimik3_{a8w4,fp4}_tuned_fmoe.csv
#     model configs, working MXFP4->CK/int4 routing, and prebuilt hsaco in
#     aiter_meta. Grafting its aiter + aiter_meta trees over the 0.1.19 install
#     makes K3 MXFP4 MoE compile.
#     Placed AFTER the vLLM/router layers so edits here do not invalidate the
#     ~40-minute vLLM compile cache.
# -----------------------------------------------------------------------------
RUN rm -rf /usr/local/lib/python3.12/dist-packages/aiter \
           /usr/local/lib/python3.12/dist-packages/aiter_meta \
           /usr/local/lib/python3.12/dist-packages/flydsl \
           /usr/local/lib/python3.12/dist-packages/aiter*.dist-info \
           /usr/local/lib/python3.12/dist-packages/amd_aiter*.dist-info 2>/dev/null || true
COPY --from=proven_k3_aiter /usr/local/lib/python3.12/dist-packages/aiter      /usr/local/lib/python3.12/dist-packages/aiter
COPY --from=proven_k3_aiter /usr/local/lib/python3.12/dist-packages/aiter_meta /usr/local/lib/python3.12/dist-packages/aiter_meta
COPY --from=proven_k3_aiter /usr/local/lib/python3.12/dist-packages/flydsl     /usr/local/lib/python3.12/dist-packages/flydsl
# flydsl stays at the donor's 0.2.2, the version the gfx950 image serves K3 with. The
# MI300X file re-pins 0.2.4 here for the gfx942-only int4 path, which never runs on gfx950.
# Drop step 2's 0.2.4 metadata so pip reports the version actually on disk.
RUN rm -rf /usr/local/lib/python3.12/dist-packages/flydsl-*.dist-info && \
    echo "FLYDSL=donor $(python3 -c 'import flydsl,sys; print(getattr(flydsl, "__version__", "?"))' 2>/dev/null)" >> /app/versions.txt
RUN rm -rf /opt/vllm_cache/aiter_jit /root/.aiter && \
    echo "AITER_GRAFT=proven_k3 (kimik3 tuned fmoe configs)" >> /app/versions.txt

# -----------------------------------------------------------------------------
# 6. CRITICAL: scrub build-time MoRI JIT state. The `import mori` verifications
#    above compile/lock MoRI EP kernels under /root/.mori/jit on the BUILD host,
#    leaving stale .hsaco.lock files. At runtime MoriAll2AllManager finds those
#    locks, waits on a build-in-progress whose owner PID is long gone, and
#    DEADLOCKS at ep:0 init. A clean image ships /root/.mori empty.
# -----------------------------------------------------------------------------
RUN rm -rf /root/.mori /tmp/mori_jit_* && mkdir -p /root/.mori && \
    echo "JIT_SCRUBBED: /root/.mori + /tmp/mori_jit_* cleared at build end" >> /app/versions.txt

RUN cat /app/versions.txt 2>/dev/null | tail -20 || true
