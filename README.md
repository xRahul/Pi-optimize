# 🥧 Raspberry Pi Home Server Optimization Suite (v4.4.0)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Pi 5](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)]()
[![OS: Debian Trixie](https://img.shields.io/badge/OS-Debian%20Trixie-blue.svg)]()

A "Pro Edition" automation suite designed exclusively for the **Raspberry Pi 5** running Debian Trixie (13). This suite transforms a fresh OS installation into a hardened, high-performance, and flash-optimized Docker host, perfect for demanding self-hosted applications like media servers, database/cache backends, automated workflow engines, and local LLMs.

---

## 🚀 The "Ultimate Edition" (v4.4.0)

This suite is not just a collection of scripts; it's a comprehensive system state management tool. It prioritizes **Flash Longevity**, **IO Performance**, and **System Stability**.

### Key Highlights:
*   **Triple-Threat Flash Protection**: Extreme measures to prevent SD Card/USB Flash wear.
*   **RPi 5 Native Tuning**: Leverages Pi 5 specific features like PCIe Gen 2 (for maximum stability/endurance) and advanced thermal management.
*   **Idempotent Execution**: Safely run any script multiple times; it only applies what's missing.
*   **Production Hardening**: Includes UFW firewall, Fail2Ban, and Kernel-level security tweaks.
*   **Local AI Ready**: Optimized support for Ollama (Local LLMs) with CPU-specific tuning.

---

## 🧠 Technical Architecture

### 🛡️ Flash Media Protection (The "Triple-Threat")
Flash storage (SD/USB) is the #1 failure point for Pi servers. We mitigate this with three layers:
1.  **Volatile Logging**: `busybox-syslogd` and `systemd-journald` are configured for **RAM-only storage**, drastically reducing constant disk writes.
2.  **ZRAM Swap & NVMe Hybrid Swap**: Disk-based swap is completely purged on flash/USB media. However, if an NVMe boot drive is detected, a 4GB static swapfile (priority 10) is initialized on the SSD to handle extreme memory overflow. All configurations use ZRAM with `zstd` compression and `vm.swappiness=150` to ensure standard memory pressure is handled in-RAM.
3.  **The Enforcer**: A systemd timer (`disk-swap-enforcer`) runs hourly to ensure no rogue services (like `dphys-swapfile`) have re-enabled swap on flash drives.

### ⚡ Performance & IO Tuning
*   **CPU Governor**: Persistent `performance` mode for maximum throughput.
*   **IO Scheduler**: Forces **BFQ** for USB drives, ensuring Docker containers aren't blocked by background writes.
*   **Network Stack**: Enables **TCP BBR** congestion control and optimizes sysctl for 16k page sizes (Pi 5 default).
*   **PCIe Config**: Forces stable **PCIe Gen 2** connection and configures an aggressive fan curve (starts at 35°C) to prevent thermal throttling.

### ⛓️ System Resilience
*   **`startup-mounts.service`**: A custom "one-shot" service that ensures all USB filesystems are successfully mounted *before* the Docker daemon starts, preventing container startup failures.
*   **`tailscale-fix.service`**: Solves a common RPi 5 race condition where Tailscale starts before the network is fully up, leading to routing failures.

---

## 🔧 Script Breakdown

### 🛠 `setup.sh` (The Provisioner)
The entry point for a new system. It handles:
*   **Bulk Dependency Management**: Installs only what's needed (Docker, Node.js 22+, Git, etc.).
*   **Modern Node.js**: Uses the latest NodeSource GPG-signed repository method.
*   **Ollama Integration**: (Optional) Installs Ollama and configures it to store models on USB to save flash space.
*   **Systemd Integration**: Configures all custom services and timers.

### ⚡ `optimize.sh` (The Tuner)
The heart of the suite. It applies:
*   **Kernel Hardening**: Protects against common network attacks via `sysctl`.
*   **ZRAM Optimization**: Configures `systemd-zram-generator` with optimal Pi 5 settings.
*   **Docker Daemon Tuning**: Enables `live-restore`, `json-file` log rotation, and optimized data-root paths.
*   **Security**: Configures UFW with specific rules for internal Docker networking and n8n/Ollama connectivity.

### 🩺 `diag.sh` (The Auditor)
A senior engineer in a script. It checks:
*   **Health Score**: A percentage-based assessment of system readiness.
*   **SMART Status**: Audits the health of attached storage drives.
*   **PMIC Status**: Checks Pi 5 Power Management IC for power supply issues.
*   **Connectivity**: Verifies internal container-to-host networking.

---

## 📋 Quick Start

### Prerequisites
*   **OS**: Raspberry Pi OS Lite (64-bit) / Debian Trixie.
*   **User**: Must be run by a user with `sudo` privileges.
*   **Storage**: An SSD (NVMe or USB 3.0) is highly recommended for the OS and Docker data.

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/your-username/pi-optimize.git
cd pi-optimize

# 2. Run the Setup (Requires Sudo)
# This will provision the system and automatically run optimize.sh
sudo ./setup.sh

# 3. Verify System Health
sudo ./diag.sh
```

---

## 🔍 Troubleshooting

**Q: Why is swappiness set to 150?**  
A: With ZRAM, a high swappiness value is actually better. It encourages the kernel to move idle pages into compressed RAM early, leaving more "real" RAM for active processes.

**Q: My USB drive didn't mount automatically?**  
A: The script attempts to find the largest non-system partition and add it to `/etc/fstab`. If you have a complex setup, you may need to manually adjust `/etc/fstab`.

**Q: How do I see the logs?**  
A: All optimization logs are at `/var/log/rpi-optimize.log`. Diagnostic logs are at `/var/log/rpi-diag.log`.

---

## 📜 License
MIT License - Copyright (c) 2025 <copyright-holder>.
