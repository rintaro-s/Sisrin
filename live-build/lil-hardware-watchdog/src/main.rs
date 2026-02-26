use std::io;
use std::process::Command;
use udev::{Event, EventType, MonitorBuilder};
use log::{error, info, warn};

fn main() -> io::Result<()> {
    env_logger::Builder::from_default_env()
        .filter_level(log::LevelFilter::Info)
        .init();

    info!("lil-hardware-watchdog: 起動しました");

    let monitor = MonitorBuilder::new()?
        .match_subsystem("usb")?
        .match_subsystem("input")?
        .match_subsystem("hidraw")?
        .match_subsystem("printer")?
        .match_subsystem("bluetooth")?
        .listen()?;

    info!("lil-hardware-watchdog: udev イベント監視を開始します");

    for event in monitor.iter() {
        handle_event(event);
    }

    Ok(())
}

fn handle_event(event: Event) {
    // 追加イベント (デバイス接続) のみを処理
    if event.event_type() != EventType::Add {
        return;
    }

    let device = event.device();
    let subsystem = device
        .subsystem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

    let devnode = device
        .devnode()
        .and_then(|p| p.to_str())
        .map(String::from);

    // --- プリンタ検出 ---
    if is_printer(&device, &subsystem) {
        if let Some(ref node) = devnode {
            info!("プリンタを検出: {} - cups.service を起動します", node);
        } else {
            info!("プリンタを検出 - cups.service を起動します");
        }
        start_service("cups.service");
        return;
    }

    // --- Bluetooth デバイス検出 ---
    if is_bluetooth(&device, &subsystem) {
        info!("Bluetooth デバイスを検出 - bluetooth.service を起動します");
        start_service("bluetooth.service");
        return;
    }

    // --- ゲームコントローラー検出 ---
    if is_gamepad(&device, &subsystem) {
        if let Some(ref node) = devnode {
            info!("ゲームコントローラーを検出: {} - ACL 権限を設定します", node);
            handle_gamepad(node, &device);
        } else {
            // devnode がない場合は hidraw のパスを構築
            let syspath = device.syspath().to_string_lossy().to_string();
            info!(
                "ゲームコントローラーを検出 (syspath: {}) - ACL 権限を設定します",
                syspath
            );
        }
    }
}

/// プリンタかどうかを判定する
fn is_printer(device: &udev::Device, subsystem: &str) -> bool {
    if subsystem == "usb" || subsystem == "printer" {
        // USB Class 7 = Printer
        if let Some(class) = device.attribute_value("bDeviceClass") {
            if class.to_string_lossy() == "7" {
                return true;
            }
        }
        if let Some(class) = get_usb_interface_class(device) {
            if class == "7" {
                return true;
            }
        }
    }
    // lp デバイスも対象
    if let Some(node) = device.devnode() {
        if let Some(s) = node.to_str() {
            if s.starts_with("/dev/usb/lp") || s.starts_with("/dev/lp") {
                return true;
            }
        }
    }
    false
}

/// Bluetooth デバイスかどうかを判定する
fn is_bluetooth(device: &udev::Device, subsystem: &str) -> bool {
    if subsystem == "bluetooth" {
        return true;
    }
    if subsystem == "usb" {
        // USB Class 224 (0xE0) = Wireless Controller, SubClass 1, Protocol 1 = Bluetooth
        if let Some(class) = device.attribute_value("bDeviceClass") {
            if class.to_string_lossy() == "224" {
                return true;
            }
        }
        // Vendor ID ベースのフォールバック
        // 代表的な Bluetooth USB アダプタ: Realtek, Intel, Broadcom
        let vendor = device
            .attribute_value("idVendor")
            .map(|v| v.to_string_lossy().to_lowercase());
        if let Some(v) = vendor {
            // Realtek RTL8761B など
            if v == "0bda" {
                return true;
            }
        }
    }
    false
}

/// ゲームパッドかどうかを判定する
fn is_gamepad(device: &udev::Device, subsystem: &str) -> bool {
    if subsystem != "input" && subsystem != "hidraw" {
        return false;
    }
    // udev が ID_INPUT_JOYSTICK または ID_INPUT_ACCELEROMETER タグを付ける
    if let Some(val) = device.property_value("ID_INPUT_JOYSTICK") {
        if val.to_string_lossy() == "1" {
            return true;
        }
    }
    if let Some(val) = device.property_value("ID_INPUT_GAMEPAD") {
        if val.to_string_lossy() == "1" {
            return true;
        }
    }
    // 名前ベースのヒューリスティック
    if let Some(name) = device.property_value("ID_INPUT_NAME").or_else(|| device.attribute_value("name")) {
        let name_lower = name.to_string_lossy().to_lowercase();
        if name_lower.contains("controller")
            || name_lower.contains("gamepad")
            || name_lower.contains("joystick")
            || name_lower.contains("xbox")
            || name_lower.contains("dualshock")
            || name_lower.contains("dualsense")
        {
            return true;
        }
    }
    false
}

