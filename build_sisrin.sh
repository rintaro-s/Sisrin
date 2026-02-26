#!/bin/bash
# Sisrin OS - メインビルドスクリプト
# Debian testing ベースのカスタム live ISO を生成する
#
# 使用方法:
#   sudo bash build_sisrin.sh [--clean]
#
# 前提条件 (自動インストール):
#   - live-build
#   - debootstrap
#   - xorriso / genisoimage
#   - squashfs-tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${SCRIPT_DIR}"               # /home/user/os
LIVE_BUILD_DIR="${SCRIPT_DIR}/live-build"
KERNEL_DIR="${WORKSPACE_DIR}/kernel"
WALLPAPER="${WORKSPACE_DIR}/wallpaper.png"

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[Sisrin Build]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- root チェック ----
if [[ $EUID -ne 0 ]]; then
    fail "このスクリプトは root (sudo) で実行してください"
fi

# ---- クリーンオプション ----
if [[ "${1:-}" == "--clean" ]]; then
    log "ビルドキャッシュをクリアします..."
    cd "$LIVE_BUILD_DIR"
    lb clean --purge 2>/dev/null || true
    ok "クリア完了"
    exit 0
fi

# ============================================================
# 1. 依存パッケージのインストール
# ============================================================
log "必要な依存パッケージをインストールします..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    live-build \
    debootstrap \
    xorriso \
    squashfs-tools \
    genisoimage \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    wget \
    curl \
    git \
    rsync
ok "依存パッケージのインストール完了"

# ============================================================
# 2. includes.chroot へのファイルコピー
# ============================================================
INCLUDES_DIR="${LIVE_BUILD_DIR}/config/includes.chroot"

# --- カーネル DEB のコピー ---
KERNEL_DEST="${INCLUDES_DIR}/root/kernel-debs"
mkdir -p "$KERNEL_DEST"

KERNEL_DEB_COUNT=$(ls "${KERNEL_DIR}"/*.deb 2>/dev/null | grep -v ':Zone.Identifier' | wc -l)
if [[ $KERNEL_DEB_COUNT -gt 0 ]]; then
    log "カーネル DEB ファイルをコピーします ($KERNEL_DEB_COUNT 個)..."
    find "$KERNEL_DIR" -name "*.deb" ! -name "*Zone.Identifier*" \
        -exec cp -v {} "$KERNEL_DEST/" \;
    ok "カーネル DEB コピー完了"
else
    warn "カーネル DEB ファイルが見つかりません: ${KERNEL_DIR}"
    warn "標準 Debian カーネルを使用します"
    # 0001-install-kernel.hook.chroot が失敗しても継続できるよう対処
    touch "${KERNEL_DEST}/.no-custom-kernel"
fi

# --- 壁紙のコピー ---
WALLPAPER_DEST="${INCLUDES_DIR}/usr/share/sisrin"
mkdir -p "$WALLPAPER_DEST"

if [[ -f "$WALLPAPER" ]]; then
    log "壁紙をコピーします..."
    cp -v "$WALLPAPER" "${WALLPAPER_DEST}/wallpaper.png"
    ok "壁紙コピー完了"
else
    warn "壁紙ファイルが見つかりません: ${WALLPAPER}"
    warn "デフォルト壁紙を使用します (0008-setup-wallpaper.hook.chroot で処理)"
fi

# --- logo.png のコピー (存在すれば GRUB・GDM3・Calamares ロゴに使用) ---
LOGO="${WORKSPACE_DIR}/logo.png"
if [[ -f "$LOGO" ]]; then
    log "logo.png をコピーします..."
    cp -v "$LOGO" "${WALLPAPER_DEST}/logo.png"
    ok "logo.png コピー完了"
else
    warn "logo.png が見つかりません。wallpaper.png をロゴ代わりに使用します"
fi

# --- lil-hardware-watchdog Rust ソースのコピー ---
WATCHDOG_SRC="${SCRIPT_DIR}/live-build/lil-hardware-watchdog"
WATCHDOG_DEST="${INCLUDES_DIR}/usr/local/src/lil-hardware-watchdog"
mkdir -p "$WATCHDOG_DEST"

if [[ -d "$WATCHDOG_SRC" ]]; then
    log "lil-hardware-watchdog ソースをコピーします..."
    rsync -av --exclude 'target/' "${WATCHDOG_SRC}/" "${WATCHDOG_DEST}/"
    ok "ソースコピー完了"
else
    fail "lil-hardware-watchdog ソースが見つかりません: ${WATCHDOG_SRC}"
fi

# ============================================================
# 3. スクリプトに実行権限を付与
# ============================================================
log "スクリプトに実行権限を付与します..."
chmod +x "${LIVE_BUILD_DIR}/auto/config"
chmod +x "${LIVE_BUILD_DIR}/auto/build"
chmod +x "${LIVE_BUILD_DIR}/auto/clean"
find "${LIVE_BUILD_DIR}/config/hooks" -type f \( -name "*.chroot" -o -name "*.binary" \) -exec chmod +x {} \;
chmod +x "${INCLUDES_DIR}/usr/local/bin/sisrin-usb-trust" 2>/dev/null || true
ok "権限設定完了"

# ============================================================
# 4. live-build の実行
# ============================================================
cd "$LIVE_BUILD_DIR"

log "live-build を初期化します..."
lb config 2>&1 | tee /tmp/sisrin-lb-config.log
ok "lb config 完了"

log "========================================================"
log " Sisrin OS ビルドを開始します"
log " Debian testing ベース"
log " カーネル: BORE + PREEMPT_FULL (6.19.0)"
log " 推定所要時間: 30〜90 分 (環境による)"
log "========================================================"

lb build 2>&1 | tee /tmp/sisrin-lb-build.log

# ============================================================
# 5. 完了メッセージ
# ============================================================
ISO_PATH=""
if [[ -f /tmp/sisrin-lb-config.log ]]; then
    ISO_PATH=$(find "$LIVE_BUILD_DIR" -name "*.iso" -newer /tmp/sisrin-lb-config.log 2>/dev/null | head -1)
fi

if [[ -z "$ISO_PATH" ]]; then
    ISO_PATH=$(find "$LIVE_BUILD_DIR" -name "*.iso" 2>/dev/null | head -1)
fi

if [[ -n "$ISO_PATH" ]]; then
    ISO_SIZE=$(du -sh "$ISO_PATH" | cut -f1)
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  Sisrin OS ビルド完了！${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo -e "  ISO ファイル : ${ISO_PATH}"
    echo -e "  サイズ       : ${ISO_SIZE}"
    echo ""
    echo -e "  書き込み方法:"
    echo -e "    sudo dd if='${ISO_PATH}' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo -e "    # または"
    echo -e "    sudo cp '${ISO_PATH}' /dev/sdX"
    echo ""
    echo -e "  QEMU でテスト:"
    echo -e "    qemu-system-x86_64 -m 4G -cdrom '${ISO_PATH}' -enable-kvm -cpu host"
    echo -e "${GREEN}============================================================${NC}"
else
    warn "ISO ファイルが見つかりませんでした。ビルドログを確認してください:"
    warn "  /tmp/sisrin-lb-build.log"
fi
