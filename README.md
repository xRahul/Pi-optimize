# 🥧 Raspberry Pi Home Server Optimization Suite (v4.2.0)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Pi 5](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)]()
[![OS: Debian Trixie](https://img.shields.io/badge/OS-Debian%20Trixie-blue.svg)]()

A "Pro Edition" automation suite for Raspberry Pi 5. This project transforms a fresh Raspberry Pi OS Lite installation into a hardened, high-performance, and flash-optimized Docker host.

---

## 🚀 The "Ultimate Edition" Upgrade (v4.x)

The suite has been completely rewritten for **Debian Trixie (13)** and **Raspberry Pi 5**, moving from simple scripts to a robust automation framework.

### Key Improvements:
*   **Idempotency**: All scripts can be run multiple times safely.
*   **Redundancy**: Triple-layer checks for critical configurations (Docker, USB, Network).
*   **Security First**: Integrated Firewall (UFW) management and Kernel hardening.
*   **Reliability**: Lock files prevent parallel runs; trap handlers manage errors.
*   **Pro Diagnostics**: Health scoring system with SMART disk monitoring.

---

## 🧠 Technical Deep Dive

### 1. Performance & Thermals
*   **Aggressive Cooling**: Fan starts at 35°C (Pi 5 specific) to prevent thermal jitter.
*   **CPU Performance**: Sets persistent `performance` governor for maximum responsiveness.
*   **I/O Scheduling**: Forces **BFQ scheduler** for USB/SD storage to handle random I/O (Docker) better.

### 2. Flash Longevity & Storage
*   **Swapoff**: Permanently disables disk-based swap to save storage wear.
*   **ZRAM Only**: Uses compressed RAM (`zstd`) for emergency memory needs.
*   **USB Optimization**: Disables USB autosuspend and increases `min_free_kbytes` for stability on flash drives.
*   **Write Minimization**: Implements `noatime`, `busybox-syslogd` (RAM logging), and volatile journald.

### 3. Network & Docker
*   **Google BBR**: Enables BBR congestion control for superior throughput.
*   **Docker Hardening**: Configures `no-new-privileges`, log rotation, and `live-restore`.
*   **Automated Mounts**: Robust UUID-based mounting for USB storage.

---

## 📋 Quick Start

### Prerequisites
1.  **Hardware**: Raspberry Pi 5.
2.  **OS**: Raspberry Pi OS Lite (64-bit).
3.  **Storage**: High-speed USB 3.0 Flash Drive or SSD (Running OS from USB is recommended).

### Installation

```bash
# 1. Clone & Enter
git clone https://github.com/xRahul/Pi-optimize.git
cd Pi-optimize

# 2. Setup (The "One-Shot" Command)
# Installs dependencies, Docker, Node.js, mounts USB, and runs optimize.sh automatically.
# Detects USB boot and skips existing packages.
sudo ./setup.sh

# 3. Verify
sudo ./diag.sh
```

---

## 🔧 Script Breakdown

### 🛠 `setup.sh` (The Provisioner)
*   **Smart Install**: Checks for existing packages to avoid redundant operations.
*   **USB Detect**: Warns if not booting from USB for optimal performance.
*   **Ollama AI**: (Optional) Installs and optimizes Ollama for local LLM inference on Pi 5.
*   **Dependencies**: Installs `fail2ban`, `ufw`, `rng-tools5`, `busybox-syslogd`, and more.
*   **Integration**: Automatically invokes `optimize.sh`.

### ⚡ `optimize.sh` (The Tuner)
*   **Swap**: Removes `dphys-swapfile` and sets `vm.swappiness=1` for minimal swapping.
*   **Kernel**: Hardens `sysctl` settings, enables BBR, and tunes memory for USB I/O.
*   **Network Repair**: Auto-detects Tailscale and installs a boot-time connectivity fix.
*   **Maintenance**: Prunes Docker, clears documentation, and configures the firewall.

### 🩺 `diag.sh` (The Auditor)
*   **Health Score**: Provides a percentage-based readiness score.
*   **Advanced Checks**: Zombie processes, failed systemd units, SMART status, and Tailscale connectivity.

---

## 🔍 Troubleshooting

### Docker is not using the USB drive?
Ensure your USB drive is formatted as **ext4** or **btrfs**. FAT32/exFAT are not recommended for Docker storage due to permission issues, though the scripts attempt to mitigate this.

### How to check logs?
Optimization logs are stored at `/var/log/rpi-optimize.log`.

---

## 📜 License
MIT License - Copyright (c) 2025 Rahul.
