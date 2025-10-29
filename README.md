# BCM43602 Wi-Fi Fix for MacBook Pro 2016/2017

Dieses Repo enthält:
- `install-bcm43602-mbp.sh` – offline-first Installer
- `firmware/brcmfmac43602-pcie.bin` – unveränderte Firmware aus linux-firmware
- `firmware/brcmfmac43602-pcie.txt` – NVRAM-Datei (MAC wird vom Skript gesetzt)
- Lizenzdateien (Broadcom Binary Redistribution)

## Nutzung offline:
```bash
sudo ./install-bcm43602-mbp.sh --offline --reload