/// ゲームパッドの ACL 権限設定と udev ルール生成
fn handle_gamepad(devnode: &str, device: &udev::Device) {
    let active_user = get_active_user();
    if active_user.is_empty() {
        warn!("アクティブユーザーを取得できませんでした。ACL 設定をスキップします");
        return;
    }

    // setfacl でアクティブユーザーに rw 付与
    let acl_result = Command::new("setfacl")
        .args(["-m", &format!("u:{}:rw", active_user), devnode])
        .status();

    match acl_result {
        Ok(s) if s.success() => {
            info!(
                "ACL 設定完了: {} -> ユーザー '{}' に rw 権限を付与",
                devnode, active_user
            );
        }
        Ok(s) => warn!("setfacl が終了コード {} で失敗しました", s),
        Err(e) => error!("setfacl の実行に失敗: {}", e),
    }

    // 動的 udev ルールを生成して永続化
    let vendor = device
        .property_value("ID_VENDOR_ID")
        .map(|v| v.to_string_lossy().to_string())
        .unwrap_or_default();
    let product = device
        .property_value("ID_MODEL_ID")
        .map(|v| v.to_string_lossy().to_string())
        .unwrap_or_default();

    if !vendor.is_empty() && !product.is_empty() {
        let rule = format!(
            "# Sisrin OS - ゲームコントローラー 動的生成ルール\n\
             SUBSYSTEM==\"input\", ATTRS{{idVendor}}==\"{vendor}\", ATTRS{{idProduct}}==\"{product}\", \
             TAG+=\"uaccess\", \
             RUN+=\"/usr/bin/setfacl -m u:$(loginctl list-sessions --no-legend | awk 'NR==1 {{print $3}}'):rw %E{{DEVNAME}}\"\n\
             SUBSYSTEM==\"hidraw\", ATTRS{{idVendor}}==\"{vendor}\", ATTRS{{idProduct}}==\"{product}\", \
             TAG+=\"uaccess\", \
             RUN+=\"/usr/bin/setfacl -m u:$(loginctl list-sessions --no-legend | awk 'NR==1 {{print $3}}'):rw %E{{DEVNAME}}\"\n"
        );
        let rule_path = format!("/etc/udev/rules.d/99-Sisrin-gamepad-{vendor}-{product}.rules");
        match std::fs::write(&rule_path, &rule) {
            Ok(_) => {
                info!("ゲームパッドルールを生成しました: {}", rule_path);
                // udev ルールをリロード
                let _ = Command::new("udevadm").args(["control", "--reload-rules"]).status();
                let _ = Command::new("udevadm").args(["trigger", "--subsystem-match=input"]).status();
            }
            Err(e) => error!("ゲームパッドルールの書き込みに失敗: {}", e),
        }
    }
}

/// systemd サービスを起動する (既に起動中なら何もしない)
fn start_service(service: &str) {
    let status = Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status();

    match status {
        Ok(s) if s.success() => {
            info!("{} は既に起動中です", service);
        }
        _ => {
            let result = Command::new("systemctl").args(["start", service]).status();
            match result {
                Ok(s) if s.success() => info!("{} を起動しました", service),
                Ok(s) => warn!("{} の起動が終了コード {} で失敗", service, s),
                Err(e) => error!("{} の起動に失敗: {}", service, e),
            }
        }
    }
}

/// systemd-logind からアクティブなログインユーザーを取得
fn get_active_user() -> String {
    let output = Command::new("loginctl")
        .args(["list-sessions", "--no-legend"])
        .output();

    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                let user = parts[2];
                // システムユーザーを除外
                if !user.starts_with('_')
                    && user != "root"
                    && !user.starts_with("gdm")
                    && !user.starts_with("sddm")
                    && !user.starts_with("lightdm")
                {
                    return user.to_string();
                }
            }
        }
    }
    String::new()
}

/// USB インターフェースクラスを取得するヘルパー
fn get_usb_interface_class(device: &udev::Device) -> Option<String> {
    device
        .attribute_value("bInterfaceClass")
        .map(|v| v.to_string_lossy().to_string())
}
