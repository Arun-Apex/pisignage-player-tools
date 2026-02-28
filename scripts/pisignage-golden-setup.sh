#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# piSignage Golden Player Setup (Pi 4)
# - Force HDMI audio + hotplug
# - Force ALSA HDMI output
# - Set piSignage server URL
# - Install first-boot identity regen (machine-id + SSH keys)
# - Optional: --prep-for-clone wipes identity + shutdown
# ============================================================

SERVER_URL_DEFAULT="https://digiddpm.com"

usage() {
  cat <<EOF
Usage:
  sudo ./pisignage-golden-setup.sh [--server https://example.com] [--prep-for-clone] [--no-hostname]

Options:
  --server URL         Server URL to set (default: ${SERVER_URL_DEFAULT})
  --prep-for-clone     Wipe SSH host keys + machine-id (so clones regenerate), then shutdown
  --no-hostname        Do not change hostname (otherwise sets pisignage-<last6serial>)
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

echo "=== piSignage Golden Setup ==="
echo "Server URL: ${SERVER_URL}"
echo "Prep for clone: ${PREP_FOR_CLONE}"
echo "Set hostname: ${SET_HOSTNAME}"
echo

# ---------- 1) Force HDMI audio + hotplug in /boot/config.txt ----------
BOOT_CONFIG="/boot/config.txt"
if [[ -f "$BOOT_CONFIG" ]]; then
  echo "[1/5] Updating ${BOOT_CONFIG} for HDMI audio..."
  # Ensure lines exist (idempotent)
  grep -q '^hdmi_drive=2' "$BOOT_CONFIG" || echo 'hdmi_drive=2' >> "$BOOT_CONFIG"
  grep -q '^hdmi_force_hotplug=1' "$BOOT_CONFIG" || echo 'hdmi_force_hotplug=1' >> "$BOOT_CONFIG"
  echo "  - Added/ensured: hdmi_drive=2, hdmi_force_hotplug=1"
else
  echo "[1/5] WARN: ${BOOT_CONFIG} not found. Skipping boot HDMI force."
fi

# ---------- 2) Force ALSA output to HDMI ----------
echo "[2/5] Forcing audio output to HDMI (amixer numid=3 2)..."
if command -v amixer >/dev/null 2>&1; then
  amixer cset numid=3 2 >/dev/null 2>&1 || true
  echo "  - amixer set attempted (some images may not expose numid=3, that's OK)."
else
  echo "  - WARN: amixer not found. Skipping."
fi

# Make it persistent via a small systemd oneshot service
echo "  - Installing persistent HDMI audio service..."
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

# ---------- 3) Set piSignage server URL ----------
echo "[3/5] Setting piSignage server URL in config (best-effort)..."

set_server_in_json() {
  local file="$1"
  # Only touch files that look like JSON
  [[ -f "$file" ]] || return 1
  [[ "$file" == *.json ]] || return 1

  # If file contains a "server" key, replace it; otherwise try to insert.
  if grep -qE '"server"\s*:' "$file"; then
    # Replace existing server value
    sed -i -E 's/"server"\s*:\s*"[^"]*"/"server": "'"${SERVER_URL//\//\\/}"'"/' "$file" || return 1
    echo "  - Updated server in: $file"
    return 0
  fi

  return 1
}

# Common locations (varies by player version)
CANDIDATES=(
  "/home/pi/.pisignage/config.json"
  "/home/pi/.pisignage/settings.json"
  "/home/pi/.config/pisignage/config.json"
  "/home/pi/.config/pisignage/settings.json"
)

FOUND_ANY="false"

for f in "${CANDIDATES[@]}"; do
  if set_server_in_json "$f"; then
    FOUND_ANY="true"
  fi
done

# If not found, do a cautious search for JSON files that contain "server":
if [[ "$FOUND_ANY" == "false" ]]; then
  echo "  - Didn't find known config paths. Searching for JSON containing \"server\" under /home/pi ..."

  # Limit search depth a bit to avoid heavy scanning
  mapfile -t MATCHES < <(grep -Rsl --include='*.json' '"server"[[:space:]]*:' /home/pi 2>/dev/null | head -n 20 || true)

  if [[ "${#MATCHES[@]}" -gt 0 ]]; then
    for m in "${MATCHES[@]}"; do
      set_server_in_json "$m" && FOUND_ANY="true" || true
    done
  fi
fi

if [[ "$FOUND_ANY" == "false" ]]; then
  echo "  - WARN: Could not locate a JSON file with a \"server\" key to update."
  echo "          You may need to tell me the exact file path used by your player image."
fi

# ---------- 4) Install First-Boot Identity Regen ----------
echo "[4/5] Installing first-boot identity regeneration (SSH keys + machine-id)..."

cat >/usr/local/sbin/firstboot-identity-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Regenerate machine-id
systemd-machine-id-setup || true

# Regenerate SSH host keys (if missing)
if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
  : # keys exist
else
  dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi

systemctl restart ssh >/dev/null 2>&1 || true

# Optional hostname set from CPU serial (safe)
if [[ "${SET_HOSTNAME_ON_FIRSTBOOT:-true}" == "true" ]]; then
  SERIAL="$(awk -F ': ' '/Serial/ {print $2}' /proc/cpuinfo | tail -n 1 || true)"
  if [[ -n "$SERIAL" ]]; then
    hostnamectl set-hostname "pisignage-${SERIAL: -6}" >/dev/null 2>&1 || true
  fi
fi

# Disable this service after run
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

# If user chose --no-hostname, update service env
if [[ "$SET_HOSTNAME" == "false" ]]; then
  sed -i 's/Environment=SET_HOSTNAME_ON_FIRSTBOOT=true/Environment=SET_HOSTNAME_ON_FIRSTBOOT=false/' \
    /etc/systemd/system/firstboot-identity-fix.service
fi

systemctl daemon-reload
systemctl enable firstboot-identity-fix.service >/dev/null 2>&1 || true

# ---------- 5) Optional prep for cloning ----------
echo "[5/5] Done installing settings."

if [[ "$PREP_FOR_CLONE" == "true" ]]; then
  echo
  echo "=== PREP FOR CLONE ==="
  echo "Wiping SSH host keys and machine-id so each cloned Pi regenerates unique identity..."

  rm -f /etc/ssh/ssh_host_* || true
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true

  # best-effort cache/log cleanup (light)
  rm -rf /var/log/journal/* >/dev/null 2>&1 || true
  sync

  echo "Shutdown now. When it's fully off, remove SD card and image/clone it."
  shutdown -h now
else
  echo
  echo "Next:"
  echo "  1) Reboot and test: HDMI audio + piSignage connects to ${SERVER_URL}"
  echo "  2) When happy, run: sudo $0 --server ${SERVER_URL} --prep-for-clone"
fi