# 🥧 Raspberry Pi Home Server Optimization Suite (v4.6.1)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Pi 5](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)]()
[![OS: Debian Trixie](https://img.shields.io/badge/OS-Debian%20Trixie-blue.svg)]()

A "Pro Edition" automation suite designed exclusively for the **Raspberry Pi 5** running Debian Trixie (13). This suite transforms a fresh OS installation into a hardened, high-performance, and flash-optimized Docker host, perfect for demanding self-hosted applications like media servers, database/cache backends, automated workflow engines, and local LLMs.

---

## 🚀 The "Ultimate Edition" (v4.6.1)

This suite is not just a collection of scripts; it's a comprehensive system state management tool. It prioritizes **Flash Longevity**, **IO Performance**, and **System Stability**.

### Key Highlights:
*   **Triple-Threat Flash Protection**: Extreme measures to prevent SD Card/USB Flash wear.
*   **RPi 5 Native Tuning**: Leverages Pi 5 specific features like PCIe Gen 2 (for maximum stability/endurance) and advanced thermal management.
*   **Idempotent Execution**: Safely run any script multiple times; it only applies what's missing.
*   **Production Hardening**: Includes UFW firewall (managed rules) and Fail2Ban (installed with distro defaults; sshd jail auto-enabled).
*   **Local AI Ready**: Optimized support for Ollama (Local LLMs) with CPU-specific tuning.

---

## 🧠 Technical Architecture

### 🛡️ Flash Media Protection (The "Triple-Threat")
Flash storage (SD/USB) is the #1 failure point for Pi servers. We mitigate this with three layers:
1.  **Media-Aware Logging**: On flash boots, `systemd-journald` runs volatile (RAM-only) and `busybox-syslogd` is installed for RAM-only syslog *unless rsyslog is already present* (the suite never removes a working syslog on its own). On NVMe boots, persistent `rsyslog` logging is deliberately kept — SSDs tolerate writes.
2.  **ZRAM Swap & NVMe Hybrid Swap**: Disk-based swap is purged on flash/USB media. On an NVMe boot drive, a 4GB static swapfile (priority 10) handles memory overflow alongside ZRAM (`zstd`, `vm.swappiness=150`). On Debian Trixie, `rpi-swap` is the single swap manager; the suite removes any competing `zram-generator.conf`.
3.  **The Enforcer**: A systemd timer (`disk-swap-enforcer`) runs hourly on flash systems to ensure no rogue services (like `dphys-swapfile`) have re-enabled swap.

### ⚡ Performance & IO Tuning
*   **CPU Governor**: Persistent `performance` mode for maximum throughput.
*   **IO Scheduler**: Forces **BFQ** for rotational USB drives and `none` for NVMe — applied at runtime *and* persisted via a udev rule so it survives reboots.
*   **Network Stack**: Enables **TCP BBR** congestion control, loose `rp_filter` (Tailscale/failover-safe), and sysctl tuned for 16k page sizes (Pi 5 default).
*   **PCIe Config**: Forces stable **PCIe Gen 2** connection and configures a quiet fan curve (starts at 50°C) to prevent thermal throttling without idle noise.

### ⛓️ System Resilience
*   **`startup-mounts.service`**: A custom "one-shot" service that ensures all USB filesystems are successfully mounted *before* the Docker daemon starts, preventing container startup failures.

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
*   **ZRAM Optimization**: Single swap-manager policy — `rpi-swap` owns zram on Trixie; competing generators are removed.
*   **Docker Daemon Tuning**: Enables `live-restore`, `json-file` log rotation, and optimized data-root paths.
*   **Security**: Configures UFW with specific rules for internal Docker networking and n8n/Ollama connectivity. Note: Docker published ports (`-p`) bypass UFW INPUT rules via the DOCKER chain — restrict them via the `DOCKER-USER` iptables chain or bind to localhost/tailscale only. Ollama binds to `127.0.0.1` by default (v4.6.1+); existing overrides that set `OLLAMA_HOST=0.0.0.0` are preserved — an unauthenticated model API on your LAN is a deliberate choice, not a default.

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
git clone <your-fork-url> pi-optimize
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
