#!/usr/bin/env bash
# Offline-first, idempotent installer for Broadcom BCM43602 (MacBook Pro 2016/2017)
# - Uses vendored firmware/.txt from ./firmware first (no internet needed)
# - Falls back to linux-firmware packages when not in --offline mode
# - Injects real MAC into NVRAM .txt (atomic replace with backup)
# - Optionally sets regulatory domain (DE)
# - NEW: Configures NetworkManager Wi-Fi backend (auto|iwd|wpa) to avoid iwd/wpa_supplicant conflicts
# - Optional soft reload (--reload), else suggests reboot
#
# Firmware redistribution per Broadcom Binary Redistribution License (unmodified binary + license included).
# See: firmware/LICENSE.Broadcom-wifi
#
# Refs (for background):
# - Linux Wireless: brcmfmac requires firmware from linux-firmware
# - Debian brcmfmac: firmware via distro packages

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR_SYS="/lib/firmware/brcm"
FW_DIR_REPO="${REPO_DIR}/firmware"

BIN_SYS="${FW_DIR_SYS}/brcmfmac43602-pcie.bin"
BIN_REPO="${FW_DIR_REPO}/brcmfmac43602-pcie.bin"
TXT_SYS="${FW_DIR_SYS}/brcmfmac43602-pcie.txt"
TXT_REPO="${FW_DIR_REPO}/brcmfmac43602-pcie.txt"
BIN_ZST_SYS="${FW_DIR_SYS}/brcmfmac43602-pcie.bin.zst"

DO_REGDOM=1
TRY_RELOAD=0
OFFLINE=0
NM_BACKEND="auto"   # auto | iwd | wpa
LOCK_FILE="/var/lock/install-bcm43602.lock"

say(){ echo -e "[BCM43602] $*"; }
die(){ echo -e "[BCM43602] ERROR: $*" >&2; exit 1; }
cleanup(){ rm -f "$LOCK_FILE" 2>/dev/null || true; }
trap cleanup EXIT
trap 'say "Fehler aufgetreten. Du kannst das Skript **einfach erneut** starten – es ist idempotent."' ERR

# -------- Argumente --------
for arg in "${@:-}"; do
  case "$arg" in
    --no-regdom) DO_REGDOM=0 ;;
    --reload)    TRY_RELOAD=1 ;;
    --offline)   OFFLINE=1 ;;
    --nm-backend=*) NM_BACKEND="${arg#*=}" ;;  # auto|iwd|wpa
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

need_root(){ [[ $EUID -eq 0 ]] || die "Bitte mit sudo/root ausführen."; }
lock(){ if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then die "Läuft bereits (Lock: $LOCK_FILE)."; fi; }

detect_pm(){
  if command -v apt    >/dev/null 2>&1; then echo apt;    return; fi
  if command -v dnf    >/dev/null 2>&1; then echo dnf;    return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  echo ""
}

install_prereqs(){
  local pm="$1"
  [[ $OFFLINE -eq 1 ]] && { say "OFFLINE: Paketinstallation übersprungen."; return; }
  [[ -z "$pm" ]] && { say "Kein Paketmanager erkannt – fahre ohne Installationsversuch fort."; return; }

  say "Installiere Voraussetzungen via ${pm} (idempotent) ..."
  case "$pm" in
    apt)    apt update && DEBIAN_FRONTEND=noninteractive apt install -y linux-firmware firmware-brcm80211 zstd iw wget curl ca-certificates ;;
    dnf)    dnf install -y linux-firmware zstd wireless-tools iw wget curl ca-certificates ;;
    pacman) pacman -Sy --noconfirm linux-firmware zstd wireless_tools iw wget curl ca-certificates || true ;;
    zypper) zypper --non-interactive install --no-confirm linux-firmware zstd wireless-tools iw wget curl ca-certificates || true ;;
  esac
}

detect_iface(){
  local iface=""
  command -v iw >/dev/null 2>&1 && iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
  [[ -z "$iface" ]] && iface=$(ip -o link show | awk -F': ' '$2 ~ /^wl/ {print $2; exit}')
  echo "$iface"
}

