#!/usr/bin/env bash
# Install the official 2BRobust BBRv1 patch as an out-of-tree replacement
# tcp_bbr kernel module for the running Linux kernel.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly OFFICIAL_REPO="https://github.com/sys-uos/bbr-cpu-contention"
readonly OFFICIAL_COMMIT="8055052d8d7770fd20f4e0db1182c9ea975398c4"
readonly PATCH_URL="https://raw.githubusercontent.com/sys-uos/bbr-cpu-contention/${OFFICIAL_COMMIT}/patches/bbr1.patch"
readonly PATCH_SHA256="07714e80b8b6af314361b2d1bdcaae02aa38004a15d0e954929cb50abe2fc163"

readonly MODULE_RELATIVE_PATH="updates/2brobust/net/ipv4/tcp_bbr.ko"
readonly SYSCTL_FILE="/etc/sysctl.d/99-2brobust.conf"

KEEP_WORKDIR=0
SKIP_DEPS=0
VERIFY_ONLY=0
WORK_ROOT="${WORK_ROOT:-/usr/local/src/2brobust}"
KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
KERNEL_VERSION="${KERNEL_VERSION:-}"

log()  { printf '[2brobust] %s\n' "$*"; }
warn() { printf '[2brobust] WARNING: %s\n' "$*" >&2; }
die()  { printf '[2brobust] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo ./install-2brobust.sh [OPTIONS]

Builds the official 2BRobust BBRv1 patch as tcp_bbr.ko for the running kernel,
installs it under /lib/modules/<release>/updates/2brobust, and activates it.

Options:
  --verify          Verify an already installed and loaded module only.
  --keep-workdir    Retain the downloaded source and build tree.
  --skip-deps       Do not install Debian build dependencies with apt.
  -h, --help        Show this help.

Environment:
  KERNEL_RELEASE    Kernel release to build for (default: uname -r).
  KERNEL_VERSION    Upstream source version (default: numeric part of uname -r).
  WORK_ROOT         Build-cache directory (default: /usr/local/src/2brobust).
EOF
}

cleanup() {
    local status=$?
    if (( status == 0 && KEEP_WORKDIR == 0 )) && [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR:-}" ]]; then
        # BUILD_DIR is always created as a child of WORK_ROOT below.
        find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        rmdir "$BUILD_DIR" 2>/dev/null || true
    elif (( status != 0 )); then
        warn "Build files were retained at ${BUILD_DIR:-$WORK_ROOT} for diagnosis."
    fi
}

require_root() {
    if (( EUID == 0 )); then
        return
    fi
    command -v sudo >/dev/null 2>&1 || die "Run this script as root (sudo is unavailable)."
    log "Re-executing through sudo."
    exec sudo --preserve-env=KERNEL_RELEASE,KERNEL_VERSION,WORK_ROOT bash "$0" "$@"
}

check_target_kernel() {
    [[ "$(uname -r)" == "$KERNEL_RELEASE" ]] || die \
        "Booted kernel is $(uname -r), not ${KERNEL_RELEASE}. Build and load only for the running kernel."
}

