# Netis / Realtek Router WISP CLI Auto-Configurator

An automated Bash tool for configuring WISP (Wireless Internet Service Provider) / Station mode on Netis and Realtek-based routers via SSH. 

This script automates setting network parameters, triggering site surveys, extracting target BSSIDs, removing wlan0 from bridge interfaces, acquiring DHCP leases, and setting up IPv4 NAT routing.

---

## Features

- **Automated Survey & Join:** Triggers `at_ss` site survey and automatically parses `/proc/wlan0/SS_Result` for target SSID BSSIDs.
- **MIB Configuration:** Configures Wireless station mode (`opmode=0x08`), SSID, and passphrase using `iwpriv`.
- **Interface & Bridge Management:** Isolates `wlan0` from `br0` to prevent network loops while maintaining local LAN routing.
- **NAT & Forwarding:** Configures `iptables` IP forwarding, masquerading, and forces DNS redirection through Cloudflare (`1.1.1.1`).
- **One-Click Reconnect Generator:** Automatically generates a local `quick_reconnect.sh` script pre-filled with credentials for rapid re-connection without interactive prompts.

---

## Prerequisites

On your host machine (Linux/macOS/WSL):
- `bash`
- `sshpass`
- `timeout`
- `ping`

On the target router:
- Root SSH access enabled (Dropbear default on most Netis models).

---

## Installation & Usage

1. **Clone the repository:**
   ```bash
   git clone 'https://github.com/VoidNullx-AIPU/NetisAutoConfig-wisp-.git'
   cd netis-wisp-autoconfig


**THE TUTORIAL IS IN THIS VIDEO**
