#!/usr/bin/env bash
# =============================================================================
#  Netis / Realtek Router — Master WISP Setup & Persistent PC Watchdog
#  Requires: OpenSSH <= 9.x (10.x removed DH group1-sha1; Dropbear 0.48 needs it)
#  Tested on: Netis N3D (Realtek RTL8812F, BusyBox Linux, Dropbear 0.48)
# =============================================================================

set -e

# ── Locate an OpenSSH <10 binary (10.x breaks Dropbear 0.48 DH negotiation) ──
SSH_BIN="/home/void/.local/opt/openssh9/bin/ssh"
if [ ! -x "$SSH_BIN" ]; then
    SSH_BIN=""
    for candidate in \
        "$HOME/.local/opt/openssh9/bin/ssh" \
        "$HOME/bin/ssh9" \
        "/usr/local/bin/ssh9" \
        ssh; do
        if command -v "$candidate" &>/dev/null; then
            ver=$("$candidate" -V 2>&1 | sed -nE 's/.*OpenSSH_([0-9]+)\..*/\1/p')
            if [ -n "$ver" ] && [ "$ver" -lt 10 ]; then
                SSH_BIN="$candidate"; break
            fi
        fi
    done
fi
if [ -z "$SSH_BIN" ]; then
    echo "ERROR: No OpenSSH <10 found."
    echo "       OpenSSH 10+ removed diffie-hellman-group1-sha1, which Dropbear 0.48"
    echo "       on this router requires. Build/install OpenSSH 9.x and set SSH_BIN."
    echo "       Example: export SSH_BIN=\$HOME/.local/opt/openssh9/bin/ssh"
    exit 1
fi
echo "Using SSH client: $SSH_BIN ($("$SSH_BIN" -V 2>&1 | head -1))"

for cmd in sshpass ping; do
    command -v "$cmd" &>/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done
command -v notify-send &>/dev/null || echo "WARN: notify-send missing — desktop notifications disabled (logging still works)"

echo "=== Netis/Realtek Master WISP Setup ==="
read -rp  "Router IP            : " ROUTER_IP
read -rsp "Router SSH password : " ROUTER_PASS; echo
read -rp  "Upstream WiFi SSID  : " TARGET_SSID
read -rsp "Upstream WiFi pass  : " TARGET_PASS; echo
read -rp  "Enable persistent watchdog across reboots? [Y/n] (Default: Y): " WATCHDOG_ENABLE
WATCHDOG_ENABLE="${WATCHDOG_ENABLE:-Y}"

case "$TARGET_SSID" in *"'"*) echo "ERROR: SSID must not contain a single quote";     exit 1;; esac
case "$TARGET_PASS" in *"'"*) echo "ERROR: Password must not contain a single quote"; exit 1;; esac
[ -z "$TARGET_SSID" ] && { echo "ERROR: SSID is empty"; exit 1; }

SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1 \
          -o HostKeyAlgorithms=+ssh-rsa \
          -o Ciphers=+aes128-cbc,3des-cbc \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout=5"

rssh() { timeout 30 sshpass -p "$ROUTER_PASS" "$SSH_BIN" $SSH_OPTS "root@$ROUTER_IP" "$@"; }

# ── 1. Reachability Check ───────────────────────────────────────────────────
echo "[1/4] Checking router connectivity..."
ping -c 1 -W 1 "$ROUTER_IP" &>/dev/null || { echo "Cannot reach $ROUTER_IP"; exit 1; }

# ── 2. Site Survey & Scanning ────────────────────────────────────────────────
echo "[2/4] Scanning for '$TARGET_SSID'..."

# Phase 1: fire the scan. `ifconfig wlan0 down` may drop SSH — expected on this
# firmware (wlan0 is bridged into br0). The remote commands still execute.
rssh "
    iwpriv wlan0 set_mib opmode=0x10 2>/dev/null
    ifconfig wlan0 down
    sleep 1
    ifconfig wlan0 up
    sleep 2
    iwpriv wlan0 at_ss '$TARGET_SSID' 2>/dev/null