stage_bin_offline(){
  mkdir -p "$FW_DIR_SYS"
  if [[ -f "$BIN_SYS" ]]; then
    say "Firmware .bin bereits im System: $(basename "$BIN_SYS")"
    return
  fi
  if [[ -f "$BIN_REPO" ]]; then
    say "Kopiere vendorte Firmware → System ..."
    install -m0644 "$BIN_REPO" "$BIN_SYS"
    return
  fi
  say "Hinweis: Keine vendorte .bin gefunden."
}

ensure_firmware_bin(){
  # 1) Offline-Stage (aus Repo)
  stage_bin_offline

  # 2) Falls noch nicht vorhanden: aus Paketen (sofern nicht --offline)
  if [[ ! -f "$BIN_SYS" ]]; then
    if [[ $OFFLINE -eq 1 ]]; then
      die "OFFLINE: Keine Firmware .bin im Repo gefunden. Lege 'firmware/brcmfmac43602-pcie.bin' ab und starte erneut."
    fi
    say "Suche Firmware aus Distro-Paketen ..."
    if [[ -f "$BIN_ZST_SYS" ]]; then
      say "Entpacke $(basename "$BIN_ZST_SYS") ..."
      unzstd -f "$BIN_ZST_SYS" -o "$BIN_SYS"
    fi
  fi

  # 3) Finaler Check
  if [[ -f "$BIN_SYS" ]]; then
    say "Firmware .bin bereit: $(basename "$BIN_SYS")"
  else
    die "Firmware .bin nicht gefunden. Bitte offline aus Repo bereitstellen oder online Pakete installieren."
  fi
}

prepare_txt_atomic(){
  [[ -f "$TXT_REPO" ]] || die "Vendorte NVRAM fehlt: $TXT_REPO"
  local tmp; tmp=$(mktemp)
  sed 's/\r$//' "$TXT_REPO" > "$tmp"
  chmod 0644 "$tmp"; chown root:root "$tmp"
  echo "$tmp"
}

inject_mac(){
  local file="$1"; local iface="$2"
  [[ -n "$iface" ]] || die "WLAN-Interface nicht gefunden."
  [[ -d "/sys/class/net/$iface" ]] || die "Interface $iface existiert nicht."
  local mac; mac=$(tr '[:upper:]' '[:lower:]' <"/sys/class/net/$iface/address")
  [[ "$mac" =~ ^([a-f0-9]{2}:){5}[a-f0-9]{2}$ ]] || die "MAC-Adresse ungültig: $mac"
  if grep -qi '^macaddr=' "$file"; then
    sed -i "s/^macaddr=.*/macaddr=${mac}/I" "$file"
  else
    echo "macaddr=${mac}" >> "$file"
  fi
  say "MAC in .txt gesetzt: $mac"
}

