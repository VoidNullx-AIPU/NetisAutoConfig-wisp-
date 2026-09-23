#!/usr/bin/env bash
# =============================================================================
#  Netis / Realtek Router — 1-Run Setup & Persistent Systemd Watchdog
# =============================================================================

set -e

for cmd in sshpass ssh ping; do
    command -v "$cmd" &>/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

echo "=== Netis/Realtek WISP Setup (Automated PC Managed) ==="
read -rp  "Router IP            : " ROUTER_IP
read -rsp "Router SSH password : " ROUTER_PASS; echo
read -rp  "Upstream WiFi SSID  : " TARGET_SSID
read -rsp "Upstream WiFi pass  : " TARGET_PASS; echo
read -rp  "Enable persistent watchdog across reboots? [Y/n] (Default: Y): " WATCHDOG_ENABLE; echo
WATCHDOG_ENABLE="${WATCHDOG_ENABLE:-Y}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1 \
          -o HostKeyAlgorithms=+ssh-rsa \
          -o Ciphers=+aes128-cbc,3des-cbc \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout=5"

rssh() { sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$@"; }

# 1. Reachability Check
echo "[1/4] Checking router connectivity..."
ping -c 1 -W 1 "$ROUTER_IP" &>/dev/null || { echo "Cannot reach $ROUTER_IP"; exit 1; }

# 2. Scanning
echo "[2/4] Scanning for '$TARGET_SSID'..."
SCAN=$(rssh "
    iwpriv wlan0 set_mib opmode=0x10 2>/dev/null
    ifconfig wlan0 down; ifconfig wlan0 up
    sleep 2
    iwpriv wlan0 at_ss '$TARGET_SSID' 2>/dev/null
    sleep 4
    cat /proc/wlan0/SS_Result 2>/dev/null
")

BSSID=$(echo "$SCAN" | awk -v ssid="$TARGET_SSID" '
    /HwAddr:/  { mac=$2 }
    /SSID:/    { s=$2 }
    /RSSI:/    { if(s==ssid) print $2, mac }
' | sort -rn | head -1 | awk '{print $2}' | tr -d ' \r\n' | tr '[:upper:]' '[:lower:]')

CHANNEL=$(echo "$SCAN" | awk -v ssid="$TARGET_SSID" '
    /Channel:/ { ch=$2 }
    /SSID:/    { if($2==ssid) print ch }
' | head -1 | tr -d ' \r\n')

if [ -n "$BSSID" ]; then
    echo "      Found BSSID: $BSSID | Channel: $CHANNEL"
else
    echo "      Auto-detect failed."
    read -rp "  Enter BSSID manually: " RAW
    BSSID=$(echo "$RAW" | tr -d ':-' | tr '[:upper:]' '[:lower:]')
    read -rp "  Enter Channel: " CHANNEL
fi

# 3. Apply Connection & Route (Netis Compatible)
echo "[3/4] Linking wlan0 and obtaining WAN lease..."
rssh "
    iwpriv wlan0 set_mib opmode=0x08
    iwpriv wlan0 set_mib channel=$CHANNEL
    iwpriv wlan0 set_mib ssid='$TARGET_SSID'
    iwpriv wlan0 set_mib passphrase='$TARGET_PASS'
    ifconfig wlan0 down; ifconfig wlan0 up
    sleep 2
    iwpriv wlan0 at_join $BSSID
    sleep 3

    brctl delif br0 wlan0 2>/dev/null || true
    killall -9 udhcpc 2>/dev/null || true
    udhcpc -i wlan0 >/dev/null 2>&1 &
    sleep 10

    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/fast_nat 2>/dev/null || true
    iptables -t nat -F
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
    iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
"

# 4. Generate local helper scripts & persistent systemd unit
echo "[4/4] Generating local scripts & setting up autostart..."

cat > "$SCRIPT_DIR/reconnect.sh" << EOF
#!/usr/bin/env bash
ROUTER_IP='$ROUTER_IP'
ROUTER_PASS='$ROUTER_PASS'
SSH_OPTS='$SSH_OPTS'

sshpass -p "\$ROUTER_PASS" ssh \$SSH_OPTS "root@\$ROUTER_IP" "
    iwpriv wlan0 set_mib opmode=0x08
    iwpriv wlan0 set_mib channel=$CHANNEL
    iwpriv wlan0 set_mib ssid='$TARGET_SSID'
    iwpriv wlan0 set_mib passphrase='$TARGET_PASS'
    ifconfig wlan0 down; ifconfig wlan0 up
    sleep 2
    iwpriv wlan0 at_join $BSSID
    sleep 3
    brctl delif br0 wlan0 2>/dev/null || true
    killall -9 udhcpc 2>/dev/null || true
    udhcpc -i wlan0 >/dev/null 2>&1 &
    sleep 10
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/fast_nat 2>/dev/null || true
    iptables -t nat -F
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
    iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
"
EOF
chmod +x "$SCRIPT_DIR/reconnect.sh"

cat > "$SCRIPT_DIR/pc_watchdog.sh" << 'WEOF'
#!/usr/bin/env bash
TARGET_PING="1.1.1.1"
CHECK_INTERVAL=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while true; do
    if ! ping -c 1 -W 2 "$TARGET_PING" &>/dev/null; then
        echo "[!] Connection lost at $(date '+%H:%M:%S'). Triggering PC reconnect..." >> "$SCRIPT_DIR/watchdog.log"
        "$SCRIPT_DIR/reconnect.sh" >> "$SCRIPT_DIR/watchdog.log" 2>&1
        sleep 15
    fi
    sleep "$CHECK_INTERVAL"
done
WEOF
chmod +x "$SCRIPT_DIR/pc_watchdog.sh"

# Cleanup existing instance before starting new service
systemctl --user stop wisp-watchdog.service 2>/dev/null || true
pkill -f "pc_watchdog.sh" 2>/dev/null || true

case "$WATCHDOG_ENABLE" in
    [Yy]*)
        if command -v systemctl &>/dev/null; then
            mkdir -p ~/.config/systemd/user
            cat > ~/.config/systemd/user/wisp-watchdog.service << EOF
[Unit]
Description=PC WISP Router Watchdog
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/pc_watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
            systemctl --user daemon-reload
            systemctl --user enable --now wisp-watchdog.service >/dev/null 2>&1
            echo ""
            echo "=== Complete! Router configured & systemd service installed (Auto-starts on boot). ==="
        else
            nohup "$SCRIPT_DIR/pc_watchdog.sh" > /dev/null 2>&1 &
            echo ""
            echo "=== Complete! Router configured & background watchdog started. ==="
        fi
        ;;
    *)
        echo ""
        echo "=== Complete! Router configured. Watchdog disabled. ==="
        ;;
esac
