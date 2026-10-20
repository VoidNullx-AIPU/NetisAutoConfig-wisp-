---

## Update — Major Fixes & Watchdog Rework

A batch of fixes and quality-of-life improvements have landed since the initial release. If you're running an older copy, update your `NetisRouterConfig.sh`.

### Breaking change: OpenSSH 10.x is not supported

** OpenSSH 10+ removed `diffie-hellman-group1-sha1` entirely ** — it's not disabled-by-default, the implementation is *gone*. The router (Dropbear 0.48, 2008) only speaks that kex, so connections from OpenSSH 10 clients fail at `expecting SSH2_MSG_KEX_ECDH_REPLY` with `Connection reset by peer`.

**Fix:** The script now auto-detects and uses an **OpenSSH 9.x binary** if available:

1. `$HOME/.local/opt/openssh9/bin/ssh`
2. `$HOME/bin/ssh9`
3. `/usr/local/bin/ssh9`
4. Falls back to `ssh` on `PATH` only if it reports version < 10

Override explicitly with `export SSH_BIN=/path/to/openssh9/bin/ssh`. Build 9.9p2 locally without touching the system OpenSSH:

```bash
wget https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz
tar -xzf openssh-9.9p2.tar.gz && cd openssh-9.9p2
./configure --prefix=$HOME/.local/opt/openssh9
make && make install
```

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
[![Watch the video](https://youtube.com)](https://youtu.be/z5xL6qee1HY)
