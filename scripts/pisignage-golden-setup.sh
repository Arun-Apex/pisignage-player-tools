#!/usr/bin/env bash
set -euo pipefail

SERVER_URL_DEFAULT="https://digiddpm.com"

usage() {
  cat <<EOF
Usage:
  sudo $0 [--server https://example.com] [--prep-for-clone] [--no-hostname]

Options:
  --server URL         Server URL to set (default: ${SERVER_URL_DEFAULT})
  --prep-for-clone     Wipe SSH host keys + machine-id then shutdown
  --no-hostname        Do not change hostname (otherwise sets pisignage-<last6serial> on first boot)
  -h, --help           Show help
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root: sudo $0 ..."
    exit 1
  fi
}

SERVER_URL="${SERVER_URL_DEFAULT}"
PREP_FOR_CLONE="false"
SET_HOSTNAME="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_URL="${2:-}"; shift 2 ;;
    --prep-for-clone) PREP_FOR_CLONE="true"; shift ;;
    --no-hostname) SET_HOSTNAME="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

need_root
[[ -n "${SERVER_URL}" ]] || { echo "ERROR: --server URL is empty"; exit 1; }

echo "=== piSignage Player Setup (CLEAN) ==="
echo "Server URL: ${SERVER_URL}"
echo "Prep for clone: ${PREP_FOR_CLONE}"
echo "Set hostname on first boot: ${SET_HOSTNAME}"
echo

choose_boot_config() {
  [[ -f /boot/firmware/config.txt ]] && echo "/boot/firmware/config.txt" || echo "/boot/config.txt"
}

# 0) Fix sudo unable to resolve host
echo "[0/5] Fixing /etc/hosts hostname entry..."
HN="$(hostname || true)"
if [[ -n "$HN" ]]; then
  if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+${HN}([[:space:]]|\$)" /etc/hosts; then
    sed -i -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]+/d' /etc/hosts
    echo "127.0.1.1       ${HN}" >> /etc/hosts
    echo "  - Added: 127.0.1.1 ${HN}"
  else
    echo "  - OK"
  fi
fi

# 1) Force HDMI audio
BOOT_CONFIG="$(choose_boot_config)"
echo "[1/5] Updating ${BOOT_CONFIG} for HDMI audio..."
if [[ -f "$BOOT_CONFIG" ]]; then
  grep -q '^hdmi_drive=2' "$BOOT_CONFIG" || echo 'hdmi_drive=2' >> "$BOOT_CONFIG"
  grep -q '^hdmi_force_hotplug=1' "$BOOT_CONFIG" || echo 'hdmi_force_hotplug=1' >> "$BOOT_CONFIG"
  echo "  - Ensured: hdmi_drive=2, hdmi_force_hotplug=1"
else
  echo "  - WARN: boot config not found"
fi

# 2) Force ALSA HDMI output
echo "[2/5] Forcing audio output to HDMI..."
if command -v amixer >/dev/null 2>&1; then
  amixer cset numid=3 2 >/dev/null 2>&1 || true
fi

cat >/etc/systemd/system/force-hdmi-audio.service <<'EOF'
[Unit]
Description=Force HDMI audio output
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'command -v amixer >/dev/null 2>&1 && amixer cset numid=3 2 || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable force-hdmi-audio.service >/dev/null 2>&1 || true
echo "  - Installed force-hdmi-audio.service"

# 3) Set server URL (ONLY known files)
echo "[3/5] Setting piSignage server URL (known files only)..."
PKG="/home/pi/player2/package.json"
DEV="/home/pi/player2/config/_device-settings.json"

[[ -f "$PKG" ]] || { echo "  - ERROR: Missing $PKG"; exit 1; }
[[ -f "$DEV" ]] || { echo "  - ERROR: Missing $DEV"; exit 1; }

# IMPORTANT: use [[:space:]]* not \s*
sed -i -E 's#"config_server"[[:space:]]*:[[:space:]]*"[^"]*"#"config_server": "'"${SERVER_URL}"'"#g' "$PKG"
sed -i -E 's#"media_server"[[:space:]]*:[[:space:]]*"[^"]*"#"media_server": "'"${SERVER_URL}"'"#g' "$PKG"
sed -i -E 's#"server"[[:space:]]*:[[:space:]]*"[^"]*"#"server": "'"${SERVER_URL}"'"#g' "$DEV"

echo "  - Updated values now:"
grep -nE '"(config_server|media_server)"[[:space:]]*:' "$PKG" || true
grep -nE '"server"[[:space:]]*:' "$DEV" || true

# 4) First boot identity regen
echo "[4/5] Installing first-boot identity regeneration..."
cat >/usr/local/sbin/firstboot-identity-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

systemd-machine-id-setup || true

if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
  :
else
  dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi
systemctl restart ssh >/dev/null 2>&1 || true

if [[ "${SET_HOSTNAME_ON_FIRSTBOOT:-true}" == "true" ]]; then
  SERIAL="$(awk -F ': ' '/Serial/ {print $2}' /proc/cpuinfo | tail -n 1 || true)"
  if [[ -n "$SERIAL" ]]; then
    hostnamectl set-hostname "pisignage-${SERIAL: -6}" >/dev/null 2>&1 || true
  fi
fi

systemctl disable firstboot-identity-fix.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/firstboot-identity-fix.service
rm -f /usr/local/sbin/firstboot-identity-fix.sh
EOF

chmod +x /usr/local/sbin/firstboot-identity-fix.sh

cat >/etc/systemd/system/firstboot-identity-fix.service <<'EOF'
[Unit]
Description=First boot identity fix (machine-id + SSH keys)
After=network.target

[Service]
Type=oneshot
Environment=SET_HOSTNAME_ON_FIRSTBOOT=true
ExecStart=/usr/local/sbin/firstboot-identity-fix.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

if [[ "$SET_HOSTNAME" == "false" ]]; then
  sed -i 's/Environment=SET_HOSTNAME_ON_FIRSTBOOT=true/Environment=SET_HOSTNAME_ON_FIRSTBOOT=false/' \
    /etc/systemd/system/firstboot-identity-fix.service
fi

systemctl daemon-reload
systemctl enable firstboot-identity-fix.service >/dev/null 2>&1 || true

# 5) Clone prep
echo "[5/5] Done."
if [[ "$PREP_FOR_CLONE" == "true" ]]; then
  rm -f /etc/ssh/ssh_host_* || true
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  sync
  shutdown -h now
else
  echo "Reboot now: sudo reboot"
fi