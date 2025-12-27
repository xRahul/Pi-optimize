# Raspberry Pi Home Server Setup & Optimization Suite

A production-ready automation suite for Raspberry Pi 5 (Debian Trixie). This project turns a fresh Raspbian Lite installation into a robust, self-healing, and high-performance Docker host.

**Target Hardware**: Raspberry Pi 5 (8GB RAM recommended)  
**Target OS**: Raspberry Pi OS Lite (Debian 13 "Trixie")  
**Design Goal**: Performance, Flash Memory Longevity, and "Set-it-and-Forget-it" Reliability.

---

## 🧠 Technical Deep Dive: Why are we doing this?

This suite applies specific kernel and system tuning. Here is the detailed rationale behind every major change:

### 1. Storage Strategy (USB vs SD Card)
*   **The Problem**: SD cards are slow (UHS-I limits) and prone to corruption under heavy write loads (like Docker logs or databases).
*   **The Solution**: We force Docker to use an external USB 3.0 drive.
*   **Why `ext4`?**: Docker's `overlay2` storage driver (the industry standard for performance) requires a filesystem that supports **d_type** (directory entry type). FAT32/exFAT do not support this. Using them causes Docker to fall back to `vfs`, which is extremely slow and space-inefficient.
    *   *Impact*: `setup.sh` strictly enforces `ext4` for Docker storage to prevent massive performance degradation.

