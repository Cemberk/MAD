# CONTEXT {'gpu_vendor': 'AMD', 'guest_os': 'UBUNTU'}
#
# Consolidated <components> Dockerfile
#
# Supports two DOCKER_TYPE values (auto-detected from /opt/rocm unless overridden):
#   BARE_OS            - Plain ubuntu: install ROCm, then install <components> from URL slots
#   ROCM_PREINSTALLED  - Base has ROCm (legacy or TheRock): install <components> from URL slots
#
# FULL_SETUP is a concept, not a DOCKER_TYPE to set. It means the base already has
# ROCm plus one or more <component>s. Do not set DOCKER_TYPE=FULL_SETUP. The
# COMPONENT_RELEASE_URL_* loop installs only slots whose URL is set; leave a slot
# empty to keep the preinstalled <component> (example: empty 1st slot keeps
# migraphx; a set 2nd slot installs onnx).
#
# Set DOCKER_TYPE=auto to auto-detect by probing the base image for ROCm: a pip
# "rocm" package (TheRock) or /opt/rocm (legacy) means ROCM_PREINSTALLED.
#
# madengine image_spec cards build this file with resolved build args (see
# compat/rocm.json). The resolved plan is stored in the org.amd.mad.build_plan
# label, and the installed stack in /opt/mad/build_info.json.
#
# INSTALL_TYPE selects between "therock" (pip wheels) and "legacy" (apt/deb).
#
# All URL ARGs can be overridden via madengine --additional-context:
#   {"docker_build_arg": {"DOCKER_TYPE": "ROCM_PREINSTALLED", "BASE_DOCKER": "rocm/pytorch:..."}}
#
# Table 1. DOCKER_TYPE vs ARG requirements
# +-----------------------------+------------------+------------------+------------------+
# |DOCKER_TYPE                  |BARE_OS           |ROCM_PREINSTALLED |FULL_SETUP        |
# |                             |                  |                  |(concept only;    |
# |                             |                  |                  |not a DT to set)  |
# |(THIS DOCKERFILE ROLE        |Install ROCm      |                  |                  |
# | DURING DOCKER BUILD)        |Install           |Install           |Install           |
# |                             |<components> from |<components> from |<component> from  |
# |                             |URL slots if set  |URL slots if set  |URL slots if set  |
# |                             |                  |                  |(empty slot =     |
# |                             |                  |                  |keep preinstalled |
# |                             |                  |                  |<component>)      |
# +-----------------------------+------------------+------------------+------------------+
# |BASE_DOCKER                  |Optional (use for |Mandatory (use to |Mandatory (base   |
# |                             |diff bare_os i.e. |set docker type   |already has ROCm  |
# |                             |centos)           |with ROCm         |+ some            |
# |                             |                  |installed)        |<component>(s))   |
# +-----------------------------+------------------+------------------+------------------+
# |COMPONENT_RELEASE_URL_*      |Optional (each    |Optional (each    |Optional (each    |
# |  (comma-separated slots)    |slot installs     |slot installs     |slot installs     |
# |                             |<component> if    |<component> if    |<component> if    |
# |                             |URL set)          |URL set)          |URL set)          |
# +-----------------------------+------------------+------------------+------------------+
ARG BASE_DOCKER=ubuntu:24.04
FROM $BASE_DOCKER
# ---------- Re-declare ARGs after FROM so they are available in RUN ----------
ARG BASE_DOCKER
# auto | BARE_OS | ROCM_PREINSTALLED
# (FULL_SETUP is not set here; implied by COMPONENT URL slots)
ARG DOCKER_TYPE="auto"
ARG GPU_ARCH=""
# therock | legacy
ARG INSTALL_TYPE="therock"
# ======================== ROCm release URLs ========================
ARG ROCM_RELEASE_URL_THEROCK="https://rocm.prereleases.amd.com/whl-multi-arch/"
ARG ROCM_RELEASE_URL_LEGACY="https://repo.radeon.com/amdgpu-install/7.2/ubuntu/noble/amdgpu-install_7.2.70200-1_all.deb"
# GPU_ARCH is a gfx target (gfx942); unset installs kernels for every target.
# devel is an extra so it resolves to the same ROCm release as the libraries.
ARG ROCM_EXTRAS="rocm[libraries,devel,device-${GPU_ARCH:-all}]"
# Optional torch, installed before components, e.g. "torch[device-gfx942]==2.10.*".
ARG TORCH_PACKAGES=""
ARG TORCH_INDEX_URL=""
# ======================== <components> release URLs ========================
# ',' separates <components> (example: 1st = migraphx, 2nd = onnx).
# A <component> is installed only when its slot is a non-empty URL.
ARG COMPONENT_RELEASE_URL_THEROCK=""
ARG COMPONENT_RELEASE_URL_LEGACY=""
ARG PIP_PREREQS_EXTRA=""
# Optional sha256 per component slot, ',' separated in slot order (empty = unchecked).
ARG COMPONENT_SHA256=""
# ======================== <components> source configuration ========================
# COMPONENT_REPOS: ',' separates <components>. Each member is <repo-url>/commit/<commit-sha>.
ARG COMPONENT_REPOS=""
# Resolved image_spec plan (JSON) from madengine; recorded as a label only.
ARG MAD_BUILD_PLAN=""
LABEL org.amd.mad.build_plan="${MAD_BUILD_PLAN}"
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]
WORKDIR /workspace
# =============================================================================
# Bootstrap: the tools every later step uses. A bare ubuntu base has no python,
# pip or wget, and Ubuntu 24.04 python refuses pip installs without this config.
# =============================================================================
RUN set -e; \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates git jq lsb-release python3 python3-pip python3-venv wget \
        libatomic1 libgomp1; \
    mkdir -p ~/.config/pip /opt/mad; \
    echo -e "[global]\nbreak-system-packages = true" > ~/.config/pip/pip.conf
