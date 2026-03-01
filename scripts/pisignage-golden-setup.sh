#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# piSignage Player Setup (Pi 4) - CLEAN / DETERMINISTIC
#
# Does:
#  0) Fix sudo "unable to resolve host" by ensuring /etc/hosts has 127.0.1.1 <hostname>
#  1) Force HDMI audio + hotplug in boot config (Bookworm: /boot/firmware/config.txt)
#  2) Force ALSA output to HDMI (systemd oneshot on every boot)
#  3) Set server URL in EXACT known locations:
#       - /home/pi/player2/package.json: config_server + media_server
#       - /home/pi/player2/config/_device-settings.json: server
#  4) Install first-boot identity regen:
#       - machine-id
#       - SSH host keys
#       - optional hostname: pisignage-<last6serial>
#
# Optional:
#  --prep-for-clone : wipes SSH host keys + machine-id then shutdown
# ============================================================

SERVER_URL_DEFAULT="https://digiddpm.com"

usage() {
  cat <<EOF
Usage:
  sudo $0 [--server https://example.com] [--prep-for-clone] [--no-hostname]

Options:
  --server URL         Server URL to set (default: ${SERVER_URL_DEFAULT})
  --prep-for-clone     Wipe SSH host keys + machine-id (so clones regenerate), then shutdown
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
    --server)
      SERVER_URL="${2:-}"
      shift 2
      ;;
    --prep-for-clone)
      PREP_FOR_CLONE="true"
      shift
      ;;
    --no-hostname)
      SET_HOSTNAME="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

need_root

if [[ -z "${SERVER_URL}" ]]; then
  echo "ERROR: --server URL is empty"
  exit 1
fi

echo "=== piSignage Player Setup (CLEAN) ==="
echo "Server URL: ${SERVER_URL}"
echo "Prep for clone: ${PREP_FOR_CLONE}"
echo "Set hostname on first boot: ${SET_HOSTNAME}"
echo

# ---------- helper: choose correct boot config ----------
choose_boot_config() {
  if [[ -f /boot/firmware/config.txt ]]; then
    echo "/boot/firmware/config.txt"
  else
    echo "/boot/config.txt"
  fi
}

# ---------- 0) Fix sudo 'unable to resolve host' ----------
echo "[0/5] Fixing /etc/hosts hostname entry (prevents sudo warning)..."
HN="$(hostname || true)"
if [[ -n "$HN" ]]; then
  if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+${HN}([[:space:]]|\$)" /etc/hosts; then
    # remove any existing 127.0.1.1 line to avoid duplicates
    sed -i -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]+/d' /etc/hosts
    echo "127.0.1.1       ${HN}" >> /etc/hosts
    echo "  - Added: 127.0.1.1 ${HN}"
  else
    echo "  - OK: /etc/hosts already has 127.0.1.1 ${HN}"
  fi
else
  echo "  - WARN: hostname empty, skipping /etc/hosts fix"
fi

# ---------- 1) Force HDMI audio + hotplug ----------
BOOT_CONFIG="$(choose_boot_config)"
if [[ -f "$BOOT_CONFIG" ]]; then
  echo "[1/5] Updating ${BOOT_CONFIG} for HDMI audio..."
  grep -q '^hdmi_drive=2' "$BOOT_CONFIG" || echo 'hdmi_drive=2' >> "$BOOT_CONFIG"
  grep -q '^hdmi_force_hotplug=1' "$BOOT_CONFIG" || echo 'hdmi_force_hotplug=1' >> "$BOOT_CONFIG"
  echo "  - Ensured: hdmi_drive=2, hdmi_force_hotplug=1"
else
  echo "[1/5] WARN: ${BOOT_CONFIG} not found. Skipping boot HDMI force."
fi

# ---------- 2) Force ALSA output to HDMI ----------
echo "[2/5] Forcing audio output to HDMI (amixer numid=3 2)..."
if command -v amixer >/dev/null 2>&1; then
  amixer cset numid=3 2 >/dev/null 2>&1 || true
  echo "  - amixer set attempted (OK if not supported on some images)."
else
  echo "  - WARN: amixer not found. Skipping."
fi

echo "  - Installing persistent HDMI audio systemd service..."
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

# ---------- 3) Set server URL in exact known files ----------
echo "[3/5] Setting piSignage server URL (exact known files only)..."

PKG="/home/pi/player2/package.json"
DEV="/home/pi/player2/config/_device-settings.json"

if [[ ! -f "$PKG" ]]; then
  echo "  - ERROR: Missing ${PKG}"
  exit 1
fi
if [[ ! -f "$DEV" ]]; then
  echo "  - ERROR: Missing ${DEV}"
  exit 1
fi

# Update /home/pi/player2/package.json keys
sed -i -E 's#"config_server"\s*:\s*"[^"]*"#"config_server": "'"${SERVER_URL}"'"#g' "$PKG"
sed -i -E 's#"media_server"\s*:\s*"[^"]*"#"media_server": "'"${SERVER_URL}"'"#g' "$PKG"

# Update /home/pi/player2/config/_device-settings.json key
sed -i -E 's#"server"\s*:\s*"[^"]*"#"server": "'"${SERVER_URL}"'"#g' "$DEV"

echo "  - Updated:"
echo "    * ${PKG}  (config_server, media_server)"
echo "    * ${DEV}  (server)"
echo "  - Verify now:"
grep -nE '"(config_server|media_server)"\s*:' "$PKG" || true
grep -nE '"server"\s*:' "$DEV" || true

# ---------- 4) Install First-Boot Identity Regen ----------
echo "[4/5] Installing first-boot identity regeneration (machine-id + SSH keys)..."

cat >/usr/local/sbin/firstboot-identity-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Regenerate machine-id
systemd-machine-id-setup || true

# Regenerate SSH host keys if missing
if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
  :
else
  dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi
systemctl restart ssh >/dev/null 2>&1 || true

# Optional hostname from CPU serial
if [[ "${SET_HOSTNAME_ON_FIRSTBOOT:-true}" == "true" ]]; then
  SERIAL="$(awk -F ': ' '/Serial/ {print $2}' /proc/cpuinfo | tail -n 1 || true)"
  if [[ -n "$SERIAL" ]]; then
    hostnamectl set-hostname "pisignage-${SERIAL: -6}" >/dev/null 2>&1 || true
    HN="$(hostname || true)"
    if [[ -n "$HN" ]]; then
      if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+${HN}([[:space:]]|\$)" /etc/hosts; then
        sed -i -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]+/d' /etc/hosts
        echo "127.0.1.1       ${HN}" >> /etc/hosts
      fi
    fi
  fi
fi

# Disable after run
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

# ---------- 5) Optional prep for cloning ----------
echo "[5/5] Done."

if [[ "$PREP_FOR_CLONE" == "true" ]]; then
  echo
  echo "=== PREP FOR CLONE ==="
  rm -f /etc/ssh/ssh_host_* || true
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  rm -rf /var/log/journal/* >/dev/null 2>&1 || true
  sync
  echo "Shutdown now."
  shutdown -h now
else
  echo
  echo "Next: reboot and verify server values stayed:"
  echo "  cat /home/pi/player2/package.json | grep server"
  echo "  grep '\"server\"' /home/pi/player2/config/_device-settings.json"
  echo
  echo "Reboot: sudo reboot"
fi