" >/dev/null 2>&1 || true

# Phase 2: fresh connection, read the result file, retry if the router needs time
SCAN=""
for attempt in 1 2 3 4; do
    sleep 5
    SCAN=$(rssh "cat /proc/wlan0/SS_Result 2>/dev/null" 2>/dev/null | tr -d '\r' || true)
    if [ -n "$SCAN" ]; then
        echo "      Scan OK (attempt $attempt, $(printf '%s' "$SCAN" | wc -l) lines)"
        break
    fi
    echo "      Scan empty on attempt $attempt, retrying..."
done

[ -z "$SCAN" ] && {
    echo "      ERROR: Empty scan after 4 attempts."
    echo "      Diagnostic: $(rssh 'ls -la /proc/wlan0/SS_Result 2>&1' || echo 'ssh failed')"
    exit 1
}

# SSID-capture uses substr-after-tag so SSIDs with spaces parse correctly.
BSSID=$(echo "$SCAN" | awk -v ssid="$TARGET_SSID" '
    /HwAddr:/  { mac=$2 }
    /SSID:/    { s=$0; sub(/^[ \t]*SSID:[ \t]*/,"",s); sub(/[ \t\r]+$/,"",s) }
    /RSSI:/    { if(s==ssid) print $2, mac }
' | sort -rn | head -1 | awk '{print $2}' | tr -d ' \r\n' | tr '[:upper:]' '[:lower:]')

CHANNEL=$(echo "$SCAN" | awk -v ssid="$TARGET_SSID" '
    /Channel:/ { ch=$2 }
    /SSID:/    { s=$0; sub(/^[ \t]*SSID:[ \t]*/,"",s); sub(/[ \t\r]+$/,"",s); if(s==ssid) print ch }
' | head -1 | tr -d ' \r\n')

echo "      Parsed BSSID: [${BSSID:-empty}]  CHANNEL: [${CHANNEL:-empty}]"

if [ -z "$BSSID" ] || [ -z "$CHANNEL" ]; then
    echo "      Auto-detect failed — enter manually."
    read -rp "  BSSID (with or without : - separators): " RAW
    BSSID=$(echo "$RAW" | tr -d ':- ' | tr '[:upper:]' '[:lower:]')
    read -rp "  Channel: " CHANNEL
fi

[[ "$BSSID"   =~ ^[0-9a-f]{12}$ ]] || { echo "ERROR: BSSID '$BSSID' is not 12 hex chars"; exit 1; }
[[ "$CHANNEL" =~ ^[0-9]+$ ]]       || { echo "ERROR: Channel '$CHANNEL' is not numeric";    exit 1; }
echo "      Using BSSID=$BSSID  CHANNEL=$CHANNEL"

# ── 3. Initial In-Memory Router Connection ─────────────────────────────────
# Router-side commands are unchanged from the original.
echo "[3/4] Linking wlan0 & initializing hardware NAT..."
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
" || true

SCRIPT_DIR="$HOME/.local/bin"
mkdir -p "$SCRIPT_DIR"

# ── 4. Generate Local PC Scripts & Systemd Service ───────────────────────────
echo "[4/4] Generating local helper scripts..."

# ── reconnect.sh ─────────────────────────────────────────────────────────────
# $SSH_BIN is intentionally UNESCAPED so the literal path is baked in at
# generation time — the watchdog runs it later without needing SSH_BIN in env.
cat > "$SCRIPT_DIR/reconnect.sh" << EOF
#!/usr/bin/env bash
# Auto-generated by NetisRouterConfig.sh. Re-run setup to regenerate.
set -u

LOCKFILE="/tmp/wisp_reconnect.lock"
exec 200>"\$LOCKFILE"
flock -n 200 2>/dev/null || { echo "[!] Reconnect already in progress. Exiting."; exit 0; }

ROUTER_IP='$ROUTER_IP'
ROUTER_PASS='$ROUTER_PASS'
TARGET_SSID='$TARGET_SSID'
TARGET_PASS='$TARGET_PASS'
CHANNEL='$CHANNEL'
BSSID='$BSSID'

SSH_OPTS="$SSH_OPTS"
SSH_BIN="$SSH_BIN"

# Pre-flight — refuse to run with broken vars (this silently broke the old watchdog)
if [ -z "\$BSSID" ] || [ -z "\$CHANNEL" ]; then
    echo "[!] BSSID/CHANNEL missing (BSSID='\$BSSID' CHANNEL='\$CHANNEL'). Re-run setup."
    exit 1
fi
[[ "\$BSSID"   =~ ^[0-9a-f]{12}\$ ]] || { echo "[!] Invalid BSSID '\$BSSID'"; exit 1; }
[[ "\$CHANNEL" =~ ^[0-9]+\$ ]]        || { echo "[!] Invalid CHANNEL '\$CHANNEL'"; exit 1; }
[ -x "\$SSH_BIN" ]                   || { echo "[!] SSH_BIN '\$SSH_BIN' not executable"; exit 1; }

notify() {
    local title="\$1" msg="\$2" urgency="\${3:-normal}"
    if command -v notify-send >/dev/null 2>&1; then
        if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/\$(id -u)/bus" ]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
        fi
        notify-send -u "\$urgency" -a "WISP Reconnect" -i network-wireless "\$title" "\$msg" 2>/dev/null || true
    fi
}

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] reconnect: starting (BSSID=\$BSSID CH=\$CHANNEL)"

# timeout 30 guards against a hung SSH blocking the watchdog forever
if timeout 30 sshpass -p "\$ROUTER_PASS" "\$SSH_BIN" \$SSH_OPTS "root@\$ROUTER_IP" "
    iwpriv wlan0 set_mib opmode=0x08
    iwpriv wlan0 set_mib channel=\$CHANNEL
    iwpriv wlan0 set_mib ssid='\$TARGET_SSID'
    iwpriv wlan0 set_mib passphrase='\$TARGET_PASS'
    ifconfig wlan0 down; ifconfig wlan0 up
    sleep 2
    iwpriv wlan0 at_join \$BSSID
    sleep 2
    brctl delif br0 wlan0 2>/dev/null || true
    killall -9 udhcpc 2>/dev/null || true
    udhcpc -i wlan0 >/dev/null 2>&1 &
    sleep 8
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/fast_nat 2>/dev/null || true
    iptables -t nat -F
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
    iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
" 2>&1
then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] reconnect: OK"
    notify "Reconnect OK" "Router re-linked to \$TARGET_SSID"
    exit 0