# =============================================================================
# Step 0: Resolve DOCKER_TYPE
# When "auto", probe the base image and persist the result for later steps.
# =============================================================================
RUN set -e; \
    DT="${DOCKER_TYPE}"; \
    rocm_path=$(python3 -m pip show rocm 2>/dev/null | awk '/^Location:/{print $2}'); \
    if [ "$DT" = "auto" ]; then \
        if [ -n "$rocm_path" ] || [ -d /opt/rocm ]; then \
            DT="ROCM_PREINSTALLED"; \
        else \
            DT="BARE_OS"; \
        fi; \
    fi; \
    echo "Resolved DOCKER_TYPE=$DT"; \
    echo "$DT" > /tmp/.docker_type; \
    if [[ $rocm_path == /opt/* ]]; then \
        ln -sfn "$(echo "$rocm_path" | cut -d/ -f1-3)" /opt/mad/venv; \
    fi
# A TheRock base that keeps ROCm in a venv under /opt is linked to /opt/mad/venv,
# so later steps and the runtime use that python. Without one this entry is inert.
ENV PATH="/opt/mad/venv/bin:${PATH}"
# =============================================================================
# Step 1: Install ROCm (only for BARE_OS)
# =============================================================================
RUN set -ex; \
    DT=$(cat /tmp/.docker_type); \
    if [ "$DT" != "BARE_OS" ]; then echo "$DT: skipping ROCm install"; exit 0; fi; \
    \
    case "$INSTALL_TYPE" in \
        therock) \
            ROCM_URL="$ROCM_RELEASE_URL_THEROCK"; \
            if [ -z "$ROCM_URL" ]; then echo "ERROR: ROCM_RELEASE_URL_THEROCK is empty"; exit 1; fi; \
            \
            pip install --no-cache-dir --pre --index-url "$ROCM_URL" "$ROCM_EXTRAS"; \
            \
            SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])"); \
            ;; \
        legacy) \
            ROCM_URL="$ROCM_RELEASE_URL_LEGACY"; \
            if [ -z "$ROCM_URL" ]; then echo "ERROR: ROCM_RELEASE_URL_LEGACY is empty"; exit 1; fi; \
            wget "$ROCM_URL" -P /tmp/ && \
            BASENAME_PKG=$(basename "$ROCM_URL") && \
            apt install -y "/tmp/$BASENAME_PKG" && \
            amdgpu-install --usecase=rocm --no-dkms -y; \
            ;; \
        *) \
            echo "ERROR: unknown INSTALL_TYPE=$INSTALL_TYPE"; exit 1; \
            ;; \
    esac; \
    set +ex
# =============================================================================
# Step 2: Components wheel install + pip extra wheels. i.e. pinned.
# =============================================================================
RUN set -ex; \
    rocm_path=$(pip show -f rocm 2>/dev/null | grep Loc | awk '{print $2}'); \
    [[ $rocm_path == /opt/* ]] && source "$(echo "$rocm_path" | cut -d/ -f1-3)/bin/activate"; \
    PIP_PREREQS=( numpy flatbuffers); \
    pip3 install "${PIP_PREREQS[@]}"; \
    if [ -n "${PIP_PREREQS_EXTRA}" ]; then \
        pip3 install ${PIP_PREREQS_EXTRA}; \
    fi; \
    if [ -n "${TORCH_PACKAGES}" ]; then \
        PRE=""; [ "$INSTALL_TYPE" = "therock" ] && PRE="--pre"; \
        read -r -a TORCH_PKGS <<< "$TORCH_PACKAGES"; \
        pip3 install --no-cache-dir $PRE \
            ${TORCH_INDEX_URL:+--index-url "$TORCH_INDEX_URL"} "${TORCH_PKGS[@]}"; \
    fi; \
    IFS=',' read -r -a COMP_SHAS <<< "$COMPONENT_SHA256"; \
    unset IFS; \
    verify_sha() { \
        local want="${COMP_SHAS[$1]:-}" file="$2"; \
        [ -n "$want" ] || return 0; \
        echo "$want  $file" | sha256sum -c - || { echo "ERROR: sha256 mismatch: $file"; return 1; }; \
    }; \
    WGET_TMP_DIR="/tmp/wgetfiles"; mkdir -p "$WGET_TMP_DIR"; \
    install_wheel() { \
        local urls="$1" report="$2" idx="$3"; \
        if [ -z "$urls" ]; then echo "WARNING: no URL, skipping"; return 0; fi; \
        rm -rf "$WGET_TMP_DIR"/*.whl; \
        for url in ${urls//,/ }; do \
            if [ -z "$url" ]; then \
                continue; \
            fi; \
            echo "--- Fetching $url ---"; \
            wget -P "$WGET_TMP_DIR" "$url" || return $?; \
            verify_sha "$idx" "$WGET_TMP_DIR/$(basename "$url")" || return $?; \
        done; \
        local whls; \
        whls=$(ls -t "$WGET_TMP_DIR"/*.whl 2>/dev/null); \
        if [ -z "$whls" ]; then echo "WARNING: no wheel files downloaded"; return 0; fi; \
        pip3 install --no-cache-dir -v --report "$report" $whls || return $?; \
    }; \
    add_ld_path() { \
        local d="$1"; \
        [ -d "$d" ] || return 0; \
        if grep -q "$d" /etc/ld.so.conf.d/rocm-pip-sdk.conf 2>/dev/null; then return 0; fi; \
        echo "$d" >> /etc/ld.so.conf.d/rocm-pip-sdk.conf; \
    }; \
    add_new_wheel_so_ld_paths() { \
        local report="$1" site="$2"; \
        local name dist_name top pkg; \
        for name in $(jq -r '.install[].metadata.name' "$report"); do \
            dist_name="${name//-/_}"; \
            for top in "$site/$dist_name"-*.dist-info/top_level.txt; do \
                [ -f "$top" ] || continue; \
                while IFS= read -r pkg; do \
                    [ -n "$pkg" ] || continue; \
                    [ -d "$site/$pkg" ] && echo "$site/$pkg"; \
                done < "$top"; \
            done; \
        done | sort -u; \
    }; \
    IFS=',' read -r -a COMP_THEROCK_URLS <<< "$COMPONENT_RELEASE_URL_THEROCK"; \
    IFS=',' read -r -a COMP_LEGACY_URLS <<< "$COMPONENT_RELEASE_URL_LEGACY"; \
    unset IFS; \
    case "$INSTALL_TYPE" in \
        therock) COMPONENT_URLS=("${COMP_THEROCK_URLS[@]}"); ;; \
        legacy)  COMPONENT_URLS=("${COMP_LEGACY_URLS[@]}");  ;; \
        *) echo "ERROR: unknown INSTALL_TYPE=$INSTALL_TYPE"; exit 1; ;; \
    esac; \
    for idx in "${!COMPONENT_URLS[@]}"; do \
        COMP_URL="${COMPONENT_URLS[$idx]}"; \
        \
        if [ -z "$COMP_URL" ]; then \
            if [ "$idx" = "0" ] && [ "$INSTALL_TYPE" = "legacy" ]; then \
                echo "ERROR: component URL member $idx is empty"; exit 1; \
            fi; \
            echo "no URL for member $idx: skipping"; \
            continue; \
        fi; \
        \
        case "$INSTALL_TYPE" in \
            therock) \
                COMP_REPORT="/tmp/pip-report-${idx}.json"; \
                install_wheel "$COMP_URL" "$COMP_REPORT" "$idx"; \
                \
                SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])"); \
                for d in "${SITE_PACKAGES}"/_rocm_sdk_*/lib; do \
                    add_ld_path "$d"; \
                done; \
                while IFS= read -r root; do \
                    [ -d "$root" ] || continue; \
                    while IFS= read -r sodir; do \
                        add_ld_path "$sodir"; \
                    done < <(find "$root" -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u); \
                done < <(add_new_wheel_so_ld_paths "$COMP_REPORT" "$SITE_PACKAGES"); \
                ldconfig; \
                ;; \
            legacy) \
                wget "$COMP_URL" -P "$WGET_TMP_DIR" && \
                BASENAME_PKG=$(basename "$COMP_URL") && \
                verify_sha "$idx" "$WGET_TMP_DIR/$BASENAME_PKG" && \
                apt install -y "$WGET_TMP_DIR/$BASENAME_PKG"; \
                ;; \
        esac; \
    done; \
    \
    rm -rf "$WGET_TMP_DIR"; \
    set +ex
# =============================================================================
# Step 3: Clone <component> source (only if that <component> URL was passed)
# Loop: each COMPONENT_REPOS member is <repo-url>/commit/<commit-sha>
# =============================================================================
RUN set -e; \
    IFS=',' read -r -a COMP_REPOS <<< "$COMPONENT_REPOS"; \
    unset IFS; \
    for COMPONENT_REPO in "${COMP_REPOS[@]}"; do \
        COMPONENT_REPO=$(echo "$COMPONENT_REPO" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); \
        if [ -z "$COMPONENT_REPO" ]; then \
            continue; \
        fi; \
        case "$COMPONENT_REPO" in \
            */commit/*) ;; \
            *) echo "ERROR: COMPONENT_REPOS must be <url>/commit/<sha>: $COMPONENT_REPO"; exit 1 ;; \
        esac; \
        REPO_URL="${COMPONENT_REPO%%/commit/*}"; \
        COMMIT_SHA="${COMPONENT_REPO##*/commit/}"; \
        REPO_NAME=$(basename "$REPO_URL"); \
        REPO_NAME="${REPO_NAME%.git}"; \
        echo "--- Cloning COMPONENT_REPOS: $REPO_URL at $COMMIT_SHA ---"; \
        cd /workspace && \
        git clone "$REPO_URL" "$REPO_NAME" && \
        git -C "$REPO_NAME" fetch origin "$COMMIT_SHA" && \
        git -C "$REPO_NAME" checkout --detach FETCH_HEAD && \
        git -C "$REPO_NAME" submodule update --init --recursive; \
    done
# =============================================================================
# Step 4: Record the installed stack for madengine (build_manifest image_info)
# =============================================================================
COPY global_univ2_build_info.py /opt/mad/build_info.py
RUN python3 /opt/mad/build_info.py > /opt/mad/build_info.json
ENTRYPOINT [""]
