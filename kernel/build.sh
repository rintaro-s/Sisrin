#!/bin/bash
# Sisrin OS Master Build Script
# Builds the complete Sisrin ISO using Live Build
#
# 要件:
#   - エラー時に失敗箇所のファイル名と行番号を表示
#   - ビルドログを logs/build-$(date +%Y%m%d-%H%M%S).log に保存
#   - ビルド成功時に ISO の SHA256 とファイルサイズを出力
#   - Rust デーモンの cargo build --release も含める
#   - ビルド前に lb clean を実行してキャッシュを初期化
set -euo pipefail

# エラー時にファイル名と行番号を表示
trap 'echo -e "\033[1;31m[ERROR]\033[0m ${BASH_SOURCE[0]}:${LINENO}: コマンド失敗: ${BASH_COMMAND}" >&2' ERR

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS_DIR="${SCRIPT_DIR}/OS"
DAEMONS_DIR="${SCRIPT_DIR}/daemons"
KERNEL_DIR="${SCRIPT_DIR}/lil_kernel_output"
LIL_PANEL_DIR="${SCRIPT_DIR}/lil-panel"
LOGS_DIR="${SCRIPT_DIR}/logs"
BUILD_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOGS_DIR}/build-${BUILD_TIMESTAMP}.log"

# ログディレクトリ作成
mkdir -p "${LOGS_DIR}"

# 全出力をログファイルにも記録
exec > >(tee -a "${LOG_FILE}") 2>&1

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

header() {
    echo ""
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $*${NC}"
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root (sudo)."
        err "Usage: sudo ./build.sh"
        exit 1
    fi
}

check_deps() {
    header "Checking build dependencies"
    local missing=()
    for cmd in lb debootstrap apt-get; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing tools: ${missing[*]}"
        info "Installing live-build and dependencies..."
        apt-get update
        apt-get install -y live-build debootstrap
    fi

    ok "Build dependencies satisfied"
}

build_daemons() {
    header "Building Rust daemons"

    if [ ! -d "$DAEMONS_DIR" ]; then
        err "Daemons directory not found: $DAEMONS_DIR"
        exit 1
    fi

    # Check if Rust is available
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    fi

    # Also check the original user's cargo
    if [ -n "${SUDO_USER:-}" ]; then
        SUDO_HOME=$(eval echo "~${SUDO_USER}")
        if [ -f "${SUDO_HOME}/.cargo/env" ]; then
            . "${SUDO_HOME}/.cargo/env"
        fi
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        err "Rust/Cargo not found. Install Rust first:"
        err "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        exit 1
    fi

    # Build all daemons in release mode
    pushd "$DAEMONS_DIR" > /dev/null
    cargo build --release 2>&1
    popd > /dev/null

    # Copy binaries
    local bindir="${OS_DIR}/config/includes.chroot/usr/bin"
    mkdir -p "$bindir"

    for bin in Sisrin-resourced Sisrin-journald-wrapper Sisrin-fade-notify \
               Sisrin-dangerback Sisrin-wmi Sisrin-udev-helper; do
        local src="${DAEMONS_DIR}/target/release/${bin}"
        if [ -f "$src" ]; then
            cp "$src" "$bindir/"
            chmod +x "${bindir}/${bin}"
            ok "Copied $bin"
        else
            warn "Binary not found: $src"
        fi
    done

    # lil-panel (Wayland UI shell)
    if [ -d "${LIL_PANEL_DIR}" ]; then
        pushd "${LIL_PANEL_DIR}" > /dev/null
        cargo build --release 2>&1
        local panel_bin="${LIL_PANEL_DIR}/target/release/lil-panel"
        if [ -f "$panel_bin" ]; then
            cp "$panel_bin" "$bindir/"
            chmod +x "${bindir}/lil-panel"
            ok "Copied lil-panel"
        else
            warn "lil-panel binary not found after build (${panel_bin})"
        fi
        popd > /dev/null
    else
        warn "lil-panel source directory not found: ${LIL_PANEL_DIR}"
    fi

    # systemd system/user units
    local systemd_dir="${OS_DIR}/config/includes.chroot/etc/systemd/system"
    local systemd_user_dir="${OS_DIR}/config/includes.chroot/etc/systemd/user"
    local wants_dir="${systemd_dir}/multi-user.target.wants"
    local user_wants_dir="${systemd_user_dir}/graphical-session.target.wants"
    mkdir -p "$systemd_dir" "$systemd_user_dir" "$wants_dir" "$user_wants_dir"

    # lil-journald-watch (system unit, root権限)
    cp "${DAEMONS_DIR}/Sisrin-journald-wrapper/lil-journald-watch.service" \
       "${systemd_dir}/lil-journald-watch.service"
    ln -sf /etc/systemd/system/lil-journald-watch.service \
       "${wants_dir}/lil-journald-watch.service"
    ok "Installed lil-journald-watch.service"

    # lil-fade-notify (user unit)
    cp "${DAEMONS_DIR}/Sisrin-fade-notify/lil-fade-notify.service" \
       "${systemd_user_dir}/lil-fade-notify.service"
    ln -sf /etc/systemd/user/lil-fade-notify.service \
        "${user_wants_dir}/lil-fade-notify.service"
    ok "Installed lil-fade-notify.service (user)"

    # lil-panel (user unit) service
    if [ -f "${LIL_PANEL_DIR}/lil-panel.service" ]; then
        cp "${LIL_PANEL_DIR}/lil-panel.service" \
           "${systemd_user_dir}/lil-panel.service"
        ln -sf /etc/systemd/user/lil-panel.service \
            "${user_wants_dir}/lil-panel.service"
        ok "Installed lil-panel.service (user)"
    else
        warn "lil-panel.service not found in ${LIL_PANEL_DIR}"
    fi

    # udev rules（99-Sisrin-usb-serial.rules が includes.chroot に既存のため上書きのみ）
    local udev_dir="${OS_DIR}/config/includes.chroot/etc/udev/rules.d"
    mkdir -p "$udev_dir"
    ok "udev rules already in includes.chroot"

    # /etc/Sisrin ディレクトリ（trusted-devices.json の初期ファイル）
    local Sisrin_etc="${OS_DIR}/config/includes.chroot/etc/Sisrin"
    mkdir -p "$Sisrin_etc"
    if [ ! -f "${Sisrin_etc}/trusted-devices.json" ]; then
        echo '{"trusted":[]}' > "${Sisrin_etc}/trusted-devices.json"
        ok "Created initial trusted-devices.json"
    fi

    ok "Rust daemons built and deployed"
}

