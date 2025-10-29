# BCM43602 Wi-Fi Fix for MacBook Pro (2016/2017) on Linux

## 📌 What is this project?
This repository provides an **offline-ready solution** to enable Wi-Fi on MacBook Pro models (2016/2017) equipped with the **Broadcom BCM43602** wireless chipset when running Linux.

The Linux driver `brcmfmac` requires specific firmware and board calibration data (NVRAM) to initialize the chip correctly. Without these files, Wi-Fi will fail to start, often showing errors like:
```
brcmf_pcie_setup: Dongle setup failed
Direct firmware load failed with error -2
```

## ❓ Why do you need this?
- Broadcom chips on MacBooks are not fully supported out-of-the-box on many Linux distributions.
- The driver expects:
  - Generic firmware (`brcmfmac43602-pcie.bin`) from the official `linux-firmware` package.
  - A **board-specific NVRAM file** (`brcmfmac43602-pcie.txt`) containing calibration data and your device’s MAC address.
- Without these files, Wi-Fi will not work or will only partially work (e.g., no 5 GHz support).

## ✅ What does this repository provide?
- **Installer script** (`install-bcm43602-mbp.sh`):
  - Works across major Linux distributions (Debian/Ubuntu, Fedora, Arch, openSUSE).
  - Idempotent and restart-safe (you can run it multiple times).
  - Offline-first: uses vendored files from this repo, no internet required.
  - Automatically injects your real MAC address into the NVRAM file.
  - Optionally sets regulatory domain (e.g., `DE` for Germany).
  - Optional soft reload of the Wi-Fi module (or reboot recommendation).
- **Firmware directory**:
  - `brcmfmac43602-pcie.bin` – official Broadcom firmware (unmodified).
  - `brcmfmac43602-pcie.txt` – NVRAM template with MAC placeholder.
  - `LICENSE.Broadcom-wifi` – Broadcom redistribution license.
  - `WHENCE.brcm` – source reference (commit ID from linux-firmware).

## 🔍 Where can it be used?
- Any Linux distribution running on:
  - MacBook Pro 13,2 / 13,3 (2016/2017 models with BCM43602).
- Works in:
  - **Online environments** (downloads packages if needed).
  - **Offline environments** (uses vendored firmware and NVRAM).

## 🛠 Requirements
- Root privileges (`sudo`).
- Basic Linux tools: `bash`, `modprobe`, `systemctl`.
- For online mode: package manager (`apt`, `dnf`, `pacman`, or `zypper`).

## 🚀 Installation & Usage

### **Option 1: Offline (recommended for systems without internet)**
1. Clone or download this repository on a machine with internet:
   ```bash
   git clone https://github.com/nilz90/bcm43602-mbp-linux.git
   cd bcm43602-mbp-linux
   ```
2. Transfer the folder to your target machine (USB stick, etc.).
3. Run the installer:
   ```bash
   sudo ./install-bcm43602-mbp.sh --offline --reload
   ```
   If `--reload` fails, reboot:
   ```bash
   sudo reboot
   ```

### **Option 2: Online**
```bash
git clone https://github.com/nilz90/bcm43602-mbp-linux.git
cd bcm43602-mbp-linux
sudo ./install-bcm43602-mbp.sh --reload
```

## ⚙️ Script Options
- `--offline` → Use vendored files only (no package installation).
- `--reload` → Attempt soft reload of Wi-Fi module (instead of reboot).
- `--no-regdom` → Skip setting regulatory domain.
- `--nm-backend=auto|iwd|wpa` → **NEW FEATURE**: Configure NetworkManager Wi-Fi backend.

### 🔍 New Feature: NetworkManager Backend Control
Arch-based systems (like CachyOS, Manjaro, EndeavourOS) often run **iwd** alongside NetworkManager or default to `wpa_supplicant`. This can cause Wi-Fi association failures even if firmware loads correctly.

The installer now supports automatic or manual backend configuration:
- `auto` (default): Detects if `iwd` is installed and active; sets NM to use `iwd`. Otherwise, uses `wpa_supplicant`.
- `iwd`: Forces NM to use `iwd` backend.
- `wpa`: Forces NM to use `wpa_supplicant` backend.

**Example:**
```bash
sudo ./install-bcm43602-mbp.sh --offline --nm-backend=auto --reload
```

**What it does:**
- Writes `/etc/NetworkManager/conf.d/10-wifi-backend.conf`.
- Enables/disables `iwd` or `wpa_supplicant` services accordingly.
- Restarts NetworkManager to apply changes.

**Troubleshooting:**
- If Wi-Fi still fails, check:
  ```bash
  journalctl -u NetworkManager | tail -n 50
  ```
- Ensure router uses WPA2-PSK (disable WPA3 or set PMF optional).

## ✅ How does it work?
- Copies firmware and NVRAM files to `/lib/firmware/brcm/`.
- Updates NVRAM file with your actual MAC address.
- Ensures firmware is unpacked if only `.zst` exists.
- Reloads `brcmfmac` module or suggests reboot.

## 📜 License
- **Installer script**: MIT License (see `LICENSE`).
- **Firmware**: Broadcom Binary Redistribution License (see `firmware/LICENSE.Broadcom-wifi`).
- Firmware is **unmodified** and sourced from the official [linux-firmware repository](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git).

## ✅ Troubleshooting
- If Wi-Fi still fails:
  - Check `dmesg | grep brcmfmac` for errors.
  - Ensure MAC address was correctly injected into `.txt`.
  - Try alternative NVRAM files (community variants linked in README).
- For 5 GHz issues:
  - Ensure regulatory domain is set (`iw reg set DE`).
  - Avoid DFS channels on your router.

## 🔗 References
- [Linux Wireless Documentation](https://wireless.docs.kernel.org/en/latest/en/users/drivers/brcm80211.html)
- [Debian brcmfmac Wiki](https://wiki.debian.org/brcmfmac)
- [Broadcom Firmware License](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/LICENCE.broadcom_bcm43xx)