derive_kernel_source() {
    if [[ -z "$KERNEL_VERSION" ]]; then
        if [[ "$KERNEL_RELEASE" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)([-+].*)?$ ]]; then
            KERNEL_VERSION="${BASH_REMATCH[1]}"
        else
            die "Cannot derive an upstream source version from ${KERNEL_RELEASE}; set KERNEL_VERSION explicitly."
        fi
    fi
    [[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die \
        "KERNEL_VERSION must be an upstream version such as 6.12.94."

    KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
    KERNEL_ARCHIVE="linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${KERNEL_ARCHIVE}"
    CHECKSUMS_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/sha256sums.asc"
}

install_dependencies() {
    local -a packages
    (( SKIP_DEPS == 1 )) && return
    command -v apt-get >/dev/null 2>&1 || die "This Debian installer requires apt-get; use --skip-deps if dependencies are already present."
    log "Installing build prerequisites."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    packages=(
        bc bison build-essential ca-certificates curl flex kmod libelf-dev libssl-dev \
        pahole patch rsync xz-utils
    )
    if [[ ! -d "/lib/modules/${KERNEL_RELEASE}/build" ]]; then
        log "Installing headers matching the running kernel: linux-headers-${KERNEL_RELEASE}."
        packages+=("linux-headers-${KERNEL_RELEASE}")
    fi
    apt-get install -y --no-install-recommends "${packages[@]}"
}

require_build_tree() {
    KDIR="/lib/modules/${KERNEL_RELEASE}/build"
    [[ -d "$KDIR" ]] || die "Missing ${KDIR}. Install or provide the matching kernel headers/build tree first."
    [[ -r "$KDIR/.config" ]] || die "Missing ${KDIR}/.config; a configured matching build tree is required."
    if grep -qx 'CONFIG_MODVERSIONS=y' "$KDIR/.config" && [[ ! -r "$KDIR/Module.symvers" ]]; then
        die "${KDIR}/Module.symvers is required because CONFIG_MODVERSIONS=y."
    fi
}

verify_sha256() {
    local expected=$1 file=$2
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

download_inputs() {
    mkdir -p "$WORK_ROOT/downloads"
    PATCH_FILE="$WORK_ROOT/downloads/bbr1-${OFFICIAL_COMMIT}.patch"
    TARBALL="$WORK_ROOT/downloads/${KERNEL_ARCHIVE}"
    CHECKSUM_FILE="$WORK_ROOT/downloads/sha256sums-v${KERNEL_MAJOR}.asc"

    log "Downloading the official 2BRobust BBRv1 patch at ${OFFICIAL_COMMIT:0:12}."
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --output "$PATCH_FILE" "$PATCH_URL"
    verify_sha256 "$PATCH_SHA256" "$PATCH_FILE"

    log "Fetching the official kernel.org checksum for Linux ${KERNEL_VERSION}."
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --output "$CHECKSUM_FILE" "$CHECKSUMS_URL"
    KERNEL_SHA256="$(awk -v archive="$KERNEL_ARCHIVE" '$2 == archive { print $1; exit }' "$CHECKSUM_FILE")"
    [[ "$KERNEL_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die \
        "No SHA-256 checksum for ${KERNEL_ARCHIVE} was found at kernel.org."

    log "Downloading Linux ${KERNEL_VERSION} from kernel.org."
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --output "$TARBALL" "$KERNEL_URL"
    verify_sha256 "$KERNEL_SHA256" "$TARBALL"
}

prepare_source() {
    BUILD_DIR="$WORK_ROOT/build-${KERNEL_RELEASE}"
    SRC="$BUILD_DIR/linux-${KERNEL_VERSION}"
    if [[ -e "$BUILD_DIR" ]]; then
        die "${BUILD_DIR} already exists. Remove it after reviewing it, or set WORK_ROOT to a new location."
    fi
    mkdir -p "$BUILD_DIR"
    trap cleanup EXIT

    log "Extracting kernel source."
    tar --extract --xz --file "$TARBALL" --directory "$BUILD_DIR"
    [[ -f "$SRC/net/ipv4/tcp_bbr.c" ]] || die "Kernel archive layout is unexpected."

    log "Checking and applying the official BBRv1 patch."
    patch --dry-run --batch --forward -p1 --directory "$SRC" < "$PATCH_FILE"
    patch --batch --forward -p1 --directory "$SRC" < "$PATCH_FILE"
    grep -Fq 'Register BBRv1 patch.' "$SRC/net/ipv4/tcp_bbr.c" || die "Patch marker is absent after applying the patch."

    # Reuse the running kernel configuration and its exported symbol CRCs.
    cp "$KDIR/.config" "$SRC/.config"
    if [[ -r "$KDIR/Module.symvers" ]]; then
        cp "$KDIR/Module.symvers" "$SRC/Module.symvers"
    fi

    log "Configuring BBR as a loadable module."
    make -s -C "$SRC" olddefconfig
    "$SRC/scripts/config" --file "$SRC/.config" --module TCP_CONG_BBR
    make -s -C "$SRC" olddefconfig
    grep -qx 'CONFIG_TCP_CONG_BBR=m' "$SRC/.config" || die \
        "The kernel configuration did not retain CONFIG_TCP_CONG_BBR=m."

    local built_release
    built_release="$(make -s -C "$SRC" kernelrelease)"
    [[ "$built_release" == "$KERNEL_RELEASE" ]] || die \
        "Source configuration produces kernel release ${built_release}, expected ${KERNEL_RELEASE}."
}

build_module() {
    local jobs
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    log "Preparing the kernel build tree and compiling tcp_bbr.ko with ${jobs} job(s)."
    make -C "$SRC" -j"$jobs" prepare modules_prepare
    make -C "$SRC" -j"$jobs" net/ipv4/tcp_bbr.ko
    [[ -f "$SRC/net/ipv4/tcp_bbr.ko" ]] || die "Build completed without tcp_bbr.ko."

    local vermagic
    vermagic="$(modinfo -F vermagic "$SRC/net/ipv4/tcp_bbr.ko")"
    [[ "$vermagic" == "$KERNEL_RELEASE"* ]] || die \
        "Built module vermagic (${vermagic}) does not start with ${KERNEL_RELEASE}."
}

install_module() {
    local destination="/lib/modules/${KERNEL_RELEASE}/${MODULE_RELATIVE_PATH}"
    log "Installing the patched module to ${destination}."
    install -D -m 0644 "$SRC/net/ipv4/tcp_bbr.ko" "$destination"
    depmod -a "$KERNEL_RELEASE"

    local resolved
    resolved="$(modinfo -k "$KERNEL_RELEASE" -n tcp_bbr)"
    [[ "$resolved" == "$destination" ]] || die \
        "depmod resolved tcp_bbr to ${resolved}, not the installed update module."
}

configure_defaults() {
    log "Configuring FQ pacing and BBR as persistent TCP defaults."
    cat > "${SYSCTL_FILE}.tmp" <<'EOF'
# Installed by install-2brobust.sh.  FQ is required for TCP BBR pacing.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    install -m 0644 "${SYSCTL_FILE}.tmp" "$SYSCTL_FILE"
    rm -f "${SYSCTL_FILE}.tmp"
}

activate_module() {
    local previous_cc
    previous_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
    # Do not leave BBR selected while asking the kernel to release its old module.
    sysctl -qw net.ipv4.tcp_congestion_control=cubic || true
    if lsmod | awk '$1 == "tcp_bbr" { found = 1 } END { exit !found }'; then
        log "Replacing the currently loaded tcp_bbr module."
        if ! modprobe -r tcp_bbr; then
            sysctl -qw net.ipv4.tcp_congestion_control="$previous_cc" || true
            warn "The existing tcp_bbr module is busy. The new module is staged for the next reboot."
            warn "Close BBR-using connections and re-run this script, or reboot then run: $0 --verify"
            return 2
        fi
    fi

    modprobe tcp_bbr
    sysctl --system >/dev/null
}

verify_installation() {
    local expected="/lib/modules/${KERNEL_RELEASE}/${MODULE_RELATIVE_PATH}"
    local resolved available default_cc qdisc
    resolved="$(modinfo -k "$KERNEL_RELEASE" -n tcp_bbr 2>/dev/null || true)"
    [[ "$resolved" == "$expected" ]] || die "tcp_bbr does not resolve to the 2BRobust update module: ${resolved:-not found}"

    lsmod | awk '$1 == "tcp_bbr" { found = 1 } END { exit !found }' || die "tcp_bbr is not loaded."
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
    [[ " $available " == *" bbr "* ]] || die "bbr is not available: ${available}"
    default_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
    [[ "$default_cc" == "bbr" ]] || die "Default congestion control is ${default_cc}, expected bbr."
    qdisc="$(sysctl -n net.core.default_qdisc)"
    [[ "$qdisc" == "fq" ]] || die "Default qdisc is ${qdisc}, expected fq."

    # The marker is emitted by the author's patch on module registration.
    if dmesg --color=never 2>/dev/null | tail -n 300 | grep -Fq 'Register BBRv1 patch.'; then
        log "Kernel log contains the official patch registration marker."
    else
        warn "The patch registration marker is no longer in the readable kernel log; module path and runtime checks passed."
    fi

    log "Verification passed: ${expected} is loaded; BBR and FQ are active defaults."
}

main() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            --verify) VERIFY_ONLY=1 ;;
            --keep-workdir) KEEP_WORKDIR=1 ;;
            --skip-deps) SKIP_DEPS=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: ${argument}" ;;
        esac
    done

    require_root "$@"
    check_target_kernel
    derive_kernel_source
    if (( VERIFY_ONLY == 1 )); then
        verify_installation
        return
    fi

    install_dependencies
    require_build_tree
    download_inputs
    prepare_source
    build_module
    install_module
    configure_defaults
    if activate_module; then
        verify_installation
    else
        exit 2
    fi
}

main "$@"
