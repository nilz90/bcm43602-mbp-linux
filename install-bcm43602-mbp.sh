#!/usr/bin/env bash
# Cross-distro, idempotent installer for Broadcom BCM43602 (MacBook Pro 2016/2017)
# - Safe to re-run: only changes what's necessary.
# - Installs prereqs via apt/dnf/pacman/zypper
# - Ensures brcmfmac43602-pcie.bin exists (unzstd .zst if needed)
# - Uses vendored NVRAM (firmware/brcmfmac43602-pcie.txt), injects real MAC, atomic replace if changed
# - Optional regulatory domain (DE)
# - Optional soft reload (--reload), else suggests reboot
#
# Refs:
#  - Firmware from linux-firmware upstream: https://wireless.docs.kernel.org/en/latest/en/users/drivers/brcm80211.html
#  - Debian brcmfmac page: https://wiki.debian.org/brcmfmac

set -Eeuo pipefail

FW_DIR="/lib/firmware/brcm"
BIN_ZST="${FW_DIR}/brcmfmac43602-pcie.bin.zst"
BIN_RAW="${FW_DIR}/brcmfmac43602-pcie.bin"

# vendored NVRAM within repo:
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDORED_TXT="${REPO_DIR}/firmware/brcmfmac43602-pcie.txt"
TXT_FILE="${FW_DIR}/brcmfmac43602-pcie.txt"

DO_REGDOM=1
TRY_RELOAD=0
LOCK_FILE="/var/lock/install-bcm43602.lock"

for arg in "${@:-}"; do
  case "$arg" in
    --no-regdom) DO_REGDOM=0 ;;
    --reload)    TRY_RELOAD=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

say(){ echo -e "[BCM43602] $*"; }
die(){ echo -e "[BCM43602] ERROR: $*" >&2; exit 1; }
cleanup(){ rm -f "$LOCK_FILE" 2>/dev/null || true; }
trap cleanup EXIT
trap 'say "Fehler aufgetreten. Du kannst das Skript später **einfach erneut starten** – es ist idempotent."' ERR

need_root(){ [[ $EUID -eq 0 ]] || die "Bitte mit sudo/root ausführen."; }
lock(){ if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then die "Läuft bereits (Lock: $LOCK_FILE)."; fi; }

detect_pm(){
  if command -v apt >/dev/null 2>&1;    then echo apt;    return; fi
  if command -v dnf >/dev/null 2>&1;    then echo dnf;    return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  die "Keinen unterstützten Paketmanager gefunden (apt/dnf/pacman/zypper)."
}

install_prereqs(){
  local pm="$1"
  say "Installiere Voraussetzungen mit ${pm} (idempotent) ..."
  case "$pm" in
    apt)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y linux-firmware firmware-brcm80211 zstd iw wget curl ca-certificates
      ;;
    dnf)
      dnf install -y linux-firmware zstd wireless-tools iw wget curl ca-certificates
      ;;
    pacman)
      pacman -Sy --noconfirm linux-firmware zstd wireless_tools iw wget curl ca-certificates || true
      ;;
    zypper)
      zypper --non-interactive install --no-confirm linux-firmware zstd wireless-tools iw wget curl ca-certificates || true
      ;;
  esac
}

detect_iface(){
  local iface=""
  if command -v iw >/dev/null 2>&1; then
    iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
  fi
  if [[ -z "$iface" ]]; then
    iface=$(ip -o link show | awk -F': ' '$2 ~ /^wl/ {print $2; exit}')
  fi
  echo "$iface"
}

ensure_firmware_bin(){
  mkdir -p "$FW_DIR"
  if [[ -f "$BIN_RAW" ]]; then say "Firmware .bin vorhanden: $(basename "$BIN_RAW")"; return; fi
  if [[ -f "$BIN_ZST" ]]; then
    say "Entpacke $(basename "$BIN_ZST") → $(basename "$BIN_RAW") ..."
    unzstd -f "$BIN_ZST" -o "$BIN_RAW"
    say "Fertig: $(basename "$BIN_RAW")"
    return
  fi
  say "Hinweis: ${BIN_RAW} nicht gefunden. Normalerweise liefert 'linux-firmware' die Datei; nach Paketlauf ggf. Skript erneut starten."
}

prepare_txt_atomic(){
  [[ -f "$VENDORED_TXT" ]] || die "Vendored NVRAM fehlt: $VENDORED_TXT"
  local tmp; tmp=$(mktemp)
  sed 's/\r$//' "$VENDORED_TXT" > "$tmp"
  chmod 0644 "$tmp"; chown root:root "$tmp"
  echo "$tmp"
}

inject_mac_into_file(){
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
    say "NVRAM .txt unverändert – kein Austausch nötig."
    rm -f "$src"; return
  fi
  if [[ -f "$dst" ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -a "$dst" "${dst}.bak.${ts}"
    say "Backup erstellt: ${dst}.bak.${ts}"
  fi
  mv -f "$src" "$dst"
  say "NVRAM .txt aktualisiert: $(basename "$dst")"
}

set_regdom(){
  [[ $DO_REGDOM -eq 1 ]] || { say "RegDomain-Setzen übersprungen (--no-regdom)."; return; }
  if command -v iw >/dev/null 2>&1; then
    say "Setze Regulatory Domain (temporär) auf DE ..."
    iw reg set DE || true
  fi
  if [[ -f /etc/default/crda ]] && ! grep -q '^REGDOMAIN=DE' /etc/default/crda; then
    say "Hinweis: Für Legacy-Setups kannst du REGDOMAIN=DE in /etc/default/crda setzen."
  fi
}

soft_reload(){
  say "Versuche sanften Reload (ohne Reboot) ..."
  systemctl stop NetworkManager 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true
  systemctl stop iwd 2>/dev/null || true
  local iface="$1"
  ip link set "$iface" down 2>/dev/null || true
  if modprobe -r brcmfmac 2>/dev/null; then
    sleep 1; modprobe brcmfmac; say "Modul neu geladen."
  else
    say "Modul-Reload nicht möglich – bitte rebooten."; return 1
  fi
  systemctl start iwd 2>/dev/null || true
  systemctl start wpa_supplicant 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true
  return 0
}

postcheck(){
  say "Kurzer Check (dmesg tail):"; dmesg | grep -i brcmfmac | tail -n 15 || true
  echo; iw dev 2>/dev/null | awk '/Interface/ {print "Interface:", $2}'; echo
  say "Falls 'Dongle setup failed' erscheint: ggf. alternative .txt testen (Repo aktualisieren) – erneuter Lauf ist ok."
}

main(){
  need_root; lock
  local pm; pm=$(detect_pm); install_prereqs "$pm"
  ensure_firmware_bin
  local tmp; tmp=$(prepare_txt_atomic)
  local iface; iface=$(detect_iface)
  if [[ -z "$iface" ]]; then say "Interface nicht automatisch gefunden. Bitte eingeben (z. B. wlp2s0): "; read -r iface; fi
  inject_mac_into_file "$tmp" "$iface"
  replace_if_changed "$tmp" "$TXT_FILE"
  set_regdom
  if [[ $TRY_RELOAD -eq 1 ]]; then soft_reload "$iface" || true; fi
  postcheck
  if [[ $TRY_RELOAD -eq 0 ]]; then echo; say "Empfehlung: **Neustart**, damit alle Änderungen sicher greifen. (sudo reboot)"; fi
}

main "$@"