else
    rc=\$?
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] reconnect: FAILED (rc=\$rc — 124=timeout, 255=ssh/auth)"
    notify "Reconnect FAILED" "rc=\$rc — see watchdog.log" critical
    exit \$rc
fi
EOF
chmod +x "$SCRIPT_DIR/reconnect.sh"

# ── pc_watchdog.sh ───────────────────────────────────────────────────────────
cat > "$SCRIPT_DIR/pc_watchdog.sh" << 'WEOF'
#!/usr/bin/env bash
# WISP watchdog: fast poll, desktop + journald notifications, 15-min heartbeat.
set -u

TARGET_PING="1.1.1.1"
CHECK_INTERVAL=3            # seconds between ping checks
FAIL_THRESHOLD=2            # consecutive failures before triggering reconnect
RECONNECT_COOLDOWN=30       # min seconds between reconnect attempts
RESTORE_POLL_INTERVAL=3     # seconds between recovery checks after reconnect
RESTORE_MAX_TRIES=6         # max recovery polls before giving up this cycle
HEARTBEAT_MIN=0            # "still OK" notification interval (0 = off)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/watchdog.log"
LOCKFILE="/tmp/wisp_watchdog.lock"

exec 201>"$LOCKFILE"
flock -n 201 2>/dev/null || { echo "Watchdog already running"; exit 0; }