### 2. Flash Memory Longevity (`commit=600`, `noatime`)
*   **The Problem**: Linux defaults to writing metadata (atime) every time a file is read, and flushing data to disk every 5 seconds (commit=5). On flash storage (SSD/SD), this causes "write amplification," shortening drive lifespan.
*   **The Solution**:
    *   `noatime`: Disables recording "last accessed time". Reading a file no longer generates a write.
    *   `commit=600`: Tells the filesystem to accumulate small writes in RAM and flush them to disk only once every 10 minutes (600s).
    *   *Reference*: [Linux Kernel Ext4 Docs](https://www.kernel.org/doc/Documentation/filesystems/ext4.txt)

### 3. Memory Optimization (ZRAM vs Swapfile)
*   **The Problem**: When RAM is full, Linux swaps to disk. Swapping to an SD card or USB drive stalls the system (IO thrashing) and wears out the flash cells.
*   **The Solution**: **ZRAM**. We create a block device in RAM that acts as swap. Data sent to it is compressed (using `zstd` algorithm).
*   **Why?**: RAM is nanoseconds fast; Disk is milliseconds slow. Compressing data in RAM is orders of magnitude faster than writing to disk. This effectively expands your usable RAM without touching the disk.
    *   *Action*: `optimize.sh` disables `dphys-swapfile` (disk swap) and enables `zram0`.

### 4. Network Performance (TCP BBR)
*   **The Problem**: The default TCP congestion control (`Cubic`) handles packet loss poorly, often treating transient loss as congestion, which slashes throughput—common on home WiFi or consumer ISPs.
*   **The Solution**: **Google's TCP BBR** (Bottleneck Bandwidth and Round-trip propagation time).
*   **Why?**: BBR models the network pipe to maximize throughput and minimize latency, rather than reacting blindly to packet loss. It significantly improves speed on unstable connections.
    *   *Reference*: [Google BBR Congestion Control](https://cloud.google.com/blog/products/networking/tcp-bbr-congestion-control-comes-to-gcp-your-internet-just-got-faster)

### 5. Headless Reliability (Hardware Watchdog)
*   **The Problem**: If a headless server freezes (kernel panic, load spike), you have to physically unplug it to restart it.
*   **The Solution**: The Raspberry Pi 5 has a built-in hardware timer (Watchdog).
*   **How it works**: The OS must "kick" (reset) this timer every 10 seconds. If the OS freezes and fails to kick it, the hardware physically cuts power and reboots the system.
    *   *Impact*: Ensures the server is always available, even after a crash.

### 6. System Cleanliness (ModemManager & Docs)
*   **ModemManager**: This service scans serial ports looking for cellular modems. It famously conflicts with Zigbee/Z-Wave USB sticks used in Home Assistant, making them unusable. Removing it prevents this headache.
*   **Documentation**: On a headless server managed via automation, 200MB+ of man pages and `/usr/share/doc` are dead weight. Removing them speeds up updates and saves backup space.

---

## 📋 Quick Start

### Prerequisites
1.  **Hardware**: Raspberry Pi 5 (The scripts tune specific thermal/hardware settings for Pi 5).
2.  **OS**: Raspberry Pi OS Lite (Debian Trixie). Fresh install recommended.
3.  **Storage**: External USB 3.0 SSD/HDD connected.
    *   *Note*: USB 2.0 is too slow for Docker. Use the blue ports.
4.  **Install Git**: `sudo apt update && sudo apt install -y git`

### Installation

```bash
# 1. Clone this repository
git clone https://github.com/xRahul/Pi-optimize.git
cd Pi-optimize

# 2. Run Setup (Interactive)
# Installs Docker, Node.js, Gemini CLI, Syncthing, and mounts USB
sudo ./setup.sh

# 3. Optimize (After Reboot)
# Applies Kernel tuning, BBR, Watchdog, ZRAM
sudo ./optimize.sh

# 4. Verify
./diag.sh
```

---

## 🔧 Script Breakdown

### 1. `setup.sh` (The Foundation)
Sets up the environment from scratch.
*   **Dependency Management**: Installs `git`, `curl`, `jq`, `bc` (math), `watchdog`, `e2fsprogs` (formatting).
*   **USB Handling**:
    *   Checks if the USB drive is formatted.
    *   **Feature**: Offers to auto-format to `ext4` if undefined (Crucial for Docker).
    *   Mounts to `/mnt/usb` and configures `/etc/fstab` for boot persistence using **UUIDs** (preventing mount failures if USB ports change).
*   **Software Stack**:
    *   **Docker**: Installs official Docker CE.
    *   **Node.js**: Installs LTS version from NodeSource.
    *   **Gemini CLI**: Installs `gemini-chat-cli` and creates `~/.gemini/settings.json` with **Preview Features Enabled**.
    *   **Syncthing**: Installs Syncthing from official repo and optimizes inotify limits.

### 2. `optimize.sh` (The Tuning)
Applies the "Deep Dive" configurations.
*   **Kernel**: Applies `net.ipv4.tcp_congestion_control = bbr`.
*   **Services**: Enables `watchdog` service and `zram`.
*   **Docker**: Edits `systemd` override to ensure `dockerd` starts **after** `/mnt/usb` is mounted (`RequiresMountsFor=/mnt/usb`).
*   **Cleanup**: Purges `triggerhappy` (hotkey daemon, useless on server), `modemmanager` (interferes with serial), and docs.
*   **Thermals**: Configures aggressive fan curves to keep Pi 5 cool (starts fan at 35°C).

### 3. `diag.sh` (The Verification)
A read-only auditor.
*   **Checks**: Temperatures, Throttling, Mount Options (`noatime` present?), Docker Storage Path, DNS Resolution.
*   **Robustness**: Uses `getent` if `nslookup` is missing; integer math if `bc` is missing.

---

## 🔍 Verification & Troubleshooting

### Why is Docker running on SD card instead of USB?
If your USB drive is formatted as FAT32 (vfat) or exFAT, `setup.sh` intentionally forces Docker to use the SD card.
*   **Reason**: Docker *cannot* run reliably on FAT filesystems (no permissions/symlinks/overlayfs support).
*   **Fix**: Run `setup.sh` again and choose "Yes" when asked to format the USB drive to **ext4**.

### How do I know BBR is working?
```bash
sysctl net.ipv4.tcp_congestion_control
# Output should be: bbr
```

### Is the Watchdog active?
```bash
systemctl status watchdog
# Status should be: active (running)
```
*   **Test it**: (Warning: This will reboot your Pi!) `sudo kill -9 $(pidof watchdog)` is safe, but to test the *hardware* reboot, you'd need to freeze the kernel (fork bomb), which is risky. Just trust the service status.

### Verify Gemini CLI Config
```bash
cat ~/.gemini/settings.json
# Should show: "previewFeatures": true
```

---

## 📜 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.