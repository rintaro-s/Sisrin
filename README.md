# Sisrin OS Live Build

## English

This repository contains scripts and configuration files to build a customized Debian-based live system called **Sisrin OS**. The system features:

- Sisrin branding (logos, wallpapers, etc.)
- Calamares graphical installer (autostart enabled)
- Japanese input support (Fcitx5, Mozc, Anthy disabled by default)
- Sish shell as the default shell
- Various usability and localization improvements

### How to Build

1. Install required dependencies (Debian/Ubuntu):
   ```sh
   sudo apt update
   sudo apt install live-build debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin systemd-container git zsh fcitx5-mozc calamares
   ```
2. Clone this repository:
   ```sh
   git clone <this-repo-url>
   cd os
   ```
3. Build the ISO image:
   ```sh
   sudo bash build_sisrin.sh --clean
   sudo bash build_sisrin.sh
   ```
4. The resulting ISO will be in `live-build/`.

### Customization
- Place your custom `logo.png` and `wallpaper.png` in the repository root before building.
- Edit hook scripts in `live-build/config/hooks/normal/` for advanced customization.

---

## 日本語

このリポジトリは、Debianベースのカスタムライブシステム「**Sisrin OS**」を構築するためのスクリプトと設定ファイルを含みます。

- Sisrinブランド（ロゴ、壁紙など）
- Calamaresグラフィカルインストーラー（自動起動対応）
- 日本語入力対応（Fcitx5、Mozc、Anthyはデフォルト無効）
- デフォルトシェルはSish
- 各種使いやすさ・ローカライズ改善

### ビルド方法

1. 必要なパッケージをインストール（Debian/Ubuntu）:
   ```sh
   sudo apt update
   sudo apt install live-build debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin systemd-container git zsh fcitx5-mozc calamares
   ```
2. このリポジトリをクローン:
   ```sh
   git clone <このリポジトリのURL>
   cd os
   ```
3. ISOイメージをビルド:
   ```sh
   sudo bash build_sisrin.sh --clean
   sudo bash build_sisrin.sh
   ```
4. 完成したISOは `live-build/` に出力されます。

### カスタマイズ
- `logo.png` と `wallpaper.png` をリポジトリ直下に配置してからビルドしてください。
- 詳細なカスタマイズは `live-build/config/hooks/normal/` 内のフックスクリプトを編集してください。