copy_kernel() {
    header "Copying custom BORE kernel"

    local pkg_dir="${OS_DIR}/config/packages.chroot"
    mkdir -p "$pkg_dir"

    # Remove stale kernel packages so only the current build artifacts are used
    rm -f "${pkg_dir}"/linux-image-*.deb \
          "${pkg_dir}"/linux-headers-*.deb \
          "${pkg_dir}"/linux-libc-dev*.deb

    local count=0
    local deb
    for pattern in linux-image-*.deb linux-headers-*.deb linux-libc-dev*.deb; do
        deb=$(ls -1t "${KERNEL_DIR}"/${pattern} 2>/dev/null | head -1 || true)
        if [ -n "${deb}" ] && [ -f "${deb}" ]; then
            cp "${deb}" "$pkg_dir/"
            ok "Copied $(basename "$deb")"
            count=$((count + 1))
        fi
    done

    if [ "$count" -eq 0 ]; then
        warn "No kernel .deb files found in $KERNEL_DIR"
        warn "The ISO will use the default Debian kernel"
    else
        ok "Copied $count kernel packages"
    fi
}

clean_build() {
    header "Cleaning previous build"
    pushd "$OS_DIR" > /dev/null
    lb clean --purge 2>/dev/null || lb clean 2>/dev/null || true
    popd > /dev/null
    ok "Build environment cleaned"
}

apply_lb_config() {
    header "Configuring Live Build"
    pushd "$OS_DIR" > /dev/null
    lb config \
        --debian-installer none \
        --binary-images iso-hybrid \
        --bootloaders grub-efi,grub-pc \
        --uefi-secure-boot disable \
        --apt-recommends false \
        2>&1
    # lb config resets kernel settings every time - re-apply custom BORE kernel config
    sed -i 's/^LB_LINUX_FLAVOURS_WITH_ARCH=.*/LB_LINUX_FLAVOURS_WITH_ARCH=""/' config/chroot
    sed -i 's/^LB_LINUX_PACKAGES=.*/LB_LINUX_PACKAGES=""/' config/chroot
    ok "lb config applied (GRUB2 UEFI+Legacy, secure boot disabled, custom kernel preserved)"
    popd > /dev/null
}

