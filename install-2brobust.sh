#!/usr/bin/env bash
# Ubuntu-only 2BRobust BBRv1 external-module installer.
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly PATCH_COMMIT='8055052d8d7770fd20f4e0db1182c9ea975398c4'
readonly PATCH_SHA256='07714e80b8b6af314361b2d1bdcaae02aa38004a15d0e954929cb50abe2fc163'
readonly PATCH_URL="https://raw.githubusercontent.com/sys-uos/bbr-cpu-contention/${PATCH_COMMIT}/patches/bbr1.patch"
readonly MODULE_SUBPATH='updates/2brobust/net/ipv4/tcp_bbr.ko'
readonly SYSCTL_FILE='/etc/sysctl.d/99-2brobust.conf'
WORK_ROOT="${WORK_ROOT:-/usr/local/src/2brobust}"
KERNEL_RELEASE="$(uname -r)"
KEEP_WORKDIR=0
SKIP_DEPS=0
VERIFY_ONLY=0
BUILD_DIR=''

log()  { printf '[2brobust] %s\n' "$*"; }
warn() { printf '[2brobust] WARNING: %s\n' "$*" >&2; }
die()  { printf '[2brobust] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sudo bash install-2brobust-ubuntu.sh [--verify] [--skip-deps] [--keep-workdir]
Ubuntu only. Fetches exact Ubuntu source and adapts the pinned BBRv1 registration-log hunk.
--verify       Check module resolution, runtime defaults and loaded module evidence.
--skip-deps    Don't install dependencies or headers.
--keep-workdir Retain extracted Ubuntu source and build artifacts.
WORK_ROOT     Work/cache root (default: /usr/local/src/2brobust).
EOF
}
cleanup() {
  local rc=$?
  if (( rc == 0 && KEEP_WORKDIR == 0 )) && [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    rm -rf -- "$BUILD_DIR"
  elif (( rc != 0 )) && [[ -n "$BUILD_DIR" ]]; then
    warn "Build directory kept for diagnosis: $BUILD_DIR"
  fi
}
trap cleanup EXIT

preflight() {
  [[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'
  [[ -r /etc/os-release ]] || die 'Cannot find /etc/os-release.'
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || die 'This script is Ubuntu-only.'
  [[ "$KERNEL_RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'Unexpected kernel release string.'
  command -v apt-get >/dev/null || die 'apt-get is required.'
  command -v dpkg-query >/dev/null || die 'dpkg-query is required.'
  command -v sha256sum >/dev/null || die 'sha256sum is required.'
  [[ "$WORK_ROOT" == /* && "$WORK_ROOT" != '/' ]] || die 'WORK_ROOT must be an absolute, non-root directory.'
  log "Ubuntu ${VERSION_ID:-unknown}; running kernel ${KERNEL_RELEASE}."
}

install_dependencies() {
  (( SKIP_DEPS == 1 )) && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # 'pahole' is the executable; on Ubuntu 20.04 the package is named 'dwarves'.
  apt-get install -y --no-install-recommends \
    bc bison build-essential ca-certificates curl dwarves flex kmod \
    libelf-dev libssl-dev patch rsync xz-utils dpkg-dev python3
  if [[ ! -d "/lib/modules/${KERNEL_RELEASE}/build" ]]; then
    apt-get install -y --no-install-recommends "linux-headers-${KERNEL_RELEASE}"
  fi
}

check_headers() {
  local uts config_release actual
  KDIR="/lib/modules/${KERNEL_RELEASE}/build"
  [[ -d "$KDIR" ]] || die "Missing $KDIR; install linux-headers-${KERNEL_RELEASE}."
  [[ -r "$KDIR/.config" && -r "$KDIR/Module.symvers" ]] || die 'Headers missing .config or Module.symvers.'

  # Ubuntu may report the underlying stable source version (e.g. 5.15.178)
  # from `make kernelrelease`, even when its generated headers are correctly
  # prepared for the Ubuntu ABI (e.g. 5.15.0-139-generic).
  # Check generated release metadata instead; verify the built vermagic later.
  [[ -r "$KDIR/include/generated/utsrelease.h" ]] || die 'Missing generated UTS_RELEASE header.'
  uts="$(sed -n 's/^#define UTS_RELEASE "\([^"]*\)"/\1/p' "$KDIR/include/generated/utsrelease.h" | head -n 1)"
  [[ "$uts" == "$KERNEL_RELEASE" ]] || die "UTS_RELEASE=${uts:-unknown}, expected ${KERNEL_RELEASE}. Headers are not a match."

  if [[ -r "$KDIR/include/config/kernel.release" ]]; then
    config_release="$(tr -d '\r\n' < "$KDIR/include/config/kernel.release")"
    if [[ "$config_release" != "$KERNEL_RELEASE" ]]; then
      warn "include/config/kernel.release reports ${config_release}; generated UTS_RELEASE matches ${KERNEL_RELEASE}. Final module vermagic must still match."
    fi
  fi

  actual="$(make -s -C "$KDIR" kernelrelease)"
  if [[ "$actual" != "$KERNEL_RELEASE" ]]; then
    warn "make kernelrelease reports ${actual}, but generated UTS_RELEASE matches ${KERNEL_RELEASE}; continuing with post-build vermagic verification."
  fi
  grep -Eq '^CONFIG_TCP_CONG_BBR=m$' "$KDIR/.config" || die 'Kernel CONFIG_TCP_CONG_BBR is not modular (m).'
  [[ -s "$KDIR/Module.symvers" ]] || die 'Module.symvers is empty; cannot safely build a versioned external module.'
  log "Kernel headers match running Ubuntu ABI: ${KERNEL_RELEASE}."
}

source_package_from_installed_kernel() {
  local pkg item meta ver
  # The modules package normally identifies the exact Ubuntu kernel source/version.
  for pkg in "linux-modules-${KERNEL_RELEASE}" "linux-image-unsigned-${KERNEL_RELEASE}" "linux-image-${KERNEL_RELEASE}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
      meta="$(dpkg-query -W -f='${source:Package}|${source:Version}|${Version}' "$pkg")"
      IFS='|' read -r SOURCE_PACKAGE SOURCE_VERSION ver <<< "$meta"
      [[ -n "$SOURCE_PACKAGE" ]] || SOURCE_PACKAGE="$pkg"
      [[ -n "$SOURCE_VERSION" ]] || SOURCE_VERSION="$ver"
      [[ -n "$SOURCE_VERSION" ]] || continue
      log "Installed ${pkg} is from ${SOURCE_PACKAGE} (${SOURCE_VERSION})."
      return 0
    fi
  done
  die "No installed Ubuntu linux-modules/linux-image package found for ${KERNEL_RELEASE}; cannot identify the exact source."
}

fetch_patch() {
  mkdir -p "$WORK_ROOT/downloads"
  PATCH_FILE="$WORK_ROOT/downloads/bbr1-${PATCH_COMMIT}.patch"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
    --output "$PATCH_FILE" "$PATCH_URL"
  printf '%s  %s\n' "$PATCH_SHA256" "$PATCH_FILE" | sha256sum -c -
}

# Query official Ubuntu deb-src indices without permanently editing sources.list.
# The scratch APT lists directory avoids changing the system's repository state.
fetch_source_via_apt() {
  local sources lists codename apt_opts
  codename="${VERSION_CODENAME:-}"
  [[ "$codename" =~ ^[a-z]+$ ]] || die 'Could not determine Ubuntu codename.'
  sources="$BUILD_DIR/ubuntu-deb-src.list"
  lists="$BUILD_DIR/apt-lists"
  mkdir -p "$lists/partial"
  cat > "$sources" <<EOF
# Temporary source repositories for this build (not installed system-wide).
deb-src http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
  local -a opts=(
    -o "Dir::Etc::sourcelist=$sources"
    -o 'Dir::Etc::sourceparts=-'
    -o "Dir::State::lists=$lists"
    -o 'APT::Get::List-Cleanup=0'
  )
  log 'Trying the exact Ubuntu source from temporary deb-src repositories.'
  if ! apt-get "${opts[@]}" update; then
    warn 'Temporary Ubuntu deb-src index update failed; trying official archive pool.'
    return 1
  fi
  if (cd "$BUILD_DIR" && apt-get "${opts[@]}" source "${SOURCE_PACKAGE}=${SOURCE_VERSION}"); then
    return 0
  fi
  warn 'Exact source absent from current deb-src indices; trying official archive pool.'
  return 1
}

# Historic Ubuntu kernel sources may remain in the official package pool after
# the APT Sources index no longer lists their version. Retrieve the signed .dsc
# and the files referenced by its Checksums-Sha256 stanza. Each input is
# checked against its exact SHA256 before dpkg-source expands it.
fetch_source_via_pool() {
  local base dsc filename hash size item count=0
  local -a bases=(
    "https://archive.ubuntu.com/ubuntu/pool/main/l/${SOURCE_PACKAGE}"
    "https://security.ubuntu.com/ubuntu/pool/main/l/${SOURCE_PACKAGE}"
    "https://old-releases.ubuntu.com/ubuntu/pool/main/l/${SOURCE_PACKAGE}"
  )
  dsc="${SOURCE_PACKAGE}_${SOURCE_VERSION}.dsc"
  [[ "$SOURCE_PACKAGE" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die 'Unsafe source package name.'
  [[ "$SOURCE_VERSION" =~ ^[a-zA-Z0-9.+:~_-]+$ && "$SOURCE_VERSION" != *:* ]] || die 'Unexpected source version syntax.'
  local pool_dir="$BUILD_DIR/source-downloads"
  mkdir -p "$pool_dir"
  for base in "${bases[@]}"; do
    log "Trying Ubuntu source archive: ${base}/${dsc}"
    if ! curl --fail --silent --show-error --location --proto '=https' \
      --tlsv1.2 --retry 2 --connect-timeout 15 --output "$pool_dir/$dsc" "$base/$dsc"; then
      continue
    fi
    local manifest="$pool_dir/source-sha256.txt"
    awk '/^Checksums-Sha256:/{flag=1;next} flag && /^ [0-9a-fA-F]/{print $1 " " $3;next} flag{exit}' \
      "$pool_dir/$dsc" > "$manifest"
    [[ -s "$manifest" ]] || die "The Ubuntu .dsc has no SHA256 manifest: $dsc"
    count=0
    local ok=1
    while IFS=' ' read -r hash filename; do
      [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid SHA256 in $dsc"
      [[ "$filename" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_~-]*$ ]] || die "Unsafe source filename: $filename"
      ((count+=1))
      item="$pool_dir/$filename"
      if [[ ! -f "$item" ]] || ! printf '%s  %s\n' "$hash" "$item" | sha256sum -c --status; then
        if ! curl --fail --silent --show-error --location --proto '=https' \
          --tlsv1.2 --retry 3 --connect-timeout 15 --output "$item" "$base/$filename"; then
          ok=0
          break
        fi
      fi
      if ! printf '%s  %s\n' "$hash" "$item" | sha256sum -c --status; then
        warn "SHA256 mismatch for $filename"
        ok=0
        break
      fi
      log "Verified Ubuntu source archive: $filename"
    done < "$manifest"
    if (( ok == 1 && count > 0 )); then
      log "Extracting SHA256-verified Ubuntu source: $dsc"
      if (cd "$BUILD_DIR" && dpkg-source -x "$pool_dir/$dsc"); then
        return 0
      fi
      die 'dpkg-source rejected the downloaded source; refusing to continue.'
    fi
    warn 'Archive mirror lacks one or more source files; trying another official mirror.'
  done
  return 1
}

fetch_ubuntu_source() {
  local -a candidates=()
  source_package_from_installed_kernel
  BUILD_DIR="$(mktemp -d "$WORK_ROOT/build-${KERNEL_RELEASE}.XXXXXXXX")"
  chmod 0755 "$BUILD_DIR" # Allow apt _apt sandbox user to access build downloads.
  log "Requesting exact Ubuntu source: ${SOURCE_PACKAGE}=${SOURCE_VERSION}"
  if ! fetch_source_via_apt; then
    fetch_source_via_pool || die "Unable to retrieve exact Ubuntu source ${SOURCE_PACKAGE}=${SOURCE_VERSION} from temporary deb-src indices or official Ubuntu archives. No other kernel version was substituted."
  fi
  mapfile -d '' -t candidates < <(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -print0)
  (( ${#candidates[@]} == 1 )) || die "Expected one unpacked kernel source directory, found ${#candidates[@]}."
  SRC="${candidates[0]}"
  [[ -f "$SRC/net/ipv4/tcp_bbr.c" ]] || die 'Ubuntu source does not contain net/ipv4/tcp_bbr.c.'
  log "Unpacked Ubuntu kernel source: $SRC"
}

apply_patch() {
  local portable_patch="$BUILD_DIR/bbr1-ubuntu-core.patch"
  local target="$SRC/net/ipv4/tcp_bbr.c"

  # The pinned upstream patch has four hunks. The first three implement the
  # congestion-control changes. The fourth merely prints a registration log,
  # but assumes an upstream BTF register_btf_kfunc_id_set() call that may not
  # exist in Ubuntu's backported bbr_register(). Keep the functional hunks
  # byte-for-byte unchanged and insert the informational marker separately.
  log 'Extracting the three functional hunks from the SHA256-pinned official patch.'
  awk '
    /^@@ / {
      hunks++
      if (hunks == 4) exit
    }
    {print}
  ' "$PATCH_FILE" > "$portable_patch"
  [[ "$(grep -c '^@@ ' "$PATCH_FILE")" -eq 4 ]] || die 'Pinned upstream patch layout changed; refusing to port automatically.'
  [[ "$(grep -c '^@@ ' "$portable_patch")" -eq 3 ]] || die 'Failed to isolate the three functional hunks.'
  grep -Fq 'Register BBRv1 patch.' "$PATCH_FILE" || die 'Expected registration marker missing from upstream patch.'

  log 'Checking functional BBRv1 hunks against exact Ubuntu source (zero fuzz).'
  if ! patch --dry-run --batch --forward --fuzz=0 -p1 --directory "$SRC" < "$portable_patch"; then
    die 'One or more functional BBRv1 hunks do not apply exactly; refusing to guess an adaptation.'
  fi
  patch --batch --forward --fuzz=0 -p1 --directory "$SRC" < "$portable_patch"

  # The registration marker is not part of the algorithm, and is inserted at
  # the opening of the same function that the fourth official hunk targets.
  # Require exactly one definition, never a declaration or an unrelated name.
  python3 - "$target" <<'PYTHON'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
pat = r'(static\s+int\s+__init\s+bbr_register\s*\(void\)\s*\{)'
matches = list(re.finditer(pat, s))
if len(matches) != 1:
    sys.exit(f'ERROR: Expected exactly one bbr_register() definition, found {len(matches)}')
if 'Register BBRv1 patch.' in s:
    sys.exit('ERROR: Registration marker already exists in source')
s = re.sub(pat, lambda m: m.group(1) + '\n\tpr_info("Register BBRv1 patch. \\n");', s, count=1)
p.write_text(s)
PYTHON
  grep -Fq 'pr_info("Register BBRv1 patch.' "$target" || die 'Registration marker was not inserted.'
  log 'Applied all functional official hunks and ported the registration log to Ubuntu.'
}

build_module() {
  local jobs vm
  MODULE_DIR="$BUILD_DIR/module"
  MODULE_KO="$MODULE_DIR/tcp_bbr.ko"
  mkdir -p "$MODULE_DIR"
  cp -- "$SRC/net/ipv4/tcp_bbr.c" "$MODULE_DIR/tcp_bbr.c"
  printf 'obj-m := tcp_bbr.o\n' > "$MODULE_DIR/Makefile"
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
  # Avoid exhausting small VPS memory by compiling with too many jobs.
  (( jobs > 4 )) && jobs=4
  log "Building against matching Ubuntu headers (${jobs} job(s))."
  make -C "$KDIR" M="$MODULE_DIR" -j"$jobs" modules
  [[ -s "$MODULE_KO" ]] || die 'Build produced no tcp_bbr.ko.'
  vm="$(modinfo -F vermagic "$MODULE_KO")"
  [[ "$vm" == "$KERNEL_RELEASE "* ]] || die "Vermagic mismatch: $vm"
  log "Built module vermagic: $vm"
}

install_module() {
  local dir resolved backup
  DEST="/lib/modules/${KERNEL_RELEASE}/${MODULE_SUBPATH}"
  dir="$(dirname "$DEST")"
  install -d -m 0755 "$dir"
  if [[ -e "$DEST" ]]; then
    backup="${DEST}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p -- "$DEST" "$backup"
    warn "Existing 2BRobust module backed up at $backup"
  fi
  install -m 0644 "$MODULE_KO" "$DEST"
  depmod -a "$KERNEL_RELEASE"
  resolved="$(modinfo -k "$KERNEL_RELEASE" -n tcp_bbr)"
  [[ "$resolved" == "$DEST" ]] || die "depmod selected $resolved rather than $DEST"
  log "Installed new module: $DEST"
}

configure_defaults() {
  local tmp
  tmp="$(mktemp /etc/sysctl.d/.2brobust.XXXXXXXX)"
  printf '%s\n' '# Managed by install-2brobust-ubuntu.sh' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr' > "$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$SYSCTL_FILE"
}

activate_module() {
  local old_cc
  old_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
  sysctl -qw net.ipv4.tcp_congestion_control=cubic || true
  if lsmod | awk '$1=="tcp_bbr" {seen=1} END {exit !seen}'; then
    if ! modprobe -r tcp_bbr; then
      sysctl -qw net.ipv4.tcp_congestion_control="$old_cc" || true
      warn 'tcp_bbr is busy; new module is staged for the next reboot.'
      warn 'Check after reboot with: sudo bash install-2brobust-ubuntu.sh --verify'
      return 2
    fi
  fi
  if ! modprobe tcp_bbr; then
    warn 'Unable to load patched module. See dmesg; Secure Boot module signing or ABI mismatches may be involved.'
    return 2
  fi
  sysctl -qw net.core.default_qdisc=fq
  sysctl -qw net.ipv4.tcp_congestion_control=bbr
}

verify_installation() {
  local resolved cc qdisc expected disk_src runtime_src
  expected="/lib/modules/${KERNEL_RELEASE}/${MODULE_SUBPATH}"
  resolved="$(modinfo -k "$KERNEL_RELEASE" -n tcp_bbr 2>/dev/null || true)"
  [[ "$resolved" == "$expected" ]] || die "module resolver points to ${resolved:-nothing}, not $expected"
  lsmod | awk '$1=="tcp_bbr" {seen=1} END {exit !seen}' || die 'tcp_bbr is not loaded.'
  cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
  qdisc="$(sysctl -n net.core.default_qdisc)"
  [[ "$cc" == 'bbr' && "$qdisc" == 'fq' ]] || die "Expected bbr/fq, got ${cc}/${qdisc}."
  disk_src="$(modinfo -F srcversion "$expected" 2>/dev/null || true)"
  runtime_src="$(cat /sys/module/tcp_bbr/srcversion 2>/dev/null || true)"
  if [[ -n "$disk_src" && -n "$runtime_src" ]]; then
    [[ "$disk_src" == "$runtime_src" ]] || die "Loaded module srcversion (${runtime_src}) differs from installed module (${disk_src}). Reboot to load the replacement."
    log 'Loaded module srcversion matches the installed module.'
  elif dmesg --color=never 2>/dev/null | grep -Fq 'Register BBRv1 patch.'; then
    log 'Found author registration marker in kernel log.'
  else
    warn 'Cannot conclusively identify loaded code (no srcversion match or readable registration marker).'
    warn 'Run strings on the installed module and inspect kernel logs; a reboot may be needed.'
  fi
  log "PASS: resolved=${resolved}, congestion_control=${cc}, qdisc=${qdisc}"
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --verify) VERIFY_ONLY=1 ;;
      --keep-workdir) KEEP_WORKDIR=1 ;;
      --skip-deps) SKIP_DEPS=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown option: $arg" ;;
    esac
  done
  preflight
  if (( VERIFY_ONLY )); then verify_installation; return; fi
  install_dependencies
  check_headers
  mkdir -p "$WORK_ROOT"
  fetch_patch
  fetch_ubuntu_source
  apply_patch
  build_module
  install_module
  configure_defaults
  if activate_module; then
    verify_installation
  else
    return 2
  fi
}
main "$@"