replace_if_changed(){
  local src="$1"; local dst="$2"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    say ".txt unverändert – kein Austausch."
    rm -f "$src"; return
  fi
  if [[ -f "$dst" ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -a "$dst" "${dst}.bak.${ts}"
    say "Backup erstellt: ${dst}.bak.${ts}"
  fi
  mv -f "$src" "$dst"
  say ".txt aktualisiert: $(basename "$dst")"
}

set_regdom(){
  [[ $DO_REGDOM -eq 1 ]] || { say "RegDomain übersprungen (--no-regdom)."; return; }
  command -v iw >/dev/null 2>&1 && { say "Setze RegDomain (temporär) auf DE ..."; iw reg set DE || true; }
  [[ -f /etc/default/crda ]] && ! grep -q '^REGDOMAIN=DE' /etc/default/crda && \
    say "Hinweis: Für Legacy-Setups REGDOMAIN=DE in /etc/default/crda setzen."
}

# -------- NetworkManager Backend (iwd vs. wpa_supplicant) --------
nm_is_present() {
  command -v nmcli >/dev/null 2>&1 || return 1
  systemctl list-unit-files | grep -q '^NetworkManager\.service' || return 1
  return 0
}
service_active()  { systemctl is-active   --quiet "$1" 2>/dev/null; }
service_enabled() { systemctl is-enabled  --quiet "$1" 2>/dev/null; }
service_exists()  { systemctl list-unit-files | grep -q "^$1"; }

write_nm_backend_conf() {
  local backend="$1"  # iwd oder wpa_supplicant
  mkdir -p /etc/NetworkManager/conf.d
  local conf="/etc/NetworkManager/conf.d/10-wifi-backend.conf"
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOF
[device]
wifi.backend=${backend}
EOF
  if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    say "NM backend bereits '${backend}' – keine Änderung."
  else
    [[ -f "$conf" ]] && cp -a "$conf" "${conf}.bak.$(date +%Y%m%d-%H%M%S)"
    mv -f "$tmp" "$conf"
    say "NM backend gesetzt: ${backend} → ${conf}"
  fi
}

ensure_nm_backend() {
  nm_is_present || { say "NetworkManager nicht gefunden – Backend‑Check übersprungen."; return 0; }

  local target=""
  case "$NM_BACKEND" in
    auto)
      if service_exists iwd.service && ( service_active iwd.service || service_enabled iwd.service ); then
        target="iwd"
      else
        target="wpa_supplicant"
      fi
      ;;
    iwd) target="iwd" ;;
    wpa) target="wpa_supplicant" ;;
    *)   say "Unbekannter NM-Backend-Wert: $NM_BACKEND – verwende auto"; target="wpa_supplicant" ;;
  esac

  if [[ "$target" == "iwd" ]]; then
    write_nm_backend_conf "iwd"
    if service_exists iwd.service; then
      systemctl enable --now iwd 2>/dev/null || true
    fi
    systemctl stop wpa_supplicant 2>/dev/null || true
  else
    write_nm_backend_conf "wpa_supplicant"
    if service_exists iwd.service; then
      systemctl disable --now iwd 2>/dev/null || true
    fi
  fi
  say "Starte NetworkManager neu, damit der WLAN-Backend aktiv wird ..."
  systemctl restart NetworkManager || say "Hinweis: Konnte NetworkManager nicht neu starten."
  nmcli --version >/dev/null 2>&1 && nmcli radio || true
}

soft_reload(){
  say "Versuche sanften Reload ..."
  systemctl stop NetworkManager 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true
  systemctl stop iwd 2>/dev/null || true
  local iface="$1"; ip link set "$iface" down 2>/dev/null || true
  if modprobe -r brcmfmac 2>/dev/null; then sleep 1; modprobe brcmfmac; say "Modul neu geladen."; else say "Reload nicht möglich – bitte rebooten."; return 1; fi
  systemctl start iwd 2>/dev/null || true
  systemctl start wpa_supplicant 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true
}

postcheck(){
  say "dmesg (tail):"; dmesg | grep -i brcmfmac | tail -n 15 || true
  echo; iw dev 2>/dev/null | awk '/Interface/ {print "Interface:", $2}'; echo
}

main(){
  need_root; lock
  local pm=""; [[ $OFFLINE -eq 0 ]] && pm=$(detect_pm)
  install_prereqs "$pm"
  ensure_firmware_bin

  local tmp; tmp=$(prepare_txt_atomic)
  local iface; iface=$(detect_iface)
  if [[ -z "$iface" ]]; then say "Interface nicht automatisch gefunden. Bitte eingeben (z. B. wlp2s0): "; read -r iface; fi
  inject_mac "$tmp" "$iface"
  mkdir -p "$FW_DIR_SYS"; replace_if_changed "$tmp" "$TXT_SYS"

  set_regdom
  ensure_nm_backend

  [[ $TRY_RELOAD -eq 1 ]] && soft_reload "$iface" || true
  postcheck

  if [[ $TRY_RELOAD -eq 0 ]]; then
    echo; say "Empfehlung: **Neustart**, damit alle Änderungen sicher greifen. (sudo reboot)"
  fi
}

main "$@"
``
