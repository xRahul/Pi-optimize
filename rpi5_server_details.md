# Raspberry Pi 5 Home Server: System Profile & Configuration Details

This document compiles the hardware, operating system, network, storage, swap, and Docker stack details for a high-performance Raspberry Pi 5 Home Server. Use this profile as a comprehensive prompt context for LLMs when asking about optimizations, debugging services, or making stack configuration changes.

---

## 1. Hardware Profile
*   **Model:** Raspberry Pi 5 Model B Rev 1.0 (or similar)
*   **Processor:** Broadcom BCM2712 (ARM Cortex-A76, 4 cores, 64-bit `aarch64` architecture)
*   **CPU Frequency:** Running at 2.4 GHz stock, configured with the `performance` scaling governor (persisted via `cpu-governor.service`).
*   **System Memory (RAM):** 8GB LPDDR5 (typical headless usage has low baseline RAM utilization, leaving ample buffer/cache space).
*   **Thermal Status:** Operating under active cooling (onboard hardware Active Cooler or heavy-duty heatsink) to maintain low temperatures.
*   **PCIe Config:** External PCIe port enabled with stable PCIe Gen 2.0 speeds configured (`dtparam=pciex1`, `dtparam=pciex1_gen=2` in `/boot/firmware/config.txt`) for SSD stability.
*   **Power Delivery:** Supported by official 27W 5V/5A power supply (prevents brownouts or USB current throttling).

---

## 2. Operating System & Kernel
*   **OS Distribution:** Debian GNU/Linux 13 (trixie) (Raspberry Pi OS Lite 64-bit, headless server).
*   **Kernel Version:** `6.x.y+rpt-rpi-2712` (Debian Trixie kernel suite)
*   **Log Limiting:** Systemd journald size capped (`SystemMaxUse=100M` in `/etc/systemd/journald.conf`) to prevent disk wear and reclaim space.
*   **Hardware Offloading:** Onboard Bluetooth (`dtoverlay=disable-bt`) and audio (`dtparam=audio=off`) disabled in `/boot/firmware/config.txt` to conserve power and IRQ resources.

---

## 3. Storage & Partition Layout
*   **System Disk (Boot/OS):** 
    *   **Device:** `/dev/nvme0n1` (NVMe M.2 SSD connected via M.2 HAT+ interface, partition `/dev/nvme0n1p2`).
    *   **Size:** Typical 250GB-500GB SSD.
    *   **Mount Options:** Mounted on `/` with `noatime` and `commit=60,lazytime` (reclaims metadata overhead and delays ext4 sync writes to increase SSD longevity).
    *   **SMART Health:** Monitored via `smartctl` with self-assessment status checking.
*   **Data Disk (Storage):** 
    *   **Device:** `/dev/sda1` (External USB bridge drive, labeled `BACKUP` or custom label).
    *   **Size:** Varies depending on storage requirements.
    *   **Mount Point:** `/mnt/usb` (dynamically handled by the setup suite).
    *   **Filesystem:** `vfat` (configured as standard FAT32) or `ext4`.
    *   **SMART Status:** Supported (checked via appropriate driver flags depending on the USB bridge).

---

## 4. Swap & Memory Tweaks
*   **ZRAM Swap:** Active ZRAM partition `/dev/zram0` (Size: up to 4GB, compressed using `zstd` algorithm, priority 100).
*   **Swappiness:** System-wide swappiness set to aggressive level (`vm.swappiness = 150`) to optimize memory eviction into ZRAM cache before page writeout.
*   **Flash Wear Swap Protection:** 
    *   Disk-based default swap (`dphys-swapfile`) is disabled and uninstalled.
    *   Swap entries in `/etc/fstab` are disabled by default on flash/USB boot media.
    *   Hourly swap enforcer (`disk-swap-enforcer.timer` and service) runs continuously to shut off any swap partitions dynamically spawned on physical drives.
    *   *NVMe Boot Exception:* If booting from NVMe, a 4GB static swapfile (`/swapfile`, priority 10) is created and enabled on the SSD to handle extreme memory overflow.
*   **Database/Valkey Tuning:** 
    *   MGLRU thrashing threshold: `min_ttl_ms` configured to `1000` via `/sys/kernel/mm/lru_gen/min_ttl_ms`.
    *   Transparent Hugepages (THP): Set to `madvise` to prevent memory allocation latency for database and cache structures.

---

## 5. Network & Firewall Optimizations
*   **TCP Congestion Control:** Google BBR congestion control algorithm enabled (`net.ipv4.tcp_congestion_control = bbr`).
*   **Bridge Network Drivers:** Kernel bridge filters (`br_netfilter`) configured to load at boot.
*   **Firewall Status:** UFW active.
*   **Rules Allowed:** 
    *   Standard SSH, HTTP, and HTTPS ports.
    *   Docker Subnet Rule: Port 11434 (Ollama) restricted to the local Docker network subnet (e.g., `10.8.1.0/24`) to prevent connection timeouts for automated services.
    *   Docker Interface: Unrestricted communication allowed on `docker0` bridge.
    *   Log Level: Logging disabled to prevent flash wear.

---

## 6. Docker Daemon Configuration
*   **Data Root:** `/var/lib/docker` (resides on fast NVMe drive. Skipped USB mount data-root optimization if the USB mount uses a filesystem incompatible with the `overlay2` driver).
*   **Daemon Settings (`/etc/docker/daemon.json`):**
    *   `live-restore` enabled (keeps containers running when docker daemon restarts).
    *   `userland-proxy` disabled (forces routing through docker iptables).
    *   cgroup driver set to `systemd`.
    *   `no-new-privileges` enabled (security hardening).
    *   `json-file` log driver limits: max file size `10m`, max files `3`.
*   **Startup Dependency:** Overridden systemd configuration forces Docker service to wait for `/mnt/usb` mount to complete before launching containers (preventing failures for stacks mapped to USB paths).

---

## 7. Docker Stack Categories & Architecture (General Overview)
All services run on a custom bridge network (typically a private subnet like `10.8.1.0/24`) with static IP assignments for service-to-service routing. The stack is grouped into the following functional categories:

### A. Core Network & Security Infrastructure
*   **VPN Gateway:** For secure ingress, remote administration, and mesh networking.
*   **DNS & Security Filters:** Local DNS servers and encrypted DNS upstream resolvers to route internal domains and block advertisements/telemetry.
*   **Reverse Proxy:** Automates SSL certificate generation and routes web requests.

### B. Productivity & File Management
*   **Web Dashboard:** Central portal showing health stats and service shortcuts.
*   **File Browser:** Remote file management with direct access to local storage.
*   **Media & Download Managers:** Clients for file downloading and local media libraries.

### C. Databases & Caching
*   **Key-Value Cache:** High-performance caching layer (e.g., Valkey/Redis) for system database operations.
*   **Relational Database:** Relational databases (e.g., PostgreSQL, SQLite) supporting primary application states.

### D. System Tools & Utilities
*   **Finance & Accounting:** Self-hosted double-entry bookkeeping and tracking software.
*   **Automation Engines:** Workflow engines (e.g., n8n) for routine automated tasks.
*   **Search Engine:** Private metasearch engine configured for LLM/automation ingestion.
*   **Document Processing:** Utilities for PDF manipulation and document management.
