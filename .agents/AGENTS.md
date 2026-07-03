# Raspberry Pi Home Server Optimization Suite

## Project Overview

The **Raspberry Pi Home Server Optimization Suite (v4.4.0)** is a "Pro Edition" automation suite designed specifically for the Raspberry Pi 5 running Debian Trixie (13) (Raspberry Pi OS Lite 64-bit). The project transforms a fresh OS installation into a hardened, high-performance, and flash-optimized Docker host. 

## Gemini CLI "Pro" Setup (Optimization)

The Gemini CLI has been optimized for this environment with the following enhancements:

### 1. Model Context Protocol (MCP) Servers
- **Filesystem**: Direct access to `/home/<user>/scripts` and `/mnt/usb`.
- **Git**: Local Git operations (status, diff, log, commit).
- **Docker**: Container monitoring and management via local daemon.

### 2. Custom Skills
- **`rpi-ops`**: A specialized skill that gives the agent expertise in using the project's scripts (`setup.sh`, `optimize.sh`, `diag.sh`) and follows flash-protection best practices.

### 3. Performance Tuning
- **Parallelism**: `maxConcurrency` set to 5 for RPi 5.
- **Context Management**: 
    - `maxSessionTurns`: 30
    - `truncateToolOutputThreshold`: 3000 (Prevents context bloat from long script logs).
    - `compressionThreshold`: 0.3

## Building and Running

*   **Idempotency & Reliability:** Scripts can be safely run multiple times. Includes lock files and trap handlers.
*   **Performance:** Configures CPU governor to `performance`, aggressive cooling fan curves, and BBR network congestion control.
*   **Flash Longevity:** Disables disk-based swap (uses ZRAM by default), sets up `noatime` mounts, RAM-based logging (`busybox-syslogd`), and volatile journald to reduce SD card/USB wear. On NVMe systems, configures a static SSD swapfile for memory overflow.
*   **Security:** Integrated UFW firewall management and kernel hardening.
*   **Storage Optimization:** BFQ I/O scheduler and optimized USB auto-mounting for Docker data.

## Building and Running

The suite consists of three main idempotent Bash scripts:

*   **Setup/Provisioning:** 
    ```bash
    sudo ./setup.sh
    ```
    Installs dependencies, Docker, Node.js, and prepares the system. It handles USB mounting and can optionally install Ollama for local LLM inference.
    
*   **Optimization/Tuning:**
    ```bash
    sudo ./optimize.sh
    ```
    Applies kernel tweaks, memory management rules, network enhancements (BBR, Tailscale fixes), and firewall configurations.
    
*   **Diagnostics/Auditing:**
    ```bash
    sudo ./diag.sh
    ```
    Provides a health score, checking SMART statuses, zombie processes, failed systemd units, and network connectivity.

### Testing

Tests are written using the [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) framework. They are located in the `tests/` directory:
```bash
# Run tests (assuming bats is installed)
bats tests/
```

## Development Conventions

*   **Language & Framework:** Pure Bash (`#!/bin/bash`).
*   **Root Requirement:** All primary scripts (`setup.sh`, `optimize.sh`, `diag.sh`) must be run with root privileges (`sudo`).
*   **Logging:** The project utilizes a custom logging library located in `lib/utils.sh`. When modifying or adding scripts, always use these helper functions instead of standard `echo` statements:
    *   `log_info "message"`
    *   `log_pass "message"`
    *   `log_fail "message"`
    *   `log_warn "message"`
    *   `log_error "message"` (exits with 1)
*   **Linting:** Bash scripts are strictly linted using `shellcheck`. Inline ignores (e.g., `# shellcheck disable=SC...`) are used when necessary.
*   **Idempotency:** Any new configuration or installation step must be idempotent (i.e., it should check if the change has already been applied before applying it).
*   **CI/CD:** The project uses GitHub Actions (`.github/workflows/`) for automated linting, testing, and releases. Ensure changes pass the CI pipeline before merging.
