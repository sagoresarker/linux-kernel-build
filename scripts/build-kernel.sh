#!/usr/bin/env bash
# =============================================================================
# build-kernel.sh
# Builds a Firecracker-compatible Linux kernel with k3s networking support.
#
# Usage:
#   ./scripts/build-kernel.sh
#
# Environment variables:
#   KERNEL_VERSION  - Kernel version to build (default: 6.1.164)
#   BUILD_JOBS      - Parallel make jobs (default: nproc)
#   BUILD_DIR       - Working directory for build (default: ./build)
#   SKIP_DOWNLOAD   - Set to 1 to skip downloading kernel source
# =============================================================================
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-6.1.164}"
KERNEL_MAJOR="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

CONFIG_FRAGMENT="${PROJECT_DIR}/configs/microvm-kernel-x86_64-k3s.config-fragment"
FIRECRACKER_BASE_CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config"

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${KERNEL_TARBALL}"
KERNEL_SRC_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"
OUTPUT_KERNEL="${BUILD_DIR}/vmlinux-${KERNEL_VERSION}-firecracker-k3s"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

check_prerequisites() {
    local missing=()
    for cmd in gcc make bc flex bison wget tar pahole; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required tools: ${missing[*]}"
        err "On Ubuntu/Debian: sudo apt-get install build-essential bc bison flex libelf-dev libssl-dev dwarves wget"
        err "On Fedora/RHEL:  sudo dnf install gcc make bc bison flex elfutils-libelf-devel openssl-devel dwarves wget"
        err "(dwarves provides 'pahole', needed for CONFIG_DEBUG_INFO_BTF)"
        exit 1
    fi

    for header_check in "elf.h:libelf-dev" "openssl/ssl.h:libssl-dev"; do
        local header="${header_check%%:*}"
        local pkg="${header_check##*:}"
        if ! echo "#include <${header}>" | gcc -E -x c - &>/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing development headers: ${missing[*]}"
        err "Install the corresponding -dev/-devel packages."
        exit 1
    fi

    log "All prerequisites satisfied"
}

download_kernel() {
    if [ "$SKIP_DOWNLOAD" = "1" ] && [ -d "$KERNEL_SRC_DIR" ]; then
        log "Skipping download (SKIP_DOWNLOAD=1, source exists at $KERNEL_SRC_DIR)"
        return 0
    fi

    mkdir -p "$BUILD_DIR"

    if [ ! -f "${BUILD_DIR}/${KERNEL_TARBALL}" ]; then
        log "Downloading Linux ${KERNEL_VERSION} from kernel.org..."
        wget -q --show-progress -O "${BUILD_DIR}/${KERNEL_TARBALL}" "$KERNEL_URL"
    else
        log "Kernel tarball already exists: ${BUILD_DIR}/${KERNEL_TARBALL}"
    fi

    if [ ! -d "$KERNEL_SRC_DIR" ]; then
        log "Extracting kernel source..."
        tar xf "${BUILD_DIR}/${KERNEL_TARBALL}" -C "$BUILD_DIR"
    else
        log "Kernel source already extracted at $KERNEL_SRC_DIR"
    fi
}

download_base_config() {
    local config_dest="${KERNEL_SRC_DIR}/.config.base"

    if [ -f "$config_dest" ]; then
        log "Firecracker base config already exists"
        return 0
    fi

    log "Downloading Firecracker base kernel config..."
    wget -q -O "$config_dest" "$FIRECRACKER_BASE_CONFIG_URL"
    log "Base config saved to $config_dest"
}

apply_config() {
    if [ ! -f "$CONFIG_FRAGMENT" ]; then
        err "Config fragment not found: $CONFIG_FRAGMENT"
        exit 1
    fi

    log "Applying Firecracker base config..."
    cp "${KERNEL_SRC_DIR}/.config.base" "${KERNEL_SRC_DIR}/.config"

    log "Merging k3s config fragment..."
    # merge_config.sh may not exist before first make invocation,
    # so fall back to manual append + olddefconfig
    if [ -x "${KERNEL_SRC_DIR}/scripts/kconfig/merge_config.sh" ]; then
        cd "$KERNEL_SRC_DIR"
        scripts/kconfig/merge_config.sh -m .config "$CONFIG_FRAGMENT"
    else
        cat "$CONFIG_FRAGMENT" >> "${KERNEL_SRC_DIR}/.config"
    fi

    log "Running olddefconfig to resolve dependencies..."
    make -C "$KERNEL_SRC_DIR" olddefconfig -j"$BUILD_JOBS" > /dev/null 2>&1

    log "Config applied successfully"
}

verify_config() {
    log "Verifying critical config options..."
    local config="${KERNEL_SRC_DIR}/.config"
    local failed=0

    local critical_options=(
        "CONFIG_VXLAN=y"
        "CONFIG_GENEVE=y"
        "CONFIG_NF_TABLES=y"
        "CONFIG_IP_SET=y"
        "CONFIG_IP_VS=y"
        "CONFIG_NETFILTER_XT_MATCH_COMMENT=y"
        "CONFIG_NETFILTER_NETLINK_ACCT=y"
        "CONFIG_TUN=y"
        "CONFIG_NFT_COUNTER=y"
        "CONFIG_NFT_CHAIN_NAT=y"
        "CONFIG_BRIDGE_NETFILTER=y"
        "CONFIG_OVERLAY_FS=y"
        "CONFIG_BPF_JIT=y"
        "CONFIG_DEBUG_INFO_BTF=y"
        "CONFIG_CRYPTO_USER_API_HASH=y"
        "CONFIG_SCHEDSTATS=y"
    )

    for opt in "${critical_options[@]}"; do
        if grep -q "^${opt}$" "$config"; then
            log "  OK: $opt"
        else
            err "  MISSING: $opt"
            failed=1
        fi
    done

    if [ "$failed" -eq 1 ]; then
        err "Some critical options are missing. The kernel may not work with k3s."
        err "Try running: make -C $KERNEL_SRC_DIR menuconfig"
        exit 1
    fi

    log "All critical config options verified"
}

build_kernel() {
    log "Building vmlinux with $BUILD_JOBS parallel jobs..."
    log "This may take 10-20 minutes depending on your hardware."

    make -C "$KERNEL_SRC_DIR" vmlinux -j"$BUILD_JOBS"

    if [ ! -f "${KERNEL_SRC_DIR}/vmlinux" ]; then
        err "Build failed: vmlinux not found"
        exit 1
    fi

    cp "${KERNEL_SRC_DIR}/vmlinux" "$OUTPUT_KERNEL"
    cp "${KERNEL_SRC_DIR}/.config" "${OUTPUT_KERNEL}.config"

    local size
    size=$(du -h "$OUTPUT_KERNEL" | cut -f1)
    log "Build complete!"
    log ""
    log "  Kernel:  $OUTPUT_KERNEL ($size)"
    log "  Config:  ${OUTPUT_KERNEL}.config"
    log ""
    log "Use this kernel in your Firecracker VM config:"
    log "  \"kernel_image_path\": \"$OUTPUT_KERNEL\""
}

main() {
    log "============================================="
    log "Firecracker K3s Kernel Builder"
    log "Kernel version: ${KERNEL_VERSION}"
    log "Build jobs:     ${BUILD_JOBS}"
    log "Build dir:      ${BUILD_DIR}"
    log "============================================="
    echo ""

    check_prerequisites
    download_kernel
    download_base_config
    apply_config
    verify_config
    build_kernel
}

main "$@"