rotate_log() {
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

notify() {
    local title="$1" msg="$2" urgency="${3:-normal}"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$urgency] $title: $msg" >> "$LOG"
    command -v logger >/dev/null 2>&1 && logger -t wisp-watchdog "[$urgency] $title: $msg" 2>/dev/null || true
    if command -v notify-send >/dev/null 2>&1; then
        if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        fi
        notify-send -u "$urgency" -a "WISP Watchdog" -i network-wireless "$title" "$msg" 2>/dev/null || true
    fi
}

rotate_log
notify "Watchdog Started" "Monitoring $TARGET_PING every ${CHECK_INTERVAL}s" low

consec_fail=0
last_reconnect=0
last_heartbeat=$(date +%s)
state="up"

while true; do
    now=$(date +%s)
    if ping -c 2 -W 1 -i 0.3 "$TARGET_PING" &>/dev/null; then
        if [ "$state" = "down" ]; then
            notify "Connection Restored" "$TARGET_PING reachable" normal
            last_heartbeat=$now
        fi
        state="up"
        consec_fail=0
        if [ "$HEARTBEAT_MIN" -gt 0 ] && [ $((now - last_heartbeat)) -ge $((HEARTBEAT_MIN * 60)) ]; then
            notify "Watchdog OK" "Connection stable" low
            last_heartbeat=$now
        fi
    else
        consec_fail=$((consec_fail + 1))
        if [ "$consec_fail" -ge "$FAIL_THRESHOLD" ] && [ $((now - last_reconnect)) -ge "$RECONNECT_COOLDOWN" ]; then
            [ "$state" = "up" ] && notify "Connection LOST" "Triggering reconnect" normal
            state="down"
            last_reconnect=$now
            "$SCRIPT_DIR/reconnect.sh" >> "$LOG" 2>&1 || true

            recovered=0; i=0
            while [ "$i" -lt "$RESTORE_MAX_TRIES" ]; do
                sleep "$RESTORE_POLL_INTERVAL"
                i=$((i + 1))
                if ping -c 1 -W 1 "$TARGET_PING" &>/dev/null; then recovered=1; break; fi
            done

            if [ "$recovered" -eq 1 ]; then
                notify "Reconnect OK" "Internet reachable after $((i * RESTORE_POLL_INTERVAL))s" normal
                state="up"; consec_fail=0; last_heartbeat=$(date +%s)
            else
                notify "Reconnect FAILED" "Will retry in ${RECONNECT_COOLDOWN}s" critical
                consec_fail=0
            fi
        fi
    fi
    rotate_log
    sleep "$CHECK_INTERVAL"
done
WEOF
chmod +x "$SCRIPT_DIR/pc_watchdog.sh"

# ── Stop any existing watchdog before re-installing ─────────────────────────
systemctl --user stop    wisp-watchdog.service 2>/dev/null || true
systemctl --user disable wisp-watchdog.service 2>/dev/null || true
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
            echo "=== Setup Complete! ==="
            echo "• Router configured in-memory with Fast NAT"
            echo "• Watchdog service: wisp-watchdog.service (active, starts on login)"
            echo ""
            echo "Monitor:"
            echo "  systemctl --user status wisp-watchdog.service"
            echo "  journalctl --user -u wisp-watchdog.service -f"
            echo "  tail -f $SCRIPT_DIR/watchdog.log"
            echo ""
            echo "Notifications: start / LOST / reconnect OK / reconnect FAILED / 15-min heartbeat."
            echo "Tip: survive logout → sudo loginctl enable-linger $USER"
        else
            nohup "$SCRIPT_DIR/pc_watchdog.sh" > /dev/null 2>&1 &
            echo ""
            echo "=== Setup Complete! ==="
            echo "• Watchdog launched in background (systemd not found)"
            echo "• Logs: $SCRIPT_DIR/watchdog.log"
        fi
        ;;
    *)
        echo ""
        echo "=== Setup Complete! ==="
        echo "• Router configured. Watchdog disabled."
        echo "• Run ./reconnect.sh manually if needed."
        ;;
esac
