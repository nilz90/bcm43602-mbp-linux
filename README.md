# BCM43602 Wi‑Fi Fix for MacBook Pro 2016/2017 (brcmfmac)

Dieses Repo enthält:
- `install-bcm43602-mbp.sh` – ein idempotentes, distro‑übergreifendes Installer‑Skript (apt/dnf/pacman/zypper)
- `firmware/brcmfmac43602-pcie.txt` – NVRAM‑Datei (mit `macaddr=xx:xx...` Platzhalter). **Das Skript setzt deine echte MAC automatisch ein.**

## Warum nötig?
Für BCM43602 auf MBP 2016/2017 braucht der Linux‑Treiber `brcmfmac` neben der generischen Firmware (`brcmfmac43602-pcie.bin`) eine passende NVRAM‑`.txt`. Die Firmware kommt aus den offiziellen **linux‑firmware**‑Paketen; die `.txt` liefert boardspezifische Kalibrierdaten. Ohne `.txt` scheitert die Initialisierung häufig.  
Referenzen: Linux‑Wireless Doku & Debian brcmfmac Seite.  
– https://wireless.docs.kernel.org/en/latest/en/users/drivers/brcm80211.html  
– https://wiki.debian.org/brcmfmac

## Nutzung
```bash
sudo ./install-bcm43602-mbp.sh --reload
# oder ohne --reload und danach:
# sudo reboot
``
