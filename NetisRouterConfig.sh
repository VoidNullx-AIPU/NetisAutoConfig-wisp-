#!/usr/bin/env bash

set -e

echo "=================================================="
echo "    Netis / Realtek Router WISP Setup             "
echo "=================================================="
echo ""

# 1. Interactive prompts
read -rp "[?] Enter Router IP: " ROUTER_IP
read -rsp "[?] Enter Router SSH Password: " ROUTER_PASS
echo ""
read -rp "[?] Enter Target Main Router SSID: " TARGET_SSID
read -rsp "[?] Enter Target Main Router Password: " TARGET_PASS
echo ""
echo ""

# Legacy SSH parameters required for Realtek Dropbear daemon
SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc,3des-cbc -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "--------------------------------------------------"
echo "[DEBUG 1/5] Testing reachability to $ROUTER_IP..."
if ping -c 1 -W 2 "$ROUTER_IP" >/dev/null 2>&1; then
    echo "[+] SUCCESS: Router at $ROUTER_IP is reachable."
else
    echo "[!] ERROR: Cannot ping $ROUTER_IP. Check physical link."
    exit 1
fi

echo ""
echo "[DEBUG 2/5] Configuring wlan0, bouncing interface, and triggering site survey..."
sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" << EOF
  iwpriv wlan0 set_mib opmode=0x08 2>/dev/null
  iwpriv wlan0 set_mib ssid="$TARGET_SSID"
  iwpriv wlan0 set_mib passphrase="$TARGET_PASS"
  ifconfig wlan0 down
  sleep 2
  ifconfig wlan0 up
  sleep 4
  iwpriv wlan0 at_ss 2>/dev/null
  sleep 3
EOF

echo ""
echo "[DEBUG 3/5] Reading /proc/wlan0/SS_Result from router..."
SCAN_OUTPUT=$(timeout 6 sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "cat /proc/wlan0/SS_Result 2>/dev/null" || true)

if [ -n "$SCAN_OUTPUT" ]; then
    echo "[+] Scan output received:"
    echo "--------------------------------------------------"
    echo "$SCAN_OUTPUT"
    echo "--------------------------------------------------"
else
    echo "[!] WARNING: /proc/wlan0/SS_Result was empty!"
fi

echo ""
echo "[DEBUG 4/5] Extracting HwAddr for SSID '$TARGET_SSID'..."
BSSID=$(echo "$SCAN_OUTPUT" | awk -v target="$TARGET_SSID" '
  /HwAddr:/ { mac=$2 }
  /SSID:/ && $2 == target { print mac }
' | tr -d ' \r\n' | tr '[:upper:]' '[:lower:]')

if [ -z "$BSSID" ]; then
    echo "[!] WARNING: Could not find HwAddr for '$TARGET_SSID' in scan results."
    read -rp "[?] Enter BSSID manually (e.g. baafcacbe92a): " MANUAL_BSSID
    BSSID=$(echo "$MANUAL_BSSID" | tr -d ':-' | tr '[:upper:]' '[:lower:]')
else
    echo "[+] SUCCESS: Captured Target BSSID: $BSSID"
fi

echo ""
echo "[DEBUG 5/5] Executing at_join, unbridging wlan0, requesting DHCP, and applying NAT..."
echo "--------------------------------------------------"

sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" << EOF
  echo "--> Joining BSSID $BSSID..."
  iwpriv wlan0 at_join $BSSID
  brctl delif br0 wlan0 2>/dev/null || true
  sleep 4

  echo "--> Requesting DHCP lease..."
  udhcpc -i wlan0 >/dev/null 2>&1 &
  sleep 10

  echo "--> Configuring IP forwarding, NAT, and DNS redirect..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo 0 > /proc/fast_nat 2>/dev/null || true
  iptables -t nat -F
  iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
  iptables -P FORWARD ACCEPT
  iptables -F FORWARD
  iptables -t nat -A PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
  iptables -t nat -A PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1

  echo "--> Router configuration complete!"
EOF

echo "--------------------------------------------------"
echo "[+] Generating automated non-interactive script: quick_reconnect.sh..."

cat << EOF > quick_reconnect.sh
#!/usr/bin/env bash

# Hardcoded configuration generated automatically by setup_router.sh
ROUTER_IP="$ROUTER_IP"
ROUTER_PASS="$ROUTER_PASS"
TARGET_SSID="$TARGET_SSID"
TARGET_PASS="$TARGET_PASS"
BSSID="$BSSID"

SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc,3des-cbc -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo "[+] Re-applying WISP configuration to \$ROUTER_IP..."

sshpass -p "\$ROUTER_PASS" ssh \$SSH_OPTS "root@\$ROUTER_IP" << REMOTE_EOF
  echo "--> Setting station mode & credentials..."
  iwpriv wlan0 set_mib opmode=0x08
  iwpriv wlan0 set_mib ssid="$TARGET_SSID"
  iwpriv wlan0 set_mib passphrase="$TARGET_PASS"

  echo "--> Bouncing wlan0..."
  ifconfig wlan0 down
  sleep 2
  ifconfig wlan0 up
  sleep 4

  echo "--> Joining BSSID $BSSID..."
  iwpriv wlan0 at_join $BSSID
  brctl delif br0 wlan0 2>/dev/null || true
  sleep 4

  echo "--> Requesting DHCP lease..."
  udhcpc -i wlan0 >/dev/null 2>&1 &
  sleep 10

  echo "--> Configuring IP forwarding, NAT, and DNS redirect..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo 0 > /proc/fast_nat 2>/dev/null || true
  iptables -t nat -F
  iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
  iptables -P FORWARD ACCEPT
  iptables -F FORWARD
  iptables -t nat -A PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
  iptables -t nat -A PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1

  echo "--> Quick reconnect finished successfully!"
REMOTE_EOF
EOF

chmod +x quick_reconnect.sh

echo ""
echo "=================================================="
echo " Setup complete!                                  "
echo " Saved instant reconnect runner to: ./quick_reconnect.sh"
echo " Run './quick_reconnect.sh' whenever the router restarts."
echo "=================================================="
