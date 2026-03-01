#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# piSignage Golden Player Setup (Pi 4)
# - Force HDMI audio + hotplug (boot config)
# - Force ALSA HDMI output (persistent systemd service)
# - Set piSignage server URL (player2/package.json + common JSONs)
# - Install first-boot identity regen (machine-id + SSH keys + optional hostname)
# - Optional: --prep-for-clone wipes identity + shutdown (for SD cloning)
#
# Usage examples:
#   sudo ./pisignage-golden-setup.sh --server https://digiddpm.com
#   sudo ./pisignage-golden-setup.sh --server https://digiddpm.com --prep-for-clone
#   sudo ./pisignage-golden-setup.sh --no-hostname
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
  -h, --help           Show this help
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

echo "=== piSignage Golden Setup ==="
echo "Server URL: ${SERVER_URL}"
echo "Prep for clone: ${PREP_FOR_CLONE}"
echo "Set hostname on first boot: ${SET_HOSTNAME}"
echo

# ---------- 1) Force HDMI audio + hotplug in boot config ----------
choose_boot_config() {
  # Bookworm often uses /boot/firmware/config.txt
  if [[ -f /boot/firmware/config.txt ]]; then
    echo "/boot/firmware/config.txt"
  else
    echo "/boot/config.txt"
  fi
}

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

# ---------- 3) Set piSignage server URL ----------
echo "[3/5] Setting piSignage server URL..."

escape_sed_repl() {
  # Escape for sed replacement
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

SERVER_URL_ESCAPED="$(escape_sed_repl "$SERVER_URL")"

set_server_in_player2_package_json() {
  local f="/home/pi/player2/package.json"
  [[ -f "$f" ]] || return 1

  # Update config_server + media_server keys
  sed -i -E \
    's/"config_server"\s*:\s*"[^"]*"/"config_server": "'"${SERVER_URL_ESCAPED}"'"/g;
     s/"media_server"\s*:\s*"[^"]*"/"media_server": "'"${SERVER_URL_ESCAPED}"'"/g' \
    "$f"

  echo "  - Updated config_server + media_server in: $f"
  return 0
}

set_server_in_json_keys() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  [[ "$file" == *.json ]] || return 1

  # Replace common server keys if present
  if grep -qE '"(server|serverUrl|serverURL|serverAddress|serverIp|serverIP|config_server|media_server)"\s*:' "$file"; then
    sed -i -E \
      's/"(server|serverUrl|serverURL|serverAddress|serverIp|serverIP|config_server|media_server)"\s*:\s*"[^"]*"/"\1": "'"${SERVER_URL_ESCAPED}"'"/g' \
      "$file" || return 1
    echo "  - Updated server-related keys in: $file"
    return 0
  fi

  return 1
}

FOUND_ANY="false"

# 3A) Your confirmed location first:
set_server_in_player2_package_json && FOUND_ANY="true" || true

# 3B) Common fallback locations (other piSignage builds)
CANDIDATES=(
  "/home/pi/.pisignage/config.json"
  "/home/pi/.pisignage/settings.json"
  "/home/pi/.config/pisignage/config.json"
  "/home/pi/.config/pisignage/settings.json"
)

for f in "${CANDIDATES[@]}"; do
  if set_server_in_json_keys "$f"; then
    FOUND_ANY="true"
  fi
done

# 3C) If still not found, cautious search
if [[ "$FOUND_ANY" == "false" ]]; then
  echo "  - Didn't find known config paths. Searching JSON under /home/pi for server keys..."
  mapfile -t MATCHES < <(grep -Rsl --include='*.json' -E '"(server|serverUrl|serverURL|serverAddress|serverIp|serverIP|config_server|media_server)"\s*:' /home/pi 2>/dev/null | head -n 30 || true)
  if [[ "${#MATCHES[@]}" -gt 0 ]]; then
    for m in "${MATCHES[@]}"; do
      set_server_in_json_keys "$m" && FOUND_ANY="true" || true
    done
  fi
fi

if [[ "$FOUND_ANY" == "false" ]]; then
  echo "  - WARN: Could not locate any file with server/config_server/media_server keys to update."
  echo "          (But your report indicates /home/pi/player2/package.json should exist.)"
fi

# ---------- 4) Install First-Boot Identity Regen ----------
echo "[4/5] Installing first-boot identity regeneration (machine-id + SSH keys)..."

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

# Optional hostname set from CPU serial (Pi)
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

  # light cleanup
  rm -rf /var/log/journal/* >/dev/null 2>&1 || true
  sync

  echo "Shutdown now. When it's fully off, remove SD card and image/clone it."
  shutdown -h now
else
  echo
  echo "Next:"
  echo "  1) Reboot and test: HDMI audio + piSignage connects to ${SERVER_URL}"
  echo "  2) If you ever want cloning: run with --prep-for-clone (it will shutdown)"
fi