fix_iso_kernel_paths() {
    header "Fixing ISO kernel paths"
    local iso="${OS_DIR}/Sisrin-amd64.hybrid.iso"
    local extract_dir="/tmp/Sisrin-iso-fix"
    local live_dir="${extract_dir}/iso/live"

    if [ ! -f "$iso" ]; then
        warn "ISO not found: $iso"
        return 1
    fi

    # Clean and create extraction directory
    rm -rf "$extract_dir"
    mkdir -p "${extract_dir}/iso"

    # Extract ISO
    info "Extracting ISO..."
    xorriso -osirrox on -indev "$iso" -extract / "${extract_dir}/iso" 2>&1 | grep -v "^xorriso :"

    # Find and copy BORE kernel to generic names
    local kernel=$(ls "${live_dir}"/vmlinuz-*bore* 2>/dev/null | sort -V | tail -1 || ls "${live_dir}"/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)
    local initrd=$(ls "${live_dir}"/initrd.img-*bore* 2>/dev/null | sort -V | tail -1 || ls "${live_dir}"/initrd.img-* 2>/dev/null | sort -V | tail -1 || true)

    if [ -z "$kernel" ] || [ -z "$initrd" ]; then
        err "Kernel or initrd not found in ISO"
        return 1
    fi

    info "Copying $(basename "$kernel") -> vmlinuz"
    cp "$kernel" "${live_dir}/vmlinuz"
    info "Copying $(basename "$initrd") -> initrd.img"
    cp "$initrd" "${live_dir}/initrd.img"
    chmod 644 "${live_dir}/vmlinuz" "${live_dir}/initrd.img"

    # Rebuild ISO
    info "Rebuilding ISO..."
    local new_iso="${OS_DIR}/Sisrin-amd64.hybrid.iso.new"
    xorriso -as mkisofs \
        -r -J -joliet-long \
        -l -iso-level 3 \
        -partition_offset 16 \
        -A "Sisrin Live" \
        -V "Sisrin Live" \
        -b boot/grub/grub_eltorito \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$new_iso" \
        "${extract_dir}/iso" 2>&1 | grep -E "(UPDATE|Written)"

    # Replace original ISO
    mv "$new_iso" "$iso"
    chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$iso" 2>/dev/null || true

    # Cleanup
    rm -rf "$extract_dir"

    ok "ISO fixed with generic kernel paths"
}

run_build() {
    header "Building Sisrin ISO"
    info "This will take a while (downloading packages, building filesystem)..."
    info "Build log: ${LOG_FILE}"
    echo ""

    pushd "$OS_DIR" > /dev/null

    # live/ フックに実行権限を付与
    find config/hooks/live/ -name '*.hook.chroot' -exec chmod +x {} \; 2>/dev/null || true

    # normal/ フックに実行権限を付与
    find config/hooks/normal/ -name '*.hook.chroot' -exec chmod +x {} \; 2>/dev/null || true

    lb build 2>&1
    local result=$?

    popd > /dev/null

    if [ "$result" -eq 0 ]; then
        # Post-build: Fix ISO to include generic vmlinuz and initrd.img
        fix_iso_kernel_paths
        local iso
        iso=$(find "${OS_DIR}" -maxdepth 1 -name "*.iso" -type f | head -1)
        if [ -n "$iso" ]; then
            local size sha256
            size=$(du -h "$iso" | cut -f1)
            sha256=$(sha256sum "$iso" | awk '{print $1}')
            echo ""
            header "BUILD SUCCESSFUL"
            ok "ISO: $iso"
            ok "Size: $size"
            ok "SHA256: $sha256"
            echo ""
            # SHA256 をファイルにも保存
            echo "${sha256}  $(basename "$iso")" > "${iso}.sha256"
            ok "SHA256 saved: ${iso}.sha256"
            echo ""
            info "=== QEMU テストコマンド ==="
            echo ""
            echo "# UEFI（マウス動作確認に virtio-tablet-pci を使用）:"
            echo "qemu-system-x86_64 -enable-kvm -m 4G -smp 2 \\"
            echo "  -bios /usr/share/ovmf/OVMF.fd \\"
            echo "  -drive file=${iso},format=raw,if=none,id=cd \\"
            echo "  -device ide-cd,drive=cd,bootindex=0 \\"
            echo "  -device virtio-tablet-pci \\"
            echo "  -display gtk,gl=on"
            echo ""
            echo "# Legacy BIOS:"
            echo "qemu-system-x86_64 -enable-kvm -m 4G -smp 2 \\"
            echo "  -cdrom ${iso} \\"
            echo "  -device virtio-tablet-pci \\"
            echo "  -display gtk"
            echo ""
            info "USB書き込み: sudo dd if=${iso} of=/dev/sdX bs=4M status=progress"
            info "ビルドログ: ${LOG_FILE}"
        else
            warn "Build completed but no ISO file found"
        fi
    else
        err "Build failed! Check ${LOG_FILE} for details."
        exit 1
    fi
}

# === Main ===
echo ""
echo -e "${BLUE}${BOLD}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║        Sisrin OS Build System                ║"
echo "  ║        Based on Debian Testing + COSMIC       ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

check_root
check_deps

# Parse arguments
SKIP_DAEMONS=false
SKIP_CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --skip-daemons) SKIP_DAEMONS=true ;;
        --skip-clean)   SKIP_CLEAN=true ;;
        --clean-only)
            clean_build
            exit 0
            ;;
        --help|-h)
            echo "Usage: sudo ./build.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-daemons   Skip rebuilding Rust daemons"
            echo "  --skip-clean     Skip cleaning previous build"
            echo "  --clean-only     Only clean, don't build"
            echo "  --help           Show this help"
            exit 0
            ;;
    esac
done

if [ "$SKIP_DAEMONS" = false ]; then
    build_daemons
else
    info "Skipping daemon build (--skip-daemons)"
fi

copy_kernel

if [ "$SKIP_CLEAN" = false ]; then
    clean_build
else
    info "Skipping clean (--skip-clean)"
fi

apply_lb_config
run_build
